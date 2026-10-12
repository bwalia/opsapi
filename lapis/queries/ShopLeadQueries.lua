-- luacheck: max line length 140
--[[
    Shop → CRM leads
    ================
    One open CRM lead per customer email (rules: lib/shop-leads.lua). Advisor
    chats, requirements and quotes all attach to it, so nothing is lost. A new
    lead fires the namespace's lead notifications; updates to an existing lead
    don't (the team was already told).
]]

local db = require("lapis.db")
local Global = require("helper.global")
local U = require("lib.shop-util")
local L = require("lib.shop-leads")

local ShopLeadQueries = {}

local function stamp()
    return os.date("!%Y-%m-%d %H:%M UTC")
end

local function notify(ns_id, lead)
    pcall(function()
        local Notif = require("queries.CrmLeadNotificationQueries")
        local ns = db.query("SELECT id, slug, name FROM namespaces WHERE id = ?", ns_id)[1]
        if ns then Notif.notify(ns, lead) end
    end)
end

--- Find-or-create the customer's open lead and attach one event.
-- p: { email (required), name?, company?, phone?, source, note?, chat_session_uuid?,
--      quote = {uuid, number, total_minor}?, requirements?, improve_consent? }
-- Returns the lead row ({ id, uuid, … }) or (nil, err).
function ShopLeadQueries.upsert(ns_id, p)
    local email = L.email(p.email)
    if not email then return nil, U.err(400, "VALIDATION_ERROR", "a valid email is required") end
    local created
    local lead = U.tx(function()
        -- Serialise per customer so two quick events can't create two leads.
        db.query("SELECT pg_advisory_xact_lock(hashtext(?))", "shop_lead:" .. ns_id .. ":" .. email)
        local row = db.query([[
            SELECT id, uuid, notes, metadata::text AS metadata, first_name, last_name, phone, company_name FROM crm_leads
             WHERE namespace_id = ? AND lower(email) = ? AND deleted_at IS NULL AND converted_at IS NULL
             ORDER BY created_at DESC LIMIT 1
        ]], ns_id, email)[1]
        local meta = L.merge_metadata(row and U.dec(row.metadata, {}) or {}, p)
        local notes = L.append_note(row and row.notes or nil, p.note, stamp())
        if row then
            local first, last = L.split_name(p.name)
            db.query([[
                UPDATE crm_leads SET notes = ?, metadata = ?::jsonb, updated_at = NOW(),
                       first_name = CASE WHEN first_name IN ('', 'Shop customer') AND ? <> 'Shop customer' THEN ? ELSE first_name END,
                       last_name = COALESCE(last_name, ?), phone = COALESCE(phone, ?), company_name = COALESCE(company_name, ?)
                 WHERE id = ?
            ]], notes or db.NULL, U.enc(meta), first, first, last or db.NULL, U.nz(p.phone) or db.NULL,
                U.nz(p.company) or db.NULL, row.id)
            return row
        end
        local first, last = L.split_name(p.name)
        created = true
        return db.query([[
            INSERT INTO crm_leads (uuid, namespace_id, first_name, last_name, email, phone, company_name, source, status,
                                   score, notes, metadata, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'new', 0, ?, ?::jsonb, NOW(), NOW()) RETURNING *
        ]], Global.generateUUID(), ns_id, first, last or db.NULL, email, U.nz(p.phone) or db.NULL,
            U.nz(p.company) or db.NULL, p.source or "shop", notes or db.NULL, U.enc(meta))[1]
    end)
    if not lead then return nil, U.err(500, "LEAD_FAILED", "Could not save the lead") end
    if created then notify(ns_id, lead) end
    return lead
end

--- Best-effort wrapper: logs and returns nil instead of raising (never fails the caller's request).
function ShopLeadQueries.safeUpsert(ns_id, p)
    local ok, lead = pcall(ShopLeadQueries.upsert, ns_id, p)
    if ok and lead then return lead end
    ngx.log(ngx.WARN, "[shop-leads] CRM lead not saved: ", tostring(lead))
    return nil
end

return ShopLeadQueries
