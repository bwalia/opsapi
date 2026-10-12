-- Runners, machines, the overview, settings and the prompt template (docs/AI_RUNNER.md §22.3, §24, §25.1).
--   GET    /runners                         ai_runs.create or ai_runners.manage (?include_revoked=true): the runners
--                                           the caller may use; `access` shown to ai_runners.manage
--   GET    /runners/:uuid                   same (404 for a runner the caller may not use)
--   POST   /runners { name, labels? }       ai_runners.manage -> 201 { runner, token } (the token is shown once)
--   PUT    /runners/:uuid { name?, labels? } ai_runners.manage
--   PUT    /runners/:uuid/access { mode: owner|everyone|listed, users?, projects? }  ai_runners.manage
--   POST   /runners/:uuid/rotate-token      ai_runners.manage -> { runner, token }; the old token stops working
--   POST   /runners/:uuid/pause | /resume   ai_runners.manage (a paused runner heartbeats but claims nothing)
--   DELETE /runners/:uuid                   ai_runners.manage: revoke (its queued runs are cancelled)
--   GET    /runners/:uuid/sessions          ai_runs.manage: the machine's last inventory, linked to runs
--   GET    /sessions                        ai_runs.manage or ai_runners.manage: every runner's sessions
--                                           (?runner_uuid&busy=1&page&per_page)
--   GET    /overview                        ai_runs.manage, ai_runners.manage or ai_runs_approvals.manage
--   GET|PUT /settings                       ai_runs_settings.manage (+ guards, §24.1)
--   GET|PUT /projects/:project_uuid/settings  owner/admin of the kanban project or ai_runs_settings.manage
--   GET|PUT /template                       ai_runs_settings.manage: the workspace template, versioned on save
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")

local function body(self)
    local b, err = sdk.body(self)
    if not b then U.fail(400, err) end
    return b
end

-- labels: up to 20 strings of up to 50 characters. nil = not given; error on anything else.
local function labels_of(v)
    if v == nil or v == cjson.null then return nil end
    if type(v) ~= "table" or (next(v) ~= nil and v[1] == nil) or #v > 20 then
        U.invalid({ labels = "must be a list of up to 20 labels" })
    end
    local out = {}
    for i, l in ipairs(v) do
        if type(l) ~= "string" or l == "" or #l > 50 then U.invalid({ labels = "each label is 1 to 50 characters" }) end
        out[i] = U.clean(l)
    end
    return U.array(out)
end

local function runner_or_404(ns, uuid)
    local r = R.runner(ns, uuid)
    if not r then U.fail(404, "Runner not found") end
    return r
end

local function may_list_runners(self)
    return sdk.can(self, "ai_runs", "create") or sdk.can(self, "ai_runners", "manage")
end

local function project_or_403(self, ns)
    local p = type(self.params.project_uuid) == "string" and #self.params.project_uuid <= 255 and U.one(
        "SELECT id, uuid, name FROM kanban_projects WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL",
        self.params.project_uuid, ns)
    if not p then U.fail(404, "Project not found") end
    if not sdk.can(self, "ai_runs_settings", "manage") and not R.project_admin(p.id, sdk.user(self).uuid) then
        U.fail(403, "Only an owner or admin of this project, or an AI run settings manager, can do this")
    end
    return p
end

