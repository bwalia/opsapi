-- Daybook demo: tax data for each vertical's clients. Run seed-daybook.lua first.
-- Safe to re-run, and that's how the demo is reset: for every client (and the demo
-- login's own rows in that workspace) it deletes the tax rows and writes them again
-- from the vertical's deterministic generators, so every run gives the same demo.
--
--   every vertical: lapis exec 'assert(loadfile("/tmp/daybook-seed/seed-daybook-data.lua"))()'
--   one vertical:   lapis exec 'assert(loadfile("/tmp/daybook-seed/seed-daybook-data.lua"))("practice")'
--
-- Per client it writes what the app itself would have written:
--   tax_user_profiles (+ _profiles)   the profile (landlord, sole trader, …), "NINO on file"
--                                     with no digits stored or shown
--   tax_agent_sessions                what the client told the AI assistant (income types,
--                                     mortgage interest, salary): the estimate reads this
--   tax_bank_accounts / tax_statements / tax_transactions
--                                     classified lines with category, HMRC box, confidence,
--                                     who classified them and why, review state, notes
--   vat_registrations / VAT coding / vat_returns   for clients with `vat`
--   tax_filing_requests               the accountant's queue, with the frozen figures built by
--                                     lib/tax-report (the same code a real request uses)
-- and, for the demo login (viewer): a copy of one client's book (vertical.viewer_book) and
-- an HMRC-confirmed VAT agent link to every VAT client, so VAT → VAT clients works read-only.
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local slug_arg = ...
local SRC = debug.getinfo(1, "S").source
local DIR = (SRC:match("^@(.*/)")) or "/tmp/daybook-seed/"
local C = assert(loadfile(DIR .. "daybook-common.lua"))()
local verticals = C.verticals(DIR, slug_arg)

local function one(sql, ...) return (db.query(sql, ...) or {})[1] end
local function jsonb(v) return db.raw(db.escape_literal(cjson.encode(v)) .. "::jsonb") end
local function r2(x) local s = x < 0 and -1 or 1; return s * math.floor(math.abs(x) * 100 + 0.5) / 100 end
local function iso_days_ago(d) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - math.floor((d or 0) * 86400)) end
local function ts_days_ago(d) return os.date("!%Y-%m-%d %H:%M:%S", os.time() - math.floor((d or 0) * 86400)) end

-- ── helpers handed to the vertical generators (see verticals/practice.lua) ──

local G = {}
local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function days_in(y, m)
    if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then return 29 end
    return DAYS[m]
end
function G.day(y, m, d)
    while m > 12 do m = m - 12; y = y + 1 end
    while m < 1 do m = m + 12; y = y - 1 end
    d = math.max(1, math.min(d, days_in(y, m)))
    return string.format("%04d-%02d-%02d", y, m, d)
