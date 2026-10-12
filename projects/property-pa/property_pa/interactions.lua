-- Interactions (calls, emails, notes, voice notes) are crm_activities rows with the PA columns, and the timeline
-- merges them with events, offers, next actions and confirmed changes. Inbound text is stored as data only: it is
-- never followed as an instruction (build prompt rule 11) — the agents get it inside a quoted, labelled block.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local I = {}

I.CHANNELS = { "call", "email", "whatsapp", "sms", "meeting", "note", "voice" }
I.DIRECTIONS = { "inbound", "outbound", "internal" }
-- sdk.validate rules for logging one.
I.RULES = {
    channel = { enum = I.CHANNELS, required = true }, direction = { enum = I.DIRECTIONS, required = true },
    subject = { type = "string", max = 255 }, raw_text = { type = "text", max = 50000 },
    transcript = { type = "text", max = 50000 }, summary = { type = "text", max = 5000 },
    person_uuid = { type = "string", max = 64 }, opportunity_uuid = { type = "uuid" },
    lead_uuid = { type = "string", max = 64 }, property_uuid = { type = "uuid" }, at = { type = "datetime" },
    meaningful = { type = "boolean" }, audio_document_uuid = { type = "uuid" },
}

local function contact_id(ns, person_uuid)
    if not person_uuid then return nil end
    local c = U.one("SELECT id FROM crm_contacts WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", ns, person_uuid)
    if not c then U.fail(422, "Validation failed", { person_uuid = "not found in this workspace" }) end
    return c.id
end

--- d = { channel, direction, subject?, raw_text?, transcript?, summary?, person_uuid?, opportunity_uuid?, lead_uuid?,
-- property_uuid?, at?, meaningful?, source?, audio_document_uuid? } @return row
-- in_tx = the caller already opened a transaction (the writes join it).
function I.log(ns, d, user_uuid, in_tx)
    local opp
    if d.opportunity_uuid then
        opp = U.one("SELECT uuid, person_uuid FROM pa_opportunities WHERE namespace_id = ? AND uuid = ?::uuid", ns,
            d.opportunity_uuid)
        if not opp then U.fail(422, "Validation failed", { opportunity_uuid = "not found in this workspace" }) end
    end
    local person = d.person_uuid or (opp and opp.person_uuid ~= db.NULL and opp.person_uuid) or nil
    local cid = contact_id(ns, person)
    -- Every other id a caller gives must be this workspace's too (they are stored as plain columns, no trigger).
    for col, tbl in pairs({ property_uuid = "property_deals_properties", lead_uuid = "crm_leads",
                            audio_document_uuid = "property_deals_documents" }) do
        if d[col] and not U.one("SELECT 1 FROM " .. tbl .. " WHERE namespace_id = ? AND uuid = ?", ns, d[col]) then
            U.fail(422, "Validation failed", { [col] = "not found in this workspace" })
        end
    end
    local text = d.summary or d.transcript or d.raw_text or ""
    local subject = d.subject or (d.channel .. ": " .. (text:gsub("%s+", " "):sub(1, 80)))
    local uuid = require("helper.global").generateUUID()
    local meaningful = d.meaningful ~= false
    local tx = in_tx and function(fn) return fn() end or U.tx
    tx(function()
        db.insert("crm_activities", {
            uuid = uuid, namespace_id = ns, activity_type = d.channel, subject = subject:sub(1, 255),
            description = d.summary or db.NULL, contact_id = cid or db.NULL, owner_user_uuid = user_uuid,
            activity_date = d.at and db.raw(db.escape_literal(d.at) .. "::timestamptz") or db.raw("NOW()"),
            completed_at = db.raw("NOW()"), status = "completed",
            channel = d.channel, direction = d.direction, raw_text = d.raw_text or db.NULL,
            transcript = d.transcript or db.NULL, summary = d.summary or db.NULL,
            audio_document_uuid = d.audio_document_uuid or db.NULL, lead_uuid = d.lead_uuid or db.NULL,
            property_uuid = d.property_uuid or db.NULL, opportunity_uuid = opp and opp.uuid or db.NULL,
            meaningful = meaningful, source = d.source or "human",
        })
        if meaningful and opp then
            db.query([[UPDATE pa_opportunities SET last_meaningful_contact_at = GREATEST(COALESCE(last_meaningful_contact_at,
                '-infinity'), COALESCE(?::timestamptz, NOW())), updated_at = NOW() WHERE namespace_id = ? AND uuid = ?::uuid]],
                d.at or db.NULL, ns, opp.uuid)
        end
        if meaningful and person and d.direction ~= "internal" then
            db.query([[
                INSERT INTO pa_relationships (namespace_id, user_uuid, person_uuid, last_meaningful_contact_at)
                VALUES (?, ?, ?, COALESCE(?::timestamptz, NOW()))
                ON CONFLICT (namespace_id, user_uuid, person_uuid) DO UPDATE SET
                    last_meaningful_contact_at = GREATEST(pa_relationships.last_meaningful_contact_at,
                        EXCLUDED.last_meaningful_contact_at), updated_at = NOW()
            ]], ns, user_uuid, person, d.at or db.NULL)
        end
    end)
    return I.get(ns, uuid)
