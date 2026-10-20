-- Inbound reply ingestion + rule-based classification (AI may suggest, never auto-send).
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("opsapi_marketing.util")
local E = require("opsapi_marketing.eligibility")

local R = {}

local CLASSES = {
    interested = true, more_info = true, pricing = true, meeting = true,
    not_interested = true, unsubscribe = true, out_of_office = true,
    complaint = true, bounce = true, human_assist = true, uncertain = true,
}

--- Deterministic keyword classifier (no LLM required for v1 path).
function R.classify_text(subject, body)
    local text = ((subject or "") .. " " .. (body or "")):lower()
    if text:find("unsubscribe", 1, true) or text:find("remove me", 1, true)
        or text:find("%f[%w]stop%f[%W]") then
        return "unsubscribe", 0.9
    end
    if text:find("out of office", 1, true) or text:find("automatic reply", 1, true)
        or text:find("away from (the )?office", 1, true) then
        return "out_of_office", 0.85
    end
    if text:find("complaint", 1, true) or text:find("spam", 1, true)
        or text:find("gdpr", 1, true) or text:find("solicitor", 1, true) then
        return "complaint", 0.7
    end
    if text:find("undeliverable", 1, true) or text:find("mail delivery failed", 1, true)
        or text:find("bounce", 1, true) then
        return "bounce", 0.8
    end
    if text:find("not interested", 1, true) or text:find("no thanks", 1, true)
        or text:find("please don't", 1, true) then
        return "not_interested", 0.75
    end
    if text:find("pricing", 1, true) or text:find("how much", 1, true)
        or text:find("quote", 1, true) or text:find("cost", 1, true) then
        return "pricing", 0.7
    end
    if text:find("meeting", 1, true) or text:find("calendar", 1, true)
        or text:find("book a call", 1, true) or text:find("schedule", 1, true) then
        return "meeting", 0.7
    end
    if text:find("more info", 1, true) or text:find("tell me more", 1, true)
        or text:find("interested in learning", 1, true) then
        return "more_info", 0.65
    end
    if text:find("interested", 1, true) or text:find("sounds good", 1, true)
        or text:find("let's talk", 1, true) then
        return "interested", 0.65
    end
    return "uncertain", 0.4
end

--- Idempotent ingest. external_id + provider dedupe via mkt_webhook_receipts.
function R.ingest(ns, payload)
    payload = payload or {}
    local provider = payload.provider or "manual"
    local external_id = payload.external_id
    if external_id then
        local exists = U.one([[
            SELECT id FROM mkt_webhook_receipts
            WHERE namespace_id = ? AND provider = ? AND external_id = ?
        ]], ns, provider, tostring(external_id))
        if exists then
            return { duplicate = true }
        end
        db.query([[
            INSERT INTO mkt_webhook_receipts (namespace_id, provider, external_id, event_type)
            VALUES (?, ?, ?, ?)
        ]], ns, provider, tostring(external_id), payload.event_type or "reply")
    end

    local class, conf = R.classify_text(payload.subject, payload.body_text or payload.text)
    if payload.classification and CLASSES[payload.classification] then
        class = payload.classification
        conf = tonumber(payload.confidence) or conf
    end
    local needs_human = class == "uncertain" or class == "human_assist"
        or class == "complaint" or (conf and conf < 0.55)

    local contact_uuid = payload.contact_uuid
    local address = payload.address or payload.from
    if not contact_uuid and address then
        local c = U.one([[
            SELECT uuid FROM crm_contacts
            WHERE namespace_id = ? AND (lower(email) = lower(?) OR phone = ? OR mobile = ?)
              AND deleted_at IS NULL LIMIT 1
        ]], ns, address, address, address)
        contact_uuid = c and c.uuid
    end

    local delivery_id = payload.delivery_id
    local campaign_id = payload.campaign_id
    if not delivery_id and payload.delivery_uuid then
        local d = U.one("SELECT id, campaign_id, contact_uuid FROM mkt_deliveries WHERE namespace_id = ? AND uuid = ?",
            ns, payload.delivery_uuid)
        if d then
            delivery_id, campaign_id = d.id, d.campaign_id
            contact_uuid = contact_uuid or d.contact_uuid
        end
    end

    local function nvl(v)
        if v == nil then return db.NULL end
        return v
    end

    -- Compliance side-effects (code gate — AI cannot skip this)
    if class == "unsubscribe" and contact_uuid then
        E.opt_out(ns, contact_uuid, payload.channel or "email", {
            address = address,
            source = "reply_unsubscribe",
            reason = "unsubscribe",
            evidence = "inbound_reply",
        })
    elseif class == "complaint" and address then
        local s = U.one([[
            SELECT id FROM mkt_suppressions
            WHERE namespace_id = ? AND lower(address) = lower(?) AND channel IS NOT DISTINCT FROM ?
        ]], ns, address, payload.channel or "email")
        if not s then
            db.query([[
                INSERT INTO mkt_suppressions (namespace_id, channel, address, contact_uuid, reason, source)
                VALUES (?, ?, ?, ?, 'complaint', 'reply')
            ]], ns, payload.channel or "email", U.lower(address), nvl(contact_uuid))
        end
    elseif class == "bounce" and address then
        local s = U.one([[
            SELECT id FROM mkt_suppressions
            WHERE namespace_id = ? AND lower(address) = lower(?) AND channel IS NOT DISTINCT FROM ?
        ]], ns, address, payload.channel or "email")
        if not s then
            db.query([[
                INSERT INTO mkt_suppressions (namespace_id, channel, address, contact_uuid, reason, source)
                VALUES (?, ?, ?, ?, 'hard_bounce', 'bounce')
            ]], ns, payload.channel or "email", U.lower(address), nvl(contact_uuid))
        end
    end

    local row = db.query([[
        INSERT INTO mkt_replies
            (namespace_id, channel, delivery_id, campaign_id, contact_uuid, address,
             classification, confidence, subject, body_text, raw, needs_human, classified_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?, ?)
        RETURNING *
    ]], ns, payload.channel or "email", nvl(delivery_id), nvl(campaign_id),
        nvl(contact_uuid), nvl(address),
        class, nvl(conf), nvl(payload.subject), nvl(payload.body_text or payload.text),
        cjson.encode(payload.raw or {}), needs_human,
        payload.classified_by or "rules")[1]

    -- NEVER auto-send from classification
    return {
        reply = row,
        auto_send = false,
        note = "Classification recorded only; no automatic outbound message.",
    }
end

function R.list(ns, params)
    params = params or {}
    local page = math.max(1, tonumber(params.page) or 1)
    local per = math.min(100, math.max(1, tonumber(params.per_page) or 20))
    local where = { "namespace_id = ?" }
    local args = { ns }
    if params.classification then
        where[#where + 1] = "classification = ?"
        args[#args + 1] = params.classification
    end
    if params.campaign_id then
        where[#where + 1] = "campaign_id = ?"
        args[#args + 1] = tonumber(params.campaign_id)
    end
    local sql = "SELECT * FROM mkt_replies WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY created_at DESC LIMIT ? OFFSET ?"
    args[#args + 1] = per
    args[#args + 1] = (page - 1) * per
    return db.query(sql, unpack(args))
end

return R
