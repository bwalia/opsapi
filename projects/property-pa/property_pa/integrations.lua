-- Week 4 integrations, the basics.
--
-- Outlook (and Gmail / IMAP): Property Deals' mail connectors already pull the inbox into
-- property_deals_inbound_messages (Microsoft Graph for Outlook). I.mail_import puts each message from a person we
-- have an opportunity with onto that opportunity's timeline as an inbound email interaction. The text is stored as
-- data, never followed (build prompt rule 11).
--
-- GoHighLevel: I.ghl_sync pulls contacts (LeadConnector API v2, a private integration token) into CRM contacts,
-- matched on the GHL id, then email, then phone. Read only: nothing is sent to GHL. Every field written is recorded
-- as an `integration` fact, so the record shows where it came from.
--
-- Each message / GHL contact is imported once: pa_external_refs holds one row per (workspace, source, external id),
-- claimed with INSERT ... ON CONFLICT DO NOTHING in the same transaction as the import, so two imports running at
-- once (the job and a manual run) can't both write it.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local I = {}

local function null(v) return v == nil or v == db.NULL end

--- Claim an external id for this workspace. @return true when this caller got it (first time it is seen)
local function claim(ns, source, id, record_uuid)
    return db.query([[INSERT INTO pa_external_refs (namespace_id, source, external_id, record_uuid) VALUES (?, ?, ?, ?)
        ON CONFLICT DO NOTHING RETURNING id]], ns, source, tostring(id), record_uuid or db.NULL)[1] ~= nil
end

