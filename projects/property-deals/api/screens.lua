-- Endpoints shaped for screens (SPEC §3.8 web, §3.9 iOS): one call instead of several.
--   GET /me                    who I am here: permissions per module, manager?, workspace settings
--   GET /today                 my tasks by urgency, red deals, approvals waiting, £ at risk
--   GET /deals/board           deals by stage for the Kanban (one template), with gate hints
--   GET /deals/:id/overview    the deal page / iOS deal view in one response
--   GET /deals/:id/timeline    audit trail of the deal and everything on it (newest first)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")
local Deals = require("property_deals.deals")
local Engine = require("property_deals.engine")
local Template = require("property_deals.template")
local Days = require("property_deals.workdays")

local MODULES = { "deals", "properties", "buyers", "tasks", "suppliers", "compliance", "approvals", "ai", "settings", "reports" }
local ACTIONS = { "read", "create", "update", "delete", "manage" }
local PUBLIC_SETTINGS = { "timezone", "jurisdiction", "currency", "digest_time", "due_time", "sla_warn_pct",
                          "sla_breach_pct", "sla_reassign_pct", "escalation_action", "red_min_working_days" }

local function is_manager(self)
    return sdk.can(self, "property_deals_approvals", "manage")
end

local TASK_SELECT = [[
    SELECT d.task_uuid, t.title, d.pd_status, d.stage_key, d.template_key, d.due_at, d.sla_minutes,
           d.urgency_score, d.urgency_why, d.blocking, d.compliance, d.escalation_level, d.agent_eligible,
           d.agent_key, d.approval_rule, d.owner_user_uuid, d.owner_agent_key, d.snoozed_until,
           (d.due_at < NOW()) AS overdue, d.deal_uuid, cd.name AS deal_name, dl.health AS deal_health
    FROM property_deals_task_details d
    JOIN kanban_tasks t ON t.uuid = d.task_uuid
    LEFT JOIN property_deals_deals dl ON dl.uuid = d.deal_uuid
    LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
]]

--- Pending approvals the caller may decide (never their own request; manager rule needs a manager).
local function approvals_for(self, ns, limit, deal_uuid)
    local me = sdk.user(self).uuid
    return db.query([[
        SELECT a.uuid, a.title, a.subject_type, a.action, a.rule, a.deal_uuid, a.task_uuid, a.created_at,
               a.requested_by_agent, a.requested_by_user_uuid, jsonb_array_length(a.decisions) AS approvals_so_far,
               cd.name AS deal_name, r.agent_key, r.provider, r.model, r.cost_usd,
               (r.provider = 'jobshout') AS from_jobshout
        FROM property_deals_approvals a
        LEFT JOIN property_deals_agent_runs r ON r.uuid = a.agent_run_uuid
        LEFT JOIN property_deals_deals dl ON dl.uuid = a.deal_uuid
        LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
        WHERE a.namespace_id = ? AND a.status = 'pending'
          AND (a.rule <> 'manager' OR ?) AND a.requested_by_user_uuid IS DISTINCT FROM ?
          AND NOT (a.decisions @> ?::jsonb)
          AND (?::uuid IS NULL OR a.deal_uuid = ?::uuid)
        ORDER BY a.created_at LIMIT ?
    ]], ns, is_manager(self), me, cjson.encode({ { user_uuid = me } }), deal_uuid or db.NULL, deal_uuid or db.NULL, limit)
end

