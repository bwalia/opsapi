-- SLA engine (SPEC §3.3), run every minute by jobs/sla_tick.lua.
-- For each open task with a clock (sla_started_at -> due_at), by share of the
-- window used (thresholds are workspace settings):
--   >= sla_warn_pct (75)     warn the owner                       (sla_warned_at)
--   >= sla_breach_pct (100)  tell managers + owner, task overdue   (sla_breached_at, task.overdue)
--   >= sla_reassign_pct (125) reassign to a manager, or to the escalation queue
--                            (escalation_action setting)           (task.escalated)
-- Each step is claimed with UPDATE ... WHERE <flag> IS NULL RETURNING, so a step
-- happens once even if two workers tick together. Snoozed tasks are skipped.
local cjson = require("cjson")
local db = require("lapis.db")
local Notify = require("property_deals.notify")

local S = {}

local function claim(sql, ...)
    return db.query(sql, ...)[1]
end

function S.tick(ns, settings)
    settings = settings or {}
    local warn = tonumber(settings.sla_warn_pct) or 75
    local breach = tonumber(settings.sla_breach_pct) or 100
    local reassign = tonumber(settings.sla_reassign_pct) or 125
    local action = settings.escalation_action or "reassign_manager"
    local E = require("property_deals.engine")
    local managers
    local stats = { warned = 0, overdue = 0, escalated = 0 }

    local rows = db.query([[
        SELECT d.task_uuid, d.deal_uuid, d.owner_user_uuid, d.escalation_level, d.sla_warned_at, d.sla_breached_at,
               t.title, cd.name AS deal_name,
               EXTRACT(EPOCH FROM (NOW() - d.sla_started_at)) * 100.0
                 / EXTRACT(EPOCH FROM (d.due_at - d.sla_started_at)) AS pct
        FROM property_deals_task_details d
        JOIN kanban_tasks t ON t.uuid = d.task_uuid
        LEFT JOIN property_deals_deals dl ON dl.uuid = d.deal_uuid
        LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
        WHERE d.namespace_id = ? AND d.pd_status NOT IN ('done', 'cancelled')
          AND d.due_at IS NOT NULL AND d.sla_started_at IS NOT NULL AND d.due_at > d.sla_started_at
          AND (d.snoozed_until IS NULL OR d.snoozed_until < NOW())
          AND d.escalation_level < 3
          AND NOW() >= d.sla_started_at + (d.due_at - d.sla_started_at) * (? / 100.0)
    ]], ns, warn)

    for _, r in ipairs(rows) do
        local pct = tonumber(r.pct) or 0
        local what = r.deal_name and (r.title .. " — " .. r.deal_name) or r.title
        local base = { route = "task", uuid = r.task_uuid, deal_uuid = r.deal_uuid ~= db.NULL and r.deal_uuid or nil }

        if pct >= warn and claim([[
            UPDATE property_deals_task_details SET sla_warned_at = NOW(), escalation_level = GREATEST(escalation_level, 1)
            WHERE task_uuid = ? AND sla_warned_at IS NULL RETURNING task_uuid
        ]], r.task_uuid) then
            stats.warned = stats.warned + 1
            if pct < breach then
                Notify.send(ns, { r.owner_user_uuid }, setmetatable({ kind = "sla_warning", event = "property_deals.task.sla_warning",
                    title = "Due soon", body = what .. " is " .. math.floor(pct) .. "% through its time" }, { __index = base }))
                require("helper.plugin-sdk").emit(ns, "property_deals.task.sla_warning",
                    { uuid = r.task_uuid, deal_uuid = base.deal_uuid, pct = math.floor(pct) })
            end
        end

        if pct >= breach and claim([[
            UPDATE property_deals_task_details SET sla_breached_at = NOW(), escalation_level = GREATEST(escalation_level, 2)
            WHERE task_uuid = ? AND sla_breached_at IS NULL RETURNING task_uuid
        ]], r.task_uuid) then
            stats.overdue = stats.overdue + 1
            managers = managers or E.managers(ns)
            local to = { r.owner_user_uuid }
            for _, m in ipairs(managers) do to[#to + 1] = m end
            Notify.send(ns, to, setmetatable({ kind = "task_overdue", event = "property_deals.task.overdue",
                title = "Overdue", body = what .. " is overdue" }, { __index = base }))
            require("helper.plugin-sdk").emit(ns, "property_deals.task.overdue",
                { uuid = r.task_uuid, deal_uuid = base.deal_uuid, owner_user_uuid = r.owner_user_uuid })
        end

        if pct >= reassign then
            managers = managers or E.managers(ns)
            local new_owner = action == "reassign_manager" and managers[1] or nil
            if new_owner == r.owner_user_uuid then new_owner = managers[2] or new_owner end
            local claimed = claim([[
                UPDATE property_deals_task_details SET escalation_level = 3,
                       metadata = metadata || ?::jsonb, updated_at = NOW()
                WHERE task_uuid = ? AND escalation_level < 3 RETURNING task_uuid
            ]], cjson.encode({ escalated_from = r.owner_user_uuid, escalation_queue = new_owner == nil }), r.task_uuid)
            if claimed then
                stats.escalated = stats.escalated + 1
                if new_owner and new_owner ~= r.owner_user_uuid then
                    require("property_deals.tasks").update(ns, r.task_uuid, { owner_user_uuid = new_owner }, nil)
                end
                Notify.send(ns, new_owner and { new_owner } or managers, setmetatable({ kind = "task_escalated",
                    event = "property_deals.task.escalated", title = "Escalated to you",
                    body = what .. " passed " .. reassign .. "% of its time" }, { __index = base }))
                require("helper.plugin-sdk").emit(ns, "property_deals.task.escalated", {
                    uuid = r.task_uuid, deal_uuid = base.deal_uuid, from = r.owner_user_uuid,
                    to = new_owner or cjson.null, queue = new_owner == nil,
                })
            end
        end
    end
    return stats
end

return S
