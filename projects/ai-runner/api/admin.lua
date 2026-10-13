-- Runners, machines, the overview, settings and the prompt template (docs/AI_RUNNER.md §22.3, §24, §25.1).
--   GET    /runners                         ai_runs.create or ai_runners.manage (?include_revoked=true, ?kind=runner|
--                                           source): the connections the caller may use; `access` and
--                                           `report_filter` shown to ai_runners.manage
--   GET    /runners/:uuid                   same (404 for a runner the caller may not use)
--   POST   /runners { name, kind?, labels?, report_filter? }  ai_runners.manage -> 201 { runner, token } (the
--                                           token is shown once); kind runner (default) or source (§27.1)
--   PUT    /runners/:uuid { name?, kind?, labels?, report_filter? }  ai_runners.manage
--   PUT    /runners/:uuid/access { mode: owner|everyone|listed, users?, projects? }  ai_runners.manage
--   POST   /runners/:uuid/rotate-token      ai_runners.manage -> { runner, token }; the old token stops working
--   POST   /runners/:uuid/pause | /resume   ai_runners.manage (a paused runner heartbeats but claims nothing)
--   DELETE /runners/:uuid                   ai_runners.manage: revoke (its queued runs are cancelled)
--   GET    /runners/:uuid/sessions          ai_runs.manage: the machine's last inventory, linked to runs
--   GET    /sessions                        ai_runs.manage or ai_runners.manage: every runner's sessions, with
--                                           the task of one started by hand (?runner_uuid&busy=1&page&per_page)
--   GET    /overview                        ai_runs.manage, ai_runners.manage or ai_runs_approvals.manage
--   GET|PUT /settings                       ai_runs_settings.manage (+ guards §24.1, session_tracking §26.2 + §27.4,
--                                           task_automation on_start / on_success and safety §27.4)
--   GET|PUT /projects/:project_uuid/settings  owner/admin of the kanban project or ai_runs_settings.manage
--   GET|PUT /template                       ai_runs_settings.manage: the workspace template, versioned on save
--   GET|PUT /platform/settings              platform admins only, no workspace (§27.5): timings, timeouts, limits
--                                           and the workspace guards' upper bounds; null resets one to its default
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")
local B = require("ai_runner.builtin")
local G = require("ai_runner.github")

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

-- §27.2: what a connection reports, { folders, exclude_folders, tools }; nil = not given, null = everything.
local function report_filter_of(v)
    if v == nil then return nil end
    if v ~= cjson.null and not U.object(v) then U.invalid({ report_filter = "must be an object" }) end
    v = v ~= cjson.null and v or {}
    return { folders = U.strings(v.folders, "report_filter.folders", 50, 255, U.folder_glob),
        exclude_folders = U.strings(v.exclude_folders, "report_filter.exclude_folders", 50, 255, U.folder_glob),
        tools = U.strings(v.tools, "report_filter.tools", 50, 40, string.lower) }
end

local KINDS = { "runner", "source" }

local function runner_or_404(ns, uuid)
    local r = R.runner(ns, uuid)
    if not r then U.fail(404, "Runner not found") end
    return r
end

-- §28: the built-in runner has no token and is never revoked (a workspace pauses it, or limits who may use it).
local function not_builtin(r, what)
    if r.kind == "builtin" then U.fail(409, "The built-in runner " .. what) end
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

local function platform_admin(self)
    if not require("helper.admin-check").isPlatformAdmin(sdk.user(self)) then
        U.fail(403, "Only a platform admin can see or change the AI Runs platform settings")
    end
end

-- { min, max } pairs as objects, for the settings page.
local function bounds_view(bounds)
    local out = {}
    for k, b in pairs(bounds) do
        out[k] = type(b[1]) == "number" and { min = b[1], max = b[2] } or bounds_view(b)
    end
    return out
end

