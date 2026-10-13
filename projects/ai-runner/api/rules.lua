-- Routing rules for sessions started by hand (docs/AI_RUNNER.md §27.3), all ai_runs_settings.manage:
--   GET    /track-rules                     the workspace's rules in order (meta: variables, default templates)
--   POST   /track-rules { name?, enabled?, match, action }      -> 201 the rule, last in order
--   PUT    /track-rules/:uuid { name?, enabled?, match?, action? }  match / action are replaced whole when given
--   DELETE /track-rules/:uuid
--   POST   /track-rules/order { uuids }     every rule of the workspace once, in the new order
--   POST   /track-rules/test { session }    -> { rule, action, title, description } for a sample session: what would
--                                          happen (with session_tracking on); nothing is created
-- match: { runner_uuids, tools, folder_globs, branch_globs, prompt_keywords } (empty = any). action: { type:
-- create_task|ignore, project_uuid, column, status: todo|in_progress, priority, assignee_uuids, title_template,
-- description_template, notify: managers|assignees|none|users, notify_user_uuids }. Projects, runners and people
-- must be the workspace's (people: active members); lists and templates are capped in size.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")
local Rules = require("ai_runner.rules")

local MAX_RULES = 100
local MANAGE = { permission = "ai_runs_settings.manage" }

local function body(self)
    local b, err = sdk.body(self)
    if not b then U.fail(400, err) end
    return b
end

local function uuid_entry(what)
    return function(u)
        u = u:lower()
        if U.is_uuid(u) then return u end
        return nil, "must be " .. what .. " uuids"
    end
end

-- Users of the workspace (active members), in its own spelling of each uuid; 422 on field otherwise.
local function members(ns, list, field)
    if #list == 0 then return U.array() end
    local rows = db.query([[SELECT DISTINCT u.uuid FROM namespace_members nm JOIN users u ON u.id = nm.user_id
        WHERE nm.namespace_id = ? AND nm.status = 'active' AND lower(u.uuid) IN ? ORDER BY u.uuid]], ns, db.list(list))
    if #rows ~= #list then U.invalid({ [field] = "must be active members of this workspace" }) end
    for i, r in ipairs(rows) do rows[i] = r.uuid end
    return U.array(rows)
end

local function match_of(ns, v)
    if v == nil or v == cjson.null then v = {} end
    if not U.object(v) then U.invalid({ match = "must be an object" }) end
    local m = {
        runner_uuids = U.strings(v.runner_uuids, "match.runner_uuids", 50, 36, uuid_entry("runner")),
        tools = U.strings(v.tools, "match.tools", 50, 40, string.lower),
        folder_globs = U.strings(v.folder_globs, "match.folder_globs", 50, 255, U.folder_glob),
        branch_globs = U.strings(v.branch_globs, "match.branch_globs", 50, 255),
        prompt_keywords = U.strings(v.prompt_keywords, "match.prompt_keywords", 50, 100, string.lower),
    }
    if #m.runner_uuids > 0 and U.one("SELECT COUNT(*)::int AS n FROM ar_runners WHERE namespace_id = ? AND uuid IN ?",
        ns, db.list(m.runner_uuids)).n ~= #m.runner_uuids then
        U.invalid({ ["match.runner_uuids"] = "must be runners of this workspace" })
    end
    return m
end

