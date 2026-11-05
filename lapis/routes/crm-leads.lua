--[[
    CRM Leads API: the lead pipeline (docs/plans/LEAD_TO_CASH_PIPELINE.md)
    =====================================================================

    Every route checks the crm_leads permission, and the visibility rule
    (lib/crm/lead-access.lua): managers (crm_leads "manage") see every lead,
    everyone else their own and unassigned ones.

    Lists and views
      GET    /api/v2/crm/leads                     list (stage, owner=me|unassigned|uuid, due=overdue|today, hot,
                                                   source, priority, search, sort, page, per_page)
      GET    /api/v2/crm/leads/board               the pipeline board: stages with counts, value and cards
      GET    /api/v2/crm/leads/funnel              funnel, timings, speed to lead, by source (from, to = YYYY-MM-DD)
      GET    /api/v2/crm/leads/stats               counts (older clients)
      GET    /api/v2/crm/leads/my-steps            my overdue / today's steps, today's meetings
      GET    /api/v2/crm/leads/team                people who can work leads (owner picker)
    One lead
      POST   /api/v2/crm/leads                     create (the pipeline starts by itself)
      GET    /api/v2/crm/leads/:uuid               lead + latest AI analysis + meetings + referrals
      GET    /api/v2/crm/leads/:uuid/timeline
      PUT    /api/v2/crm/leads/:uuid               edit details (a stage or owner change goes through the rules)
      DELETE /api/v2/crm/leads/:uuid
      POST   /api/v2/crm/leads/:uuid/stage         { stage, reason?, nurture_until? }
      POST   /api/v2/crm/leads/:uuid/assign        { owner_user_uuid | null }
      POST   /api/v2/crm/leads/:uuid/calls         { outcome, notes?, duration_minutes?, next_at?, lost_reason? }
      POST   /api/v2/crm/leads/:uuid/steps         { type, due_at, note?, subject? }
      POST   /api/v2/crm/leads/:uuid/steps/:activity_uuid   { status: completed|cancelled, note? }
      POST   /api/v2/crm/leads/:uuid/qualify       { answers?, estimated_value?, currency?, expected_close_date?, move? }
      POST   /api/v2/crm/leads/:uuid/analyse       run the AI again
      POST   /api/v2/crm/leads/:uuid/convert       { name?, value?, currency?, pipeline_uuid?, stage?, expected_close_date? }
      POST   /api/v2/crm/leads/:uuid/meetings      book a meeting
      PUT    /api/v2/crm/meetings/:uuid            move it;  POST .../cancel  POST .../outcome
    Settings (managers)
      GET|PUT /api/v2/crm/leads/settings
      GET|POST /api/v2/crm/leads/assignment-rules;  PUT|DELETE /api/v2/crm/leads/assignment-rules/:uuid
      GET|PUT /api/v2/crm/leads/notification-settings (+ POST .../test-telegram)
]]

local cjson = require("cjson")
local db = require("lapis.db")
local Api = require("lib.crm.api")
local U = require("lib.crm.util")
local Access = require("lib.crm.lead-access")
local Pipeline = require("lib.crm.lead-pipeline")
local Settings = require("lib.crm.lead-settings")
local Stages = require("lib.crm.lead-stages")
local CrmLeadNotificationQueries = require("queries.CrmLeadNotificationQueries")

local H = Api.handler

-- The lead in this workspace that this person may see, else a response.
local function visible_lead(self)
    local lead = Pipeline.find(self.namespace.id, self.params.uuid)
    if not lead then return nil, Api.not_found() end
    if not Access.can_see(self, lead) then return nil, Api.not_found() end
    return lead
end

local function workable_lead(self)
    local lead, res = visible_lead(self)
    if not lead then return nil, res end
    if not Access.can_work(self, lead) then return nil, Api.denied("You can only work leads you own or unassigned ones") end
    return lead
end

local function full(self, uuid)
    local ns = self.namespace.id
    local settings = Settings.get(ns)
    local lead = Pipeline.get(ns, uuid, settings)
    if not lead then return nil end
    lead.analysis = require("lib.crm.lead-ai").for_viewer(lead.analysis, lead, Access.me(self))
    lead.meetings = require("lib.crm.lead-meetings").for_lead(ns, lead.id)
    lead.referrals = require("lib.crm.partners").referrals_for(ns, not U.null(lead.converted_deal_id) and lead.converted_deal_id or nil, lead.id)
    lead.permissions = { can_work = Access.can_work(self, lead), is_manager = Access.is_manager(self),
        can_assign_any = Access.is_manager(self), can_convert = Access.can(self, "update") and U.crm() }
    lead.call_outcomes = Pipeline.CALL_OUTCOMES
    return lead
