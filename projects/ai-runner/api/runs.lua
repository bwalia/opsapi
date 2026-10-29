-- AI runs for users (docs/AI_RUNNER.md §22.3, §23.3, §25.1). Who may start: ai_runs.create and (the task's
-- assignee, ai_runs.manage or owner/admin of its kanban project), on a runner they may use (R.runner_access_sql;
-- else 403). Editing the prompt: ai_runs.manage. Who sees: own runs (requested, or on a task assigned to them),
-- project owners/admins their project's runs, ai_runs.manage all. Cancel / retry / messages: requester or
-- ai_runs.manage. Start approvals: managers (R.is_manager), never the requester. Permission requests: per
-- approval_policy.deciders (R.can_decide). Start and retry check the workspace guards (§24.2): caps, the daily
-- token limit, then similar work (which `confirm_similar: true` accepts).
--   POST /tasks/:task_uuid/runs/preview     prompt, runners, suggested folder, conflicts (+ similar), limits,
--                                           needs_approval
--   POST /tasks/:task_uuid/runs             start (Idempotency-Key) -> 201 run | 409 { conflict } | 422
--   GET  /tasks/:task_uuid/runs             the task's run history
--   GET  /runs                              ?status&task_uuid&runner_uuid&mine&page&per_page, newest first
--   GET  /runs/:uuid                        run + events + requests + turns + usage + task + runner + can_*
--   POST /runs/:uuid/cancel                 pending_approval/queued -> cancelled; running -> cancelling
--   POST /runs/:uuid/retry                  { confirm_similar? } a new run (attempt + 1) with the same inputs
--   POST /runs/:uuid/approve | /reject      pending_approval -> queued | cancelled (managers)
--   POST /runs/:uuid/turns                  { text } a follow-up or needs_input answer, queued for the runner
--   POST /runs/:uuid/requests/:req/decide   { decision: allow|deny, reason?, remember? }
--   GET  /waiting                           the requests and approvals the caller may decide
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")
local B = require("ai_runner.builtin")
local Term = require("ai_runner.terminal")

-- Run fields in the API (all real columns; the list leaves out the prompt, the detail adds it).
local FIELDS = { "uuid", "task_uuid", "project_uuid", "requested_by", "assignee_uuid", "runner_uuid", "profile",
    "model", "repo_path", "repo_remote", "base_branch", "work_branch", "previous_branch", "output_mode", "pr_draft",
    "pr_base", "template_uuid", "template_version", "prompt_sha256", "status", "status_seq", "attempt", "retry_of",
    "timeout_s", "lease_until", "heartbeat_at", "claimed_at", "started_at", "finished_at", "cancel_requested_at",
    "cancel_requested_by", "pid", "agent_session_id", "exit_code", "error_category", "error", "summary",
    "commit_sha", "pr_url", "created_at", "updated_at", "approved_by", "approved_at", "question", "tokens_in",
    "tokens_out", "cache_read", "cache_write", "cost_estimate", "turns", "executor_kind", "provider_uuid",
    "jobshout_run_id", "conversation_summary" }
local COLS = {}
for i, f in ipairs(FIELDS) do COLS[i] = "r." .. f end
COLS = table.concat(COLS, ", ") .. ", r.task_snapshot"

local NOT_ALLOWED = "Only the task's assignee, an owner or admin of its project, or an AI runs manager can start "
    .. "an AI run on this task"
local APPROVE_OWN = "You can't approve a run you asked for; another manager must"

local function view(r)
    local v = {}
    for _, f in ipairs(FIELDS) do v[f] = U.null(r[f]) end
    v.task_snapshot = U.json(r.task_snapshot) or cjson.null
    v.context_snapshot = U.json(r.context_snapshot) or cjson.null
    -- Totals again as one object: on the detail `turns` is the conversation, not the count.
    v.usage = { tokens_in = r.tokens_in or 0, tokens_out = r.tokens_out or 0, cache_read = r.cache_read or 0,
        cache_write = r.cache_write or 0, cost_estimate = r.cost_estimate or 0, turns = r.turns or 0 }
    if r.prompt then v.prompt = r.prompt end
    for _, f in ipairs({ "prompt_preview", "task_title", "task_number", "runner_name", "requested_by_name",
        "pending_requests" }) do
        if r[f] ~= nil then v[f] = r[f] end
    end
    return v