local function action_of(ns, v)
    if not U.object(v) then U.invalid({ action = "must be an object" }) end
    local d, errors = sdk.validate(v, {
        type = { required = true, enum = { "create_task", "ignore" } },
        project_uuid = { type = "uuid" }, column = { max = 100 }, status = { enum = { "todo", "in_progress" } },
        priority = { enum = { "critical", "high", "medium", "low", "none" } },
        title_template = { type = "text", max = 500 }, description_template = { type = "text", max = 5000 },
        notify = { enum = Rules.NOTIFY },
    })
    if not d then
        local out = {}
        for k, m in pairs(errors) do out["action." .. k] = m end
        U.invalid(out)
    end
    for k, x in pairs(d) do if x == db.NULL or x == "" then d[k] = nil end end
    if d.type == "ignore" then return Rules.action_view({ type = "ignore" }) end
    if not d.project_uuid then U.invalid({ ["action.project_uuid"] = "is required to create a task" }) end
    local target = R.track_target(ns, d.project_uuid, d.column)
    if not target then U.invalid({ ["action.project_uuid"] = "must be a kanban project of this workspace" }) end
    if d.column and not target.column_found then
        U.invalid({ ["action.column"] = "must be a column of the project's first board" })
    end
    local notify = d.notify or "managers"
    local notify_users = members(ns, U.strings(v.notify_user_uuids, "action.notify_user_uuids", 20, 36,
        uuid_entry("user")), "action.notify_user_uuids")
    if notify == "users" and #notify_users == 0 then
        U.invalid({ ["action.notify_user_uuids"] = "is required when notify is users" })
    end
    return Rules.action_view({ type = "create_task", project_uuid = target.project_uuid,
        column = d.column and target.column_name, status = d.status or "in_progress", priority = d.priority,
        assignee_uuids = members(ns, U.strings(v.assignee_uuids, "action.assignee_uuids", 20, 36,
            uuid_entry("user")), "action.assignee_uuids"),
        title_template = d.title_template and U.clean(d.title_template),
        description_template = d.description_template and U.clean(d.description_template), notify = notify,
        notify_user_uuids = notify_users })
end

local function rule_or_404(ns, uuid)
    local r = U.is_uuid(uuid) and U.one("SELECT * FROM ar_track_rules WHERE namespace_id = ? AND uuid = ?", ns, uuid)
    if not r then U.fail(404, "Rule not found") end
    return r
end

-- Rule changes of one workspace, one at a time (the count cap, the order).
local function lock(ns)
    db.query("SELECT pg_advisory_xact_lock(hashtext('ai_runner:rules:' || ?::text))", ns)
end

local function str(v, max)
    if type(v) == "string" then return U.clean(v, max) end
end

