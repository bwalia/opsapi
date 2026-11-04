--[[
    Lead pipeline: background work
    ==============================

    handlers: the "core.crm" subscriber of the event outbox (helper/plugin-events.lua),
    delivered at least once with retries:
      crm.lead.created        start the pipeline for the lead (lead-pipeline.after_created)
      crm.activity.created/updated   send a meeting's calendar invite / cancellation
      invoice.paid            close the referral whose commission it bills

    start(): timers on worker 0 of each pod. Several pods run them at once,
    so every step claims its row with a conditional UPDATE ... RETURNING
    before it notifies anyone: nothing is sent twice.
      every 30 s   next steps due soon / overdue (owner), escalations (managers),
                   nurture dates reached, meeting reminders and outcome prompts
      every 10 s   AI analyses waiting in the queue
      every 6 h    web research older than two years is removed (Google's terms)
]]

local db = require("lapis.db")
local U = require("lib.crm.util")

local Jobs = {}

local function meeting_event(event)
    local data = type(event.data) == "table" and event.data or {}
    if data.activity_type and data.activity_type ~= "meeting" then return true end
    if not event.entity_id or not event.namespace_id then return true end
    return require("lib.crm.lead-meetings").deliver(event.namespace_id, event.entity_id)
end

Jobs.handlers = {
    ["crm.lead.created"] = function(event)
        if not event.entity_id or not event.namespace_id then return true end
        return require("lib.crm.lead-pipeline").after_created(event.namespace_id, event.entity_id)
    end,
    ["crm.activity.created"] = meeting_event,
    ["crm.activity.updated"] = meeting_event,
    ["invoice.paid"] = function(event)
        if not event.entity_id or not event.namespace_id then return true end
        return require("lib.crm.partners").invoice_paid(event.namespace_id, event.entity_id)
    end,
}

-- ---------------------------------------------------------------------------
-- Next steps: due soon, overdue, escalation
-- ---------------------------------------------------------------------------

local function name_of(l)
    return U.full_name(l.first_name, l.last_name) or U.nz(l.company_name) or U.nz(l.email) or "a lead"
end

local STEP_WORDS = { call = "Call", email = "Email", follow_up = "Follow up with", meeting = "Meeting with", task = "Task for" }

function Jobs.due_steps()
    local Notify = require("lib.crm.lead-notify")
    -- Owner: 15 minutes before (or as soon as we notice it's overdue).
    for _, l in ipairs(db.query([[
        UPDATE crm_leads l SET next_action_warned_at = NOW()
        WHERE l.id IN (
            SELECT id FROM crm_leads
            WHERE deleted_at IS NULL AND status IN ('new','contacting','qualified','meeting')
              AND next_action_at IS NOT NULL AND next_action_warned_at IS NULL AND owner_user_uuid IS NOT NULL
              AND next_action_at <= NOW() + interval '15 minutes'
            ORDER BY next_action_at LIMIT 200 FOR UPDATE SKIP LOCKED)
        RETURNING l.id, l.uuid, l.namespace_id, l.owner_user_uuid, l.first_name, l.last_name, l.company_name, l.email,
                  l.next_action_type, l.next_action_at, (l.next_action_at < NOW()) AS overdue
    ]])) do
        local verb = STEP_WORDS[l.next_action_type] or "Follow up with"
        Notify.send(tonumber(l.namespace_id), { l.owner_user_uuid }, {
            kind = l.overdue and "step_overdue" or "step_due", lead_uuid = l.uuid, email = l.overdue == true,
            title = (l.overdue and "Overdue: " or "Due soon: ") .. verb .. " " .. name_of(l),
            body = l.overdue and "This next step is past its time. Do it now, or move it to a time that works."
                or "This next step is due in the next 15 minutes.",
        })
    end
    -- Managers: still not done escalate_after_minutes after it was due.
    for _, l in ipairs(db.query([[
        UPDATE crm_leads l SET next_action_escalated_at = NOW()
        WHERE l.id IN (
            SELECT cl.id FROM crm_leads cl
            LEFT JOIN crm_lead_settings s ON s.namespace_id = cl.namespace_id
            WHERE cl.deleted_at IS NULL AND cl.status IN ('new','contacting','qualified','meeting')
              AND cl.next_action_at IS NOT NULL AND cl.next_action_escalated_at IS NULL
              AND cl.next_action_at + make_interval(mins => COALESCE(NULLIF(s.settings->>'escalate_after_minutes', '')::int, 60)) < NOW()
            ORDER BY cl.next_action_at LIMIT 200 FOR UPDATE OF cl SKIP LOCKED)
        RETURNING l.id, l.uuid, l.namespace_id, l.owner_user_uuid, l.first_name, l.last_name, l.company_name, l.email,
                  l.next_action_type, l.next_action_at
    ]])) do
        local ns = tonumber(l.namespace_id)
        local settings = require("lib.crm.lead-settings").get(ns)
        local managers = require("lib.crm.lead-access").managers(ns, settings)
        local verb = STEP_WORDS[l.next_action_type] or "Follow up with"
        local owner = U.nz(l.owner_user_uuid) and U.one([[SELECT NULLIF(TRIM(CONCAT(first_name, ' ', last_name)), '') AS n, email
            FROM users WHERE uuid = ?]], l.owner_user_uuid)
        Notify.send(ns, managers, {
            kind = "step_escalated", lead_uuid = l.uuid,
            title = "Escalated: " .. verb .. " " .. name_of(l) .. " is overdue",
            body = owner and ("It's with " .. (owner.n or owner.email) .. ". Check in, or give the lead to someone else.")
                or "Nobody owns this lead yet. Give it to someone.",
        })
    end
end

--- Nurture leads whose "contact again" date has come back to Contacting.
function Jobs.nurture_returns()
    local Pipeline = require("lib.crm.lead-pipeline")
    for _, l in ipairs(db.query([[
        SELECT uuid, namespace_id, owner_user_uuid, first_name, last_name, company_name, email FROM crm_leads
        WHERE deleted_at IS NULL AND status = 'nurture' AND nurture_until IS NOT NULL AND nurture_until <= CURRENT_DATE
        ORDER BY nurture_until LIMIT 200
    ]])) do
        local ns = tonumber(l.namespace_id)
        local moved = Pipeline.move(ns, l.uuid, "contacting", nil, { reason = "Nurture date reached" })
        if moved and U.nz(l.owner_user_uuid) then
            require("lib.crm.lead-notify").send(ns, { l.owner_user_uuid }, {
                kind = "nurture_back", lead_uuid = l.uuid, title = "Time to contact " .. name_of(l) .. " again",
                body = "The nurture date you set has come. A call is planned for today.",
            })
        end
    end
end

function Jobs.purge_research()
    db.query([[
        UPDATE crm_lead_analyses SET result = result - 'research'
        WHERE result -> 'research' IS NOT NULL AND created_at < NOW() - make_interval(days => ?)
    ]], require("lib.crm.lead-research").KEEP_DAYS)
end

-- ---------------------------------------------------------------------------
-- Timers
-- ---------------------------------------------------------------------------

local function guarded(name, fn)
    return function(premature)
        if premature then return end
        local ok, err = pcall(fn)
        if not ok then ngx.log(ngx.ERR, "[crm-leads] ", name, " failed: ", tostring(err)) end
        pcall(function() require("helper.plugin-events").releaseConnection() end)
    end
end

local ai_busy = false

function Jobs.tick()
    Jobs.due_steps()
    Jobs.nurture_returns()
    if U.crm() then require("lib.crm.lead-meetings").tick() end
end

function Jobs.ai_tick()
    if ai_busy then return end
    ai_busy = true
    local ok, err = pcall(require("lib.crm.lead-ai").process, 2)
    ai_busy = false
    if not ok then error(err, 0) end
end

--- Called from PluginEvents.start (worker 0 only).
function Jobs.start()
    if ngx.worker.id() ~= 0 then return end
    ngx.timer.every(30, guarded("tick", Jobs.tick))
    ngx.timer.every(10, guarded("ai", Jobs.ai_tick))
    ngx.timer.every(6 * 3600, guarded("purge", Jobs.purge_research))
end

return Jobs