end

local LEAD_FIELDS = { "first_name", "last_name", "email", "phone", "company_name", "job_title", "source", "channel",
    "campaign", "referrer_url", "landing_page_url", "priority", "notes" }
local MAX = { notes = 10000, referrer_url = 2000, landing_page_url = 2000 }
local PRIORITIES = { low = true, medium = true, high = true, urgent = true }

local function lead_fields(data, out)
    for _, f in ipairs(LEAD_FIELDS) do
        if data[f] ~= nil then
            if data[f] == cjson.null or data[f] == "" then
                out[f] = f == "first_name" and "" or db.NULL
            elseif type(data[f]) ~= "string" then
                return nil, { status = 422, code = "LEAD_INVALID", message = f .. " must be text", fields = { [f] = "text" } }
            else
                out[f] = U.text(data[f], MAX[f] or 255) or db.NULL
            end
        end
    end
    if out.priority and out.priority ~= db.NULL and not PRIORITIES[out.priority] then
        return nil, { status = 422, code = "LEAD_INVALID", message = "Priority is low, medium, high or urgent", fields = { priority = "low | medium | high | urgent" } }
    end
    if out.email and out.email ~= db.NULL and not tostring(out.email):match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
        return nil, { status = 422, code = "LEAD_INVALID", message = "That email doesn't look right", fields = { email = "valid email" } }
    end
    return out
end

