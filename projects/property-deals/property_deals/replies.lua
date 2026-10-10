-- A lead replied: how keen are they, and if they're hot, get someone on the phone.
--   * Replies come from the mail connectors (sender = a lead's email, not on a deal) or are logged by a
--     person (a WhatsApp, SMS, call or DM: POST /leads/{id}/replies).
--   * Score = rules (clear "call me" / "not interested" phrases, a phone number, a question) and, when the
--     workspace has an AI provider, the model's reading of the reply (the text is fenced as untrusted data,
--     never instructions). An opt-out always wins: cold, and it says so.
--   * Hot (score >= hot_score_threshold, default 70): a "Call <name> now" task due in hot_call_within_minutes
--     (default 15) for the lead's owner (else the managers) — the SLA engine escalates it if nobody picks it
--     up — plus app push (WSLCRM iOS/Android) + in-app, email, and the free channels the workspace set up
--     (ntfy, Telegram, SMS from its own phone), each as that person's preferences allow.
local db = require("lapis.db")
local U = require("property_deals.util")

local R = {}

local function null(v) return v == nil or v == db.NULL end

local OPT_OUT = { "not interested", "unsubscribe", "remove me", "stop contacting", "don't contact", "do not contact",
    "no thanks", "no thank you", "leave me alone", "take me off" }
-- Asking for a call / viewing / offer is hot on its own; the rest is interest.
local CALL_NOW = { "call me", "ring me", "phone me", "give me a call", "call back", "call you", "can you call",
    "speak today", "talk today", "free now", "free after", "free this", "book a viewing", "arrange a viewing",
    "make an offer", "asap" }
local KEEN = { "interested", "yes please", "let's talk", "lets talk", "keen", "when can", "can we", "book a", "viewing",
    "how much", "what price", "send me", "available", "sounds good", "tell me more", "i'd like", "i would like" }

local function has_any(text, list)
    for _, w in ipairs(list) do
        if text:find(w, 1, true) then return w end
    end
end

