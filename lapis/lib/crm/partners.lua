--[[
    Partners and referrals: pass a deal to a company that fulfils it, earn a commission
    =================================================================================

    Partner   a CRM account (crm_accounts) with a profile (crm_partner_profiles):
              what it supplies, categories, regions, who receives referrals and
              the default commission (a percentage of the deal, or a fixed fee).
    Referral  a deal — or a lead not converted yet — passed to one partner
              (crm_deal_referrals), followed to the commission being paid:

        draft -> sent -> accepted -> won -> commission_invoiced -> commission_paid
                     \-> declined     \-> lost
        any open state -> cancelled

    Sending emails the partner a summary and a private link
    (/partner-referral/<token>) to accept or decline, and later to say they won
    or lost it, with the final value. Only a hash of the link's secret is stored.

    Privacy (UK GDPR): the customer's name and contact details go to the
    partner only when share_contact is on, and that needs a person to confirm
    the customer agreed (consent_confirmed). Otherwise the partner gets what
    is wanted and the size, without who it is for, and we connect them after.

    Commission invoice: billed to the partner through core invoicing, linked
    to the deal; when it is paid (invoice.paid event) the referral closes.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local U = require("lib.crm.util")

local Partners = {}

Partners.STATUSES = { "draft", "sent", "accepted", "declined", "won", "lost", "commission_invoiced", "commission_paid", "cancelled" }
Partners.LABELS = {
    draft = "Draft", sent = "Sent to partner", accepted = "Partner accepted", declined = "Partner declined",
    won = "Partner won it", lost = "Partner lost it", commission_invoiced = "Commission invoiced",
    commission_paid = "Commission paid", cancelled = "Cancelled",
}
-- Moves a person may make by hand (the partner's link makes the same ones).
local MOVES = {
    draft = { sent = true, cancelled = true },
    sent = { accepted = true, declined = true, cancelled = true },
    accepted = { won = true, lost = true, cancelled = true },
    won = { lost = true },
    commission_invoiced = { commission_paid = true },
}
local TOKEN_DAYS = 90

local function available()
    return U.has_table("crm_partner_profiles") and U.has_table("crm_deal_referrals")
end
Partners.available = available

local function email_ok(v)
    return type(v) == "string" and #v <= 254 and v:match("^[^%s@<>]+@[^%s@<>]+%.[^%s@<>]+$") ~= nil
end

local function sha256_hex(s)
    local sha = require("resty.sha256"):new()
    sha:update(s)
    return require("resty.string").to_hex(sha:final())
end

local function list_of(v, max_items, max_len)
    local out = {}
    if type(v) == "table" then
        for _, s in ipairs(v) do
            local t = U.text(s, max_len)
            if t and #out < max_items then out[#out + 1] = t end
        end
    elseif type(v) == "string" then
        for s in v:gmatch("[^,]+") do
            local t = U.text(s, max_len)
            if t and #out < max_items then out[#out + 1] = t end
        end
    end
    return U.array(out)
end

function Partners.commission(kind, rate, value)
    rate, value = tonumber(rate) or 0, tonumber(value)
    if kind == "fixed" then return U.money(rate) end
    if not value then return nil end
    return U.money(value * rate / 100)
end

-- ---------------------------------------------------------------------------
-- Directory
-- ---------------------------------------------------------------------------

local PARTNER_SQL = [[
    SELECT p.uuid, p.categories, p.offering, p.regions, p.referral_email, p.referral_contact_name, p.commission_type,
           p.commission_value, p.currency, p.terms, p.active, p.created_at, p.updated_at,
           a.uuid AS account_uuid, a.name, a.website, a.email AS account_email, a.phone,
           (SELECT COUNT(*) FROM crm_deal_referrals r WHERE r.partner_account_id = a.id AND r.status <> 'cancelled') AS referrals,
           (SELECT COUNT(*) FROM crm_deal_referrals r WHERE r.partner_account_id = a.id
              AND r.status IN ('won','commission_invoiced','commission_paid')) AS won,
           (SELECT COALESCE(SUM(r.commission_amount), 0) FROM crm_deal_referrals r WHERE r.partner_account_id = a.id
              AND r.status = 'commission_paid') AS commission_paid
    FROM crm_partner_profiles p JOIN crm_accounts a ON a.id = p.account_id AND a.deleted_at IS NULL
]]

local function present(p)
    p.categories = U.array(U.json(p.categories, {}))
    p.regions = U.array(U.json(p.regions, {}))
    p.referrals, p.won = tonumber(p.referrals) or 0, tonumber(p.won) or 0
    p.commission_paid = tonumber(p.commission_paid) or 0
    return p
end

function Partners.list(ns, q)
    q = q or {}
    local where, args = { "p.namespace_id = ?" }, { ns }
    if q.active ~= "all" then where[#where + 1] = "p.active" end
    if U.nz(q.search) then
        local s = "%" .. U.text(q.search, 100):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(a.name ILIKE ? OR p.offering ILIKE ? OR p.categories::text ILIKE ?)"
        args[#args + 1], args[#args + 2], args[#args + 3] = s, s, s
    end
    local rows = db.query(PARTNER_SQL .. " WHERE " .. table.concat(where, " AND ") .. " ORDER BY lower(a.name) LIMIT 500",
        unpack(args))
    for i, r in ipairs(rows) do rows[i] = present(r) end
    return U.array(rows)
end

function Partners.get(ns, uuid)
    if not U.is_uuid(uuid) then return nil end
    local row = U.one(PARTNER_SQL .. " WHERE p.namespace_id = ? AND p.uuid = ?::uuid", ns, uuid)
    return row and present(row) or nil
end

--- Create a partner (a new CRM account, or an existing one by account_uuid)
-- or update one (uuid given). @return partner | nil, err
function Partners.save(ns, actor, b, uuid)
    if not available() then return U.fail(409, "PARTNERS_OFF", "Partners need the CRM module in this deployment") end
    b = type(b) == "table" and b or {}
    local e = {}
    local kind = b.commission_type ~= nil and b.commission_type or nil
    if kind ~= nil and kind ~= "percent" and kind ~= "fixed" then e.commission_type = "percent or fixed" end
    local value = b.commission_value ~= nil and tonumber(b.commission_value) or nil
    if b.commission_value ~= nil and (not value or value < 0 or value >= 1e13) then e.commission_value = "a positive number" end
    if (kind or "percent") == "percent" and value and value > 100 then e.commission_value = "0 to 100 percent" end
    local email = b.referral_email
    if email ~= nil and email ~= cjson.null and email ~= "" and not email_ok(email) then e.referral_email = "a valid email" end
    local currency = b.currency ~= nil and b.currency ~= cjson.null and tostring(b.currency):upper() or nil
    if currency and currency ~= "" and not currency:match("^%u%u%u$") then e.currency = "3-letter code, e.g. GBP" end
    if next(e) then return U.fail(422, "PARTNER_INVALID", "Some fields need fixing", e) end

    local saved, err = U.tx(function()
        local profile
        if uuid then
            profile = U.one("SELECT * FROM crm_partner_profiles WHERE namespace_id = ? AND uuid = ?::uuid FOR UPDATE", ns, uuid)
            if not profile then return U.fail(404, "PARTNER_NOT_FOUND", "Partner not found") end
        end
        local account_id = profile and profile.account_id
        if not account_id then
            if U.nz(b.account_uuid) then
                local acc = U.one("SELECT id FROM crm_accounts WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL",
                    ns, b.account_uuid)
                if not acc then return U.fail(422, "PARTNER_INVALID", "That company isn't in your CRM", { account_uuid = "not found" }) end
                if U.one("SELECT 1 AS x FROM crm_partner_profiles WHERE account_id = ?", acc.id) then
                    return U.fail(409, "PARTNER_EXISTS", "That company is already a partner")
                end
                account_id = acc.id
            else
                local name = U.text(b.name, 200)
                if not name then return U.fail(422, "PARTNER_INVALID", "Give the partner a name", { name = "required" }) end
                local existing = U.one([[SELECT a.id, p.id AS profile_id FROM crm_accounts a
                    LEFT JOIN crm_partner_profiles p ON p.account_id = a.id
                    WHERE a.namespace_id = ? AND lower(a.name) = lower(?) AND a.deleted_at IS NULL LIMIT 1]], ns, name)
                if existing and not U.null(existing.profile_id) then
                    return U.fail(409, "PARTNER_EXISTS", "A partner with that name already exists")
                end
                if existing then
                    account_id = existing.id
                else
                    local website = U.text(b.website, 300)
                    if website and not website:match("^https?://") then website = "https://" .. website end
                    account_id = db.query([[
                        INSERT INTO crm_accounts (uuid, namespace_id, name, website, email, phone, owner_user_uuid, status,
                            metadata, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 'active', '{"partner":true}'::jsonb, NOW(), NOW()) RETURNING id
                    ]], require("helper.global").generateUUID(), ns, name, website or db.NULL,
                        email_ok(b.account_email) and b.account_email or db.NULL, U.text(b.phone, 40) or db.NULL,
                        actor or db.NULL)[1].id
                end
            end
        elseif U.nz(b.name) then
            db.query("UPDATE crm_accounts SET name = ?, updated_at = NOW() WHERE id = ?", U.text(b.name, 200), account_id)
        end
        local set = {
            categories = b.categories ~= nil and U.enc(list_of(b.categories, 30, 60)) or nil,
            offering = b.offering ~= nil and (U.text(b.offering, 2000) or db.NULL) or nil,
            regions = b.regions ~= nil and U.enc(list_of(b.regions, 30, 60)) or nil,
            referral_email = email ~= nil and (email_ok(email) and email:lower() or db.NULL) or nil,
            referral_contact_name = b.referral_contact_name ~= nil and (U.text(b.referral_contact_name, 120) or db.NULL) or nil,
            commission_type = kind,
            commission_value = value,
            currency = currency ~= nil and (currency ~= "" and currency or db.NULL) or nil,
            terms = b.terms ~= nil and (U.text(b.terms, 2000) or db.NULL) or nil,
        }
        if b.active ~= nil then set.active = b.active == true end
        if profile then
            set.updated_at = db.raw("NOW()")
            db.update("crm_partner_profiles", set, { id = profile.id })
            return profile.uuid
        end
        set.namespace_id, set.account_id, set.created_by_uuid = ns, account_id, actor or db.NULL
        if set.active == nil then set.active = true end
        return db.insert("crm_partner_profiles", set, { returning = { "uuid" } })[1].uuid
    end)
    if not saved then return nil, err end
    return Partners.get(ns, saved)
end

-- ---------------------------------------------------------------------------
-- Referrals
-- ---------------------------------------------------------------------------

local REFERRAL_SQL = [[
    SELECT r.uuid, r.status, r.deal_value, r.currency, r.commission_type, r.commission_value, r.commission_amount,
           r.message, r.consent_confirmed_at, r.partner_reference, r.partner_notes, r.ai_reason, r.sent_at,
           r.responded_at, r.won_at, r.closed_at, r.created_at, r.updated_at, r.response_token_expires_at,
           a.name AS partner_name, p.uuid AS partner_uuid, p.referral_email,
           d.uuid AS deal_uuid, d.name AS deal_name, l.uuid AS lead_uuid,
           i.uuid AS invoice_uuid, i.invoice_number, i.status AS invoice_status
    FROM crm_deal_referrals r
    JOIN crm_accounts a ON a.id = r.partner_account_id
    LEFT JOIN crm_partner_profiles p ON p.account_id = a.id
    LEFT JOIN crm_deals d ON d.id = r.deal_id
    LEFT JOIN crm_leads l ON l.id = r.lead_id
    LEFT JOIN invoices i ON i.id = r.invoice_id
]]

local function present_ref(r)
    r.status_label = Partners.LABELS[r.status] or r.status
    r.consent_confirmed = not U.null(r.consent_confirmed_at)
    return r
end

local function referral_sql()
    -- invoices only exists with the invoicing feature.
    if U.has_table("invoices") then return REFERRAL_SQL end
    return (REFERRAL_SQL:gsub("i%.uuid AS invoice_uuid, i%.invoice_number, i%.status AS invoice_status",
        "NULL AS invoice_uuid, NULL AS invoice_number, NULL AS invoice_status"):gsub("LEFT JOIN invoices i ON i%.id = r%.invoice_id", ""))
end

function Partners.referral(ns, uuid)
    if not U.is_uuid(uuid) then return nil end
    local r = U.one(referral_sql() .. " WHERE r.namespace_id = ? AND r.uuid = ?::uuid", ns, uuid)
    return r and present_ref(r) or nil
end

--- Referrals of a deal or a lead (and, for a converted lead, its deal).
function Partners.referrals_for(ns, deal_id, lead_id)
    if not available() then return U.array({}) end
    local rows = db.query(referral_sql() .. [[ WHERE r.namespace_id = ? AND (r.deal_id = ? OR r.lead_id = ?)
        ORDER BY r.created_at DESC LIMIT 50]], ns, deal_id or -1, lead_id or -1)
    for i, r in ipairs(rows) do rows[i] = present_ref(r) end
    return U.array(rows)
end

--- Referrals across the workspace (for the partners page), newest first.
function Partners.referrals(ns, q)
    if not available() then return U.array({}) end
    q = q or {}
    local where, args = { "r.namespace_id = ?" }, { ns }
    if U.nz(q.status) then where[#where + 1] = "r.status = ?"; args[#args + 1] = U.text(q.status, 40) end
    if U.is_uuid(q.partner_uuid) then where[#where + 1] = "p.uuid = ?::uuid"; args[#args + 1] = q.partner_uuid end
    local rows = db.query(referral_sql() .. " WHERE " .. table.concat(where, " AND ") .. " ORDER BY r.created_at DESC LIMIT 200",
        unpack(args))
    for i, r in ipairs(rows) do rows[i] = present_ref(r) end
    return U.array(rows)
end

local function subject_of(ns, b)
    if U.nz(b.deal_uuid) then
        local d = U.one("SELECT * FROM crm_deals WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", ns, b.deal_uuid)
        if not d then return U.fail(404, "DEAL_NOT_FOUND", "Deal not found") end
        local lead = not U.null(d.lead_id) and U.one("SELECT * FROM crm_leads WHERE id = ?", d.lead_id) or nil
        return { deal = d, lead = lead }
    end
    if U.nz(b.lead_uuid) then
        local l = U.one("SELECT * FROM crm_leads WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", ns, b.lead_uuid)
        if not l then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        local d = not U.null(l.converted_deal_id) and U.one("SELECT * FROM crm_deals WHERE id = ?", l.converted_deal_id) or nil
        return { deal = d, lead = l }
    end
    return U.fail(422, "REFERRAL_SUBJECT", "Say which deal or lead to pass on", { deal_uuid = "or lead_uuid" })
end

--- The lead/deal a referral is about, for permission checks in the route.
function Partners.subject(ns, b) return subject_of(ns, b) end

--- Create a referral, and send it unless `send` is false.
-- b = { deal_uuid | lead_uuid, partner_uuid, deal_value?, commission_type?, commission_value?, message?,
--       share_contact?, consent_confirmed?, ai_reason?, send? }
function Partners.refer(ns, actor, b)
    if not available() then return U.fail(409, "PARTNERS_OFF", "Partners need the CRM module in this deployment") end
    b = type(b) == "table" and b or {}
    local subject, serr = subject_of(ns, b)
    if not subject then return nil, serr end
    local partner = Partners.get(ns, b.partner_uuid)
    if not partner then return U.fail(422, "REFERRAL_PARTNER", "Pick a partner", { partner_uuid = "not found" }) end
    if not partner.active then return U.fail(409, "REFERRAL_PARTNER", "That partner is switched off") end
    local share = b.share_contact == true
    if share and b.consent_confirmed ~= true then
        return U.fail(422, "REFERRAL_CONSENT", "Confirm the customer agreed to their details being shared with "
            .. partner.name, { consent_confirmed = "required to share contact details" })
    end
    local send = b.send ~= false
    if send and not email_ok(partner.referral_email) then
        return U.fail(422, "REFERRAL_EMAIL", partner.name .. " has no referral email. Add one to the partner first.",
            { referral_email = "missing on the partner" })
    end
    local kind = b.commission_type or partner.commission_type
    if kind ~= "percent" and kind ~= "fixed" then return U.fail(422, "REFERRAL_COMMISSION", "percent or fixed", { commission_type = "percent | fixed" }) end
    local rate = b.commission_value ~= nil and tonumber(b.commission_value) or tonumber(partner.commission_value) or 0
    if rate < 0 or (kind == "percent" and rate > 100) then
        return U.fail(422, "REFERRAL_COMMISSION", "Commission must be 0 to 100%", { commission_value = "0 to 100" })
    end
    local deal, lead = subject.deal, subject.lead
    local value = b.deal_value ~= nil and U.money(b.deal_value)
        or (deal and tonumber(deal.value) and tonumber(deal.value) > 0 and tonumber(deal.value))
        or (lead and tonumber(lead.estimated_value)) or nil
    if b.deal_value ~= nil and not value then return U.fail(422, "REFERRAL_VALUE", "Deal value must be a positive amount", { deal_value = "amount" }) end
    local currency = U.nz(b.currency) or (deal and U.nz(deal.currency)) or (lead and U.nz(lead.currency)) or partner.currency
        or require("lib.crm.lead-settings").get(ns).currency

    local token = require("helper.uuid").random_string(40, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    local created, err = U.tx(function()
        local live = U.one([[SELECT uuid FROM crm_deal_referrals
            WHERE partner_account_id = (SELECT account_id FROM crm_partner_profiles WHERE uuid = ?::uuid)
              AND status NOT IN ('declined','lost','cancelled')
              AND ((? > 0 AND deal_id = ?) OR (? = 0 AND deal_id IS NULL AND lead_id = ?))]],
            partner.uuid, deal and deal.id or 0, deal and deal.id or 0, deal and deal.id or 0, lead and lead.id or 0)
        if live then return U.fail(409, "REFERRAL_EXISTS", "This is already with " .. partner.name) end
        local row = db.query([[
            INSERT INTO crm_deal_referrals (namespace_id, deal_id, lead_id, partner_account_id, status, deal_value, currency,
                commission_type, commission_value, commission_amount, message, consent_confirmed_at, consent_by_uuid,
                response_token_hash, response_token_expires_at, ai_reason, created_by_uuid, share_contact)
            SELECT ?, ?, ?, account_id, 'draft', ?, ?, ?, ?, ?, ?, CASE WHEN ? THEN NOW() END, ?, ?,
                NOW() + make_interval(days => ?), ?, ?, ?
            FROM crm_partner_profiles WHERE uuid = ?::uuid
            RETURNING id, uuid
        ]], ns, deal and deal.id or db.NULL, lead and lead.id or db.NULL, value or db.NULL, currency or db.NULL, kind, rate,
            Partners.commission(kind, rate, value) or db.NULL, U.text(b.message, 3000) or db.NULL, share, share and actor or db.NULL,
            sha256_hex(token), TOKEN_DAYS, U.text(b.ai_reason, 300) or db.NULL, actor or db.NULL, share, partner.uuid)[1]
        return row
    end)
    if not created then return nil, err end
    if send then
        local ok, why = Partners.send(ns, created.uuid, token, actor)
        if not ok then
            return U.fail(502, "REFERRAL_NOT_SENT", "The referral was saved but the email to " .. partner.name
                .. " couldn't be sent: " .. tostring(why) .. ". Check the workspace email settings and press Send again.")
        end
    end
    return Partners.referral(ns, created.uuid)
end

local function frontend()
    return ((os.getenv("FRONTEND_URL") or os.getenv("DASHBOARD_URL") or ""):gsub("/+$", ""))
end

--- Email the partner (first send, or "Send again" with a fresh link).
function Partners.send(ns, uuid, token, actor)
    local r = U.one("SELECT * FROM crm_deal_referrals WHERE namespace_id = ? AND uuid = ?::uuid", ns, uuid)
    if not r then return nil, "referral not found" end
    if r.status ~= "draft" and r.status ~= "sent" then return nil, "this referral was already answered" end
    local partner = U.one([[SELECT a.name, p.referral_email, p.referral_contact_name FROM crm_partner_profiles p
        JOIN crm_accounts a ON a.id = p.account_id WHERE p.account_id = ?]], r.partner_account_id)
    if not partner or not email_ok(partner.referral_email) then return nil, "the partner has no referral email" end
    if not token then
        token = require("helper.uuid").random_string(40, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        db.query([[UPDATE crm_deal_referrals SET response_token_hash = ?, response_token_expires_at = NOW() + make_interval(days => ?)
            WHERE id = ?]], sha256_hex(token), TOKEN_DAYS, r.id)
    end
    local lead = not U.null(r.lead_id) and U.one("SELECT * FROM crm_leads WHERE id = ?", r.lead_id) or nil
    local deal = not U.null(r.deal_id) and U.one("SELECT * FROM crm_deals WHERE id = ?", r.deal_id) or nil
    local analysis = lead and U.one([[SELECT result FROM crm_lead_analyses WHERE lead_id = ? AND status = 'done'
        ORDER BY created_at DESC LIMIT 1]], lead.id)
    local ai = analysis and U.json(analysis.result, {}) or {}
    local ns_row = U.one("SELECT name FROM namespaces WHERE id = ?", ns) or {}
    local share = r.share_contact == true and not U.null(r.consent_confirmed_at)
    local customer = ""
    if share == true and lead then
        customer = table.concat({
            U.full_name(lead.first_name, lead.last_name) or "", U.nz(lead.company_name) or "",
            U.nz(lead.email) or "", U.nz(lead.phone) or "" }, " · "):gsub("^[ ·]+", ""):gsub("[ ·]+$", "")
    end
    local value = tonumber(r.deal_value)
    local commission = r.commission_type == "fixed" and (tostring(r.commission_value) .. " " .. (r.currency or "") .. " fixed fee")
        or (tostring(tonumber(r.commission_value)) .. "% of the deal value")
    local data = {
        partner_name = partner.referral_contact_name or partner.name,
        from_name = ns_row.name or "",
        deal_title = (deal and deal.name) or (lead and (U.nz(ai.wants) or U.nz(lead.company_name))) or "A new customer",
        summary = U.nz(ai.summary) and (share and ai.summary or ("A customer wants: " .. tostring(ai.wants or ai.summary))) or "",
        wants = U.nz(ai.wants) or "",
        value = value and (string.format("%.2f", value) .. " " .. (r.currency or "")) or "to be agreed",
        commission = commission,
        customer = customer,
        message = U.nz(r.message) or "",
        respond_url = frontend() .. "/partner-referral/" .. token,
    }
    local ok, err = require("helper.namespace-mail").send(ns, "crm.partner_referral", partner.referral_email, data)
    if not ok then return nil, tostring(err) end
    db.query([[UPDATE crm_deal_referrals SET status = 'sent', sent_at = COALESCE(sent_at, NOW()), updated_at = NOW()
        WHERE id = ?]], r.id)
    return true
end

--- A person moves a referral (see MOVES). b = { status, deal_value?, partner_reference?, notes? }
function Partners.move(ns, actor, uuid, b)
    local to = type(b.status) == "string" and b.status or ""
    local moved, err = U.tx(function()
        local r = U.one("SELECT * FROM crm_deal_referrals WHERE namespace_id = ? AND uuid = ?::uuid FOR UPDATE", ns, uuid)
        if not r then return U.fail(404, "REFERRAL_NOT_FOUND", "Referral not found") end
        if not (MOVES[r.status] and MOVES[r.status][to]) then
            return U.fail(409, "REFERRAL_MOVE", "A referral that is “" .. (Partners.LABELS[r.status] or r.status)
                .. "” can't become “" .. (Partners.LABELS[to] or to) .. "”")
        end
        local value = b.deal_value ~= nil and U.money(b.deal_value) or tonumber(r.deal_value)
        if b.deal_value ~= nil and not value then return U.fail(422, "REFERRAL_VALUE", "Deal value must be a positive amount", { deal_value = "amount" }) end
        db.query([[
            UPDATE crm_deal_referrals SET status = ?, deal_value = ?, commission_amount = ?,
                partner_reference = COALESCE(?, partner_reference),
                partner_notes = CONCAT_WS(E'\n', NULLIF(partner_notes, ''), ?::text),
                responded_at = CASE WHEN ? IN ('accepted','declined') THEN NOW() ELSE responded_at END,
                won_at = CASE WHEN ? = 'won' THEN NOW() ELSE won_at END,
                closed_at = CASE WHEN ? IN ('declined','lost','cancelled','commission_paid') THEN NOW() ELSE closed_at END,
                response_token_hash = CASE WHEN ? IN ('lost','cancelled','commission_paid') THEN NULL ELSE response_token_hash END,
                updated_at = NOW()
            WHERE id = ?
        ]], to, value or db.NULL, Partners.commission(r.commission_type, r.commission_value, value) or db.NULL,
            U.text(b.partner_reference, 120) or db.NULL, U.text(b.notes, 2000) or db.NULL, to, to, to, to, r.id)
        return true
    end)
    if not moved then return nil, err end
    return Partners.referral(ns, uuid)
end

--- The partner answers through their link. b = { action = accept|decline|won|lost, reference?, notes?, deal_value? }
function Partners.respond(token, b)
    if type(token) ~= "string" or #token < 20 or #token > 100 then return U.fail(404, "REFERRAL_LINK", "This link isn't valid") end
    local r = U.one([[SELECT r.*, a.name AS partner_name FROM crm_deal_referrals r JOIN crm_accounts a ON a.id = r.partner_account_id
        WHERE r.response_token_hash = ?]], sha256_hex(token))
    if not r then return U.fail(404, "REFERRAL_LINK", "This link isn't valid any more") end
    if U.one("SELECT ?::timestamptz < NOW() AS expired", r.response_token_expires_at).expired then
        return U.fail(410, "REFERRAL_LINK", "This link has expired. Ask us for a new one.")
    end
    if b == nil then return r end
    local map = { accept = "accepted", decline = "declined", won = "won", lost = "lost" }
    local to = map[b.action]
    if not to then return U.fail(422, "REFERRAL_ACTION", "accept, decline, won or lost", { action = "accept | decline | won | lost" }) end
    local moved, err = Partners.move(tonumber(r.namespace_id), nil, r.uuid,
        { status = to, deal_value = b.deal_value, partner_reference = b.reference, notes = b.notes and ("Partner: " .. tostring(b.notes)) })
    if not moved then return nil, err end
    -- Tell whoever owns the deal (or lead).
    local owner = U.one([[SELECT COALESCE(d.owner_user_uuid, l.owner_user_uuid) AS o, l.uuid AS lead_uuid
        FROM crm_deal_referrals r LEFT JOIN crm_deals d ON d.id = r.deal_id LEFT JOIN crm_leads l ON l.id = r.lead_id
        WHERE r.id = ?]], r.id)
    if owner and U.nz(owner.o) then
        require("lib.crm.lead-notify").send(tonumber(r.namespace_id), { owner.o }, { kind = "referral_" .. to,
            lead_uuid = owner.lead_uuid, title = r.partner_name .. ": " .. (Partners.LABELS[to] or to),
            body = (b.notes and U.text(b.notes, 300)) or ("The partner updated the referral to “" .. (Partners.LABELS[to] or to) .. "”."),
            action_label = "Open" })
    end
    return moved
end

--- What the partner sees on their link (nothing about other partners or internals).
function Partners.public_view(token)
    local r, err = Partners.respond(token, nil)
    if not r then return nil, err end
    local ns = tonumber(r.namespace_id)
    local lead = not U.null(r.lead_id) and U.one("SELECT * FROM crm_leads WHERE id = ?", r.lead_id) or nil
    local deal = not U.null(r.deal_id) and U.one("SELECT name FROM crm_deals WHERE id = ?", r.deal_id) or nil
    local analysis = lead and U.one([[SELECT result FROM crm_lead_analyses WHERE lead_id = ? AND status = 'done'
        ORDER BY created_at DESC LIMIT 1]], lead.id)
    local ai = analysis and U.json(analysis.result, {}) or {}
    local share = r.share_contact == true and not U.null(r.consent_confirmed_at)
    return {
        from = (U.one("SELECT name FROM namespaces WHERE id = ?", ns) or {}).name,
        partner = r.partner_name, status = r.status, status_label = Partners.LABELS[r.status],
        title = (deal and deal.name) or U.nz(ai.wants) or "A customer enquiry",
        wants = U.nz(ai.wants) or cjson.null,
        summary = share and (U.nz(ai.summary) or cjson.null) or cjson.null,
        message = U.nz(r.message) or cjson.null,
        deal_value = tonumber(r.deal_value) or cjson.null, currency = r.currency or cjson.null,
        commission_type = r.commission_type, commission_value = tonumber(r.commission_value),
        customer = share and lead and {
            name = U.full_name(lead.first_name, lead.last_name) or cjson.null, company = U.nz(lead.company_name) or cjson.null,
            email = U.nz(lead.email) or cjson.null, phone = U.nz(lead.phone) or cjson.null,
        } or cjson.null,
        can = { accept = r.status == "sent", decline = r.status == "sent", won = r.status == "accepted", lost = r.status == "accepted" },
        expires_at = r.response_token_expires_at,
    }
end

--- Bill the partner for the commission of a won referral (core invoicing).
function Partners.invoice(ns, actor, uuid, b)
    if not U.has_table("invoices") then return U.fail(409, "INVOICING_OFF", "Invoicing isn't deployed here") end
    b = type(b) == "table" and b or {}
    local r = U.one("SELECT * FROM crm_deal_referrals WHERE namespace_id = ? AND uuid = ?::uuid", ns, uuid)
    if not r then return U.fail(404, "REFERRAL_NOT_FOUND", "Referral not found") end
    if r.status ~= "won" then return U.fail(409, "REFERRAL_NOT_WON", "Invoice the commission once the partner has won the deal") end
    local amount = U.money(r.commission_amount)
    if not amount or amount <= 0 then
        return U.fail(422, "REFERRAL_AMOUNT", "Set the final deal value first so the commission can be worked out",
            { deal_value = "required" })
    end
    local partner = U.one([[SELECT a.id, a.name, a.email, p.referral_email FROM crm_accounts a
        JOIN crm_partner_profiles p ON p.account_id = a.id WHERE a.id = ?]], r.partner_account_id)
    local deal = not U.null(r.deal_id) and U.one("SELECT name FROM crm_deals WHERE id = ?", r.deal_id) or nil
    local tax_rate = tonumber(b.tax_rate) or 0
    if tax_rate < 0 or tax_rate > 100 then return U.fail(422, "REFERRAL_TAX", "Tax rate 0 to 100", { tax_rate = "0 to 100" }) end
    local InvoiceQueries = require("queries.InvoiceQueries")
    local invoice
    local ok, err = U.tx(function()
        local locked = U.one("SELECT status FROM crm_deal_referrals WHERE id = ? FOR UPDATE", r.id)
        if locked.status ~= "won" then return U.fail(409, "REFERRAL_NOT_WON", "This commission was already invoiced") end
        invoice = InvoiceQueries.create({
            namespace_id = ns, customer_name = partner.name,
            customer_email = U.nz(partner.referral_email) or U.nz(partner.email), account_id = partner.id,
            currency = r.currency or "GBP", owner_user_uuid = actor, payment_terms_days = tonumber(b.payment_terms_days) or 30,
            notes = "Referral commission" .. (U.nz(r.partner_reference) and (" — your reference " .. r.partner_reference) or ""),
            line_items = { { description = "Commission: " .. ((deal and deal.name) or "referred deal")
                .. (r.commission_type == "percent" and string.format(" (%s%% of %.2f)", tostring(tonumber(r.commission_value)),
                    tonumber(r.deal_value) or 0) or ""), quantity = 1, unit_price = amount, tax_rate = tax_rate } },
        }).data
        db.query("UPDATE invoices SET deal_id = ? WHERE id = ?", r.deal_id ~= db.NULL and r.deal_id or db.NULL, invoice.internal_id)
        db.query([[UPDATE crm_deal_referrals SET status = 'commission_invoiced', invoice_id = ?, updated_at = NOW() WHERE id = ?]],
            invoice.internal_id, r.id)
        return true
    end)
    if not ok then return nil, err end
    return { referral = Partners.referral(ns, uuid), invoice_uuid = invoice.uuid }
end

--- invoice.paid (outbox): close the referral whose commission it bills.
function Partners.invoice_paid(ns, invoice_uuid)
    if not available() then return true end
    db.query([[
        UPDATE crm_deal_referrals r SET status = 'commission_paid', closed_at = NOW(), response_token_hash = NULL, updated_at = NOW()
        FROM invoices i WHERE i.id = r.invoice_id AND i.uuid = ? AND r.namespace_id = ? AND r.status = 'commission_invoiced'
    ]], invoice_uuid, ns)
    return true
end

return Partners
