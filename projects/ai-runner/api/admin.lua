-- Runners, settings and the prompt template (docs/AI_RUNNER.md §22.3).
--   GET    /runners                         ai_runs.create or ai_runners.manage (?include_revoked=true)
--   GET    /runners/:uuid                   same
--   POST   /runners { name, labels? }       ai_runners.manage -> 201 { runner, token } (the token is shown once)
--   PUT    /runners/:uuid { name?, labels? } ai_runners.manage
--   POST   /runners/:uuid/rotate-token      ai_runners.manage -> { runner, token }; the old token stops working
--   POST   /runners/:uuid/pause | /resume   ai_runners.manage (a paused runner heartbeats but claims nothing)
--   DELETE /runners/:uuid                   ai_runners.manage: revoke (its queued runs are cancelled)
--   GET    /runners/:uuid/sessions          ai_runs.manage: the machine's last inventory, linked to runs
--   GET|PUT /settings                       ai_runs_settings.manage
--   GET|PUT /projects/:project_uuid/settings  owner/admin of the kanban project or ai_runs_settings.manage
--   GET|PUT /template                       ai_runs_settings.manage: the workspace template, versioned on save
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")

local BRANCH = "^[%w%._/%-]+$"

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
    if not sdk.can(self, "ai_runs_settings", "manage")
        and not require("queries.KanbanProjectQueries").isAdmin(p.id, sdk.user(self).uuid) then
        U.fail(403, "Only an owner or admin of this project, or an AI run settings manager, can do this")
    end
    return p
end

local function template_view(t)
    return { uuid = U.null(t.uuid), version = t.version, body = t.body, builtin = t.builtin == true,
        created_by = U.null(t.created_by), created_at = U.null(t.created_at),
        variables = U.array({ unpack(R.TEMPLATE_VARIABLES) }) }
end

return function(app)
    -- Runners --------------------------------------------------------------------------------------------------
    app:get("/runners", sdk.handler({}, U.guard(function(self)
        if not may_list_runners(self) then return sdk.error(403, "Permission denied") end
        local ns = sdk.namespace_id(self)
        local page, per_page, offset = sdk.page(self.params)
        local all = self.params.include_revoked == "true" or self.params.include_revoked == "1"
        local w = "r.namespace_id = ?" .. (all and "" or " AND r.status <> 'revoked'")
        local out = {}
        for i, r in ipairs(db.query("SELECT " .. R.RUNNER_COLS .. " FROM ar_runners r WHERE " .. w
            .. " ORDER BY lower(r.name), r.id LIMIT ? OFFSET ?", ns, per_page, offset)) do
            out[i] = R.runner_view(r)
        end
        local total = db.query("SELECT COUNT(*)::int AS n FROM ar_runners r WHERE " .. w, ns)[1].n
        return sdk.ok(U.array(out), { page = page, per_page = per_page, total = total,
            total_pages = math.ceil(total / per_page) })
    end)))

    app:get("/runners/:uuid", sdk.handler({}, U.guard(function(self)
        if not may_list_runners(self) then return sdk.error(403, "Permission denied") end
        return sdk.ok(R.runner_view(runner_or_404(sdk.namespace_id(self), self.params.uuid)))
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
        return sdk.created({ runner = R.runner_view(R.runner(ns, row.uuid)), token = raw })
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
        return sdk.ok(R.runner_view(R.runner(ns, r.uuid)))
    end)))

    app:post("/runners/:uuid/rotate-token", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = runner_or_404(ns, self.params.uuid)
        if r.status == "revoked" then U.fail(409, "This runner was revoked") end
        local raw, hash, hint = U.new_token()
        db.query("UPDATE ar_runners SET token_hash = ?, token_hint = ?, updated_at = NOW() WHERE id = ?", hash, hint,
            r.id)
        return sdk.ok({ runner = R.runner_view(R.runner(ns, r.uuid)), token = raw })
    end)))

    for action, change in pairs({ pause = { "active", "paused" }, resume = { "paused", "active" } }) do
        app:post("/runners/:uuid/" .. action, sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
            local ns = sdk.namespace_id(self)
            local r = runner_or_404(ns, self.params.uuid)
            if r.status == "revoked" then U.fail(409, "This runner was revoked") end
            db.query("UPDATE ar_runners SET status = ?, updated_at = NOW() WHERE id = ? AND status = ?", change[2],
                r.id, change[1])
            return sdk.ok(R.runner_view(R.runner(ns, r.uuid)))
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
        return sdk.ok(R.runner_view(R.runner(ns, r.uuid)))
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
        if not tostring(s.pr_base):match(BRANCH) then U.invalid({ pr_base = "must be a branch name" }) end
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
            require_start_approval = { type = "boolean" },
            permission_timeout_minutes = { type = "integer", min = 1, max = 1440 },
            input_timeout_minutes = { type = "integer", min = 1, max = 1440 } })
        db.query([[
            INSERT INTO ar_settings (namespace_id, output_mode, pr_draft, pr_base, max_run_minutes, task_automation,
                approval_policy, updated_by)
            VALUES (?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?)
            ON CONFLICT (namespace_id) DO UPDATE SET output_mode = EXCLUDED.output_mode, pr_draft = EXCLUDED.pr_draft,
                pr_base = EXCLUDED.pr_base, max_run_minutes = EXCLUDED.max_run_minutes,
                task_automation = EXCLUDED.task_automation, approval_policy = EXCLUDED.approval_policy,
                updated_by = EXCLUDED.updated_by, updated_at = NOW()
        ]], ns, s.output_mode, s.pr_draft, s.pr_base, s.max_run_minutes, cjson.encode(s.task_automation),
            cjson.encode(s.approval_policy), sdk.user(self).uuid)
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
        if type(d.base_branch) == "string" and not d.base_branch:match(BRANCH) then
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