end
-- April .. March of a "2025-26" tax year.
function G.months(year)
    local a = tonumber(year:sub(1, 4))
    local out = {}
    for m = 4, 12 do out[#out + 1] = { a, m } end
    for m = 1, 3 do out[#out + 1] = { a + 1, m } end
    return out
end
-- Deterministic PRNG (an LCG), so data doesn't depend on the runtime's math.random.
function G.rng(seed)
    local s = (seed or 1) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    local r = {}
    local function nxt() s = (s * 48271) % 2147483647; return s end
    function r:int(a, b) return a + nxt() % (b - a + 1) end
    function r:money(lo, hi) return r2(lo + (nxt() % 100000) / 100000 * (hi - lo)) end
    function r:pick(list) return list[1 + nxt() % #list] end
    function r:chance(p) return (nxt() % 10000) / 10000 < p end
    return r
end

-- ── reference data ─────────────────────────────────────────────────────────

local CATS = {}
for _, c in ipairs(db.query([[SELECT c.key, c.is_tax_deductible, h.key AS hmrc
    FROM tax_categories c LEFT JOIN tax_hmrc_categories h ON h.id = c.hmrc_category_id
    WHERE c.is_active = true AND c.namespace_id IS NULL]])) do
    CATS[c.key] = { deductible = c.is_tax_deductible == true or c.is_tax_deductible == "t", hmrc = c.hmrc }
end

local VAT = require("lib.vat")
local ok_vrq, VatReturnQueries = pcall(require, "queries.VatReturnQueries")
local TaxReport = require("lib.tax-report")

-- A VRN that passes HMRC's modulus-97 check, made from a 7-digit stem.
local function vrn_from(stem)
    stem = tostring(stem):sub(1, 7)
    local total = 0
    for i = 1, 7 do total = total + tonumber(stem:sub(i, i)) * (9 - i) end
    for check = 0, 99 do
        if (total + check) % 97 == 0 then return stem .. string.format("%02d", check) end
    end
end

-- ── wipe ───────────────────────────────────────────────────────────────────

-- Every tax row of one person in one workspace (all of them for clients, who live in
-- one workspace only; the demo login's are limited to this workspace).
local function wipe(ns_id, user_id, user_uuid)
    local txn = "SELECT uuid FROM tax_transactions WHERE user_id = ? AND namespace_id = ?"
    db.query("DELETE FROM tax_transaction_audit WHERE namespace_id = ? AND transaction_uuid IN (" .. txn .. ")",
        ns_id, user_id, ns_id)
    db.query("DELETE FROM tax_audit_logs WHERE user_id = ?", user_id)
    db.query("DELETE FROM tax_transactions WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM tax_statements WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM tax_bank_accounts WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM tax_agent_messages WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM tax_agent_sessions WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM tax_filing_requests WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM my_incomes WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM tax_income_records WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM tax_user_custom_categories WHERE user_uuid = ? AND namespace_id = ?", user_uuid, ns_id)
    for _, reg in ipairs(db.query("SELECT id FROM vat_registrations WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)) do
        db.query("DELETE FROM vat_returns WHERE registration_id = ?", reg.id)
        db.query("DELETE FROM vat_adjustments WHERE registration_id = ?", reg.id)
        db.query("DELETE FROM vat_agent_clients WHERE registration_id = ?", reg.id)
    end
    db.query("DELETE FROM vat_registrations WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM vat_agent_clients WHERE agent_user_id = ? AND namespace_id = ?", user_id, ns_id)
    db.query("DELETE FROM vat_agents WHERE user_id = ? AND namespace_id = ?", user_id, ns_id)
end

-- ── one client's book ──────────────────────────────────────────────────────

local function write_profile(ns_id, user, client)
    -- One profile row per person (tax_user_profiles is unique on user_id).
    db.query("DELETE FROM tax_user_profiles WHERE user_id = ?", user.id)
    db.query("DELETE FROM tax_user_profiles_profiles WHERE user_id = ?", user.id)
    db.insert("tax_user_profiles", {
        uuid = Global.generateUUID(), user_id = user.id, user_uuid = user.uuid, namespace_id = ns_id,
        has_nino = true, nino_last4 = db.NULL, hmrc_connected = false, default_tax_year = client.tax_year,
        default_profile_key = client.profile_key, business_description = client.business_description,
        mtd_enabled = true, created_at = db.raw("NOW()"), updated_at = db.raw("NOW()"),
    })
    db.insert("tax_user_profiles_profiles", { user_id = user.id, profile_key = client.profile_key,
        namespace_id = ns_id, is_primary = true, created_at = db.raw("NOW()") })
end

local function write_session(ns_id, user_id, client, year, messages)
    local profile = {}
    for k, v in pairs(client.profile or {}) do profile[k] = v end
    profile.income_types = client.income_types
    local uuid = Global.generateUUID()
    db.query([[INSERT INTO tax_agent_sessions (uuid, namespace_id, user_id, tax_year, status, archived,
            income_types, profile, progress, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'active', false, ?, ?, '{}'::jsonb, NOW(), NOW())]],
        uuid, ns_id, user_id, year, jsonb(client.income_types), jsonb(profile))
    if messages then
        local s = one("SELECT id FROM tax_agent_sessions WHERE uuid = ?", uuid)
        for i, m in ipairs(messages) do
            db.insert("tax_agent_messages", { uuid = Global.generateUUID(), session_id = s.id, namespace_id = ns_id,
                user_id = user_id, role = m[1], content = m[2],
                created_at = db.raw("NOW() - make_interval(mins => " .. ((#messages - i + 1) * 3) .. ")") })
        end
    end
end

-- Generate the client's lines for each year and write accounts, statements, lines.
-- Returns { [year] = count }, plus the VAT lines to code later.
local function write_book(ns_id, user, client, ctx)
    local accounts = {}
    for key, a in pairs(client.accounts) do
        local uuid = Global.generateUUID()
        db.insert("tax_bank_accounts", { uuid = uuid, user_id = user.id, namespace_id = ns_id, bank_name = a.bank,
            account_name = a.name, account_number = a.last4, sort_code = a.sort, account_type = a.type or "BUSINESS",
            currency = "GBP", is_primary = (key == "main"), is_active = true })
        accounts[key] = { spec = a, id = one("SELECT id FROM tax_bank_accounts WHERE uuid = ?", uuid).id }
    end

    local counts = {}
    for _, year in ipairs(client.years or { client.tax_year }) do
        local lines = {}
        local add = function(t)
            assert(t.date and t.desc and t.amount and t.cat, "line needs date, desc, amount and cat")
            assert(CATS[t.cat], "unknown category " .. tostring(t.cat))
            t.amount = r2(t.amount)
            lines[#lines + 1] = t
        end
        client.generate(G, add, year)
        table.sort(lines, function(a, b)
            if a.date ~= b.date then return a.date < b.date end
            return a.desc < b.desc
        end)

        -- Statements: one per account per `statement_months` months (default 1).
        local by_stmt, order = {}, {}
        for _, t in ipairs(lines) do
            local acct = accounts[t.acct or "main"]
            assert(acct, "unknown account " .. tostring(t.acct))
            local per = acct.spec.statement_months or 1
            local y, m = t.date:match("^(%d+)-(%d+)")
            y, m = tonumber(y), tonumber(m)
            local idx = math.floor((((y * 12 + m - 1) - (tonumber(year:sub(1, 4)) * 12 + 3))) / per)
            local k = (t.acct or "main") .. "#" .. idx
            if not by_stmt[k] then by_stmt[k] = { acct = acct, idx = idx, lines = {} }; order[#order + 1] = k end
            table.insert(by_stmt[k].lines, t)
        end

        local balance = {}
        local this_year = (year == client.tax_year)
        local handler_id = ctx.handler_id
        for _, k in ipairs(order) do
            local st = by_stmt[k]
            local acct = st.acct
            local per = acct.spec.statement_months or 1
            local a0 = tonumber(year:sub(1, 4))
            local first_m = 4 + st.idx * per
            local ps = G.day(a0, first_m, 1)
            local pe = G.day(a0, first_m + per - 1, 31)
            local opening = balance[acct.id] or acct.spec.opening or 0
            local close = opening
            for _, t in ipairs(st.lines) do close = close + (t.dir == "CREDIT" and t.amount or -t.amount) end
            local label = (per == 1) and os.date("%b %Y", os.time{ year = a0 + math.floor((first_m - 1) / 12),
                month = (first_m - 1) % 12 + 1, day = 1 }) or (ps .. " to " .. pe)
            local suuid = Global.generateUUID()
            db.insert("tax_statements", {
                uuid = suuid, bank_account_id = acct.id, user_id = user.id, namespace_id = ns_id,
                file_name = acct.spec.bank .. " statement " .. label .. ".pdf", file_type = "application/pdf",
                file_size_bytes = 48000 + #st.lines * 900, statement_date = pe, period_start = ps, period_end = pe,
                opening_balance = r2(opening), closing_balance = r2(close),
                processing_status = "COMPLETED", validation_status = "VALIDATED",
                workflow_step = this_year and (client.workflow or "CLASSIFIED") or "FILED",
                tax_year = year, is_filed = (not this_year) or client.workflow == "FILED",
                uploaded_at = db.raw("NOW() - interval '60 days'"), processed_at = db.raw("NOW() - interval '60 days'"),
            })
            local sid = one("SELECT id FROM tax_statements WHERE uuid = ?", suuid).id
            balance[acct.id] = close

            local running = opening
            for _, t in ipairs(st.lines) do
                running = running + (t.dir == "CREDIT" and t.amount or -t.amount)
                local cat = CATS[t.cat]
                local status = t.status or "classified"
                local cs = ({ confirmed = "CONFIRMED", classified = "CLASSIFIED", review = "NEEDS_REVIEW",
                    resolved = "CONFIRMED" })[status]
                local deductible = t.deductible
                if deductible == nil then deductible = (t.dir == "DEBIT") and cat.deductible or false end
                local reviewed = (status == "resolved")
                local row = {
                    uuid = Global.generateUUID(), statement_id = sid, bank_account_id = acct.id, user_id = user.id,
                    namespace_id = ns_id, transaction_date = t.date, description = t.desc, amount = t.amount,
                    balance = r2(running), transaction_type = t.dir, category = t.cat, hmrc_category = cat.hmrc or db.NULL,
                    confidence_score = t.conf or 0.9, classified_by = t.by or "rule_engine",
                    classification_source = (t.by == "learned") and "memory" or (t.by == "agent" and "llm" or "rules"),
                    cleaned_merchant_name = (t.desc:gsub("%s+%d+$", "")),
                    is_tax_deductible = deductible, is_business_expense = (t.business ~= false),
                    llm_response = cjson.encode({ reasoning = t.reason or (t.cat:gsub("_", " ")),
                        category = t.cat, confidence = t.conf or 0.9 }),
                    confirmation_status = "CONFIRMED", confirmed_at = db.raw("NOW() - interval '59 days'"),
                    classification_status = cs,
                    is_manually_reviewed = reviewed, user_notes = t.note or db.NULL,
                }
                if cs == "CONFIRMED" then
                    row.classification_confirmed_at = db.raw("NOW() - interval '50 days'")
                    row.classification_confirmed_by = reviewed and handler_id or user.id
                end
                if reviewed then
                    row.reviewed_by = handler_id; row.reviewed_at = db.raw("NOW() - interval '47 days'")
                    row.modified_by_role = "accountant"; row.modified_at = db.raw("NOW() - interval '47 days'")
                end
                if t.vat and ctx.vat_reg then
                    row.vat_registration_id = ctx.vat_reg.id
                    if t.vat.review then
                        row.vat_review = true
                        row.vat_review_reasons = jsonb(t.vat.reasons or {})
                    else
                        local split = assert(VAT.split(t.amount, t.vat.code))
                        local def = VAT.code(t.vat.code)
                        row.vat_code = t.vat.code; row.net_amount = split.net; row.vat_amount = split.vat
                        row.vat_notional = split.notional_vat; row.vat_reclaimable_pct = def.reclaimable
                        row.vat_source = t.vat.source or "rule"; row.vat_confidence = t.vat.conf or 1
                        row.vat_reason = t.vat.reason or db.NULL; row.vat_review = false
                        row.vat_decided_at = db.raw("NOW() - interval '40 days'")
                    end
                end
                db.insert("tax_transactions", row)
            end
        end
        counts[year] = #lines
    end
    return counts
end

local function write_vat(ns_id, user, client)
    local v = client.vat
    local stem = tostring(4000000 + (user.id * 7919) % 999999)
    db.insert("vat_registrations", {
        uuid = Global.generateUUID(), namespace_id = ns_id, user_id = user.id, business_name = v.business_name,
        vrn = vrn_from(stem), effective_date = v.effective_date, scheme = v.scheme or "standard",
        stagger = v.stagger or "quarterly_mar", flat_rate_first_year = false, limited_cost_trader = false,
        partially_exempt = false, status = "active", created_by = user.id, sales_from = "bank",
        business_address = v.business_address,
    })
    return one("SELECT * FROM vat_registrations WHERE user_id = ? AND namespace_id = ? ORDER BY id DESC LIMIT 1", user.id, ns_id)
end

local function write_vat_returns(reg, client, handler_id)
    if not ok_vrq then print("  VAT: VatReturnQueries not loaded, returns skipped"); return end
    for _, rt in ipairs(client.vat.returns or {}) do
        local res, err = VatReturnQueries.save_draft(reg, rt.start, rt["end"], handler_id, {})
        if not res then print("  VAT " .. rt.start .. ": " .. tostring(err)) end
        if res and rt.state == "submitted" then
            local key = "25A1"
            db.query([[UPDATE vat_returns SET status = 'submitted', period_key = ?, submitted_by = ?,
                    submitted_at = NOW() - interval '120 days', hmrc_receipt = ?
                WHERE registration_id = ? AND period_start = ? AND period_end = ?]],
                key, handler_id, cjson.encode({ processingDate = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 120 * 86400),
                    formBundleNumber = "256660290587", chargeRefNumber = "XQ002610015187", sandbox = true }),
                reg.id, rt.start, rt["end"])
        end
    end
end

local function write_filing(ns_id, user, client, handler_id)
    local f = client.filing
    local report, err = TaxReport.build({ namespace_id = ns_id, user_id = user.id, tax_year = client.tax_year,
        has_permission = function() return true end })
    if not report then print("  filing " .. client.key .. ": " .. tostring(err)); return end
    local timeline, declared = {}, nil
    for _, e in ipairs(f.timeline or {}) do
        local entry = { type = e.type or "status", status = e.status, by = e.by, at = iso_days_ago(e.days_ago), text = e.text }
        if e.hmrc_reference then entry.text = "HMRC reference: " .. e.hmrc_reference end
        if not declared and e.status == "submitted" then declared = e.days_ago end
        timeline[#timeline + 1] = entry
    end
    db.query([[INSERT INTO tax_filing_requests (uuid, namespace_id, user_id, tax_year, status, snapshot, figures_hash,
            our_total_due, declaration_text, declared_at, hmrc_reference, hmrc_total_due, client_message, updates,
            handled_by, filed_at, created_at, updated_at)
        VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())]],
        ns_id, user.id, client.tax_year, f.status, jsonb(report), TaxReport.hash(report),
        report.summary.total_tax_and_nic,
        "My figures are correct and complete. I authorise this service's accountant to file my Self Assessment "
            .. "tax return with HMRC on my behalf, as my agent. I understand I remain responsible for my return "
            .. "and may have to pay penalties if I give false information.",
        ts_days_ago(declared or 1), f.hmrc_reference or db.NULL,
        f.status == "filed" and report.summary.total_tax_and_nic or db.NULL, f.client_message or db.NULL,
        jsonb(timeline), (f.status ~= "submitted") and handler_id or db.NULL,
        f.filed_days_ago and ts_days_ago(f.filed_days_ago) or db.NULL, ts_days_ago(declared or 1))
    return report
end

-- ── run ────────────────────────────────────────────────────────────────────

for _, v in ipairs(verticals) do
    local ns = one("SELECT id, slug FROM namespaces WHERE slug = ?", v.namespace.slug)
    assert(ns, "workspace " .. v.namespace.slug .. " not found: run seed-daybook.lua first")
    local handler = one("SELECT id FROM users WHERE email = ?", v.handler or "")
    local handler_id = handler and handler.id or db.NULL
    local viewer = one("SELECT id, uuid FROM users WHERE email = ?", C.DEMO_EMAIL)
    assert(viewer, C.DEMO_EMAIL .. " not found: run seed-daybook.lua first")

    db.query("BEGIN")
    local ok, err = pcall(function()
        wipe(ns.id, viewer.id, viewer.uuid)
        local vat_clients = {}
        for _, c in ipairs(v.clients) do
            c.tax_year = c.tax_year or v.tax_year
            local user = one("SELECT id, uuid FROM users WHERE email = ?", c.email)
            assert(user, c.email .. " not found: run seed-daybook.lua first")
            wipe(ns.id, user.id, user.uuid)
            write_profile(ns.id, user, c)
            for _, y in ipairs(c.years or { c.tax_year }) do write_session(ns.id, user.id, c, y) end
            local reg = c.vat and write_vat(ns.id, user, c) or nil
            local counts = write_book(ns.id, user, c, { handler_id = handler_id, vat_reg = reg })
            if reg then
                write_vat_returns(reg, c, handler_id)
                vat_clients[#vat_clients + 1] = reg
            end
            local report = c.filing and write_filing(ns.id, user, c, handler_id)
            local parts = {}
            for y, n in pairs(counts) do parts[#parts + 1] = y .. ":" .. n end
            table.sort(parts)
            print(("  %s %s %s lines[%s]%s%s"):format(c.key, c.first, c.last, table.concat(parts, " "),
                reg and (" VRN " .. reg.vrn) or "",
                report and (" filing=" .. c.filing.status .. " due £" .. tostring(report.summary.total_tax_and_nic)) or ""))
        end

        -- The demo login's own book: a copy of one client's (see verticals/practice.lua).
        if v.viewer_book then
            local src
            for _, c in ipairs(v.clients) do if c.key == v.viewer_book then src = c end end
            assert(src, "viewer_book " .. v.viewer_book .. " is not a client of " .. v.slug)
            local copy = {}
            for k, val in pairs(src) do copy[k] = val end
            copy.filing, copy.vat = nil, nil
            write_profile(ns.id, viewer, copy)
            write_session(ns.id, viewer.id, copy, copy.tax_year, {
                { "assistant", "Hello! I'm the Daybook assistant. This is a sample client's book (a copy of "
                    .. src.first .. " " .. src.last .. "'s), so you can see what a client sees. Which kinds of income did you have in "
                    .. copy.tax_year .. "?" },
                { "user", "I'm a self-employed IT consultant. Everything goes through one Monzo account, personal spending too." },
                { "assistant", "Thanks. I've read both statements and sorted every line. Personal spending is kept out of the "
                    .. "business figures. A few lines need you: open Transactions and filter by \"Needs review\"." },
            })
            local counts = write_book(ns.id, viewer, copy, { handler_id = handler_id })
            print(("  viewer book: copy of %s, %d lines"):format(v.viewer_book, counts[copy.tax_year] or 0))
        end

        -- The demo login acts as the practice's VAT agent for every VAT client.
        if #vat_clients > 0 then
            db.insert("vat_agents", { namespace_id = ns.id, user_id = viewer.id, arn = v.vat_agent_arn or "XARN0000001" })
            for _, reg in ipairs(vat_clients) do
                db.insert("vat_agent_clients", { uuid = Global.generateUUID(), namespace_id = ns.id, agent_user_id = viewer.id,
                    arn = v.vat_agent_arn or "XARN0000001", registration_id = reg.id, client_vrn = reg.vrn,
                    known_fact = reg.effective_date, status = "active", last_checked_at = db.raw("NOW()"),
                    created_at = db.raw("NOW() - interval '200 days'") })
            end
        end
    end)
    if ok then
        db.query("COMMIT")
        print(("daybook %s: data seeded in %s"):format(v.slug, ns.slug))
    else
        db.query("ROLLBACK")
        error("daybook " .. v.slug .. ": " .. tostring(err))
    end
end