-- users / projects of a runner's access: up to 200 uuids, each one of this workspace's (a member, a project).
-- @return the list as stored (the workspace's own spelling of each uuid)
local function access_list(v, field, ns)
    if v == nil or v == cjson.null then return U.array() end
    if type(v) ~= "table" or (next(v) ~= nil and v[1] == nil) or #v > 200 then
        U.invalid({ [field] = "must be a list of up to 200 uuids" })
    end
    local seen = {}
    for _, id in ipairs(v) do
        if not U.is_uuid(id) then U.invalid({ [field] = "must be a list of up to 200 uuids" }) end
        seen[id] = true
    end
    local wanted = {}
    for id in pairs(seen) do wanted[#wanted + 1] = id end
    if #wanted == 0 then return U.array() end
    local rows = field == "users" and db.query([[SELECT u.uuid FROM namespace_members nm
            JOIN users u ON u.id = nm.user_id
            WHERE nm.namespace_id = ? AND nm.status = 'active' AND u.uuid IN ? ORDER BY u.uuid]], ns, db.list(wanted))
        or db.query([[SELECT uuid FROM kanban_projects WHERE namespace_id = ? AND deleted_at IS NULL AND uuid IN ?
            ORDER BY uuid]], ns, db.list(wanted))
    if #rows ~= #wanted then
        U.invalid({ [field] = field == "users" and "must be members of this workspace"
            or "must be projects of this workspace" })
    end
    for i, r in ipairs(rows) do rows[i] = r.uuid end
    return U.array(rows)
end

local function template_view(t)
    return { uuid = U.null(t.uuid), version = t.version, body = t.body, builtin = t.builtin == true,
        created_by = U.null(t.created_by), created_at = U.null(t.created_at),
        variables = U.array({ unpack(R.TEMPLATE_VARIABLES) }) }
end

return function(app)
    -- Runners --------------------------------------------------------------------------------------------------
    -- Only the runners the caller may use (§25.1): the Start dialog offers nothing it would refuse.
    app:get("/runners", sdk.handler({}, U.guard(function(self)
        if not may_list_runners(self) then return sdk.error(403, "Permission denied") end
        local ns = sdk.namespace_id(self)
        local page, per_page, offset = sdk.page(self.params)
        local all = self.params.include_revoked == "true" or self.params.include_revoked == "1"
        local cond, args = R.runner_access_sql(self, ns)
        local w = cond .. " AND r.namespace_id = ?" .. (all and "" or " AND r.status <> 'revoked'")
        args[#args + 1] = ns
        local q_args = { unpack(args) }
        q_args[#q_args + 1] = per_page
        q_args[#q_args + 1] = offset
        local out, show_access = {}, sdk.can(self, "ai_runners", "manage")
        for i, r in ipairs(db.query("SELECT " .. R.RUNNER_COLS .. " FROM ar_runners r WHERE " .. w
            .. " ORDER BY lower(r.name), r.id LIMIT ? OFFSET ?", unpack(q_args))) do
            out[i] = R.runner_view(r, show_access)
        end
        local total = db.query("SELECT COUNT(*)::int AS n FROM ar_runners r WHERE " .. w, unpack(args))[1].n
        return sdk.ok(U.array(out), { page = page, per_page = per_page, total = total,
            total_pages = math.ceil(total / per_page) })
    end)))

    app:get("/runners/:uuid", sdk.handler({}, U.guard(function(self)
        if not may_list_runners(self) then return sdk.error(403, "Permission denied") end
        local r, usable = R.usable_runner(self, sdk.namespace_id(self), self.params.uuid)
        if not usable then return sdk.not_found("Runner") end
        return sdk.ok(R.runner_view(r, sdk.can(self, "ai_runners", "manage")))
    end)))

    -- No Idempotency-Key here: a replayed answer would have to keep the token.
    app:post("/runners", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local b = body(self)
        local d, errors = sdk.validate(b, { name = { required = true, max = 100 } })
        if not d then U.invalid(errors) end
        local raw, hash, hint = U.new_token()
        local row = db.insert("ar_runners", { namespace_id = ns, name = U.clean(d.name),
            labels = cjson.encode(labels_of(b.labels) or U.array()), token_hash = hash, token_hint = hint,
            created_by = sdk.user(self).uuid }, { returning = "*" })[1]
        return sdk.created({ runner = R.runner_view(R.runner(ns, row.uuid), true), token = raw })
    end)))

    app:put("/runners/:uuid", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = runner_or_404(ns, self.params.uuid)
        if r.status == "revoked" then U.fail(409, "This runner was revoked") end
        local b = body(self)
        local d, errors = sdk.validate(b, { name = { max = 100 } }, true)
        if not d or d.name == db.NULL or d.name == "" then U.invalid(errors or { name = "is required" }) end
        local name, l = d.name and U.clean(d.name) or r.name, labels_of(b.labels)
        db.query("UPDATE ar_runners SET name = ?, labels = COALESCE(?::jsonb, labels), updated_at = NOW() WHERE id = ?",
            name, l and cjson.encode(l) or db.NULL, r.id)
        return sdk.ok(R.runner_view(R.runner(ns, r.uuid), true))
    end)))

    -- Who may use the runner (§25.1): its owner and AI-run managers always; `everyone` who may start a run;
    -- `listed` also the users and the tasks of the projects named.
    app:put("/runners/:uuid/access", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = runner_or_404(ns, self.params.uuid)
        if r.status == "revoked" then U.fail(409, "This runner was revoked") end
        local b = body(self)
        local d, errors = sdk.validate(b, { mode = { required = true, enum = { "owner", "everyone", "listed" } } })
        if not d then U.invalid(errors) end
        local access = { mode = d.mode, users = access_list(b.users, "users", ns),
            projects = access_list(b.projects, "projects", ns) }
        db.query("UPDATE ar_runners SET access = ?::jsonb, updated_at = NOW() WHERE id = ?", cjson.encode(access), r.id)
        return sdk.ok(R.runner_view(R.runner(ns, r.uuid), true))
    end)))

    app:post("/runners/:uuid/rotate-token", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = runner_or_404(ns, self.params.uuid)
        if r.status == "revoked" then U.fail(409, "This runner was revoked") end
        local raw, hash, hint = U.new_token()
        db.query("UPDATE ar_runners SET token_hash = ?, token_hint = ?, updated_at = NOW() WHERE id = ?", hash, hint,
            r.id)
        return sdk.ok({ runner = R.runner_view(R.runner(ns, r.uuid), true), token = raw })
    end)))

    for action, change in pairs({ pause = { "active", "paused" }, resume = { "paused", "active" } }) do
        app:post("/runners/:uuid/" .. action, sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
            local ns = sdk.namespace_id(self)
            local r = runner_or_404(ns, self.params.uuid)
            if r.status == "revoked" then U.fail(409, "This runner was revoked") end
            db.query("UPDATE ar_runners SET status = ?, updated_at = NOW() WHERE id = ? AND status = ?", change[2],
                r.id, change[1])
            return sdk.ok(R.runner_view(R.runner(ns, r.uuid), true))
        end)))
    end

    app:delete("/runners/:uuid", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = runner_or_404(ns, self.params.uuid)
        if r.status ~= "revoked" then
            U.tx(function()
                db.query([[UPDATE ar_runners SET status = 'revoked', revoked_at = NOW(), updated_at = NOW()
                    WHERE id = ?]], r.id)
                -- Nobody can claim its queued runs any more. Claimed ones end through the lease sweep (lost).
                db.query([[UPDATE ar_runs SET status = 'cancelled', finished_at = NOW(), updated_at = NOW(),
                    error_category = 'runner_revoked', error = 'The runner was revoked'
                    WHERE runner_uuid = ? AND namespace_id = ? AND status = 'queued']], r.uuid, ns)
                db.query([[DELETE FROM ar_locks l USING ar_runs x WHERE x.uuid = l.run_uuid AND x.runner_uuid = ?
                    AND x.status NOT IN ]] .. R.OPEN_SQL, r.uuid)
            end)
        end
        return sdk.ok(R.runner_view(R.runner(ns, r.uuid), true))
    end)))

    app:get("/runners/:uuid/sessions", sdk.handler({ permission = "ai_runs.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = runner_or_404(ns, self.params.uuid)
        local page, per_page, offset = sdk.page(self.params)
        local rows = db.query([[
            SELECT s.session_key AS key, s.tool, s.status, s.cwd, s.branch, s.session_id, s.started_at, s.updated_at,
                   s.prompt_preview, s.labels, s.run_uuid, s.managed, s.seen_at,
                   x.task_uuid, x.status AS run_status, t.title AS task_title
            FROM ar_sessions s
            LEFT JOIN ar_runs x ON x.uuid = s.run_uuid
            LEFT JOIN kanban_tasks t ON t.uuid = x.task_uuid
            WHERE s.runner_uuid = ? AND s.namespace_id = ?
            ORDER BY s.managed DESC, s.updated_at DESC NULLS LAST, s.session_key LIMIT ? OFFSET ?
        ]], r.uuid, ns, per_page, offset)
        local out = {}
        for i, s in ipairs(rows) do
            local v = {}
            for _, k in ipairs({ "key", "tool", "status", "cwd", "branch", "session_id", "started_at", "updated_at",
                "prompt_preview", "run_uuid", "seen_at", "task_uuid", "run_status", "task_title" }) do
                v[k] = U.null(s[k])
            end
            v.managed, v.labels = s.managed == true, U.json(s.labels) or cjson.null
            out[i] = v
        end
        local total = db.query("SELECT COUNT(*)::int AS n FROM ar_sessions WHERE runner_uuid = ? AND namespace_id = ?",
            r.uuid, ns)[1].n
        return sdk.ok(U.array(out), { page = page, per_page = per_page, total = total,
            total_pages = math.ceil(total / per_page) })
    end)))

    -- Machines and the overview (§24.4, §24.5) -----------------------------------------------------------------
    app:get("/sessions", sdk.handler({}, U.guard(function(self)
        if not (sdk.can(self, "ai_runs", "manage") or sdk.can(self, "ai_runners", "manage")) then
            return sdk.error(403, "Permission denied")
        end
        local ns, p = sdk.namespace_id(self), self.params
        local where, args = { "s.namespace_id = ?", "ru.status <> 'revoked'" }, { ns }
        if type(p.runner_uuid) == "string" and p.runner_uuid ~= "" then
            if not U.is_uuid(p.runner_uuid) then U.fail(400, "runner_uuid must be a uuid") end
            where[#where + 1] = "s.runner_uuid = ?"
            args[#args + 1] = p.runner_uuid:lower()
        end
        if p.busy == "1" or p.busy == "true" then
            where[#where + 1] = "lower(COALESCE(s.status, '')) NOT IN " .. R.IDLE_SQL
        end
        local w = table.concat(where, " AND ")
        local page, per_page, offset = sdk.page(p)
        local q_args = { unpack(args) }
        q_args[#q_args + 1] = per_page
        q_args[#q_args + 1] = offset
        local out = {}
        for i, s in ipairs(db.query([[
            SELECT s.session_key, s.tool, s.status, s.cwd, s.branch, s.managed, s.prompt_preview, s.updated_at,
                   s.seen_at, s.run_uuid, ru.uuid AS runner_uuid, ru.name AS runner_name, ru.status AS runner_state,
                   (ru.last_heartbeat_at IS NOT NULL AND ru.last_heartbeat_at > NOW() - interval ']] .. R.ONLINE_S
                .. [[ seconds') AS online,
                   t.task_number, COALESCE(t.title, x.task_snapshot->>'title') AS task_title
            FROM ar_sessions s
            JOIN ar_runners ru ON ru.uuid = s.runner_uuid
            LEFT JOIN ar_runs x ON x.uuid = s.run_uuid
            LEFT JOIN kanban_tasks t ON t.uuid = x.task_uuid
            WHERE ]] .. w .. [[
            ORDER BY lower(ru.name), ru.id, s.managed DESC, s.updated_at DESC NULLS LAST, s.session_key
            LIMIT ? OFFSET ?]], unpack(q_args))) do
            out[i] = { key = s.session_key, tool = U.null(s.tool), status = U.null(s.status), cwd = U.null(s.cwd),
                branch = U.null(s.branch), managed = s.managed == true, prompt_preview = U.null(s.prompt_preview),
                updated_at = U.null(s.updated_at), seen_at = s.seen_at,
                runner = { uuid = s.runner_uuid, name = s.runner_name,
                    status = R.runner_status({ status = s.runner_state, online = s.online }) },
                run = s.run_uuid and { uuid = s.run_uuid, task_title = U.null(s.task_title),
                    task_number = U.null(s.task_number) } or cjson.null }
        end
        local total = db.query([[SELECT COUNT(*)::int AS n FROM ar_sessions s
            JOIN ar_runners ru ON ru.uuid = s.runner_uuid WHERE ]] .. w, unpack(args))[1].n
        return sdk.ok(U.array(out), { page = page, per_page = per_page, total = total,
            total_pages = math.ceil(total / per_page) })
    end)))

    app:get("/overview", sdk.handler({}, U.guard(function(self)
        if not (sdk.can(self, "ai_runs", "manage") or sdk.can(self, "ai_runners", "manage")
            or sdk.can(self, "ai_runs_approvals", "manage")) then
            return sdk.error(403, "Permission denied")
        end
        local ns = sdk.namespace_id(self)
        local by_status = {}
        for _, st in ipairs(R.OPEN) do by_status[st] = 0 end
        for _, r in ipairs(db.query("SELECT status, COUNT(*)::int AS n FROM ar_runs WHERE namespace_id = ? "
            .. "AND status IN " .. R.OPEN_SQL .. " GROUP BY status", ns)) do
            by_status[r.status] = r.n
        end
        local online = "last_heartbeat_at > NOW() - interval '" .. R.ONLINE_S .. " seconds'"
        local runners = U.one([[SELECT COUNT(*) FILTER (WHERE status = 'active' AND ]] .. online .. [[)::int AS online,
                COUNT(*) FILTER (WHERE status = 'active' AND NOT COALESCE(]] .. online .. [[, false))::int AS offline,
                COUNT(*) FILTER (WHERE status = 'paused')::int AS paused
            FROM ar_runners WHERE namespace_id = ? AND status <> 'revoked']], ns)
        local today = "date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'"
        local cost = U.one([[SELECT COALESCE(SUM(cost_estimate), 0) AS c FROM ar_run_turns
            WHERE namespace_id = ? AND role = 'assistant' AND at >= ]] .. today, ns).c
        local week = U.one([[SELECT COUNT(*) FILTER (WHERE status = 'succeeded')::int AS succeeded,
                COUNT(*) FILTER (WHERE status = 'failed')::int AS failed,
                COUNT(*) FILTER (WHERE status = 'cancelled')::int AS cancelled,
                COUNT(*) FILTER (WHERE status = 'lost')::int AS lost
            FROM ar_runs WHERE namespace_id = ? AND finished_at > NOW() - interval '7 days']], ns)
        -- Decided by a person: an "allow for this run" repeat is decided the moment it is asked, so it isn't a wait.
        local wait = U.one([[SELECT round(AVG(EXTRACT(EPOCH FROM decided_at - created_at))::numeric, 1) AS s
            FROM ar_run_requests WHERE namespace_id = ? AND status IN ('allowed', 'denied')
              AND decided_at > NOW() - interval '7 days' AND decided_at > created_at]], ns).s
        return sdk.ok({ runs_by_status = by_status, queue_depth = by_status.queued,
            runners = { online = runners.online, offline = runners.offline, paused = runners.paused },
            tokens_today = R.tokens_today(ns), cost_today = tonumber(cost) or 0,
            runs_7d = { succeeded = week.succeeded, failed = week.failed, cancelled = week.cancelled,
                lost = week.lost },
            avg_permission_wait_s_7d = U.null(tonumber(wait)) })
    end)))

    -- Workspace settings ---------------------------------------------------------------------------------------
    app:get("/settings", sdk.handler({ permission = "ai_runs_settings.manage" }, U.guard(function(self)
        return sdk.ok(R.settings(sdk.namespace_id(self)))
    end)))

    app:put("/settings", sdk.handler({ permission = "ai_runs_settings.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local b = body(self)
        local d, errors = sdk.validate(b, {
            output_mode = { enum = R.OUTPUT_MODES }, pr_draft = { type = "boolean" }, pr_base = { max = 255 },
            max_run_minutes = { type = "integer", min = 1, max = 1440 },
        }, true)
        if not d then U.invalid(errors) end
        local s = R.settings(ns)
        local function put(into, defaults, clean)
            for k, v in pairs(clean) do
                if v == db.NULL then into[k] = defaults[k] else into[k] = v end
            end
        end
        put(s, R.SETTINGS_DEFAULTS, d)
        if not U.is_branch(s.pr_base) then U.invalid({ pr_base = "must be a branch name" }) end
        local function merge(name, rules)
            local given = b[name]
            if given == nil then return end
            if type(given) ~= "table" or given[1] ~= nil then U.invalid({ [name] = "must be an object" }) end
            local clean, errs = sdk.validate(given, rules, true)
            if not clean then
                local out = {}
                for k, m in pairs(errs) do out[name .. "." .. k] = m end
                U.invalid(out)
            end
            put(s[name], R.SETTINGS_DEFAULTS[name], clean)
        end
        merge("task_automation", { in_progress_on_start = { type = "boolean" },
            review_on_success = { type = "boolean" } })
        merge("approval_policy", { deciders = { enum = { "requester", "managers", "requester_or_managers" } },
            require_start_approval = { type = "boolean" }, project_admins_decide = { type = "boolean" },
            permission_timeout_minutes = { type = "integer", min = 1, max = 1440 },
            input_timeout_minutes = { type = "integer", min = 1, max = 1440 } })
        merge("guards", { similar_threshold = { type = "number", min = 0.1, max = 1 },
            max_open_runs_per_user = { type = "integer", min = 0, max = 100 },
            max_open_runs_per_workspace = { type = "integer", min = 0, max = 1000 },
            daily_token_limit = { type = "integer", min = 0, max = 1000000000 },
            retention_days = { type = "integer", min = 30, max = 3650 } })
        db.query([[
            INSERT INTO ar_settings (namespace_id, output_mode, pr_draft, pr_base, max_run_minutes, task_automation,
                approval_policy, guards, updated_by)
            VALUES (?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?::jsonb, ?)
            ON CONFLICT (namespace_id) DO UPDATE SET output_mode = EXCLUDED.output_mode, pr_draft = EXCLUDED.pr_draft,
                pr_base = EXCLUDED.pr_base, max_run_minutes = EXCLUDED.max_run_minutes,
                task_automation = EXCLUDED.task_automation, approval_policy = EXCLUDED.approval_policy,
                guards = EXCLUDED.guards, updated_by = EXCLUDED.updated_by, updated_at = NOW()
        ]], ns, s.output_mode, s.pr_draft, s.pr_base, s.max_run_minutes, cjson.encode(s.task_automation),
            cjson.encode(s.approval_policy), cjson.encode(s.guards), sdk.user(self).uuid)
        return sdk.ok(R.settings(ns))
    end)))

    -- Project settings -----------------------------------------------------------------------------------------
    app:get("/projects/:project_uuid/settings", sdk.handler({}, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        return sdk.ok(R.project_settings(ns, project_or_403(self, ns).uuid))
    end)))

    app:put("/projects/:project_uuid/settings", sdk.handler({}, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local p = project_or_403(self, ns)
        local b = body(self)
        local d, errors = sdk.validate(b, { output_mode = { enum = R.OUTPUT_MODES }, base_branch = { max = 255 } },
            true)
        if not d then U.invalid(errors) end
        if type(d.base_branch) == "string" and not U.is_branch(d.base_branch) then
            U.invalid({ base_branch = "must be a branch name" })
        end
        local cur = R.project_settings(ns, p.uuid)
        local paths = cur.default_repo_paths
        if b.default_repo_paths ~= nil then
            local given = b.default_repo_paths
            if given == cjson.null then given = {} end
            if type(given) ~= "table" or given[1] ~= nil then
                U.invalid({ default_repo_paths = "must be an object { runner_uuid: folder }" })
            end
            paths = {}
            local n = 0
            for k, v in pairs(given) do
                n = n + 1
                local path = U.path(v)
                if not U.is_uuid(k) or not path or n > 50 then
                    U.invalid({ default_repo_paths = "maps up to 50 runner uuids to absolute folder paths" })
                end
                paths[k:lower()] = path
            end
        end
        local function pick(k)
            if d[k] == db.NULL then return db.NULL end
            if d[k] ~= nil then return d[k] end
            return cur[k] ~= cjson.null and cur[k] or db.NULL
        end
        db.query([[
            INSERT INTO ar_project_settings (namespace_id, project_uuid, default_repo_paths, output_mode, base_branch,
                updated_by)
            VALUES (?, ?, ?::jsonb, ?, ?, ?)
            ON CONFLICT (namespace_id, project_uuid) DO UPDATE SET default_repo_paths = EXCLUDED.default_repo_paths,
                output_mode = EXCLUDED.output_mode, base_branch = EXCLUDED.base_branch,
                updated_by = EXCLUDED.updated_by, updated_at = NOW()
        ]], ns, p.uuid, next(paths) and cjson.encode(paths) or "{}", pick("output_mode"), pick("base_branch"),
            sdk.user(self).uuid)
        return sdk.ok(R.project_settings(ns, p.uuid))
    end)))

    -- Prompt template ------------------------------------------------------------------------------------------
    app:get("/template", sdk.handler({ permission = "ai_runs_settings.manage" }, U.guard(function(self)
        return sdk.ok(template_view(R.template(sdk.namespace_id(self))))
    end)))

    app:put("/template", sdk.handler({ permission = "ai_runs_settings.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local d, errors = sdk.validate(body(self), { body = { type = "text", required = true, max = 50000 } })
        if not d then U.invalid(errors) end
        -- A concurrent save of the same version hits the unique index -> 409, never a silent overwrite.
        local row = U.one([[
            INSERT INTO ar_prompt_templates (namespace_id, name, version, body, variables, created_by)
            SELECT ?, 'default', COALESCE(MAX(version), 0) + 1, ?, ?::jsonb, ?
            FROM ar_prompt_templates WHERE namespace_id = ? AND project_uuid IS NULL AND name = 'default'
            RETURNING uuid, version, body, created_by, created_at
        ]], ns, U.clean(d.body), cjson.encode(U.array({ unpack(R.TEMPLATE_VARIABLES) })), sdk.user(self).uuid, ns)
        return sdk.ok(template_view(row))
    end)))
end