-- The values in force (from the row, not the cache: what was just saved), the defaults, the bounds, who saved.
local function platform_view()
    local row = U.one("SELECT settings, updated_by, updated_at FROM ar_platform_settings WHERE id = 1") or {}
    local stored = U.json(row.settings)
    local v = R.platform_values(stored, R.PLATFORM_DEFAULTS, R.PLATFORM_BOUNDS)
    v.defaults, v.bounds = R.PLATFORM_DEFAULTS, bounds_view(R.PLATFORM_BOUNDS)
    -- Where task links point; "" = the deployment's FRONTEND_URL (shown so the page can say what that is).
    v.dashboard_url = R.base_url(type(stored) == "table" and stored.dashboard_url) or ""
    v.dashboard_url_fallback = R.frontend_url()
    -- §28.3: the GitHub App; secrets are only ever "set" or not.
    local gh = type(stored) == "table" and type(stored.github) == "table" and stored.github or {}
    local function str(x) return type(x) == "string" and x or "" end
    v.github = { api_url = str(gh.api_url), web_url = str(gh.web_url), app_id = gh.app_id and tostring(gh.app_id) or "",
        app_slug = str(gh.app_slug), client_id = str(gh.client_id),
        has_client_secret = type(gh.client_secret_sealed) == "string",
        has_private_key = type(gh.private_key_sealed) == "string",
        callback_url = (v.dashboard_url ~= "" and v.dashboard_url or v.dashboard_url_fallback)
            .. "/dashboard/ai-runner/github",
        default_api_url = G.API_URL, default_web_url = G.WEB_URL }
    v.github.configured = v.github.app_id ~= "" and v.github.app_slug ~= "" and v.github.client_id ~= ""
        and v.github.has_client_secret and v.github.has_private_key
    v.updated_at, v.updated_by = U.null(row.updated_at), U.null(row.updated_by)
    return v
end