--- Rules only. @return { score, temperature?, reason, opted_out }
function R.rules(text)
    local t = " " .. tostring(text or ""):lower():gsub("[’`]", "'") .. " "
    local opt = has_any(t, OPT_OUT) or (t:match("^%s*stop%s*$") and "stop")
    if opt then return { score = 0, temperature = "cold", reason = "Asked not to be contacted (\"" .. opt .. "\")", opted_out = true } end
    local score, why = 30, {}
    local now = has_any(t, CALL_NOW)
    local keen = has_any(t, KEEN)
    if now then score = score + 50; why[#why + 1] = "asks to talk now (\"" .. now .. "\")"
    elseif keen then score = score + 30; why[#why + 1] = "says \"" .. keen .. "\"" end
    if t:match("%+?%d[%d%s]%d%d%d[%d%s]+%d%d%d") then score = score + 15; why[#why + 1] = "gave a phone number" end
    if t:find("?", 1, true) then score = score + 10; why[#why + 1] = "asked a question" end
    if #t < 12 then score = score - 10 end
    score = math.max(0, math.min(100, score))
    return { score = score, reason = #why > 0 and ("Rules: " .. table.concat(why, ", ")) or "Rules: a plain reply",
             opted_out = false }
end

local function temperature(score, threshold)
    if score >= threshold then return "hot" end
    if score >= 40 then return "warm" end
    return "cold"
end

local INSTRUCTIONS = table.concat({
    "You read one reply from a property lead and judge how ready they are to talk now.",
    "Return JSON only: {\"score\": 0-100, \"temperature\": \"hot|warm|cold\", \"reason\": \"one short sentence\"}.",
    "hot = wants to talk or act now (asks to be called, wants a viewing/offer/price, gives availability).",
    "warm = interested but not now. cold = no, not now, or asks to stop. Asking to stop is always cold.",
}, "\n")

--- AI reading of the reply, or nil (no provider / no usable answer).
local function ai_score(ns, lead, text)
    local Config = require("property_deals.ai.config")
    local route = Config.route(ns, "classify")
    if #route.chain == 0 then return nil end
    local G = require("property_deals.ai.guard")
    local who = { kind = lead.lead_kind, name = lead.first_name, company = lead.company_name }
    local ok, msg = pcall(require("lib.ai-providers").chat, ns, route.chain, {
        { role = "system", content = G.PREAMBLE .. "\n\n[agent:reply_scorer]\n" .. INSTRUCTIONS },
        { role = "user", content = "Lead:\n" .. G.fence("lead", who) .. "\nTheir reply:\n" .. G.fence("reply", text) },
    }, nil, { json = true, max_tokens = 300, local_only = route.local_only, feature = "property_deals:reply_scorer" })
    if not ok or not msg then return nil end
    local out = G.json_object(msg.content)
    if type(out) ~= "table" or tonumber(out.score) == nil then return nil end
    return { score = math.max(0, math.min(100, math.floor(tonumber(out.score)))),
             temperature = ({ hot = "hot", warm = "warm", cold = "cold" })[out.temperature],
             reason = G.text(out.reason, 300) }
end

--- Score a reply text for a lead row (crm_leads + details). @return { score, temperature, reason, opted_out, by }
function R.score(ns, lead, text, settings)
    local threshold = tonumber((settings or {}).hot_score_threshold) or 70
    local rules = R.rules(text)
    if rules.opted_out then rules.by = "rules"; return rules end
    local ai = ai_score(ns, lead, text)
    local r = ai and { score = ai.score, reason = "AI: " .. tostring(ai.reason or ""), by = "ai" }
        or { score = rules.score, reason = rules.reason, by = "rules" }
    r.temperature = temperature(r.score, threshold)
    r.opted_out = false
    return r
end

local function lead_row(ns, lead_uuid)
    return U.one([[
        SELECT l.uuid, l.first_name, l.last_name, l.email, l.phone, l.company_name, l.owner_user_uuid,
               d.lead_kind, d.temperature
        FROM crm_leads l LEFT JOIN property_deals_lead_details d ON d.lead_uuid = l.uuid
        WHERE l.namespace_id = ? AND l.uuid = ? AND l.deleted_at IS NULL
    ]], ns, lead_uuid)
end

local function name_of(lead)
    local n = ((null(lead.first_name) and "" or lead.first_name) .. " " .. (null(lead.last_name) and "" or lead.last_name))
        :gsub("^%s+", ""):gsub("%s+$", "")
    if n == "" then n = not null(lead.company_name) and lead.company_name or "A lead" end
    return n
end

--- Alert the people who should call: app push + in-app, email, ntfy, Telegram, SMS (as each person's prefs allow).
local function alert(ns, lead, task, msg, minutes)
    local N = require("property_deals.notify")
    local who = not null(lead.owner_user_uuid) and { lead.owner_user_uuid } or require("property_deals.engine").managers(ns)
    local first = not null(lead.first_name) and lead.first_name or name_of(lead)
    N.send(ns, who, { kind = "hot_lead", title = "Hot lead: call " .. first .. " now",
        body = first .. " just replied and looks keen. Call within " .. minutes .. " minutes while they're active.",
        route = "task", uuid = task.task_uuid, event = "property_deals.lead.hot" })
    local phone = not null(lead.phone) and (" on " .. lead.phone) or ""
    local snippet = tostring(msg.body_text or ""):gsub("%s+", " "):sub(1, 140)
    local text = "Hot lead: " .. name_of(lead) .. " just replied" .. phone .. ". Call now (within " .. minutes
        .. " min). \"" .. snippet .. "\""
    local M = require("property_deals.messaging")
    for _, ch in ipairs({ "ntfy", "telegram", "sms" }) do
        if M.available(ns, ch) then
            local allowed = {}
            for _, u in ipairs(who) do
                if N.allowed(ns, u, "hot_lead", ch) then allowed[#allowed + 1] = u end
            end
            M.to_users(ns, ch, allowed, { title = "Hot lead: call " .. first .. " now", body = text })
        end
    end
    for _, u in ipairs(who) do
        if N.allowed(ns, u, "hot_lead", "email") then
            local row = U.one("SELECT email FROM users WHERE uuid = ?", u)
            if row and not null(row.email) then
                local esc = function(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
                N.email(row.email, "Hot lead: call " .. name_of(lead) .. " now",
                    "<p><strong>" .. esc(name_of(lead)) .. "</strong> just replied" .. esc(phone)
                    .. " and looks keen. Call within " .. minutes .. " minutes.</p><blockquote>" .. esc(snippet)
                    .. "</blockquote><p>Why: " .. esc(msg.reply_reason or "") .. "</p>", text)
            end
        end
    end
    return #who
end

--- Score a stored reply (property_deals_inbound_messages row with lead_uuid) and act on it.
-- @return { temperature, score, reason, hot_task_uuid? }
function R.handle(ns, msg, settings)
    settings = settings or require("helper.plugin-sdk").settings("property_deals", ns) or {}
    local lead = lead_row(ns, msg.lead_uuid)
    if not lead then return nil end
    local s = R.score(ns, lead, msg.body_text or msg.subject or "", settings)
    local result = { temperature = s.temperature, score = s.score, reason = s.reason, by = s.by }
    db.update("property_deals_inbound_messages", { reply_temperature = s.temperature, reply_score = s.score,
        reply_reason = s.reason:sub(1, 1000), processed_at = db.raw("NOW()") }, { id = msg.id })
    db.query([[
        INSERT INTO property_deals_lead_details (namespace_id, lead_uuid, temperature, hot_score, hot_reason, last_reply_at)
        VALUES (?, ?, ?, ?, ?, ?::timestamptz)
        ON CONFLICT (lead_uuid) DO UPDATE SET temperature = EXCLUDED.temperature, hot_score = EXCLUDED.hot_score,
            hot_reason = EXCLUDED.hot_reason,
            last_reply_at = GREATEST(property_deals_lead_details.last_reply_at, EXCLUDED.last_reply_at), updated_at = NOW()
    ]], ns, lead.uuid, s.temperature, s.score, s.reason:sub(1, 1000), msg.received_at)
    if s.temperature ~= "hot" then return result end

    local minutes = math.max(1, math.min(240, tonumber(settings.hot_call_within_minutes) or 15))
    local Tasks = require("property_deals.tasks")
    -- One open "call now" task per lead: a second hot reply re-alerts on the same task.
    local open = U.one([[
        SELECT task_uuid FROM property_deals_task_details
        WHERE namespace_id = ? AND lead_uuid = ? AND pd_status NOT IN ('done', 'cancelled')
          AND metadata ->> 'kind' = 'hot_lead_call' LIMIT 1
    ]], ns, lead.uuid)
    local task
    if open then
        task = Tasks.get(ns, open.task_uuid)
    else
        local owner = not null(lead.owner_user_uuid) and lead.owner_user_uuid or require("property_deals.engine").managers(ns)[1]
        local phone = not null(lead.phone) and lead.phone or "no number on file"
        task = U.tx(function()
            require("property_deals.workspace").ensure(ns, owner, settings)
            return Tasks.create(ns, {
                title = "Call " .. name_of(lead) .. " now — they just replied",
                description = "Phone: " .. phone .. "\nReply (" .. tostring(msg.channel or "email") .. "): "
                    .. tostring(msg.body_text or ""):sub(1, 1500) .. "\n\nWhy hot: " .. s.reason,
                lead_uuid = lead.uuid, owner_user_uuid = owner, priority = "critical",
                due_at = os.date("!%Y-%m-%dT%H:%M:%SZ", ngx.time() + minutes * 60), sla_minutes = minutes,
                approval_rule = "none", metadata = { kind = "hot_lead_call", message_uuid = msg.uuid },
            }, owner)
        end)
    end
    db.update("property_deals_inbound_messages", { hot_task_uuid = task.task_uuid }, { id = msg.id })
    msg.reply_reason = s.reason
    result.hot_task_uuid = task.task_uuid
    result.alerted = alert(ns, lead, task, msg, minutes)
    return result
end

--- A person logs a reply that didn't come by email (WhatsApp, SMS, a call, a DM).
function R.log(ns, lead_uuid, b, user_uuid)
    local row = db.query([[
        INSERT INTO property_deals_inbound_messages (namespace_id, external_id, lead_uuid, channel, from_name, subject,
            received_at, body_text, matched_by, logged_by_user_uuid)
        VALUES (?, ?, ?, ?, ?, ?, COALESCE(?::timestamptz, NOW()), ?, 'logged', ?) RETURNING *
    ]], ns, "logged:" .. require("helper.global").generateUUID(), lead_uuid, b.channel, b.from_name or db.NULL,
        b.subject or db.NULL, b.received_at or db.NULL, tostring(b.text):sub(1, 60000), user_uuid or db.NULL)[1]
    local result = R.handle(ns, row)
    return row, result
end

function R.list(ns, lead_uuid, limit)
    return U.array(db.query([[
        SELECT uuid, lead_uuid, deal_uuid, channel, from_address, from_name, subject, received_at,
               LEFT(body_text, 2000) AS body_text, reply_temperature, reply_score, reply_reason, hot_task_uuid, matched_by,
               logged_by_user_uuid
        FROM property_deals_inbound_messages WHERE namespace_id = ? AND lead_uuid = ?
        ORDER BY received_at DESC LIMIT ?
    ]], ns, lead_uuid, limit or 50))
end

--- Leads to call now: replied hot in the last 7 days and their "call now" task is still open. Newest first.
function R.hot(ns, owner_uuid, limit)
    local mine = owner_uuid and (" AND l.owner_user_uuid = " .. db.escape_literal(owner_uuid)) or ""
    return U.array(db.query([[
        SELECT l.uuid AS lead_uuid, l.first_name, l.last_name, l.company_name, l.phone, l.email, l.owner_user_uuid,
               d.lead_kind, d.hot_score, d.hot_reason, d.last_reply_at,
               (SELECT t.task_uuid FROM property_deals_task_details t WHERE t.namespace_id = d.namespace_id
                  AND t.lead_uuid = l.uuid AND t.pd_status NOT IN ('done', 'cancelled')
                  AND t.metadata ->> 'kind' = 'hot_lead_call' LIMIT 1) AS call_task_uuid,
               (SELECT t.due_at FROM property_deals_task_details t WHERE t.namespace_id = d.namespace_id
                  AND t.lead_uuid = l.uuid AND t.pd_status NOT IN ('done', 'cancelled')
                  AND t.metadata ->> 'kind' = 'hot_lead_call' LIMIT 1) AS call_due_at
        FROM property_deals_lead_details d JOIN crm_leads l ON l.uuid = d.lead_uuid AND l.deleted_at IS NULL
        WHERE d.namespace_id = ? AND d.temperature = 'hot' AND d.last_reply_at > NOW() - INTERVAL '7 days'
          AND EXISTS (SELECT 1 FROM property_deals_task_details t WHERE t.namespace_id = d.namespace_id
                      AND t.lead_uuid = l.uuid AND t.pd_status NOT IN ('done', 'cancelled')
                      AND t.metadata ->> 'kind' = 'hot_lead_call')]] .. mine .. [[
        ORDER BY d.last_reply_at DESC LIMIT ?
    ]], ns, limit or 20))
end

return R