local function screens(app)
    app:get("/me", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local perms = {}
        for _, m in ipairs(MODULES) do
            local list = {}
            for _, a in ipairs(ACTIONS) do
                if sdk.can(self, "property_deals_" .. m, a) then list[#list + 1] = a end
            end
            perms[m] = sdk.array(list)
        end
        local settings, public = sdk.settings(self), {}
        for _, k in ipairs(PUBLIC_SETTINGS) do public[k] = settings[k] end
        local state = require("property_deals.workspace").get(sdk.namespace_id(self))
        return sdk.ok({
            user_uuid = sdk.user(self).uuid, namespace_uuid = self.namespace.uuid,
            is_manager = is_manager(self), permissions = perms, settings = public,
            setup_done = state ~= nil and state.setup_at ~= nil,
        })
    end))

    app:get("/today", sdk.handler({ permission = "property_deals_tasks.read" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local limit = math.min(tonumber(self.params.limit) or 50, 200)
        local tasks = db.query(TASK_SELECT .. [[
            WHERE d.namespace_id = ? AND d.owner_user_uuid = ? AND d.pd_status NOT IN ('done', 'cancelled')
              AND (d.snoozed_until IS NULL OR d.snoozed_until < NOW())
            ORDER BY d.urgency_score DESC, d.due_at ASC NULLS LAST, d.id LIMIT ?
        ]], ns, me, limit)
        local cal = Days.calendar(ns, sdk.settings(self))
        local day_end = Days.at(cal, Days.add(cal, Days.today(cal), 1), "00:00")
        local counts = U.one([[
            SELECT COUNT(*)::int AS open,
                   COUNT(*) FILTER (WHERE due_at < NOW())::int AS overdue,
                   COUNT(*) FILTER (WHERE due_at >= NOW() AND due_at < ?::timestamptz)::int AS due_today,
                   COUNT(*) FILTER (WHERE pd_status = 'awaiting_approval')::int AS awaiting_approval
            FROM property_deals_task_details
            WHERE namespace_id = ? AND owner_user_uuid = ? AND pd_status NOT IN ('done', 'cancelled')
        ]], day_end, ns, me)
        local mine = is_manager(self) and "TRUE" or ("(cd.owner_user_uuid = " .. db.escape_literal(me)
            .. " OR EXISTS (SELECT 1 FROM property_deals_task_details x WHERE x.deal_uuid = dl.uuid AND x.owner_user_uuid = "
            .. db.escape_literal(me) .. " AND x.pd_status NOT IN ('done', 'cancelled')))")
        local red = db.query([[
            SELECT dl.uuid, cd.name, dl.stage_key, dl.health, dl.health_reasons, dl.money_at_risk,
                   dl.target_completion_date, dl.predicted_completion_date
            FROM property_deals_deals dl JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
            WHERE dl.namespace_id = ? AND dl.status = 'active' AND dl.health = 'red' AND ]] .. mine .. [[
            ORDER BY dl.money_at_risk DESC, dl.target_completion_date NULLS LAST LIMIT 20
        ]], ns)
        local money = U.one([[
            SELECT COALESCE(SUM(dl.money_at_risk), 0) AS total FROM property_deals_deals dl
            JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
            WHERE dl.namespace_id = ? AND dl.status = 'active' AND ]] .. mine, ns).total
        local approvals = approvals_for(self, ns, 10)
        return sdk.ok({
            generated_at = Days.now(), today = Days.today(cal),
            counts = counts, tasks = sdk.array(tasks), red_deals = sdk.array(red),
            money_at_risk = tonumber(money), approvals_waiting = sdk.array(approvals),
            approvals_waiting_count = #approvals,
        })
    end)))

    app:get("/deals/board", sdk.handler({ permission = "property_deals_deals.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local Store = require("property_deals.templates_store")
        local key = self.params.template
        if not key or key == "" then
            -- Default: the template most active deals use; on a tie (e.g. no deals yet)
            -- the workspace's default_template setting, then by name.
            local preferred = tostring((sdk.settings(self) or {}).default_template or "uk_guaranteed_sale")
            local first = U.one([[
                SELECT t.key FROM property_deals_workflow_templates t
                LEFT JOIN property_deals_workflow_template_versions v ON v.template_uuid = t.uuid
                LEFT JOIN property_deals_deals d ON d.template_version_uuid = v.uuid AND d.status = 'active'
                WHERE t.namespace_id = ? AND t.is_active
                GROUP BY t.key, t.name ORDER BY COUNT(d.id) DESC, (t.key = ?) DESC, t.name LIMIT 1
            ]], ns, preferred)
            key = first and first.key
        end
        if not key then return sdk.not_found("Template") end
        local tpl, version = Store.active(ns, key)
        if not tpl then return sdk.not_found("Template") end
        local deals = db.query([[
            SELECT dl.uuid, cd.name, dl.stage_key, dl.status, dl.health, dl.money_at_risk, dl.deal_type,
                   dl.target_completion_date, dl.predicted_completion_date, cd.owner_user_uuid,
                   p.address_line1, p.postcode,
                   (SELECT COUNT(*)::int FROM property_deals_task_details x WHERE x.deal_uuid = dl.uuid
                      AND x.pd_status NOT IN ('done', 'cancelled')) AS open_tasks,
                   (SELECT COUNT(*)::int FROM property_deals_task_details x WHERE x.deal_uuid = dl.uuid
                      AND x.pd_status NOT IN ('done', 'cancelled') AND x.due_at < NOW()) AS overdue_tasks
            FROM property_deals_deals dl
            JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
            JOIN property_deals_workflow_template_versions v ON v.uuid = dl.template_version_uuid
            LEFT JOIN property_deals_properties p ON p.uuid = dl.property_uuid
            WHERE dl.namespace_id = ? AND v.template_uuid = ? AND dl.status IN ('active', 'on_hold')
            ORDER BY (dl.health = 'red') DESC, dl.target_completion_date NULLS LAST, dl.created_at
        ]], ns, tpl.uuid)
        local columns, index = {}, {}
        for _, s in ipairs(version.definition.stages) do
            local g = s.entry_gate
            columns[#columns + 1] = {
                key = s.key, name = s.name, parallel = s.parallel == true, optional = s.optional == true,
                has_gate = g ~= nil, gate_summary = g and {
                    tasks = #(g.tasks_done or {}), compliance = #(g.compliance_passed or {}),
                    documents = #(g.documents or {}), fields = #(g.fields or {}),
                    no_open_blocking_enquiries = g.no_open_blocking_enquiries == true,
                } or cjson.null,
                deals = sdk.array({}),
            }
            index[s.key] = columns[#columns]
        end
        local other = sdk.array({})
        for _, d in ipairs(deals) do
            local col = index[d.stage_key]
            if col then table.insert(col.deals, d) else other[#other + 1] = d end
        end
        return sdk.ok({ template = { uuid = tpl.uuid, key = tpl.key, name = tpl.name, version = version.version },
                        columns = sdk.array(columns), other_stage = other })
    end)))

    app:get("/deals/:id/overview", sdk.handler({ permission = "property_deals_deals.read" }, U.guard(function(self)
        local ns, settings = sdk.namespace_id(self), sdk.settings(self)
        local ctx = Engine.context(ns, self.params.id, settings)
        if not ctx then return sdk.not_found("Deal") end
        local deal, id = ctx.deal, ctx.deal.uuid

        local stages, cur_idx = {}, select(2, Template.stage(ctx.def, deal.stage_key)) or 0
        for i, s in ipairs(ctx.def.stages) do
            local applies = Engine.when(ctx, s.when)
            stages[#stages + 1] = {
                key = s.key, name = s.name, parallel = s.parallel == true, optional = s.optional == true,
                has_gate = s.entry_gate ~= nil,
                state = not applies and "skipped" or (i < cur_idx and "done") or (i == cur_idx and "current") or "upcoming",
            }
        end
        local next_key = Engine.next_stage(ctx)
        local next_gate = next_key and Engine.gate(ctx, next_key) or cjson.null

        local parties = db.query([[
            SELECT p.uuid, p.role, p.is_primary, p.contact_uuid, p.account_uuid,
                   COALESCE(c.first_name || COALESCE(' ' || c.last_name, ''), a.name) AS name,
                   COALESCE(c.email, a.email) AS email, COALESCE(c.mobile, c.phone, a.phone) AS phone
            FROM property_deals_deal_parties p
            LEFT JOIN crm_contacts c ON c.uuid = p.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = p.account_uuid
            WHERE p.namespace_id = ? AND p.deal_uuid = ? ORDER BY p.role, p.is_primary DESC
        ]], ns, id)
        local tasks = db.query(TASK_SELECT .. [[
            WHERE d.namespace_id = ? AND d.deal_uuid = ? AND d.pd_status NOT IN ('done', 'cancelled')
            ORDER BY d.urgency_score DESC, d.due_at ASC NULLS LAST
        ]], ns, id)
        local task_counts = U.one([[
            SELECT COUNT(*)::int AS total, COUNT(*) FILTER (WHERE pd_status = 'done')::int AS done,
                   COUNT(*) FILTER (WHERE pd_status NOT IN ('done', 'cancelled') AND due_at < NOW())::int AS overdue
            FROM property_deals_task_details WHERE namespace_id = ? AND deal_uuid = ?
        ]], ns, id)
        local enquiries = db.query([[
            SELECT uuid, title, owner_party, status, blocking, raised_at, due_at, source
            FROM property_deals_enquiries WHERE namespace_id = ? AND deal_uuid = ? AND status = 'open' ORDER BY raised_at
        ]], ns, id)
        local chases = db.query([[
            SELECT uuid, to_party, to_name, channel, subject, status, sent_at, reply_at, enquiry_uuid
            FROM property_deals_chases WHERE namespace_id = ? AND deal_uuid = ? ORDER BY COALESCE(sent_at, created_at) DESC LIMIT 5
        ]], ns, id)
        -- Compliance: every item the template expects, with its latest check.
        local compliance = {}
        for _, item in ipairs(ctx.def.compliance or {}) do
            if item.subject ~= "workspace" then
                local c = U.one([[
                    SELECT uuid, status, checked_by_user_uuid, checked_at, expires_at, risk_rating
                    FROM property_deals_compliance_checks WHERE namespace_id = ? AND deal_uuid = ? AND check_type = ?
                    ORDER BY updated_at DESC LIMIT 1
                ]], ns, id, item.key)
                compliance[#compliance + 1] = {
                    key = item.key, name = item.name, party_role = item.party_role,
                    applies = Engine.when(ctx, item.when), check = c or cjson.null,
                    status = c and c.status or "not_started",
                }
            end
        end
        local documents = db.query([[
            SELECT category, COUNT(*)::int AS count FROM property_deals_documents
            WHERE namespace_id = ? AND (deal_uuid = ? OR (property_uuid IS NOT NULL AND property_uuid::text = ?))
            GROUP BY category ORDER BY category
        ]], ns, id, deal.property_uuid or "")
        local matches = deal.property_uuid and db.query([[
            SELECT m.uuid, m.buyer_profile_uuid, m.score, m.status, m.breakdown
            FROM property_deals_matches m WHERE m.namespace_id = ? AND m.property_uuid = ? ORDER BY m.score DESC LIMIT 3
        ]], ns, deal.property_uuid) or {}

        local cal = ctx.cal
        return sdk.ok({
            deal = deal,
            property = ctx.property or cjson.null,
            stage = { current = deal.stage_key, next = next_key or cjson.null, stages = sdk.array(stages), next_gate = next_gate },
            health = {
                health = deal.health, reasons = deal.health_reasons, money_at_risk = deal.money_at_risk,
                target_completion_date = deal.target_completion_date or cjson.null,
                predicted_completion_date = deal.predicted_completion_date or cjson.null,
                working_days_left = deal.target_completion_date
                    and Days.between(cal, Days.today(cal), tostring(deal.target_completion_date)) or cjson.null,
                late_penalty_per_day = deal.late_penalty_per_day, late_penalty_cap_days = deal.late_penalty_cap_days or cjson.null,
            },
            parties = sdk.array(parties),
            tasks = { counts = task_counts, open = sdk.array(tasks) },
            enquiries = sdk.array(enquiries),
            recent_chases = sdk.array(chases),
            compliance = sdk.array(compliance),
            documents = sdk.array(documents),
            approvals_waiting = sdk.array(approvals_for(self, ns, 20, id)),
            top_matches = sdk.array(matches),
        })
    end)))

    app:get("/deals/:id/timeline", sdk.handler({ permission = "property_deals_deals.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local deal = Deals.get(ns, self.params.id)
        if not deal then return sdk.not_found("Deal") end
        if not U.one("SELECT to_regclass('audit_events') IS NOT NULL AS ok").ok then
            return sdk.ok(sdk.array({}), { page = 1, per_page = 0, total = 0 })
        end
        local page, per_page, offset = sdk.page(self.params)
        local ids = [[
            SELECT ?::text UNION SELECT ?::text
            UNION SELECT uuid::text FROM property_deals_task_details WHERE deal_uuid = ?
            UNION SELECT uuid::text FROM property_deals_enquiries WHERE deal_uuid = ?
            UNION SELECT uuid::text FROM property_deals_chases WHERE deal_uuid = ?
            UNION SELECT uuid::text FROM property_deals_compliance_checks WHERE deal_uuid = ?
            UNION SELECT uuid::text FROM property_deals_approvals WHERE deal_uuid = ?
            UNION SELECT uuid::text FROM property_deals_bookings WHERE deal_uuid = ?
            UNION SELECT uuid::text FROM property_deals_documents WHERE deal_uuid = ?
            UNION SELECT uuid::text FROM property_deals_deal_parties WHERE deal_uuid = ?
        ]]
        local id = deal.uuid
        local args = { ns, id, deal.crm_deal_uuid, id, id, id, id, id, id, id, id, id }
        local where = [[ namespace_id = ? AND (entity_id IN (]] .. ids .. [[) OR new_values ->> 'uuid' = ?
                         OR new_values ->> 'deal_uuid' = ?) ]]
        local q_args = {}
        for _, v in ipairs(args) do q_args[#q_args + 1] = v end
        q_args[#q_args + 1], q_args[#q_args + 2] = id, id
        local rows = db.query("SELECT uuid, event_type, entity_type, entity_id, actor_user_uuid, old_values, new_values, created_at "
            .. "FROM audit_events WHERE " .. where .. " ORDER BY created_at DESC, id DESC LIMIT " .. per_page .. " OFFSET " .. offset,
            unpack(q_args))
        return sdk.ok(sdk.array(rows), { page = page, per_page = per_page })
    end)))
end

return function(app)
    screens(app)
end