end

I.SELECT = [[
    SELECT a.uuid, a.channel, a.direction, a.subject, a.raw_text, a.transcript, a.summary, a.activity_date AS at,
           a.owner_user_uuid, c.uuid AS person_uuid, a.lead_uuid, a.property_uuid, a.opportunity_uuid, a.meaningful,
           a.source, a.audio_document_uuid, a.created_at
    FROM crm_activities a LEFT JOIN crm_contacts c ON c.id = a.contact_id
]]

function I.get(ns, uuid)
    return U.one(I.SELECT .. " WHERE a.namespace_id = ? AND a.uuid = ? AND a.deleted_at IS NULL", ns, uuid)
end

--- Retention: remove the words (note text, voice transcript, email body, and a subject made from them) of PA
-- interactions older than `days`, keeping the row (who, when, channel, summary). Only PA rows (channel set).
-- @return count
function I.redact(ns, days)
    return #db.query([[UPDATE crm_activities SET raw_text = NULL, transcript = NULL,
            subject = CASE WHEN subject LIKE channel || ': %' THEN channel || ': (text removed)' ELSE subject END
        WHERE namespace_id = ? AND channel IS NOT NULL AND (raw_text IS NOT NULL OR transcript IS NOT NULL)
          AND activity_date < NOW() - make_interval(days => ?) RETURNING id]], ns,
        math.max(30, math.floor(tonumber(days) or 365)))
end

--- The text of an interaction the PA may quote from (for grounding checks).
function I.text(ns, uuid)
    local r = U.one([[SELECT CONCAT_WS(E'\n', raw_text, transcript, summary, description) AS t FROM crm_activities
        WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL]], ns, uuid)
    return r and r.t
end

--- One merged timeline, newest first, for an opportunity or a person.
-- Each item: { kind, at, uuid, title, detail, source, ... }.
function I.timeline(ns, params)
    local opp, person = params.opportunity_uuid, params.person_uuid
    if not U.is_uuid(opp) and not person then U.fail(422, "Validation failed", { opportunity_uuid = "or person_uuid is required" }) end
    local limit = math.min(tonumber(params.limit) or 100, 300)
    local L = db.escape_literal
    -- alias -> "<alias>.opportunity_uuid = ..." (or FALSE when there is no opportunity filter)
    local function opp_f(a) return U.is_uuid(opp) and (a .. ".opportunity_uuid = " .. L(opp) .. "::uuid") or "FALSE" end
    local function person_f(a) return person and (a .. ".person_uuid = " .. L(person)) or "FALSE" end
    local rows = db.query([[
        SELECT * FROM (
            SELECT 'interaction' AS kind, a.activity_date::timestamptz AS at, a.uuid::text AS uuid,
                   a.subject AS title, COALESCE(a.summary, a.transcript, a.raw_text, a.description) AS detail,
                   a.channel AS sub_kind, a.direction, a.source, a.owner_user_uuid AS by_user_uuid
            FROM crm_activities a LEFT JOIN crm_contacts c ON c.id = a.contact_id
            WHERE a.namespace_id = ? AND a.deleted_at IS NULL AND (]] .. opp_f("a") .. [[ OR c.uuid = ]]
                .. (person and L(person) or "NULL") .. [[)
            UNION ALL
            SELECT 'event', e.at, e.uuid::text, e.title, e.details::text, e.kind, NULL, NULL, NULL
            FROM pa_events e WHERE e.namespace_id = ? AND (]] .. opp_f("e") .. " OR " .. person_f("e") .. [[)
            UNION ALL
            SELECT 'offer', o.made_at, o.uuid::text, CONCAT('Offer £', TO_CHAR(o.amount, 'FM999,999,999')), o.conditions,
                   o.response, NULL, NULL, o.authority_user_uuid
            FROM pa_offers o WHERE o.namespace_id = ? AND ]] .. opp_f("o") .. [[
            UNION ALL
            SELECT 'next_action', d.created_at, d.task_uuid, t.title, d.reason, d.pd_status, NULL, NULL, d.owner_user_uuid
            FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
            WHERE d.namespace_id = ? AND ]] .. opp_f("d") .. [[
            UNION ALL
            SELECT 'change', f.created_at, f.uuid::text, CONCAT(f.target_table, '.', f.field), (f.value -> 'v')::text,
                   f.action, NULL, f.source, f.confirmed_by_user_uuid
            FROM pa_field_facts f WHERE f.namespace_id = ? AND f.target_table = 'pa_opportunities'
              AND f.target_uuid = ]] .. (U.is_uuid(opp) and L(opp) or "NULL") .. [[
        ) x ORDER BY at DESC NULLS LAST LIMIT ]] .. limit, ns, ns, ns, ns, ns)
    for _, r in ipairs(rows) do
        if r.kind == "event" and type(r.detail) == "string" then r.detail = U.json(r.detail) end
        if r.kind == "change" and type(r.detail) == "string" then
            local ok, v = pcall(cjson.decode, r.detail)
            if ok then r.detail = v end
        end
    end
    return U.array(rows)
end

return I
