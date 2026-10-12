-- The PA (the chat assistant on Today) and the workspace playbook.
--   GET    /pa/briefing          everything the PA needs to start: who I am, my day (urgent tasks, due, hot leads,
--                                approvals, deals at risk) and the playbook. One call, so a small model stays on track.
--                                Hot leads and lead news only for people with property_deals_leads.read.
--   GET    /playbooks            the playbook sections (seeded from a default the first time)
--   PUT    /playbooks/:key       { title?, body?, position? } create or edit a section (managers)
--   DELETE /playbooks/:key       (managers)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local PB = require("property_deals.playbook")

return function(app)
    app:get("/playbooks", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        return sdk.ok(PB.list(sdk.namespace_id(self)))
    end))

    app:put("/playbooks/:key", sdk.handler({ permission = "property_deals_settings.manage" }, U.guard(function(self)
        local key = tostring(self.params.key or "")
        if not key:match("^[a-z0-9_]+$") or #key > 60 then
            return sdk.error(422, "Validation failed", { key = "lowercase letters, digits and _ (max 60)" })
        end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, { title = { type = "string", max = 160 }, body = { type = "text" },
            position = { type = "integer", min = 0, max = 1000 } }, true)
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns = sdk.namespace_id(self)
        PB.ensure(ns)
        local existing = U.one("SELECT id FROM property_deals_playbooks WHERE namespace_id = ? AND key = ?", ns, key)
        if not existing and not data.title then return sdk.error(422, "Validation failed", { title = "required for a new section" }) end
        if data.body and #data.body > 20000 then return sdk.error(422, "Validation failed", { body = "max 20000 characters" }) end
        data.updated_by_user_uuid, data.updated_at = sdk.user(self).uuid, db.raw("NOW()")
        if existing then
            db.update("property_deals_playbooks", data, { id = existing.id })
        else
            data.namespace_id, data.key = ns, key
            data.body = data.body or ""
            data.position = data.position or 100
            db.insert("property_deals_playbooks", data)
        end
        return sdk.ok(U.one([[SELECT uuid, key, title, body, position, updated_by_user_uuid, updated_at
            FROM property_deals_playbooks WHERE namespace_id = ? AND key = ?]], ns, key))
    end)))

    app:delete("/playbooks/:key", sdk.handler({ permission = "property_deals_settings.manage" }, function(self)
        local res = db.query("DELETE FROM property_deals_playbooks WHERE namespace_id = ? AND key = ? RETURNING id",
            sdk.namespace_id(self), tostring(self.params.key or ""))
        if #res == 0 then return sdk.not_found("Playbook section") end
        return sdk.ok({ deleted = true })
    end))

    app:get("/pa/briefing", sdk.handler({ permission = "property_deals_tasks.read" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local manager = sdk.can(self, "property_deals_approvals", "manage")
        local who = U.one([[SELECT COALESCE(NULLIF(TRIM(CONCAT(first_name, ' ', last_name)), ''), email) AS name
            FROM users WHERE uuid = ?]], me) or {}
        local mine = "d.owner_user_uuid = " .. db.escape_literal(me)
        local tasks = db.query([[
            SELECT d.task_uuid, t.title, d.pd_status, d.due_at, (d.due_at < NOW()) AS overdue, d.urgency_score,
                   d.blocking, d.deal_uuid, cd.name AS deal_name, d.lead_uuid,
                   NULLIF(TRIM(CONCAT(l.first_name, ' ', l.last_name)), '') AS lead_name
            FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
            LEFT JOIN property_deals_deals dl ON dl.uuid = d.deal_uuid LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
            LEFT JOIN crm_leads l ON l.uuid = d.lead_uuid
            WHERE d.namespace_id = ? AND ]] .. mine .. [[ AND d.pd_status NOT IN ('done', 'cancelled')
              AND (d.snoozed_until IS NULL OR d.snoozed_until < NOW())
            ORDER BY d.urgency_score DESC, d.due_at ASC NULLS LAST LIMIT 10
        ]], ns)
        local counts = U.one([[
            SELECT COUNT(*)::int AS open, COUNT(*) FILTER (WHERE due_at < NOW())::int AS overdue,
                   COUNT(*) FILTER (WHERE due_at >= NOW() AND due_at < date_trunc('day', NOW()) + INTERVAL '1 day')::int AS due_today
            FROM property_deals_task_details d WHERE d.namespace_id = ? AND ]] .. mine .. [[
              AND d.pd_status NOT IN ('done', 'cancelled')
        ]], ns)
        local approvals = db.query([[
            SELECT uuid, title, action, rule, created_at FROM property_deals_approvals
            WHERE namespace_id = ? AND status = 'pending' AND (? OR rule <> 'manager')
            ORDER BY created_at LIMIT 8
        ]], ns, manager)
        local red = db.query([[
            SELECT dl.uuid, cd.name, dl.money_at_risk, dl.health_reasons FROM property_deals_deals dl
            JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
            WHERE dl.namespace_id = ? AND dl.status = 'active' AND dl.health = 'red'
              AND (? OR cd.owner_user_uuid = ?) ORDER BY dl.money_at_risk DESC LIMIT 5
        ]], ns, manager, me)
        local leads_ok = sdk.can(self, "property_deals_leads", "read")
        local news = not leads_ok and {} or db.query([[
            SELECT s.lead_uuid, NULLIF(TRIM(CONCAT(l.first_name, ' ', l.last_name)), '') AS lead_name, s.title, s.occurred_at
            FROM property_deals_lead_signals s JOIN crm_leads l ON l.uuid = s.lead_uuid AND l.deleted_at IS NULL
            WHERE s.namespace_id = ? AND s.used_at IS NULL AND s.created_at > NOW() - INTERVAL '7 days'
              AND (? OR l.owner_user_uuid = ?) ORDER BY s.occurred_at DESC LIMIT 8
        ]], ns, manager, me)
        local Replies = require("property_deals.replies")
        return sdk.ok({
            me = { name = who.name, is_manager = manager },
            today = os.date("!%Y-%m-%d"),
            counts = counts,
            hot_leads = leads_ok and Replies.hot(ns, manager and nil or me, 5) or sdk.array({}),
            my_tasks = sdk.array(tasks),
            approvals_waiting = sdk.array(approvals),
            deals_at_risk = sdk.array(red),
            fresh_news = sdk.array(news),
            playbook = PB.text(ns, 9000),
        })
    end)))
end