end

local function body(self)
    local b, err = sdk.body(self)
    if not b then U.fail(400, err) end
    return b
end

local function map(rows, fn)
    for i, r in ipairs(rows) do rows[i] = fn(r) end
    return U.array(rows)
end

-- How the prompt names the run's folder and what happens to its work: a machine's folder, or for the built-in
-- runner (§28) its GitHub repository (or none) and its branch. Includes project context pack.
local function render_opts(builtin, repo_path, defaults, output_mode, context_snapshot)
    local target = type(defaults.project_settings.target_repo_url) == "string"
        and defaults.project_settings.target_repo_url or nil
    local base = {
        base_branch = defaults.base_branch, output_mode = output_mode,
        context_snapshot = context_snapshot, target_repo = target,
    }
    if builtin then
        base.repo_path = repo_path and B.repo_label(repo_path) or nil
        base.output_text = B.OUTPUT_TEXT[repo_path == B.NO_REPO and "none" or output_mode]
        return base
    end
    base.repo_path = repo_path
    return base
end

local function task_or_404(ns, task_uuid)
    local task = R.task(ns, task_uuid)
    if not task then U.fail(404, "Task not found") end
    return task
end

local function list(self, ns, params)
    local cond, vals = R.visible_sql(self, ns)
    local where, args = { "r.namespace_id = ?", cond }, { ns }
    for _, v in ipairs(vals) do args[#args + 1] = v end
    local function add(sql, v)
        where[#where + 1] = sql
        args[#args + 1] = v
    end
    if type(params.status) == "string" and params.status ~= "" then
        local wanted = {}
        for s in params.status:gmatch("[^,%s]+") do
            local known = false
            for _, k in ipairs(R.STATUSES) do if k == s then known = true end end
            if not known then U.fail(400, "Unknown status: " .. U.clean(s, 40)) end
            wanted[#wanted + 1] = s
        end
        if #wanted > 0 then add("r.status IN ?", db.list(wanted)) end
    end
    if type(params.task_uuid) == "string" and params.task_uuid ~= "" then
        add("r.task_uuid = ?", params.task_uuid:sub(1, 255))
    end
    if type(params.runner_uuid) == "string" and params.runner_uuid ~= "" then
        if not U.is_uuid(params.runner_uuid) then U.fail(400, "runner_uuid must be a uuid") end
        add("r.runner_uuid = ?", params.runner_uuid)
    end
    if params.mine == "1" or params.mine == "true" or params.mine == true then
        add("r.requested_by = ?", sdk.user(self).uuid)
    end
    local page, per_page, offset = sdk.page(params)
    local w = table.concat(where, " AND ")
    local q_args = { unpack(args) }
    q_args[#q_args + 1] = per_page
    q_args[#q_args + 1] = offset
    local rows = db.query("SELECT " .. COLS .. [[, left(r.prompt, 300) AS prompt_preview, t.title AS task_title,
            t.task_number, ru.name AS runner_name,
            NULLIF(TRIM(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')), '') AS requested_by_name,
            (SELECT COUNT(*)::int FROM ar_run_requests q WHERE q.run_uuid = r.uuid AND q.status = 'pending'
                AND (q.expires_at IS NULL OR q.expires_at > NOW())) AS pending_requests
        FROM ar_runs r
        LEFT JOIN kanban_tasks t ON t.uuid = r.task_uuid
        LEFT JOIN ar_runners ru ON ru.uuid = r.runner_uuid
        LEFT JOIN users u ON u.uuid = r.requested_by
        WHERE ]] .. w .. " ORDER BY r.created_at DESC, r.id DESC LIMIT ? OFFSET ?", unpack(q_args))
    local total = db.query("SELECT COUNT(*)::int AS n FROM ar_runs r WHERE " .. w, unpack(args))[1].n
    local out = {}
    for i, r in ipairs(rows) do out[i] = view(r) end
    return U.array(out), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) }
end

-- The runners the caller may use for a task of this project (§25.1); sources run nothing (§27.1). The built-in
-- runner (§28) comes last: the Start dialog picks the first one online, so it is the default when no machine is.
local function runners(self, ns, project_uuid)
    B.refresh(ns)
    local cond, args = R.runner_access_sql(self, ns, project_uuid)
    args[#args + 1] = ns
    local out, show_access = {}, sdk.can(self, "ai_runners", "manage")
    for i, r in ipairs(db.query("SELECT " .. R.runner_cols() .. " FROM ar_runners r WHERE " .. cond
        .. " AND r.namespace_id = ? AND r.status <> 'revoked' AND r.kind IN ('runner', 'builtin') "
        .. "ORDER BY r.kind = 'builtin', lower(r.name), r.id LIMIT 100", unpack(args))) do
        out[i] = R.runner_view(r, show_access)
    end
    return out
end

return function(app)
    app:post("/tasks/:task_uuid/runs/preview", sdk.handler({ permission = "ai_runs.create" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local task = task_or_404(ns, self.params.task_uuid)
        local allowed, privileged = R.can_start(self, task)
        if not allowed then return sdk.error(403, NOT_ALLOWED) end
        local b = body(self)
        local d, errors = sdk.validate(b, {
            runner_uuid = { type = "uuid" }, profile = { max = 80 }, repo_path = { max = 1024 },
            executor_kind = { max = 40 }, provider_uuid = { type = "uuid" },
        })
        if not d then U.invalid(errors) end
        local Ctx = require("ai_runner.context")
        local list_ = runners(self, ns, task.project_uuid)
        local runner_uuid = type(d.runner_uuid) == "string" and d.runner_uuid:lower() or nil
        if runner_uuid then
            local r, usable = R.usable_runner(self, ns, runner_uuid, task.project_uuid)
            if r and not usable then return sdk.error(403, R.CANT_USE_RUNNER) end
        else
            for _, r in ipairs(list_) do
                if r.status == "online" then runner_uuid = r.uuid break end
            end
        end
        local defaults = R.defaults(ns, task)
        local ps = defaults.project_settings
        local snap = Ctx.snapshot(ps, {
            selected_skill_urls = b.selected_skill_urls, selected_md = b.selected_md,
        })
        local builtin = runner_uuid and B.is_builtin(ns, runner_uuid)
        local suggested = R.default_repo_path(ns, task, runner_uuid, ps)
        if builtin and not B.repo_ref(suggested) then suggested = B.NO_REPO end
        local given = type(d.repo_path) == "string" and (builtin and B.repo_ref(d.repo_path) or U.path(d.repo_path))
        local repo_path = given or suggested
        local tpl = R.template(ns)
        local guards = R.settings(ns).guards
        local busy = not builtin and runner_uuid and repo_path and R.busy_session(ns, runner_uuid, repo_path)
        local lock = not builtin and runner_uuid and repo_path and R.folder_lock(ns, runner_uuid, repo_path)
        local profile
        for _, r in ipairs(list_) do
            if r.uuid == runner_uuid then
                for _, p in ipairs(r.capabilities.profiles or {}) do
                    if type(p) == "table" and p.key == d.profile then profile = p end
                end
            end
        end
        local default_executor = (type(ps.default_executor) == "string" and ps.default_executor ~= ""
            and ps.default_executor ~= cjson.null and ps.default_executor)
            or (builtin and "builtin") or "machine"
        local terminals = Term.offer(ns, task, ps, { user_uuid = sdk.user(self).uuid,
            can_autologin = sdk.can(self, Term.AUTOLOGIN_PERMISSION[1], Term.AUTOLOGIN_PERMISSION[2]),
            can_unattended = sdk.can(self, "ai_runs", "manage") })
        return sdk.ok({
            prompt = R.render(tpl.body, task, render_opts(builtin, repo_path, defaults, defaults.output_mode, snap)),
            template_version = tpl.version, template_uuid = U.null(tpl.uuid), can_edit_prompt = privileged,
            runners = U.array(list_), runner_uuid = U.null(runner_uuid), default_repo_path = U.null(suggested),
            repo_path = U.null(repo_path), work_branch = R.work_branch(task), output_mode = defaults.output_mode,
            conflicts = { open_run = R.open_run(ns, task.uuid) or cjson.null, folder_lock = lock or cjson.null,
                busy_session = busy or cjson.null, similar = R.similar(self, ns, task, guards.similar_threshold) },
            limits = R.limits(ns, sdk.user(self).uuid, guards),
            needs_approval = R.needs_approval(ns, profile, R.is_manager(self, task.project_uuid)),
            context = snap,
            project = R.project_settings_view(ps),
            executor_kind = default_executor,
            allowed_executors = U.array(ps.allowed_executors or {}),
            executor_locked = ps.executor_locked == true,
            can_change_executor = not ps.executor_locked or R.is_manager(self, task.project_uuid),
            -- Web terminals (docs/AI_RUNNER_WEB_TERMINAL.md): where the person can work on it themselves.
            terminals = terminals,
            terminal_prompt = #terminals > 0 and Term.prompt(ns, task) or cjson.null,
        })
    end)))

    app:post("/tasks/:task_uuid/runs", sdk.handler({ permission = "ai_runs.create" }, U.guard(function(self)
        return sdk.idempotent(self, function()
            local ns = sdk.namespace_id(self)
            local task = task_or_404(ns, self.params.task_uuid)
            local allowed, privileged, assignee = R.can_start(self, task)
            if not allowed then return sdk.error(403, NOT_ALLOWED) end
            local b = body(self)
            local d, errors = sdk.validate(b, {
                runner_uuid = { type = "uuid" }, profile = { required = true, max = 80 },
                model = { max = 120 }, repo_path = { max = 1024 },
                prompt = { type = "text", max = 100000 }, output_mode = { enum = R.OUTPUT_MODES },
                confirm_similar = { type = "boolean" }, executor_kind = { max = 40 },
                provider_uuid = { type = "uuid" },
            })
            if not d then U.invalid(errors) end
            for k, v in pairs(d) do if v == db.NULL or v == "" then d[k] = nil end end
            -- A locked or disallowed executor is the real reason a start fails: say so before checking folders.
            R.resolve_executor(self, ns, task, d, nil)
            -- JobShout runs inside JobShout: prefer the built-in runner as the OpsAPI host row when the client
            -- didn't pick a machine (or picked one by habit).
            if d.executor_kind == "jobshout" then
                B.refresh(ns)
                local bi = U.one("SELECT uuid FROM ar_runners WHERE namespace_id = ? AND kind = 'builtin' LIMIT 1", ns)
                if bi then d.runner_uuid = bi.uuid end
                if not d.repo_path then d.repo_path = B.NO_REPO end
                if not d.profile then d.profile = "jobshout" end
            end
            if not d.runner_uuid then U.invalid({ runner_uuid = "is required" }) end
            if not d.repo_path then U.invalid({ repo_path = "is required" }) end
            local builtin = B.is_builtin(ns, d.runner_uuid:lower())
            local path = builtin and B.repo_ref(d.repo_path) or (not builtin and U.path(d.repo_path)) or nil
            if not path then
                U.invalid({ repo_path = builtin and "must be one of the built-in runner's repositories, or none"
                    or "must be an absolute folder path" })
            end
            if builtin then B.refresh(ns) end
            if d.prompt and not privileged then
                return sdk.error(403, "Only an AI runs manager can edit the prompt")
            end
            local defaults = R.defaults(ns, task)
            local Ctx = require("ai_runner.context")
            local snap = Ctx.snapshot(defaults.project_settings, {
                selected_skill_urls = b.selected_skill_urls, selected_md = b.selected_md,
            })
            local output_mode = d.output_mode or defaults.output_mode
            local tpl = R.template(ns)
            local prompt = d.prompt and U.clean(d.prompt) or R.render(tpl.body, task,
                render_opts(builtin, path, defaults, output_mode, snap))
            local key = ngx.req.get_headers()["Idempotency-Key"]
            local run = R.create(self, ns, task, {
                runner_uuid = d.runner_uuid:lower(), profile = d.profile, model = d.model, repo_path = path,
                prompt = prompt, template_uuid = tpl.uuid, template_version = tpl.version, output_mode = output_mode,
                pr_draft = defaults.pr_draft, pr_base = defaults.pr_base, base_branch = defaults.base_branch,
                timeout_s = defaults.timeout_s, assignee_uuid = assignee, confirm_similar = d.confirm_similar,
                idempotency_key = type(key) == "string" and key:sub(1, 255) or nil,
                executor_kind = d.executor_kind, provider_uuid = d.provider_uuid, context_snapshot = snap,
                selected_skill_urls = b.selected_skill_urls, selected_md = b.selected_md,
            })
            return sdk.created(view(run))
        end)
    end)))

    app:get("/tasks/:task_uuid/runs", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local task = task_or_404(ns, self.params.task_uuid)
        local params = {}
        for k, v in pairs(self.params) do params[k] = v end
        params.task_uuid = task.uuid
        return sdk.ok(list(self, ns, params))
    end)))

    app:get("/runs", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        return sdk.ok(list(self, sdk.namespace_id(self), self.params))
    end)))

    app:get("/runs/:uuid", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local run = R.find_visible(self, ns, self.params.uuid)
        if not run then return sdk.not_found("Run") end
        local v = view(run)
        local events = db.query([[SELECT seq, type, text, data, at FROM (SELECT seq, type, text, data, at
            FROM ar_run_events WHERE run_uuid = ? ORDER BY seq DESC LIMIT 500) e ORDER BY seq]], run.uuid)
        for i, e in ipairs(events) do
            events[i] = { seq = e.seq, type = e.type, text = U.null(e.text), data = U.null(U.json(e.data)), at = e.at }
        end
        v.events = U.array(events)
        local task = R.task(ns, run.task_uuid)
        v.task = task and { uuid = task.uuid, task_number = U.null(task.task_number), title = task.title,
            status = task.status, priority = U.null(task.priority), url = R.task_url(task.project_uuid, task.uuid),
            project = { uuid = task.project_uuid, name = task.project_name } } or cjson.null
        local runner = R.runner(ns, run.runner_uuid)
        v.runner = runner and { uuid = runner.uuid, name = runner.name, status = R.runner_status(runner),
            host = U.null(runner.host) } or cjson.null
        local u = run.requested_by and db.query([[SELECT uuid, email,
            NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), '') AS name
            FROM users WHERE uuid = ?]], run.requested_by)[1]
        v.requester = u and { uuid = u.uuid, name = U.null(u.name), email = U.null(u.email) } or cjson.null
        v.requests = map(db.query(R.REQUEST_SQL .. [[ WHERE q.run_uuid = ? AND q.namespace_id = ?
            ORDER BY q.created_at DESC, q.id DESC LIMIT 200]], run.uuid, ns), R.request_view)
        v.turns = map(db.query("SELECT * FROM (" .. R.TURN_SQL .. [[ WHERE t.run_uuid = ? AND t.namespace_id = ?
            ORDER BY t.seq DESC LIMIT 200) x ORDER BY x.seq]], run.uuid, ns), R.turn_view)
        v.can_decide = R.can_decide(self, run)
        v.can_approve = R.can_approve(self, run)
        v.can_message = R.IS_ACTIVE[run.status] == true and R.may_control(self, run)
        return sdk.ok(v)
    end)))

    app:post("/runs/:uuid/cancel", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local run = R.find_visible(self, ns, self.params.uuid)
        if not run then return sdk.not_found("Run") end
        if not R.may_control(self, run) then
            return sdk.error(403, "Only the person who started this run or an AI runs manager can cancel it")
        end
        return sdk.ok(view(R.cancel(run, sdk.user(self).uuid)))
    end)))

    app:post("/runs/:uuid/retry", sdk.handler({ permission = "ai_runs.create" }, U.guard(function(self)
        return sdk.idempotent(self, function()
            local ns = sdk.namespace_id(self)
            local run = R.find_visible(self, ns, self.params.uuid)
            if not run then return sdk.not_found("Run") end
            if not R.may_control(self, run) then
                return sdk.error(403, "Only the person who started this run or an AI runs manager can retry it")
            end
            if not R.TERMINAL[run.status] then
                return sdk.error(409, "This run is still open (" .. run.status .. ")")
            end
            local task = task_or_404(ns, run.task_uuid)
            if not R.can_start(self, task) then return sdk.error(403, NOT_ALLOWED) end
            local d, errors = sdk.validate(body(self), { confirm_similar = { type = "boolean" } })
            if not d then U.invalid(errors) end
            if B.is_builtin(ns, run.runner_uuid) then B.refresh(ns) end
            local key = ngx.req.get_headers()["Idempotency-Key"]
            local new = R.create(self, ns, task, {
                runner_uuid = run.runner_uuid, profile = run.profile, model = run.model, repo_path = run.repo_path,
                prompt = run.prompt, template_uuid = run.template_uuid, template_version = run.template_version,
                output_mode = run.output_mode, pr_draft = run.pr_draft, pr_base = run.pr_base,
                base_branch = run.base_branch, timeout_s = run.timeout_s, assignee_uuid = run.assignee_uuid,
                attempt = run.attempt + 1, retry_of = run.uuid, confirm_similar = d.confirm_similar,
                idempotency_key = type(key) == "string" and key:sub(1, 255) or nil,
            })
            return sdk.created(view(new))
        end)
    end)))

    -- Start approvals (§23.3, §25.1): managers only, pending_approval runs only; nobody approves their own run.
    for action, apply in pairs({ approve = R.approve, reject = R.reject }) do
        app:post("/runs/:uuid/" .. action, sdk.handler({}, U.guard(function(self)
            local ns = sdk.namespace_id(self)
            local run = R.find(ns, self.params.uuid)
            if not run then return sdk.not_found("Run") end
            if not R.is_manager(self, run.project_uuid) then
                return sdk.error(403, "Only an AI run manager can " .. action .. " this run")
            end
            if action == "approve" and run.requested_by == sdk.user(self).uuid then
                return sdk.error(403, APPROVE_OWN)
            end
            local d, errors = sdk.validate(body(self), { reason = { type = "text", max = 2000 } })
            if not d then U.invalid(errors) end
            local reason = type(d.reason) == "string" and d.reason ~= "" and U.clean(U.redact(d.reason)) or nil
            return sdk.ok(view(apply(run, sdk.user(self).uuid, reason)))
        end)))
    end

    -- A follow-up, or the answer to the agent's needs_input question; the runner fetches it (turns/next).
    app:post("/runs/:uuid/turns", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local run = R.find_visible(self, ns, self.params.uuid)
        if not run then return sdk.not_found("Run") end
        if not R.may_control(self, run) then
            return sdk.error(403, "Only the person who started this run or an AI runs manager can message it")
        end
        local d, errors = sdk.validate(body(self), { text = { type = "text", required = true, max = 8000 } })
        if not d then U.invalid(errors) end
        local me = sdk.user(self).uuid
        local turn = U.tx(function()
            local now = U.one("SELECT status FROM ar_runs WHERE id = ? FOR UPDATE", run.id)
            if not R.IS_ACTIVE[now.status] then
                U.fail(409, "This run isn't working right now (" .. now.status .. ")", { status = now.status })
            end
            -- §25.7: the agent hasn't taken the ones already waiting; don't pile more on (§27.5 max_queued_followups).
            local queued = U.one([[SELECT COUNT(*)::int AS n FROM ar_run_turns WHERE run_uuid = ? AND role = 'user'
                AND status = 'queued']], run.uuid).n
            if queued >= R.platform().max_queued_followups then
                U.fail(409, "This run already has " .. queued .. " messages waiting for the agent", { queued = queued })
            end
            return R.insert_turn(run, { role = "user", status = "queued", author_user_uuid = me,
                text = U.clean(U.redact(d.text)) })
        end)
        -- From the inserted row: the runner may already have taken the turn (delivered) by now.
        turn.author_name = U.one("SELECT " .. R.name_sql("a") .. " AS n FROM users a WHERE a.uuid = ?", me).n
        return sdk.created(R.turn_view(turn))
    end)))

    -- Permission requests: decided once (compare-and-set), by whoever the workspace approval policy names.
    app:post("/runs/:uuid/requests/:req_uuid/decide", sdk.handler({}, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local run = R.find(ns, self.params.uuid)
        local q = run and U.is_uuid(self.params.req_uuid) and U.one([[SELECT id, rememberable FROM ar_run_requests
            WHERE uuid = ? AND run_uuid = ? AND namespace_id = ?]], self.params.req_uuid, run.uuid, ns)
        if not q then return sdk.not_found("Request") end
        if not R.can_decide(self, run) then
            return sdk.error(403, "The workspace's approval policy doesn't let you decide this run's requests")
        end
        local d, errors = sdk.validate(body(self), { decision = { required = true, enum = { "allow", "deny" } },
            reason = { type = "text", max = 2000 }, remember = { type = "boolean" } })
        if not d then U.invalid(errors) end
        if not R.IS_ACTIVE[run.status] then
            U.fail(409, "This run has ended (" .. run.status .. ")", { status = run.status })
        end
        R.expire_requests(q.id)
        local done = U.one([[UPDATE ar_run_requests SET status = ?, decided_by = ?, decided_at = NOW(), reason = ?,
            remember = ? WHERE id = ? AND status = 'pending' RETURNING id]],
            d.decision == "allow" and "allowed" or "denied", sdk.user(self).uuid,
            type(d.reason) == "string" and d.reason ~= "" and U.clean(U.redact(d.reason)) or db.NULL,
            d.decision == "allow" and d.remember == true and q.rememberable == true, q.id)
        if not done then
            local now = U.one("SELECT status FROM ar_run_requests WHERE id = ?", q.id)
            U.fail(409, "This request is no longer pending (" .. now.status .. ")", { status = now.status })
        end
        R.notify(run)
        return sdk.ok(R.request_view(U.one(R.REQUEST_SQL .. " WHERE q.id = ?", q.id)))
    end)))

    -- What waits on the caller. ponytail: the newest 200 of each, filtered in Lua with the same checks the
    -- actions use; move the rules into SQL if a workspace ever has more than that waiting at once.
    app:get("/waiting", sdk.handler({}, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local requests = {}
        for _, q in ipairs(db.query([[
            SELECT q.*, NULL AS decided_by_name, r.requested_by, r.project_uuid, r.status AS run_status, r.task_uuid,
                   r.profile, t.title AS task_title, t.task_number, ]] .. R.name_sql("ru") .. [[ AS requested_by_name
            FROM ar_run_requests q
            JOIN ar_runs r ON r.uuid = q.run_uuid
            LEFT JOIN kanban_tasks t ON t.uuid = r.task_uuid
            LEFT JOIN users ru ON ru.uuid = r.requested_by
            WHERE q.namespace_id = ? AND q.status = 'pending' AND (q.expires_at IS NULL OR q.expires_at > NOW())
              AND r.status IN ]] .. R.ACTIVE_SQL .. [[
            ORDER BY q.created_at, q.id LIMIT 200
        ]], ns)) do
            if R.can_decide(self, q) then
                local v = R.request_view(q)
                v.task = { uuid = q.task_uuid, title = U.null(q.task_title), task_number = U.null(q.task_number),
                    project_uuid = U.null(q.project_uuid) }
                v.run = { uuid = q.run_uuid, status = q.run_status, task_uuid = q.task_uuid,
                    task_title = U.null(q.task_title), task_number = U.null(q.task_number),
                    project_uuid = U.null(q.project_uuid), requested_by = q.requested_by,
                    requested_by_name = U.null(q.requested_by_name), profile = q.profile }
                requests[#requests + 1] = v
            end
        end
        local approvals = {}
        for _, r in ipairs(db.query("SELECT " .. COLS .. [[, left(r.prompt, 300) AS prompt_preview,
                t.title AS task_title, t.task_number, ru.name AS runner_name, ]] .. R.name_sql("u")
                .. [[ AS requested_by_name
            FROM ar_runs r
            LEFT JOIN kanban_tasks t ON t.uuid = r.task_uuid
            LEFT JOIN ar_runners ru ON ru.uuid = r.runner_uuid
            LEFT JOIN users u ON u.uuid = r.requested_by
            WHERE r.namespace_id = ? AND r.status = 'pending_approval' ORDER BY r.created_at, r.id LIMIT 200
        ]], ns)) do
            if R.can_approve(self, r) then approvals[#approvals + 1] = view(r) end
        end
        return sdk.ok({ requests = U.array(requests), approvals = U.array(approvals) })
    end)))

    -- Task work record + PRs + web terminal (AI task completion) ----------------------------------------------
    app:get("/tasks/:task_uuid/work", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local task = task_or_404(ns, self.params.task_uuid)
        local W = require("ai_runner.task_work")
        local V = require("ai_runner.vault_pr")
        pcall(function() require("ai_runner.pr_poll").refresh_task(ns, task.uuid) end)
        Term.ensure_poll_timer()
        local latest = W.latest(ns, task.uuid)
        local history = {}
        for i, w in ipairs(W.list(ns, task.uuid)) do history[i] = W.view(w) end
        local prs = {}
        for i, p in ipairs(V.list_for_task(ns, task.uuid)) do prs[i] = V.view(p) end
        local sessions = {}
        for i, s in ipairs(Term.list_for_task(ns, task.uuid)) do sessions[i] = Term.session_view(s) end
        return sdk.ok({
            work = latest and W.view(latest) or cjson.null,
            history = U.array(history),
            pull_requests = U.array(prs),
            terminal_sessions = U.array(sessions),
            project = R.project_settings_view(R.project_settings(ns, task.project_uuid)),
            manager_links = latest and {
                task_url = R.task_url(task.project_uuid, task.uuid),
                run_url = latest.run_uuid and ("/dashboard/ai-runner/runs/" .. latest.run_uuid) or cjson.null,
                pr_urls = (function()
                    local urls = {}
                    for _, p in ipairs(prs) do urls[#urls + 1] = p.pr_url end
                    return U.array(urls)
                end)(),
            } or cjson.null,
        })
    end)))

    app:get("/tasks/:task_uuid/prs", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        task_or_404(ns, self.params.task_uuid)
        local V = require("ai_runner.vault_pr")
        local out = {}
        for i, p in ipairs(V.list_for_task(ns, self.params.task_uuid)) do out[i] = V.view(p) end
        return sdk.ok(U.array(out))
    end)))

    app:post("/tasks/:task_uuid/prs/:pr_uuid/review", sdk.handler({}, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local task = task_or_404(ns, self.params.task_uuid)
        if not R.is_manager(self, task.project_uuid) then
            return sdk.error(403, "Only an AI run manager can sign off on a pull request")
        end
        local d, errors = sdk.validate(body(self), {
            decision = { required = true, enum = { "approved", "changes_requested" } },
            note = { type = "text", max = 2000 },
        })
        if not d then U.invalid(errors) end
        local V = require("ai_runner.vault_pr")
        local row = V.review(ns, task.uuid, self.params.pr_uuid, sdk.user(self).uuid, d.decision,
            type(d.note) == "string" and d.note or nil)
        local label = d.decision == "approved" and "Manager approved PR (OpsAPI sign-off; not merged)"
            or "Manager requested changes on PR"
        pcall(function()
            require("queries.KanbanTaskQueries").addComment({
                task_id = task.id, user_uuid = sdk.user(self).uuid,
                content = label
                    .. (d.note and d.note ~= "" and (" — " .. U.clean(d.note, 500)) or "")
                    .. "\n" .. tostring(row.pr_url),
            })
        end)
        return sdk.ok(V.view(row))
    end)))
end