--- Import inbound mail from known people onto their opportunity timelines. @return { imported, skipped, considered }
function I.mail_import(ns, days)
    local rows = db.query([[
        SELECT m.uuid, m.subject, m.body_text, m.received_at, o.uuid AS opportunity_uuid, o.owner_user_uuid
        FROM property_deals_inbound_messages m
        JOIN crm_contacts c ON c.namespace_id = m.namespace_id AND LOWER(c.email) = LOWER(m.from_address) AND c.deleted_at IS NULL
        JOIN LATERAL (SELECT uuid, owner_user_uuid FROM pa_opportunities WHERE namespace_id = m.namespace_id
                      AND person_uuid = c.uuid AND status = 'open' ORDER BY updated_at DESC LIMIT 1) o ON TRUE
        WHERE m.namespace_id = ? AND m.received_at > NOW() - make_interval(days => ?)
          AND NOT EXISTS (SELECT 1 FROM pa_external_refs r WHERE r.namespace_id = m.namespace_id AND r.source = 'mail'
                          AND r.external_id = m.uuid::text)
        ORDER BY m.received_at LIMIT 200
    ]], ns, days or 14)
    local out = { imported = 0, skipped = 0, considered = #rows }
    local Int = require("property_pa.interactions")
    for _, m in ipairs(rows) do
        local ok, err = pcall(U.tx, function()
            if not claim(ns, "mail", m.uuid) then return end -- another import got it
            -- No owner to file it under: marked as seen (so it never blocks the window), not imported.
            if null(m.owner_user_uuid) then out.skipped = out.skipped + 1 return end
            local it = Int.log(ns, { channel = "email", direction = "inbound",
                subject = "Email: " .. tostring(null(m.subject) and "(no subject)" or m.subject):sub(1, 200),
                raw_text = null(m.body_text) and "" or m.body_text, opportunity_uuid = m.opportunity_uuid,
                at = m.received_at, source = "integration" }, m.owner_user_uuid, true)
            db.query([[UPDATE pa_external_refs SET record_uuid = ?
                WHERE namespace_id = ? AND source = 'mail' AND external_id = ?]], it.uuid, ns, tostring(m.uuid))
            out.imported = out.imported + 1
        end)
        if not ok then
            -- A message that can't be imported is marked too, so it can't hold up newer mail.
            ngx.log(ngx.ERR, "[property_pa] mail import ", tostring(m.uuid), ": ", tostring(type(err) == "table"
                and err.message or err))
            claim(ns, "mail", m.uuid)
            out.skipped = out.skipped + 1
        end
    end
    return out
end

-- ------------------------------------------------------------------ GoHighLevel
I.GHL_URL = os.getenv("GHL_API_URL") or "https://services.leadconnectorhq.com"
I.GHL_PAGES = 20 -- pages of 100 per run; a bigger location carries on from its saved cursor on the next run
I.WEBHOOK_PER_MINUTE = 120 -- GHL webhook calls per caller IP

local function ghl_get(token, path)
    local http = require("resty.http").new()
    http:set_timeout(20000)
    local url = I.GHL_URL:gsub("/+$", "") .. path
    if not url:match("^https://") and os.getenv("OPSAPI_INTEGRATIONS_ALLOW_PRIVATE") ~= "true" then
        return nil, "GHL_API_URL must be https"
    end
    local res, err = http:request_uri(url, { method = "GET", ssl_verify = true,
        headers = { Authorization = "Bearer " .. token, Version = "2021-07-28", Accept = "application/json" } })
    if not res then
        ngx.log(ngx.WARN, "[property_pa] GoHighLevel: ", tostring(err))
        return nil, "GoHighLevel couldn't be reached"
    end
    if res.status >= 300 then return nil, "GoHighLevel refused the request (HTTP " .. res.status .. ")" end
    local ok, data = pcall(cjson.decode, res.body or "")
    if not ok or type(data) ~= "table" then return nil, "GoHighLevel returned something that isn't JSON" end
    return data
end

local function s(v) return type(v) == "string" and v ~= "" and v or nil end

--- A phone number in E.164 (UK numbers without a country code are taken as UK). nil when it isn't one.
function I.e164(phone)
    if type(phone) ~= "string" then return nil end
    local p = phone:gsub("%(0%)", ""):gsub("[^%d+]", "")
    if p:sub(1, 2) == "00" then p = "+" .. p:sub(3)
    elseif p:sub(1, 1) == "0" then p = "+44" .. p:sub(2)
    elseif p:sub(1, 1) ~= "+" and #p >= 11 then p = "+" .. p end
    return p:match("^%+[1-9]%d%d%d%d%d%d%d+$") and #p <= 16 and p or nil
end

--- Create or update the CRM person behind one GHL contact. c = { id, first_name, last_name, email, phone, dnd?,
-- consent_basis? }. Matched on the GHL id, then email, then phone (the last 10 digits, so 07700 900111 =
-- +447700900111). GHL's DND flag records an opt-out (never cleared from here); a consent basis is kept when valid.
-- @return "created" | "updated" | "unchanged", contact uuid
function I.ghl_upsert(ns, c, owner_uuid)
    local result, uuid = I.ghl_person(ns, c, owner_uuid)
    if uuid and (c.dnd == true or c.consent_basis) then
        require("property_pa.consent").set(ns, uuid, { consent_basis = c.consent_basis,
            opted_out = c.dnd == true or nil, source = "ghl" })
    end
    return result, uuid
end

function I.ghl_person(ns, c, owner_uuid)
    local F = require("property_pa.facts")
    local gid = tostring(c.id)
    local email = s(c.email) and c.email:lower() or nil
    local phone = I.e164(c.phone)
    local fields = { first_name = s(c.first_name) or "Unknown", last_name = s(c.last_name), email = email,
        phone = phone or s(c.phone) }
    return U.tx(function()
        local existing = U.one([[
            SELECT c.uuid, c.email, c.phone FROM crm_contacts c
            WHERE c.namespace_id = ? AND c.deleted_at IS NULL AND (
                c.uuid = (SELECT record_uuid FROM pa_external_refs WHERE namespace_id = ? AND source = 'ghl'
                          AND external_id = ?)
                OR (?::text IS NOT NULL AND LOWER(c.email) = ?)
                OR (?::text IS NOT NULL AND (RIGHT(regexp_replace(COALESCE(c.phone, ''), '[^0-9]', '', 'g'), 10) = ?
                    OR RIGHT(regexp_replace(COALESCE(c.mobile, ''), '[^0-9]', '', 'g'), 10) = ?)))
            ORDER BY (c.uuid = (SELECT record_uuid FROM pa_external_refs WHERE namespace_id = ? AND source = 'ghl'
                      AND external_id = ?)) DESC NULLS LAST, (LOWER(c.email) = ?) DESC NULLS LAST, c.id
            LIMIT 1 -- ponytail: scans the workspace's contacts for the phone match; index it past ~100k contacts
        ]], ns, ns, gid, email or db.NULL, email or db.NULL, phone or db.NULL, phone and phone:sub(-10) or db.NULL,
            phone and phone:sub(-10) or db.NULL, ns, gid, email or db.NULL)
        if not existing then
            local uuid = require("helper.global").generateUUID()
            -- Claimed first: the same GHL contact arriving twice at once becomes one person.
            if not claim(ns, "ghl", gid, uuid) then
                local ref = U.one("SELECT record_uuid FROM pa_external_refs WHERE namespace_id = ? AND source = 'ghl' "
                    .. "AND external_id = ?", ns, gid)
                return "unchanged", ref and ref.record_uuid
            end
            db.insert("crm_contacts", { uuid = uuid, namespace_id = ns, first_name = fields.first_name,
                last_name = fields.last_name or db.NULL, email = fields.email or db.NULL,
                phone = fields.phone or db.NULL,
                owner_user_uuid = owner_uuid, status = "active",
                metadata = db.raw(db.escape_literal(cjson.encode({ ghl_id = gid, source = "ghl" })) .. "::jsonb") })
            F.record(ns, { target_table = "crm_contacts", target_uuid = uuid, field = "_create",
                value = { ghl_id = gid }, action = "create", source = "integration", source_ref = "ghl:" .. gid })
            return "created", uuid
        end
        db.query([[INSERT INTO pa_external_refs (namespace_id, source, external_id, record_uuid) VALUES (?, 'ghl', ?, ?)
            ON CONFLICT (namespace_id, source, external_id) DO UPDATE SET record_uuid = EXCLUDED.record_uuid]],
            ns, gid, existing.uuid)
        local changed = false
        for _, f in ipairs({ "email", "phone" }) do
            local now = not null(existing[f]) and existing[f] or nil
            local same = f == "phone" and now and I.e164(now) == fields.phone or fields[f] == now
            if fields[f] and not same then
                db.query("UPDATE crm_contacts SET " .. f .. " = ?, updated_at = NOW() WHERE namespace_id = ? "
                    .. "AND uuid = ?", fields[f], ns, existing.uuid)
                F.record(ns, { target_table = "crm_contacts", target_uuid = existing.uuid, field = f, value = fields[f],
                    source = "integration", source_ref = "ghl:" .. gid })
                changed = true
            end
        end
        return changed and "updated" or "unchanged", existing.uuid
    end)
end

--- One step of the GHL pull: carry on the pass under way from its saved cursor, or start a new pass when the last
-- one started an hour ago (or a sync was asked for). settings: ghl_location_id, ghl_token (secret).
-- @return summary | nil, err
function I.ghl_sync(ns, settings, owner_uuid, max_pages)
    local loc, token = s(settings.ghl_location_id), s(settings.ghl_token)
    if not loc or not token then return nil, "Set the GoHighLevel location id and token in the Property PA settings" end
    local st = U.one([[SELECT cursor, (pass_started_at IS NULL OR pass_started_at < NOW() - INTERVAL '1 hour') AS due
        FROM pa_sync_state WHERE namespace_id = ? AND source = 'ghl']], ns)
    local after = st and not null(st.cursor) and st.cursor or nil
    if not after and st and not st.due then return { skipped = "the last pull started less than an hour ago" } end
    if not after then
        db.query([[INSERT INTO pa_sync_state (namespace_id, source, pass_started_at) VALUES (?, 'ghl', NOW())
            ON CONFLICT (namespace_id, source) DO UPDATE SET pass_started_at = NOW()]], ns)
    end
    local out = { created = 0, updated = 0, unchanged = 0, pages = 0, complete = false }
    local err
    for _ = 1, max_pages or I.GHL_PAGES do
        local q = "/contacts/?locationId=" .. ngx.escape_uri(loc) .. "&limit=100"
            .. (after and ("&startAfterId=" .. ngx.escape_uri(after)) or "")
        local data, gerr = ghl_get(token, q)
        if not data then err = gerr break end
        out.pages = out.pages + 1
        local list = type(data.contacts) == "table" and data.contacts or {}
        for _, c in ipairs(list) do
            if s(c.id) then
                local result = I.ghl_upsert(ns, { id = c.id, first_name = s(c.firstName) or s(c.contactName),
                    last_name = c.lastName, email = c.email, phone = c.phone, dnd = c.dnd }, owner_uuid)
                out[result] = out[result] + 1
            end
        end
        after = type(data.meta) == "table" and s(data.meta.startAfterId) or nil
        if #list < 100 or not after then out.complete, after = true, nil break end
    end
    -- Where to carry on next run (nothing = the pass is complete); a failed page is retried from the same place.
    db.query([[UPDATE pa_sync_state SET cursor = ?, last_run_at = NOW(), last_result = ?::jsonb
        WHERE namespace_id = ? AND source = 'ghl']], after or db.NULL, cjson.encode(err and { error = err } or out), ns)
    if err then return nil, err end
    return out
end

--- A GHL webhook body as a contact for I.ghl_upsert: a workflow's webhook (snake_case, contact_id) or an app's
-- ContactCreate / ContactUpdate event (camelCase, id), flat or under `contact`. @return contact | nil
function I.ghl_webhook_contact(body)
    local c = type(body.contact) == "table" and body.contact or body
    local id = s(c.contact_id) or s(c.contactId) or s(c.id)
    if not id or #id > 255 then return nil end
    local function cap(v, n) return v and v:sub(1, n) end
    return { id = id, first_name = cap(s(c.first_name) or s(c.firstName) or s(c.full_name) or s(c.name), 100),
        last_name = cap(s(c.last_name) or s(c.lastName), 100), email = cap(s(c.email), 255),
        phone = cap(s(c.phone), 40),
        dnd = c.dnd == true or c.dnd == "true" or c.opted_out == true, consent_basis = s(c.consent_basis) }
end

--- Ask for a pull now (the hourly pull, early): the job runs it within a few seconds. @return number of runs queued
function I.ghl_request(ns)
    db.query("UPDATE pa_sync_state SET pass_started_at = NULL WHERE namespace_id = ? AND source = 'ghl'", ns)
    return require("helper.plugin-jobs").runNow("property_pa.ghl_sync", ns) or 0
end

return I