return function(app)
    -- ---------------------------------------------------------------------
    -- Literal paths first (so they aren't captured by /:uuid)
    -- ---------------------------------------------------------------------

    app:get("/api/v2/crm/leads", H("crm_leads", "read", function(self)
        local ns = self.namespace.id
        local settings = Settings.get(ns)
        local scope_sql, scope_params = Access.scope(self)
        local q = {}
        for _, k in ipairs({ "stage", "owner", "due", "hot", "source", "search", "sort", "page", "per_page" }) do q[k] = self.params[k] end
        q.stage = q.stage or self.params.status
        local result = Pipeline.list(ns, { sql = scope_sql, params = scope_params }, Access.me(self), q, settings)
        if U.nz(self.params.priority) and PRIORITIES[self.params.priority] then
            -- ponytail: priority filtered after paging; older clients only, move into P.list if it's used more.
            local kept = {}
            for _, l in ipairs(result.items) do if l.priority == self.params.priority then kept[#kept + 1] = l end end
            result.items = U.array(kept)
        end
        return Api.ok(result.items, 200, result.meta)
    end))

    app:get("/api/v2/crm/leads/board", H("crm_leads", "read", function(self)
        local ns = self.namespace.id
        local scope_sql, scope_params = Access.scope(self)
        return Api.ok(Pipeline.board(ns, { sql = scope_sql, params = scope_params }, Settings.get(ns), {
            per_stage = self.params.per_stage, recent_days = self.params.recent_days,
            owner = self.params.owner, me = Access.me(self) }))
    end))

    app:get("/api/v2/crm/leads/funnel", H("crm_leads", "read", function(self)
        local ns = self.namespace.id
        local from = U.date(self.params.from) or db.query("SELECT (CURRENT_DATE - 89)::text AS d")[1].d
        local to = U.date(self.params.to) or db.query("SELECT CURRENT_DATE::text AS d")[1].d
        if db.query("SELECT ?::date > ?::date AS bad", from, to)[1].bad then
            return Api.fail({ status = 422, code = "FUNNEL_DATES", message = "The start date must be before the end date" })
        end
        if db.query("SELECT ?::date - ?::date > 1830 AS bad", to, from)[1].bad then
            return Api.fail({ status = 422, code = "FUNNEL_DATES", message = "Pick up to five years at a time" })
        end
        local scope_sql, scope_params = Access.scope(self)
        return Api.ok(Pipeline.funnel(ns, { sql = scope_sql, params = scope_params }, Settings.get(ns), from, to))
    end))

    app:get("/api/v2/crm/leads/stats", H("crm_leads", "read", function(self)
        local ns = self.namespace.id
        local scope_sql, scope_params = Access.scope(self)
        local args = { ns }
        for _, p in ipairs(scope_params) do args[#args + 1] = p end
        local row = db.query([[
            SELECT COUNT(*) AS total_leads,
                COUNT(*) FILTER (WHERE status = 'new') AS new_leads,
                COUNT(*) FILTER (WHERE status = 'contacting') AS contacted_leads,
                COUNT(*) FILTER (WHERE status = 'contacting') AS contacting_leads,
                COUNT(*) FILTER (WHERE status = 'qualified') AS qualified_leads,
                COUNT(*) FILTER (WHERE status = 'meeting') AS meeting_leads,
                COUNT(*) FILTER (WHERE status = 'converted') AS converted_leads,
                COUNT(*) FILTER (WHERE status = 'nurture') AS nurture_leads,
                COUNT(*) FILTER (WHERE status = 'lost') AS lost_leads,
                COUNT(*) FILTER (WHERE next_action_at < NOW() AND status IN ('new','contacting','qualified','meeting')) AS overdue_leads,
                COUNT(*) FILTER (WHERE owner_user_uuid IS NULL AND status IN ('new','contacting','qualified','meeting')) AS unassigned_leads,
                COALESCE(SUM(estimated_value) FILTER (WHERE status IN ('new','contacting','qualified','meeting')), 0) AS open_value,
                CASE WHEN COUNT(*) FILTER (WHERE status IN ('converted','lost')) > 0
                    THEN ROUND(COUNT(*) FILTER (WHERE status = 'converted')::numeric
                        / COUNT(*) FILTER (WHERE status IN ('converted','lost')) * 100, 2) ELSE 0 END AS conversion_rate
            FROM crm_leads l WHERE l.namespace_id = ? AND l.deleted_at IS NULL AND ]] .. scope_sql, unpack(args))[1]
        row.leads_by_source = U.array(db.query([[SELECT source, COUNT(*) AS count FROM crm_leads l
            WHERE l.namespace_id = ? AND l.deleted_at IS NULL AND ]] .. scope_sql .. " GROUP BY source ORDER BY count DESC",
            unpack(args)))
        row.currency = Settings.get(ns).currency
        return Api.ok(row)
    end))

    app:get("/api/v2/crm/leads/my-steps", H("crm_leads", "read", function(self)
        return Api.ok(Pipeline.my_steps(self.namespace.id, Access.me(self), Access.is_manager(self)))
    end))

    app:get("/api/v2/crm/leads/team", H("crm_leads", "read", function(self)
        return Api.ok(U.array(Access.workers(self.namespace.id)))
    end))

    -- Settings ------------------------------------------------------------

    app:get("/api/v2/crm/leads/settings", H("crm_leads", "read", function(self)
        local ns = self.namespace.id
        local s = Settings.get(ns)
        return Api.ok({ settings = s, stage_labels = Stages.labels(s.stage_labels), stages = Stages.ORDER,
            call_outcomes = Pipeline.CALL_OUTCOMES, meeting_types = require("lib.crm.lead-meetings").TYPES,
            ai_providers = U.array(db.query([[SELECT uuid, name, provider_type, is_local, enabled FROM namespace_ai_providers
                WHERE namespace_id = ? AND provider_type <> 'jobshout' ORDER BY name]], ns)),
            web_research = require("lib.crm.lead-research").provider(ns) ~= nil,
            can_edit = Access.is_manager(self) })
    end))

    app:put("/api/v2/crm/leads/settings", H("crm_leads", "manage", function(self)
        local saved, errs = Settings.save(self.namespace.id, Access.me(self), self.body)
        if not saved then return Api.fail({ status = 422, code = "SETTINGS_INVALID", message = "Some settings need fixing", fields = errs }) end
        return Api.ok(saved)
    end))

    app:get("/api/v2/crm/leads/assignment-rules", H("crm_leads", "read", function(self)
        local rows = db.query([[SELECT uuid, name, position, conditions, assignee_user_uuid, pool, enabled, created_at, updated_at
            FROM crm_lead_assignment_rules WHERE namespace_id = ? ORDER BY position, id]], self.namespace.id)
        for _, r in ipairs(rows) do r.conditions = U.json(r.conditions, {}); r.pool = U.array(U.json(r.pool, {})) end
        return Api.ok(U.array(rows))
    end))

    local function rule_input(ns, b)
        local name = U.text(b.name, 120)
        if not name then return nil, { name = "required" } end
        local c = type(b.conditions) == "table" and b.conditions or {}
        local conditions = {}
        for _, k in ipairs({ "sources", "channels", "campaigns", "keywords" }) do
            if c[k] ~= nil then
                if type(c[k]) ~= "table" or #c[k] > 50 then return nil, { ["conditions." .. k] = "a list of up to 50 words" } end
                local list = {}
                for _, v in ipairs(c[k]) do local t = U.text(v, 80); if t then list[#list + 1] = t end end
                conditions[k] = U.array(list)
            end
        end
        local assignee = U.nz(b.assignee_user_uuid)
        local pool = {}
        if type(b.pool) == "table" then for _, u in ipairs(b.pool) do if U.nz(u) then pool[#pool + 1] = u end end end
        if not assignee and #pool == 0 then return nil, { assignee_user_uuid = "pick a person or a pool" } end
        for _, u in ipairs(assignee and { assignee } or pool) do
            if not Access.worker(ns, u) then return nil, { assignee_user_uuid = "everyone must be able to work leads" } end
        end
        return { name = name, conditions = U.enc(conditions), assignee_user_uuid = assignee or db.NULL, pool = U.enc(U.array(pool)),
            position = tonumber(b.position) or 0, enabled = b.enabled ~= false }
    end

    app:post("/api/v2/crm/leads/assignment-rules", H("crm_leads", "manage", function(self)
        local ns = self.namespace.id
        local row, errs = rule_input(ns, self.body)
        if not row then return Api.fail({ status = 422, code = "RULE_INVALID", message = "The rule needs fixing", fields = errs }) end
        row.namespace_id, row.created_by_uuid = ns, Access.me(self)
        local created = db.insert("crm_lead_assignment_rules", row, { returning = { "uuid" } })[1]
        return Api.ok({ uuid = created.uuid }, 201)
    end))

    app:put("/api/v2/crm/leads/assignment-rules/:rule_uuid", H("crm_leads", "manage", function(self)
        local ns = self.namespace.id
        if not U.is_uuid(self.params.rule_uuid) then return Api.not_found("Rule not found") end
        local row, errs = rule_input(ns, self.body)
        if not row then return Api.fail({ status = 422, code = "RULE_INVALID", message = "The rule needs fixing", fields = errs }) end
        row.updated_at = db.raw("NOW()")
        local n = db.update("crm_lead_assignment_rules", row, { namespace_id = ns, uuid = self.params.rule_uuid })
        if (n.affected_rows or 0) == 0 then return Api.not_found("Rule not found") end
        return Api.ok({ uuid = self.params.rule_uuid })
    end))

    app:delete("/api/v2/crm/leads/assignment-rules/:rule_uuid", H("crm_leads", "manage", function(self)
        if not U.is_uuid(self.params.rule_uuid) then return Api.not_found("Rule not found") end
        local n = db.delete("crm_lead_assignment_rules", { namespace_id = self.namespace.id, uuid = self.params.rule_uuid })
        if (n.affected_rows or 0) == 0 then return Api.not_found("Rule not found") end
        return Api.ok({ deleted = true })
    end))

    -- Notification settings (owner only, unchanged behaviour) ----------------

    app:get("/api/v2/crm/leads/notification-settings", H("crm_leads", "read", function(self)
        return Api.ok(CrmLeadNotificationQueries.getForApi(self.namespace.id))
    end))

    app:put("/api/v2/crm/leads/notification-settings", H("crm_leads", "read", function(self)
        if not (self.is_namespace_owner or self.is_platform_admin) then
            return Api.denied("Only the workspace owner can change notification settings")
        end
        local body = self.body
        return Api.ok(CrmLeadNotificationQueries.upsert(self.namespace.id, {
            notify_admin = body.notify_admin == true, admin_email = body.admin_email,
            send_confirmation = body.send_confirmation == true, telegram_enabled = body.telegram_enabled == true,
            telegram_bot_token = body.telegram_bot_token, telegram_chat_id = body.telegram_chat_id,
        }))
    end))

    app:post("/api/v2/crm/leads/notification-settings/test-telegram", H("crm_leads", "read", function(self)
        if not (self.is_namespace_owner or self.is_platform_admin) then
            return Api.denied("Only the workspace owner can send a test alert")
        end
        local ok, err = CrmLeadNotificationQueries.sendTestTelegram(self.namespace.id, {
            telegram_bot_token = self.body.telegram_bot_token, telegram_chat_id = self.body.telegram_chat_id })
        if not ok then return Api.fail({ status = 400, code = "TELEGRAM_TEST", message = err or "Telegram test failed" }) end
        return Api.ok({ sent = true })
    end))

    -- ---------------------------------------------------------------------
    -- Create
    -- ---------------------------------------------------------------------

    app:post("/api/v2/crm/leads", H("crm_leads", "create", function(self)
        local ns, me = self.namespace.id, Access.me(self)
        return require("helper.idempotency").run(self, ns, me, function()
            local data = self.body
            if not U.nz(data.first_name) and not U.nz(data.email) then
                return Api.fail({ status = 400, code = "LEAD_INVALID", message = "A first name or an email is required",
                    fields = { first_name = "or email" } })
            end
            local row, err = lead_fields(data, {})
            if not row then return Api.fail(err) end
            row.first_name = row.first_name ~= db.NULL and row.first_name or ""
            row.source = row.source ~= db.NULL and row.source or "manual"
            row.priority = row.priority ~= db.NULL and row.priority or "medium"
            local stage = data.status ~= nil and Stages.normalise(data.status) or "new"
            if not stage or not Stages.is_open(stage) then
                return Api.fail({ status = 422, code = "LEAD_STAGE_INVALID", message = "A new lead starts in an open stage",
                    fields = { status = "new | contacting | qualified | meeting" } })
            end
            -- Owner: the creator, unless they leave it unassigned or (managers) pick someone.
            local owner = me
            if data.owner_user_uuid == cjson.null or data.unassigned == true then
                owner = nil
            elseif U.nz(data.owner_user_uuid) and data.owner_user_uuid ~= me then
                if not Access.is_manager(self) then return Api.denied("Only managers can give a new lead to someone else") end
                if not Access.worker(ns, data.owner_user_uuid) then
                    return Api.fail({ status = 422, code = "LEAD_OWNER_INVALID", message = "That person can't work leads",
                        fields = { owner_user_uuid = "must be able to work leads" } })
                end
                owner = data.owner_user_uuid
            end
            local value
            if data.estimated_value ~= nil and data.estimated_value ~= cjson.null then
                value = U.money(data.estimated_value)
                if not value then return Api.fail({ status = 422, code = "LEAD_VALUE", message = "The value must be a positive amount",
                    fields = { estimated_value = "amount" } }) end
            end
            local meta = type(data.metadata) == "table" and data.metadata or {}
            if value then meta.value_from = "person" end
            row.uuid = require("helper.global").generateUUID()
            row.namespace_id, row.status, row.score = ns, stage, 0
            row.owner_user_uuid = owner or db.NULL
            row.assigned_at = owner and db.raw("NOW()") or db.NULL
            row.estimated_value = value or db.NULL
            row.currency = U.nz(data.currency) and tostring(data.currency):upper():sub(1, 3) or db.NULL
            row.metadata = U.enc(meta)
            row.created_at, row.updated_at = db.raw("NOW()"), db.raw("NOW()")
            local created = db.insert("crm_leads", row, { returning = { "uuid" } })[1]
            return Api.ok(full(self, created.uuid), 201)
        end)
    end))

    -- ---------------------------------------------------------------------
    -- Meetings by their own id
    -- ---------------------------------------------------------------------

    local function meeting_lead(self)
        local ns = self.namespace.id
        local row = U.one([[SELECT l.* FROM crm_activities a JOIN crm_leads l ON l.id = a.lead_id
            WHERE a.namespace_id = ? AND a.uuid = ? AND a.activity_type = 'meeting' AND a.deleted_at IS NULL AND l.deleted_at IS NULL]],
            ns, self.params.meeting_uuid)
        if not row or not Access.can_see(self, row) then return nil, Api.not_found("Meeting not found") end
        if not Access.can_work(self, row) then return nil, Api.denied() end
        return row
    end

    app:put("/api/v2/crm/meetings/:meeting_uuid", H("crm_leads", "update", function(self)
        local lead, res = meeting_lead(self)
        if not lead then return res end
        return Api.result(require("lib.crm.lead-meetings").update(self.namespace.id, self.params.meeting_uuid, Access.me(self), self.body))
    end))

    app:post("/api/v2/crm/meetings/:meeting_uuid/cancel", H("crm_leads", "update", function(self)
        local lead, res = meeting_lead(self)
        if not lead then return res end
        return Api.result(require("lib.crm.lead-meetings").cancel(self.namespace.id, self.params.meeting_uuid, Access.me(self), self.body.reason))
    end))

    app:post("/api/v2/crm/meetings/:meeting_uuid/outcome", H("crm_leads", "update", function(self)
        local lead, res = meeting_lead(self)
        if not lead then return res end
        return Api.result(require("lib.crm.lead-meetings").outcome(self.namespace.id, self.params.meeting_uuid, Access.me(self), self.body))
    end))

    -- ---------------------------------------------------------------------
    -- One lead
    -- ---------------------------------------------------------------------

    app:get("/api/v2/crm/leads/:uuid", H("crm_leads", "read", function(self)
        local lead, res = visible_lead(self)
        if not lead then return res end
        return Api.ok(full(self, lead.uuid))
    end))

    app:get("/api/v2/crm/leads/:uuid/timeline", H("crm_leads", "read", function(self)
        local lead, res = visible_lead(self)
        if not lead then return res end
        return Api.ok(Pipeline.timeline(self.namespace.id, lead))
    end))

    app:put("/api/v2/crm/leads/:uuid", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local ns, me, data = self.namespace.id, Access.me(self), self.body
        local row, err = lead_fields(data, {})
        if not row then return Api.fail(err) end
        if data.score ~= nil then row.score = math.max(0, math.min(100, math.floor(tonumber(data.score) or 0))) end
        if data.metadata ~= nil then
            if type(data.metadata) ~= "table" then return Api.fail({ status = 422, code = "LEAD_INVALID", message = "metadata must be an object" }) end
            local meta = U.json(lead.metadata, {})
            for k, v in pairs(data.metadata) do meta[k] = v ~= cjson.null and v or nil end
            row.metadata = U.enc(meta)
        end
        if next(row) then
            if lead.status == "converted" then return Api.fail({ status = 409, code = "LEAD_CONVERTED", message = "This lead is converted. Edit its deal." }) end
            row.updated_at = db.raw("NOW()")
            db.update("crm_leads", row, { id = lead.id })
        end
        -- Owner and stage changes go through their rules.
        if data.owner_user_uuid ~= nil then
            local owner = U.nz(data.owner_user_uuid ~= cjson.null and data.owner_user_uuid or nil)
            if owner ~= U.nz(lead.owner_user_uuid) then
                if not Access.can_assign(self, lead, owner) then return Api.denied("Only managers can give a lead to someone else") end
                local _, aerr = Pipeline.assign(ns, lead.uuid, owner, me)
                if aerr then return Api.fail(aerr) end
            end
        end
        local stage = data.stage or data.status
        if stage ~= nil then
            local target = Stages.normalise(stage)
            if target ~= lead.status then
                if target == "converted" then
                    return Api.fail({ status = 422, code = "LEAD_USE_CONVERT", message = "Use “Convert to deal” to convert a lead" })
                end
                local _, merr = Pipeline.move(ns, lead.uuid, stage, me, { reason = data.lost_reason or data.reason,
                    nurture_until = data.nurture_until })
                if merr then return Api.fail(merr) end
            end
        elseif data.lost_reason ~= nil and lead.status == "lost" then
            db.update("crm_leads", { lost_reason = U.text(data.lost_reason, 200) or db.NULL }, { id = lead.id })
        end
        if next(row) == nil and data.owner_user_uuid == nil and stage == nil and data.lost_reason == nil then
            return Api.fail({ status = 400, code = "LEAD_NOTHING", message = "No valid fields to update" })
        end
        return Api.ok(full(self, lead.uuid))
    end))

    app:delete("/api/v2/crm/leads/:uuid", H("crm_leads", "delete", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        db.query("UPDATE crm_leads SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", lead.id)
        if U.crm() then
            db.query([[UPDATE crm_activities SET status = 'cancelled', cancelled_at = NOW(), updated_at = NOW()
                WHERE lead_id = ? AND status = 'planned' AND deleted_at IS NULL AND deal_id IS NULL]], lead.id)
        end
        return Api.ok({ message = "Lead deleted" })
    end))

    app:post("/api/v2/crm/leads/:uuid/stage", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local _, err = Pipeline.move(self.namespace.id, lead.uuid, self.body.stage, Access.me(self),
            { reason = self.body.reason, nurture_until = self.body.nurture_until })
        if err then return Api.fail(err) end
        return Api.ok(full(self, lead.uuid))
    end))

    app:post("/api/v2/crm/leads/:uuid/assign", H("crm_leads", "update", function(self)
        local lead, res = visible_lead(self)
        if not lead then return res end
        local owner = self.body.owner_user_uuid
        owner = (owner ~= nil and owner ~= cjson.null) and U.nz(owner) or nil
        if not Access.can_assign(self, lead, owner) then
            return Api.denied("You can take an unassigned lead, or hand yours back. Managers can give leads to anyone.")
        end
        local _, err = Pipeline.assign(self.namespace.id, lead.uuid, owner, Access.me(self))
        if err then return Api.fail(err) end
        return Api.ok(full(self, lead.uuid))
    end))

    app:post("/api/v2/crm/leads/:uuid/calls", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local result, err = Pipeline.log_call(self.namespace.id, lead.uuid, Access.me(self), self.body)
        if not result then return Api.fail(err) end
        result.lead = full(self, lead.uuid)
        return Api.ok(result, 201)
    end))

    app:post("/api/v2/crm/leads/:uuid/steps", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local _, err = Pipeline.set_next_step(self.namespace.id, lead.uuid, Access.me(self), self.body)
        if err then return Api.fail(err) end
        return Api.ok(full(self, lead.uuid), 201)
    end))

    app:post("/api/v2/crm/leads/:uuid/steps/:activity_uuid", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local _, err = Pipeline.finish_step(self.namespace.id, lead.uuid, self.params.activity_uuid, Access.me(self),
            self.body.status, self.body.note)
        if err then return Api.fail(err) end
        return Api.ok(full(self, lead.uuid))
    end))

    app:post("/api/v2/crm/leads/:uuid/qualify", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local _, err = Pipeline.qualify(self.namespace.id, lead.uuid, Access.me(self), self.body)
        if err then return Api.fail(err) end
        return Api.ok(full(self, lead.uuid))
    end))

    app:post("/api/v2/crm/leads/:uuid/analyse", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local settings = Settings.get(self.namespace.id)
        if not settings.ai_enabled then
            return Api.fail({ status = 409, code = "AI_OFF", message = "AI analysis is turned off in lead settings" })
        end
        local queued = require("lib.crm.lead-ai").enqueue(self.namespace.id, lead.id, "manual", Access.me(self))
        return Api.ok({ queued = queued ~= nil, message = queued and "The AI is analysing the lead. This takes a minute."
            or "An analysis is already running for this lead." }, 202)
    end))

    app:post("/api/v2/crm/leads/:uuid/convert", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        if not require("middleware.namespace").hasPermission(self, "crm_deals", "create") then
            return Api.denied("Converting creates a deal: you need permission to create deals")
        end
        local b = self.body
        -- Older clients send { deal = { name, value, currency, stage, pipeline_id } }.
        if type(b.deal) == "table" then
            b = { name = b.deal.name, value = b.deal.value, currency = b.deal.currency, stage = b.deal.stage }
        end
        local result, err = require("lib.crm.lead-convert").convert(self.namespace.id, lead.uuid, Access.me(self), b)
        if not result then return Api.fail(err) end
        result.lead = full(self, lead.uuid)
        return Api.ok(result)
    end))

    app:post("/api/v2/crm/leads/:uuid/meetings", H("crm_leads", "update", function(self)
        local lead, res = workable_lead(self)
        if not lead then return res end
        local meeting, err = require("lib.crm.lead-meetings").book(self.namespace.id, lead.uuid, Access.me(self), self.body)
        if not meeting then return Api.fail(err) end
        return Api.ok(meeting, 201)
    end))
end