return function(app)
    app:get("/track-rules", sdk.handler(MANAGE, U.guard(function(self)
        local rules = Rules.load(sdk.namespace_id(self), true)
        return sdk.ok(U.array(rules), { total = #rules, max = MAX_RULES,
            variables = U.array({ unpack(Rules.VARIABLES) }), default_title_template = Rules.TITLE_TEMPLATE,
            default_description_template = Rules.DESCRIPTION_TEMPLATE })
    end)))

    app:post("/track-rules", sdk.handler(MANAGE, U.guard(function(self)
        local ns, b = sdk.namespace_id(self), body(self)
        local d, errors = sdk.validate(b, { name = { max = 100 }, enabled = { type = "boolean" } })
        if not d then U.invalid(errors) end
        local match, action = match_of(ns, b.match), action_of(ns, b.action)
        local me = sdk.user(self).uuid
        local row = U.tx(function()
            lock(ns)
            if U.one("SELECT COUNT(*)::int AS n FROM ar_track_rules WHERE namespace_id = ?", ns).n >= MAX_RULES then
                U.fail(409, "A workspace has at most " .. MAX_RULES .. " routing rules")
            end
            return U.one([[INSERT INTO ar_track_rules (namespace_id, name, position, enabled, match, action, created_by,
                    updated_by)
                SELECT ?, ?, COALESCE(MAX(position), 0) + 1, ?, ?::jsonb, ?::jsonb, ?, ?
                FROM ar_track_rules WHERE namespace_id = ? RETURNING *]], ns, type(d.name) == "string"
                and U.clean(d.name) or "", d.enabled ~= false, cjson.encode(match), cjson.encode(action), me, me, ns)
        end)
        return sdk.created(Rules.view(row))
    end)))

    app:put("/track-rules/:uuid", sdk.handler(MANAGE, U.guard(function(self)
        local ns, b = sdk.namespace_id(self), body(self)
        local r = rule_or_404(ns, self.params.uuid)
        local d, errors = sdk.validate(b, { name = { max = 100 }, enabled = { type = "boolean" } }, true)
        if not d then U.invalid(errors) end
        local set = { updated_by = sdk.user(self).uuid, updated_at = db.raw("NOW()") }
        if d.name ~= nil then set.name = d.name == db.NULL and "" or U.clean(d.name) end
        if type(d.enabled) == "boolean" then set.enabled = d.enabled end
        if b.match ~= nil then set.match = cjson.encode(match_of(ns, b.match)) end
        if b.action ~= nil then set.action = cjson.encode(action_of(ns, b.action)) end
        db.update("ar_track_rules", set, { id = r.id })
        return sdk.ok(Rules.view(U.one("SELECT * FROM ar_track_rules WHERE id = ?", r.id)))
    end)))

    app:delete("/track-rules/:uuid", sdk.handler(MANAGE, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = rule_or_404(ns, self.params.uuid)
        db.query("DELETE FROM ar_track_rules WHERE id = ?", r.id)
        return sdk.ok({ uuid = r.uuid, deleted = true })
    end)))

    app:post("/track-rules/order", sdk.handler(MANAGE, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local uuids = U.strings(body(self).uuids, "uuids", MAX_RULES, 36, uuid_entry("rule"))
        U.tx(function()
            lock(ns)
            local have = {}
            for _, r in ipairs(db.query("SELECT uuid FROM ar_track_rules WHERE namespace_id = ?", ns)) do
                have[r.uuid] = true
            end
            local order = {}
            for i, u in ipairs(uuids) do
                if not have[u] then U.invalid({ uuids = "must list every rule of this workspace once" }) end
                order[i] = { uuid = u, pos = i }
            end
            if #uuids ~= #db.query("SELECT 1 FROM ar_track_rules WHERE namespace_id = ?", ns) then
                U.invalid({ uuids = "must list every rule of this workspace once" })
            end
            if #order > 0 then
                db.query([[UPDATE ar_track_rules r SET position = x.pos, updated_at = NOW()
                    FROM jsonb_to_recordset(?::jsonb) AS x(uuid uuid, pos int)
                    WHERE r.uuid = x.uuid AND r.namespace_id = ?]], cjson.encode(order), ns)
            end
        end)
        return sdk.ok(U.array(Rules.load(ns, true)))
    end)))

    -- The tester: what a sample session would become under the rules as saved, with the redaction a reported
    -- session gets. runner_uuid (optional) is one of the workspace's connections.
    app:post("/track-rules/test", sdk.handler(MANAGE, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local s = U.object(body(self).session)
        if not s then U.invalid({ session = "must be an object" }) end
        local runner
        if s.runner_uuid ~= nil and s.runner_uuid ~= cjson.null then
            runner = R.runner(ns, type(s.runner_uuid) == "string" and s.runner_uuid:lower() or nil)
            if not runner then U.invalid({ ["session.runner_uuid"] = "is not a runner of this workspace" }) end
        end
        local started = str(s.started_at, 64)
        local sample = {
            tool = str(s.tool, 40), cwd = U.path(str(s.cwd)), branch = str(s.branch, 255),
            session_id = str(s.session_id, 255),
            first_prompt = U.cut(str(s.first_prompt) and U.clean(U.redact(U.clean(s.first_prompt))), 300),
            prompt_preview = U.cut(str(s.prompt_preview) and U.clean(U.redact(U.clean(s.prompt_preview))), 200),
            started = started and U.one([[SELECT to_char(ai_runner_ts(?) AT TIME ZONE 'UTC',
                'YYYY-MM-DD HH24:MI "UTC"') AS t]], started).t or nil,
        }
        local st = R.settings(ns).session_tracking
        local rule, action, title, description = Rules.evaluate(Rules.load(ns), st, runner and runner.uuid,
            runner and runner.name or "(runner)", sample)
        return sdk.ok({ rule = rule or cjson.null, action = action, title = U.null(title),
            description = U.null(description) })
    end)))
end
