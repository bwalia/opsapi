-- Week 4 integrations, the basics.
--
-- Outlook (and Gmail / IMAP): Property Deals' mail connectors already pull the inbox into
-- property_deals_inbound_messages (Microsoft Graph for Outlook). I.mail_import puts each message from a person we
-- have an opportunity with onto that opportunity's timeline as an inbound email interaction. The text is stored as
-- data, never followed (build prompt rule 11). Each message is imported once.
--
-- GoHighLevel: I.ghl_sync pulls contacts (LeadConnector API v2, a private integration token) into CRM contacts,
-- matched on the GHL id then email. Read only: nothing is sent to GHL. Every field written is recorded as an
-- `integration` fact, so the record shows where it came from.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local I = {}

--- Import inbound mail from known people onto their opportunity timelines. @return { imported, skipped }
function I.mail_import(ns, days)
    local rows = db.query([[
        SELECT m.uuid, m.from_address, m.subject, m.body_text, m.received_at, c.uuid AS person_uuid, o.uuid AS opportunity_uuid,
               o.owner_user_uuid
        FROM property_deals_inbound_messages m
        JOIN crm_contacts c ON c.namespace_id = m.namespace_id AND LOWER(c.email) = LOWER(m.from_address) AND c.deleted_at IS NULL
        JOIN LATERAL (SELECT uuid, owner_user_uuid FROM pa_opportunities WHERE namespace_id = m.namespace_id
                      AND person_uuid = c.uuid AND status = 'open' ORDER BY updated_at DESC LIMIT 1) o ON TRUE
        WHERE m.namespace_id = ? AND m.received_at > NOW() - make_interval(days => ?)
          AND NOT EXISTS (SELECT 1 FROM crm_activities a WHERE a.namespace_id = m.namespace_id
                          AND a.metadata ->> 'inbound_message_uuid' = m.uuid::text)
        ORDER BY m.received_at LIMIT 200
    ]], ns, days or 14)
    local n = 0
    for _, m in ipairs(rows) do
        local owner = m.owner_user_uuid ~= db.NULL and m.owner_user_uuid or nil
        if owner then
            local it = require("property_pa.interactions").log(ns, { channel = "email", direction = "inbound",
                subject = "Email: " .. tostring(m.subject ~= db.NULL and m.subject or "(no subject)"):sub(1, 200),
                raw_text = m.body_text ~= db.NULL and m.body_text or "", opportunity_uuid = m.opportunity_uuid,
                at = m.received_at, source = "integration" }, owner)
            db.query([[UPDATE crm_activities SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
                'inbound_message_uuid', ?::text) WHERE namespace_id = ? AND uuid = ?]], m.uuid, ns, it.uuid)
            n = n + 1
        end
    end
    return { imported = n, considered = #rows }
end

-- ------------------------------------------------------------------ GoHighLevel
I.GHL_URL = os.getenv("GHL_API_URL") or "https://services.leadconnectorhq.com"

local function ghl_get(token, path)
    local http = require("resty.http").new()
    http:set_timeout(20000)
    local url = I.GHL_URL:gsub("/+$", "") .. path
    if not url:match("^https://") and os.getenv("OPSAPI_INTEGRATIONS_ALLOW_PRIVATE") ~= "true" then
        return nil, "GHL_API_URL must be https"
    end
    local res, err = http:request_uri(url, { method = "GET", ssl_verify = true,
        headers = { Authorization = "Bearer " .. token, Version = "2021-07-28", Accept = "application/json" } })
    if not res then return nil, "GoHighLevel unreachable: " .. tostring(err) end
    if res.status >= 300 then return nil, "GoHighLevel HTTP " .. res.status end
    local ok, data = pcall(cjson.decode, res.body or "")
    if not ok or type(data) ~= "table" then return nil, "GoHighLevel returned something that isn't JSON" end
    return data
end

local function s(v) return type(v) == "string" and v ~= "" and v or nil end

--- Pull contacts from a GHL location. settings: ghl_location_id, ghl_token (secret). @return summary | nil, err
function I.ghl_sync(ns, settings, owner_uuid, max_pages)
    local loc, token = s(settings.ghl_location_id), s(settings.ghl_token)
    if not loc or not token then return nil, "Set the GoHighLevel location id and token in the Property PA settings" end
    local F = require("property_pa.facts")
    local out = { created = 0, updated = 0, unchanged = 0, pages = 0 }
    local after
    for _ = 1, max_pages or 20 do
        local q = "/contacts/?locationId=" .. ngx.escape_uri(loc) .. "&limit=100"
            .. (after and ("&startAfterId=" .. ngx.escape_uri(after)) or "")
        local data, err = ghl_get(token, q)
        if not data then return nil, err end
        out.pages = out.pages + 1
        local list = type(data.contacts) == "table" and data.contacts or {}
        for _, c in ipairs(list) do
            local gid = s(c.id)
            if gid then
                local email = s(c.email) and c.email:lower() or nil
                local existing = U.one([[SELECT uuid, first_name, last_name, email, phone FROM crm_contacts WHERE namespace_id = ?
                    AND deleted_at IS NULL AND (metadata ->> 'ghl_id' = ? OR (?::text IS NOT NULL AND LOWER(email) = ?))
                    ORDER BY (metadata ->> 'ghl_id' = ?) DESC NULLS LAST LIMIT 1]], ns, gid, email or db.NULL, email or db.NULL, gid)
                local fields = { first_name = s(c.firstName) or s(c.contactName) or "Unknown", last_name = s(c.lastName),
                    email = email, phone = s(c.phone) }
                if not existing then
                    local uuid = require("helper.global").generateUUID()
                    db.insert("crm_contacts", { uuid = uuid, namespace_id = ns, first_name = fields.first_name,
                        last_name = fields.last_name or db.NULL, email = fields.email or db.NULL, phone = fields.phone or db.NULL,
                        owner_user_uuid = owner_uuid, status = "active",
                        metadata = db.raw(db.escape_literal(cjson.encode({ ghl_id = gid, source = "ghl" })) .. "::jsonb") })
                    F.record(ns, { target_table = "crm_contacts", target_uuid = uuid, field = "_create",
                        value = { ghl_id = gid }, action = "create", source = "integration", source_ref = "ghl:" .. gid })
                    out.created = out.created + 1
                else
                    local changed = false
                    for _, f in ipairs({ "email", "phone" }) do
                        if fields[f] and fields[f] ~= (existing[f] ~= db.NULL and existing[f] or nil) then
                            db.query("UPDATE crm_contacts SET " .. f .. " = ?, updated_at = NOW() WHERE namespace_id = ? AND uuid = ?",
                                fields[f], ns, existing.uuid)
                            F.record(ns, { target_table = "crm_contacts", target_uuid = existing.uuid, field = f, value = fields[f],
                                source = "integration", source_ref = "ghl:" .. gid })
                            changed = true
                        end
                    end
                    db.query([[UPDATE crm_contacts SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('ghl_id', ?::text)
                        WHERE namespace_id = ? AND uuid = ?]], gid, ns, existing.uuid)
                    if changed then out.updated = out.updated + 1 else out.unchanged = out.unchanged + 1 end
                end
            end
        end
        after = type(data.meta) == "table" and s(data.meta.startAfterId) or nil
        if #list < 100 or not after then break end
    end
    return out
end

return I