-- §28.3: the GitHub App settings as stored, from a PUT's github object. Only the keys given change; null or ""
-- clears one; null for the whole object clears them all. The client secret and private key are sealed and never
-- returned.
local function github_of(given, current)
    if given == cjson.null then return nil end
    if not U.object(given) then U.invalid({ github = "must be an object" }) end
    local out = U.object(current) or {}
    local function set(k, check, message)
        local v = given[k]
        if v == nil then return end
        if v == cjson.null or v == "" then out[k] = nil return end
        local ok = type(v) == "string" and check(v)
        if not ok then U.invalid({ ["github." .. k] = message }) end
        out[k] = ok
    end
    set("api_url", G.base_url,
        "must be an address like https://api.github.com (GitHub Enterprise: https://host/api/v3)")
    set("web_url", G.base_url, "must be an address like https://github.com")
    set("app_id", function(v) return v:match("^%d+$") and #v <= 20 and v end, "must be the App ID (a number)")
    set("app_slug", function(v) return v:match("^[%w%-]+$") and #v <= 100 and v end,
        "must be the App's slug, as in github.com/apps/<slug>")
    set("client_id", function(v) return v:match("^[%w%.]+$") and #v <= 100 and v end, "must be the App's client ID")
    local Box = require("helper.secret-box")
    for k, check in pairs({
        client_secret = function(v) return v:match("^[%w]+$") and #v <= 200 end,
        private_key = function(v)
            v = v:gsub("\\n", "\n")
            local ok, key = pcall(require("resty.openssl.pkey").new, v)
            return #v <= 16384 and ok and key and key:is_private() and key:get_key_type().sn == "rsaEncryption" and v
        end,
    }) do
        local v = given[k]
        if v == cjson.null or v == "" then
            out[k .. "_sealed"] = nil
        elseif v ~= nil then
            local plain = type(v) == "string" and check(v)
            if not plain then
                U.invalid({ ["github." .. k] = k == "private_key" and "must be the App's private key (PEM, RSA)"
                    or "must be the App's client secret" })
            end
            out[k .. "_sealed"] = Box.seal(plain == true and v or plain, G.PURPOSE)
        end
    end
    return next(out) and out or nil
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
        local kind = self.params.kind
        if kind ~= nil and kind ~= "" and kind ~= "runner" and kind ~= "source" and kind ~= "builtin" then
            U.fail(400, "kind must be runner, source or builtin")
        end
        if kind ~= "runner" and kind ~= "source" then
            B.refresh(ns, self.params.refresh == "1" or self.params.refresh == "true")
        end
        local cond, args = R.runner_access_sql(self, ns)
        local w = cond .. " AND r.namespace_id = ?" .. (all and "" or " AND r.status <> 'revoked'")
        args[#args + 1] = ns
        if kind == "runner" or kind == "source" or kind == "builtin" then
            w = w .. " AND r.kind = ?"
            args[#args + 1] = kind
        end
        local q_args = { unpack(args) }
        q_args[#q_args + 1] = per_page
        q_args[#q_args + 1] = offset
        local out, show_access = {}, sdk.can(self, "ai_runners", "manage")
        for i, r in ipairs(db.query("SELECT " .. R.runner_cols() .. " FROM ar_runners r WHERE " .. w
            .. " ORDER BY r.kind = 'builtin', lower(r.name), r.id LIMIT ? OFFSET ?", unpack(q_args))) do
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
        local d, errors = sdk.validate(b, { name = { required = true, max = 100 }, kind = { enum = KINDS } })
        if not d then U.invalid(errors) end
        local raw, hash, hint = U.new_token()
        local row = db.insert("ar_runners", { namespace_id = ns, name = U.clean(d.name),
            labels = cjson.encode(labels_of(b.labels) or U.array()), token_hash = hash, token_hint = hint,
            kind = type(d.kind) == "string" and d.kind or "runner",
            report_filter = cjson.encode(report_filter_of(b.report_filter) or R.report_filter({})),
            created_by = sdk.user(self).uuid }, { returning = "*" })[1]
        return sdk.created({ runner = R.runner_view(R.runner(ns, row.uuid), true), token = raw })
    end)))

    app:put("/runners/:uuid", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = runner_or_404(ns, self.params.uuid)
        if r.status == "revoked" then U.fail(409, "This runner was revoked") end
        local b = body(self)
        local d, errors = sdk.validate(b, { name = { max = 100 }, kind = { enum = KINDS } }, true)
        if not d or d.name == db.NULL or d.name == "" then U.invalid(errors or { name = "is required" }) end
        local name, l, rf = d.name and U.clean(d.name) or r.name, labels_of(b.labels), report_filter_of(b.report_filter)
        local kind = type(d.kind) == "string" and d.kind or r.kind
        if r.kind == "builtin" and kind ~= "builtin" then U.invalid({ kind = "the built-in runner stays built-in" }) end
        db.query([[UPDATE ar_runners SET name = ?, labels = COALESCE(?::jsonb, labels), kind = ?,
            report_filter = COALESCE(?::jsonb, report_filter), updated_at = NOW() WHERE id = ?]],
            name, l and cjson.encode(l) or db.NULL, kind, rf and cjson.encode(rf) or db.NULL, r.id)
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
        not_builtin(r, "has no token")
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
        not_builtin(r, "can't be revoked; pause it instead")
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
            where[#where + 1] = "lower(COALESCE(s.status, '')) NOT IN ?"
            args[#args + 1] = R.idle(ns)
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
                   ]] .. R.online_sql("ru") .. [[ AS online,
                   t.task_number, COALESCE(t.title, x.task_snapshot->>'title') AS task_title,
                   tt.uuid AS tracked_uuid, tt.task_number AS tracked_number, tt.title AS tracked_title,
                   tp.uuid AS tracked_project
            FROM ar_sessions s
            JOIN ar_runners ru ON ru.uuid = s.runner_uuid
            LEFT JOIN ar_runs x ON x.uuid = s.run_uuid
            LEFT JOIN kanban_tasks t ON t.uuid = x.task_uuid
            LEFT JOIN ar_tracked_sessions ts ON ts.runner_uuid = s.runner_uuid
                AND ts.session_ref = COALESCE(NULLIF(s.session_id, ''), s.session_key)
            LEFT JOIN kanban_tasks tt ON tt.uuid = ts.task_uuid AND tt.deleted_at IS NULL
            LEFT JOIN kanban_boards tb ON tb.id = tt.board_id
            LEFT JOIN kanban_projects tp ON tp.id = tb.project_id
            WHERE ]] .. w .. [[
            ORDER BY lower(ru.name), ru.id, s.managed DESC, s.updated_at DESC NULLS LAST, s.session_key
            LIMIT ? OFFSET ?]], unpack(q_args))) do
            out[i] = { key = s.session_key, tool = U.null(s.tool), status = U.null(s.status), cwd = U.null(s.cwd),
                branch = U.null(s.branch), managed = s.managed == true, prompt_preview = U.null(s.prompt_preview),
                updated_at = U.null(s.updated_at), seen_at = s.seen_at,
                runner = { uuid = s.runner_uuid, name = s.runner_name,
                    status = R.runner_status({ status = s.runner_state, online = s.online }) },
                run = s.run_uuid and { uuid = s.run_uuid, task_title = U.null(s.task_title),
                    task_number = U.null(s.task_number) } or cjson.null,
                -- §26.4: the task a session started by hand became.
                task = s.tracked_uuid and { uuid = s.tracked_uuid, task_number = U.null(s.tracked_number),
                    title = s.tracked_title, project_uuid = U.null(s.tracked_project) } or cjson.null }
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
        local online = "last_heartbeat_at > NOW() - interval '" .. math.floor(R.platform().online_s) .. " seconds'"
        local runners = U.one([[SELECT COUNT(*) FILTER (WHERE status = 'active' AND ]] .. online .. [[)::int AS online,
                COUNT(*) FILTER (WHERE status = 'active' AND NOT COALESCE(]] .. online .. [[, false))::int AS offline,
                COUNT(*) FILTER (WHERE status = 'paused')::int AS paused
            FROM ar_runners WHERE namespace_id = ? AND status <> 'revoked' AND kind <> 'builtin']], ns)
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
    -- §27.5: the platform's current upper bounds, so the settings form allows what the platform allows.
    local function with_limits(s)
        local p = R.platform()
        local gm = p.guard_max
        s.limits = { max_run_minutes = gm.max_run_minutes, max_new_per_heartbeat = p.max_tracked_per_heartbeat_cap,
            guards = { max_open_runs_per_user = gm.max_open_runs_per_user,
                max_open_runs_per_workspace = gm.max_open_runs_per_workspace,
                daily_token_limit = gm.daily_token_limit, retention_days = gm.retention_days } }
        return s
    end

    app:get("/settings", sdk.handler({ permission = "ai_runs_settings.manage" }, U.guard(function(self)
        return sdk.ok(with_limits(R.settings(sdk.namespace_id(self))))
    end)))

    app:put("/settings", sdk.handler({ permission = "ai_runs_settings.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local b = body(self)
        b.limits = nil -- read-only, returned by GET (a GET -> PUT round trip sends it back)
        local p = R.platform()
        local gm = p.guard_max -- §27.5: the platform's upper bounds
        local d, errors = sdk.validate(b, {
            output_mode = { enum = R.OUTPUT_MODES }, pr_draft = { type = "boolean" }, pr_base = { max = 255 },
            max_run_minutes = { type = "integer", min = 1, max = gm.max_run_minutes },
        }, true)
        if not d then U.invalid(errors) end
        local s = R.settings(ns)
        local function put(into, defaults, clean)
            for k, v in pairs(clean) do
                if v == db.NULL then into[k] = R.copy(defaults[k]) else into[k] = v end
            end
        end
        put(s, R.SETTINGS_DEFAULTS, d)
        if not U.is_branch(s.pr_base) then U.invalid({ pr_base = "must be a branch name" }) end
        local function object(name, given)
            if not U.object(given) then U.invalid({ [name] = "must be an object" }) end
            return given
        end
        local function validate(name, given, rules)
            local clean, errs = sdk.validate(object(name, given), rules, true)
            if not clean then
                local out = {}
                for k, m in pairs(errs) do out[name .. "." .. k] = m end
                U.invalid(out)
            end
            return clean
        end
        local function merge(name, rules)
            if b[name] == nil then return end
            put(s[name], R.SETTINGS_DEFAULTS[name], validate(name, b[name], rules))
        end

        -- §27.4: on_start / on_success { enabled, status, column }; the old booleans still switch them on or off
        -- (an object given wins). The booleans are kept, mirroring `enabled`.
        if b.task_automation ~= nil then
            local given = object("task_automation", b.task_automation)
            local flags = validate("task_automation", given, { in_progress_on_start = { type = "boolean" },
                review_on_success = { type = "boolean" } })
            local ta, td = s.task_automation, R.SETTINGS_DEFAULTS.task_automation
            for which, flag in pairs({ on_start = "in_progress_on_start", on_success = "review_on_success" }) do
                local name = "task_automation." .. which
                if given[which] == cjson.null then
                    ta[which] = R.copy(td[which])
                elseif given[which] ~= nil then
                    for k, v in pairs(validate(name, given[which], { enabled = { type = "boolean" },
                        status = { enum = R.TASK_STATUSES }, column = { max = 100 } })) do
                        if v == db.NULL then
                            ta[which][k] = k == "column" and cjson.null or td[which][k]
                        else
                            ta[which][k] = v
                        end
                    end
                    if ta[which].column == "" then ta[which].column = cjson.null end
                elseif type(flags[flag]) == "boolean" then
                    ta[which].enabled = flags[flag]
                end
            end
            ta.in_progress_on_start, ta.review_on_success = ta.on_start.enabled == true, ta.on_success.enabled == true
        end
        merge("approval_policy", { deciders = { enum = { "requester", "managers", "requester_or_managers" } },
            require_start_approval = { type = "boolean" }, project_admins_decide = { type = "boolean" },
            permission_timeout_minutes = { type = "integer", min = 1, max = 1440 },
            input_timeout_minutes = { type = "integer", min = 1, max = 1440 } })
        merge("guards", { similar_threshold = { type = "number", min = 0.1, max = 1 },
            max_open_runs_per_user = { type = "integer", min = 0, max = gm.max_open_runs_per_user },
            max_open_runs_per_workspace = { type = "integer", min = 0, max = gm.max_open_runs_per_workspace },
            daily_token_limit = { type = "integer", min = 0, max = gm.daily_token_limit },
            retention_days = { type = "integer", min = 30, max = gm.retention_days } })
        merge("session_tracking", { enabled = { type = "boolean" }, project_uuid = { type = "uuid" },
            column = { max = 100 }, status = { enum = { "todo", "in_progress" } }, notify = { type = "boolean" },
            gone_after_minutes = { type = "integer", min = 1, max = 1440 },
            max_new_per_heartbeat = { type = "integer", min = 1, max = p.max_tracked_per_heartbeat_cap } })
        -- §26.2: the tasks of sessions started by hand go to a kanban project of this workspace (required when on),
        -- into a column of its first board. Checked when given, so a project deleted since doesn't block other saves.
        local st = s.session_tracking
        if b.session_tracking ~= nil then
            local given = b.session_tracking
            if st.column == "" then st.column = cjson.null end
            local target = st.project_uuid ~= cjson.null and R.track_target(ns, st.project_uuid, st.column)
            if st.project_uuid == cjson.null and st.enabled == true then
                U.invalid({ ["session_tracking.project_uuid"] = "is required when tracking is on" })
            elseif st.project_uuid ~= cjson.null and not target then
                U.invalid({ ["session_tracking.project_uuid"] = "must be a kanban project of this workspace" })
            elseif st.column ~= cjson.null and not (target and target.column_found) then
                U.invalid({ ["session_tracking.column"] = "must be a column of the project's first board" })
            end
            if target then st.project_uuid = target.project_uuid end
            if st.column ~= cjson.null then st.column = target.column_name end
            -- §27.4: the statuses that aren't busy, and how each tool is named in titles.
            if given.idle_statuses == cjson.null then
                st.idle_statuses = U.array({ unpack(R.IDLE_STATUSES) })
            elseif given.idle_statuses ~= nil then
                st.idle_statuses = U.strings(given.idle_statuses, "session_tracking.idle_statuses", 50, 40,
                    string.lower)
                if #st.idle_statuses == 0 then
                    U.invalid({ ["session_tracking.idle_statuses"] = "must name at least one status" })
                end
            end
            if given.tool_labels == cjson.null then
                st.tool_labels = R.copy(R.SETTINGS_DEFAULTS.session_tracking.tool_labels)
            elseif given.tool_labels ~= nil then
                local labels, n = {}, 0
                for tool, label in pairs(object("session_tracking.tool_labels", given.tool_labels)) do
                    n = n + 1
                    tool = type(tool) == "string" and U.clean(tool:match("^%s*(.-)%s*$")):lower()
                    label = type(label) == "string" and U.clean(label:match("^%s*(.-)%s*$"))
                    if n > 50 or not tool or tool == "" or #tool > 40 or not label or label == "" or #label > 60 then
                        U.invalid({ ["session_tracking.tool_labels"] =
                            "maps up to 50 tool names (1-40 characters) to labels (1-60 characters)" })
                    end
                    labels[tool] = label
                end
                st.tool_labels = labels
            end
        end
        -- §27.4: additions to the safety lists (they can only add: the built-in ones always apply).
        if b.safety ~= nil then
            local given = object("safety", b.safety)
            if given.extra_denied_commands ~= nil then
                s.safety.extra_denied_commands = U.strings(given.extra_denied_commands, "safety.extra_denied_commands",
                    100, 200)
            end
            if given.extra_redactions ~= nil then
                s.safety.extra_redactions = U.strings(given.extra_redactions, "safety.extra_redactions", 20, 200,
                    function(re)
                        local ok, message = U.check_regex(re)
                        if ok then return re end
                        return nil, "each entry " .. message
                    end)
            end
        end
        db.query([[
            INSERT INTO ar_settings (namespace_id, output_mode, pr_draft, pr_base, max_run_minutes, task_automation,
                approval_policy, guards, session_tracking, safety, updated_by)
            VALUES (?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?::jsonb, ?::jsonb, ?::jsonb, ?)
            ON CONFLICT (namespace_id) DO UPDATE SET output_mode = EXCLUDED.output_mode, pr_draft = EXCLUDED.pr_draft,
                pr_base = EXCLUDED.pr_base, max_run_minutes = EXCLUDED.max_run_minutes,
                task_automation = EXCLUDED.task_automation, approval_policy = EXCLUDED.approval_policy,
                guards = EXCLUDED.guards, session_tracking = EXCLUDED.session_tracking, safety = EXCLUDED.safety,
                updated_by = EXCLUDED.updated_by, updated_at = NOW()
        ]], ns, s.output_mode, s.pr_draft, s.pr_base, s.max_run_minutes, cjson.encode(s.task_automation),
            cjson.encode(s.approval_policy), cjson.encode(s.guards), cjson.encode(st), cjson.encode(s.safety),
            sdk.user(self).uuid)
        ngx.ctx.ar_redact = nil -- the workspace's redactions may have changed
        return sdk.ok(with_limits(R.settings(ns)))
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

    -- Platform settings (§27.5) --------------------------------------------------------------------------------
    -- Platform admins only, and for every workspace: no workspace header, no workspace RBAC.
    app:get("/platform/settings", sdk.handler({ namespace = false }, U.guard(function(self)
        platform_admin(self)
        return sdk.ok(platform_view())
    end)))

    -- Only the keys given change; null puts one back to its default (the row keeps only what was set).
    app:put("/platform/settings", sdk.handler({ namespace = false }, U.guard(function(self)
        platform_admin(self)
        local b = body(self)
        local row = U.one("SELECT settings FROM ar_platform_settings WHERE id = 1")
        local stored = row and U.object(U.json(row.settings)) or {}
        local function apply(into, given, defaults, bounds, prefix)
            local rules = {}
            for k, d in pairs(defaults) do
                if type(d) ~= "table" then rules[k] = { type = "integer", min = bounds[k][1], max = bounds[k][2] } end
            end
            local clean, errs = sdk.validate(given, rules, true)
            if not clean then
                local out = {}
                for k, m in pairs(errs) do out[prefix .. k] = m end
                U.invalid(out)
            end
            for k, v in pairs(clean) do
                if v == db.NULL then into[k] = nil else into[k] = v end
            end
        end
        if b.dashboard_url ~= nil then
            if b.dashboard_url == cjson.null or b.dashboard_url == "" then
                stored.dashboard_url = nil
            else
                local url = R.base_url(b.dashboard_url)
                if not url then
                    U.invalid({ dashboard_url = "must be the dashboard's address, like https://ops.example.com (no path)" })
                end
                stored.dashboard_url = url
            end
            b.dashboard_url = nil
        end
        if b.github ~= nil then
            stored.github = github_of(b.github, stored.github)
            b.github = nil
        end
        apply(stored, b, R.PLATFORM_DEFAULTS, R.PLATFORM_BOUNDS, "")
        if b.guard_max == cjson.null then
            stored.guard_max = nil
        elseif b.guard_max ~= nil then
            if not U.object(b.guard_max) then U.invalid({ guard_max = "must be an object" }) end
            stored.guard_max = U.object(stored.guard_max) or {}
            apply(stored.guard_max, b.guard_max, R.PLATFORM_DEFAULTS.guard_max, R.PLATFORM_BOUNDS.guard_max,
                "guard_max.")
        end
        local v = R.platform_values(stored, R.PLATFORM_DEFAULTS, R.PLATFORM_BOUNDS)
        -- A runner heartbeats well within its lease, and within the time it counts as online.
        if v.heartbeat_s >= v.lease_s then U.invalid({ heartbeat_s = "must be less than lease_s" }) end
        if v.heartbeat_s >= v.online_s then U.invalid({ heartbeat_s = "must be less than online_s" }) end
        db.query([[INSERT INTO ar_platform_settings (id, settings, updated_by) VALUES (1, ?::jsonb, ?)
            ON CONFLICT (id) DO UPDATE SET settings = EXCLUDED.settings, updated_by = EXCLUDED.updated_by,
                updated_at = NOW()]], cjson.encode(stored), sdk.user(self).uuid)
        R.platform_changed()
        return sdk.ok(platform_view())
    end)))
end
