--[[
    VAT records (VAT plan phase 1): registrations, VAT coding rules, and the VAT
    on each bank line. Figures come from lib/vat.lua; nothing here guesses.

    A "business" is one VAT registration: a person's own (namespace_id + user_id,
    the tax product where many sole traders share a namespace) or a whole
    namespace's (user_id NULL, accounting). Rules belong to a registration (or are
    global and read-only), so one business's corrections never touch another's.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local VAT = require("lib.vat")

local VatQueries = {}

local function null(v) return v == nil or v == db.NULL or (ngx and v == ngx.null) end

local function bool(v)
    if v == true or v == "true" or v == "t" or v == 1 or v == "1" then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Registrations
-- ---------------------------------------------------------------------------

--- The active registration for a business (user_id nil = the namespace's own).
function VatQueries.get_registration(namespace_id, user_id)
    local rows
    if user_id then
        rows = db.query([[SELECT * FROM vat_registrations
            WHERE namespace_id = ? AND user_id = ? AND status = 'active' LIMIT 1]], namespace_id, user_id)
    else
        rows = db.query([[SELECT * FROM vat_registrations
            WHERE namespace_id = ? AND user_id IS NULL AND status = 'active' LIMIT 1]], namespace_id)
    end
    return rows and rows[1] or nil
end

--- Check registration fields; returns the cleaned set or nil + message.
function VatQueries.validate_registration(f)
    f = f or {}
    local out = {}
    local vrn, verr = VAT.valid_vrn(f.vrn)
    if not vrn then return nil, verr end
    out.vrn = vrn
    out.scheme = f.scheme or "standard"
    if not VAT.SCHEMES[out.scheme] then
        return nil, "Scheme must be one of: standard, cash, flat_rate, annual"
    end
    out.stagger = f.stagger or (out.scheme == "annual" and "annual" or "quarterly_mar")
    local staggers = { quarterly_mar = 1, quarterly_apr = 1, quarterly_may = 1, monthly = 1, annual = 1 }
    if not staggers[out.stagger] then
        return nil, "Stagger must be quarterly_mar, quarterly_apr, quarterly_may, monthly or annual"
    end
    if out.scheme == "flat_rate" then
        local pct = tonumber(f.flat_rate_pct)
        if not pct or pct <= 0 or pct > 20 then
            return nil, "Flat Rate Scheme needs your flat rate % (between 0 and 20)"
        end
        out.flat_rate_pct = VAT.round2(pct)
        out.flat_rate_first_year = bool(f.flat_rate_first_year)
        out.limited_cost_trader = bool(f.limited_cost_trader)
    else
        out.flat_rate_pct = db.NULL
        out.flat_rate_first_year = false
        out.limited_cost_trader = false
    end
    out.partially_exempt = bool(f.partially_exempt)
    if out.partially_exempt then
        local r = tonumber(f.recovery_pct)
        if not r or r < 0 or r > 100 then
            return nil, "Partially exempt: give the share of VAT you can recover (0–100%)"
        end
        out.recovery_pct = VAT.round2(r)
    else
        out.recovery_pct = db.NULL
    end
    if f.effective_date and f.effective_date ~= "" then
        if not VAT.valid_date(f.effective_date) then
            return nil, "Effective date must look like 2025-04-01"
        end
        out.effective_date = f.effective_date
    end
    if f.business_name then out.business_name = tostring(f.business_name):sub(1, 255) end
    if f.business_address then out.business_address = tostring(f.business_address):sub(1, 500) end
    if f.sales_from ~= nil then
        if not ({ auto = 1, invoices = 1, bank = 1 })[f.sales_from] then
            return nil, "sales_from must be auto, invoices or bank"
        end
        out.sales_from = f.sales_from
    end
    return out
end

--- Create or update a business's registration.
-- @return row or nil, message, http_status
function VatQueries.save_registration(namespace_id, user_id, fields, actor_id)
    local clean, err = VatQueries.validate_registration(fields)
    if not clean then return nil, err, 400 end
    -- No platform-wide "VAT number already taken" check: the number isn't verified here,
    -- so a claim would let anyone block (and probe) another business's number. HMRC only
    -- lets the person who signed in file for a number they're authorised for.

    local existing = VatQueries.get_registration(namespace_id, user_id)
    clean.updated_at = db.raw("NOW()")
    if existing then
        db.update("vat_registrations", clean, { id = existing.id })
    else
        clean.namespace_id = namespace_id
        clean.user_id = user_id or db.NULL
        clean.created_by = actor_id
        db.insert("vat_registrations", clean)
    end
    return VatQueries.get_registration(namespace_id, user_id)
end

--- Stop being VAT registered (keeps the records).
function VatQueries.deregister(registration)
    db.update("vat_registrations", { status = "deregistered", updated_at = db.raw("NOW()") },
        { id = registration.id })
    return true
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

--- The business's own rules plus the global ones.
function VatQueries.list_rules(registration_id)
    return db.query([[SELECT uuid, registration_id, match_type, match_value, vat_code, reclaimable_pct,
            reason, source, hits, is_active, created_at, updated_at,
            (registration_id IS NULL) AS is_global
        FROM vat_rules
        WHERE registration_id IS NULL OR registration_id = ?
        ORDER BY (registration_id IS NULL), match_type, lower(match_value)]], registration_id or 0)
end

local function validate_rule(f, partial)
    local out = {}
    if f.match_type ~= nil or not partial then
        if not ({ merchant = 1, contains = 1, category = 1 })[f.match_type or ""] then
            return nil, "match_type must be merchant, contains or category"
        end
        out.match_type = f.match_type
    end
    if f.match_value ~= nil or not partial then
        local v = tostring(f.match_value or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" or #v > 255 then return nil, "match_value is required (up to 255 characters)" end
        out.match_value = v
    end
    if f.vat_code ~= nil or not partial then
        local c = VAT.code(f.vat_code)
        if not c then return nil, "Unknown VAT code" end
        out.vat_code = c.code
    end
    if f.reclaimable_pct ~= nil then
        if f.reclaimable_pct == "" or f.reclaimable_pct == cjson.null then
            out.reclaimable_pct = db.NULL
        else
            local p = tonumber(f.reclaimable_pct)
            if not p or p < 0 or p > 100 then return nil, "reclaimable_pct must be 0–100" end
            out.reclaimable_pct = p
        end
    end
    if f.reason ~= nil then out.reason = tostring(f.reason):sub(1, 1000) end
    if f.is_active ~= nil then out.is_active = bool(f.is_active) end
    return out
end

function VatQueries.create_rule(registration, fields, actor_id)
    local clean, err = validate_rule(fields or {}, false)
    if not clean then return nil, err, 400 end
    local dup = db.query([[SELECT 1 FROM vat_rules WHERE registration_id = ? AND match_type = ?
        AND lower(match_value) = lower(?)]], registration.id, clean.match_type, clean.match_value)
    if dup and #dup > 0 then return nil, "You already have a rule for that.", 409 end
    clean.registration_id = registration.id
    clean.source = "user"
    clean.created_by = actor_id
    local row = db.insert("vat_rules", clean, "uuid")
    return db.query("SELECT * FROM vat_rules WHERE uuid = ?", row[1] and row[1].uuid or row.uuid)[1]
end

local function own_rule(registration, uuid)
    local r = db.query("SELECT * FROM vat_rules WHERE uuid = ? LIMIT 1", uuid)[1]
    if not r then return nil, "Rule not found", 404 end
    if null(r.registration_id) then
        return nil, "Starting rules can't be changed. Add your own rule — it always wins.", 403
    end
    if r.registration_id ~= registration.id then return nil, "Rule not found", 404 end
    return r
end

function VatQueries.update_rule(registration, uuid, fields)
    local r, err, status = own_rule(registration, uuid)
    if not r then return nil, err, status end
    local clean, verr = validate_rule(fields or {}, true)
    if not clean then return nil, verr, 400 end
    clean.updated_at = db.raw("NOW()")
    db.update("vat_rules", clean, { id = r.id })
    return db.query("SELECT * FROM vat_rules WHERE id = ?", r.id)[1]
end

function VatQueries.delete_rule(registration, uuid)
    local r, err, status = own_rule(registration, uuid)
    if not r then return nil, err, status end
    db.query("DELETE FROM vat_rules WHERE id = ?", r.id)
    return true
end

-- ---------------------------------------------------------------------------
-- VAT on a business's lines (a person's tax_transactions; a workspace's accounting lines)
-- ---------------------------------------------------------------------------

--- Work out the VAT fields for a line and code (no write).
-- @return fields table for the row, or nil + message
function VatQueries.vat_fields(amount, code, opts)
    opts = opts or {}
    local split, err = VAT.split(amount, code, { vat_amount = opts.vat_amount })
    if not split then return nil, err end
    local def = VAT.code(code)
    local pct = opts.reclaimable_pct
    if pct == nil or pct == db.NULL then pct = def.reclaimable end
    return {
        vat_code = split.code,
        net_amount = split.net,
        vat_amount = split.vat,
        vat_notional = split.notional_vat,
        vat_reclaimable_pct = tonumber(pct),
        is_vat_applicable = not def.no_vat,
        vat_rate = def.rate,
    }
end

--- One line of this business (its own bank lines, or the workspace's accounting lines),
-- by uuid. @return { src, id, amount (positive), transaction_type, description, category }
function VatQueries.find_line(registration, uuid)
    local L = require("queries.VatReturnQueries")
    local from = L.lines_from(registration)
    if not from or type(uuid) ~= "string" then return nil end
    return db.query([[SELECT l.src, l.id, l.amount, l.dir AS transaction_type, l.description, l.category
        FROM ]] .. from .. " WHERE l.uuid = ? LIMIT 1", uuid)[1]
end

--- A person sets (or corrects) the VAT on one of the business's lines.
function VatQueries.set_transaction_vat(registration, uuid, fields, actor_id)
    fields = fields or {}
    local L = require("queries.VatReturnQueries")
    local t = VatQueries.find_line(registration, uuid)
    if not t then return nil, "Transaction not found", 404 end
    local pct = fields.reclaimable_pct
    if pct ~= nil and pct ~= "" then
        pct = tonumber(pct)
        if not pct or pct < 0 or pct > 100 then return nil, "reclaimable_pct must be 0–100", 400 end
    else
        pct = nil
    end
    local vf, err = VatQueries.vat_fields(t.amount, fields.vat_code,
        { vat_amount = fields.vat_amount ~= "" and fields.vat_amount or nil, reclaimable_pct = pct })
    if not vf then return nil, err, 400 end
    vf.vat_source = "user"
    vf.vat_confidence = 1
    vf.vat_review = false -- a person decided: nothing left to check
    vf.vat_review_reasons = db.NULL
    vf.vat_reason = fields.reason and tostring(fields.reason):sub(1, 1000) or db.NULL
    vf.vat_rule_id = db.NULL
    vf.vat_registration_id = registration.id
    vf.vat_decided_by = actor_id
    vf.vat_decided_at = db.raw("NOW()")
    if type(fields.evidence) == "table" then
        local e = fields.evidence
        local ev = { has_receipt = bool(e.has_receipt), document_url = e.document_url }
        if e.supplier_vrn and e.supplier_vrn ~= "" then
            local v, verr = VAT.valid_vrn(e.supplier_vrn)
            if not v then return nil, "Supplier VAT number: " .. verr, 400 end
            ev.supplier_vrn = v
        end
        vf.vat_evidence = cjson.encode(ev)
    end
    vf.updated_at = db.raw("NOW()")
    L.write_line(t.src, t.id, vf)
    return db.query([[SELECT l.uuid, l.amount, l.dir AS transaction_type, l.vat_code, l.net_amount, l.vat_amount,
        l.vat_notional, l.vat_reclaimable_pct, l.vat_source, l.vat_reason, l.vat_evidence
        FROM ]] .. L.lines_from(registration) .. " WHERE l.src = ? AND l.id = ?", t.src, t.id)[1]
end

--- Code every un-coded line (or every rule-coded line, with refresh) by the rules.
-- People's own decisions (vat_source = 'user') are never changed.
-- opts: { tax_year?, statement_id?, refresh? }
-- @return { matched, unmatched, by_code = { CODE = n } }
function VatQueries.apply_rules(registration, opts)
    opts = opts or {}
    local L = require("queries.VatReturnQueries")
    local out = { matched = 0, unmatched = 0, by_code = {} }
    local from = L.lines_from(registration)
    if not from then return out end
    local where = L.line_filters(registration, opts)
    where[#where + 1] = opts.refresh and "(l.vat_code IS NULL OR l.vat_source = 'rule')" or "l.vat_code IS NULL"
    local lines = db.query("SELECT l.src, l.id, l.amount, l.description, l.category, l.merchant FROM " .. from
        .. " WHERE " .. table.concat(where, " AND ")) or {}
    local rules = db.query([[SELECT id, registration_id, match_type, match_value, vat_code, reclaimable_pct,
            reason, is_active
        FROM vat_rules WHERE is_active AND (registration_id IS NULL OR registration_id = ?)]], registration.id)

    local hits = {}
    for _, l in ipairs(lines) do
        local r = VAT.match_rule(rules, l)
        if r then
            local vf = VatQueries.vat_fields(l.amount, r.vat_code,
                { reclaimable_pct = not null(r.reclaimable_pct) and r.reclaimable_pct or nil })
            if vf then
                vf.vat_source = "rule"
                vf.vat_confidence = 1
                vf.vat_reason = r.reason or db.NULL
                vf.vat_rule_id = r.id
                vf.vat_registration_id = registration.id
                vf.vat_decided_at = db.raw("NOW()")
                vf.updated_at = db.raw("NOW()")
                L.write_line(l.src, l.id, vf)
                out.matched = out.matched + 1
                out.by_code[r.vat_code] = (out.by_code[r.vat_code] or 0) + 1
                hits[r.id] = (hits[r.id] or 0) + 1
            end
        else
            out.unmatched = out.unmatched + 1
        end
    end
    for id, n in pairs(hits) do
        db.query("UPDATE vat_rules SET hits = hits + ? WHERE id = ?", n, id)
    end
    return out
end

return VatQueries
