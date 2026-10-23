-- Web terminals (docs/AI_RUNNER_WEB_TERMINAL.md).
--   GET    /terminals                       ai_runners.manage: this workspace's terminals (never their secrets)
--   POST   /terminals { name, url, agents? }   ai_runners.manage -> 201 { terminal, secret } (the secret, once)
--   PUT    /terminals/:uuid { name?, url?, agents?, is_active? }   ai_runners.manage
--   POST   /terminals/:uuid/rotate-secret   ai_runners.manage -> { terminal, secret }; old links and webhooks stop
--   DELETE /terminals/:uuid                 ai_runners.manage (its sessions stay on their tasks)
--   POST   /tasks/:task_uuid/terminal-sessions { terminal_uuid, path, agent, prompt? }
--                                           ai_runs.create + who may start AI work on the task -> 201
--                                           { session, launch_url }
--   GET    /tasks/:task_uuid/terminal-sessions   ai_runs.read
--   POST   /public/terminal/webhook         signed by the terminal (X-Opsapi-Signature: sha256=<hex>)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")
local T = require("ai_runner.terminal")

local function body(self)
    local b, err = sdk.body(self)
    if not b then U.fail(400, err) end
    return b
end

local function terminal_or_404(ns, uuid)
    local t = T.find(ns, uuid)
    if not t then U.fail(404, "Web terminal not found") end
    return t
end

local function url_of(v)
    local u = R.base_url(v)
    if not u then U.invalid({ url = "must be the terminal's address, like https://dev.example.com" }) end
    return u
end

return function(app)
    app:get("/terminals", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local out = {}
        for i, t in ipairs(T.list(sdk.namespace_id(self))) do out[i] = T.view(t) end
        return sdk.ok(U.array(out))
    end)))

    app:post("/terminals", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local b = body(self)
        local d, errors = sdk.validate(b, {
            name = { required = true, max = 100 }, url = { required = true, max = 255 },
        })
        if not d then U.invalid(errors) end
        local plain, sealed, hint = T.new_secret()
        local row = db.insert("ar_terminals", {
            namespace_id = ns, name = U.clean(d.name), url = url_of(d.url), secret_sealed = sealed, secret_hint = hint,
            agents = cjson.encode(T.agents_of(b.agents) or T.DEFAULT_AGENTS), created_by = sdk.user(self).uuid,
        }, { returning = "*" })[1]
        return sdk.created({ terminal = T.view(row), secret = plain })
    end)))

    app:put("/terminals/:uuid", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local t = terminal_or_404(ns, self.params.uuid)
        local b = body(self)
        local d, errors = sdk.validate(b, {
            name = { max = 100 }, url = { max = 255 }, is_active = { type = "boolean" },
        }, true)
        if not d or d.name == db.NULL or d.name == "" then U.invalid(errors or { name = "is required" }) end
        local agents = T.agents_of(b.agents)
        local active = t.is_active
        if type(d.is_active) == "boolean" then active = d.is_active end
        db.query([[UPDATE ar_terminals SET name = ?, url = ?, agents = COALESCE(?::jsonb, agents), is_active = ?,
            updated_at = NOW() WHERE id = ?]],
            d.name and U.clean(d.name) or t.name, d.url and url_of(d.url) or t.url,
            agents and cjson.encode(agents) or db.NULL, active, t.id)
        return sdk.ok(T.view(T.find(ns, t.uuid)))
    end)))

    app:post("/terminals/:uuid/rotate-secret", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local t = terminal_or_404(ns, self.params.uuid)
        local plain, sealed, hint = T.new_secret()
        db.query("UPDATE ar_terminals SET secret_sealed = ?, secret_hint = ?, updated_at = NOW() WHERE id = ?",
            sealed, hint, t.id)
        return sdk.ok({ terminal = T.view(T.find(ns, t.uuid)), secret = plain })
    end)))

    app:delete("/terminals/:uuid", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local t = terminal_or_404(sdk.namespace_id(self), self.params.uuid)
        db.query("DELETE FROM ar_terminals WHERE id = ?", t.id)
        return sdk.ok({ deleted = true })
    end)))

    local launch = sdk.handler({ permission = "ai_runs.create" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local task = R.task(ns, self.params.task_uuid)
        if not task then U.fail(404, "Task not found") end
        if not R.can_start(self, task) then
            return sdk.error(403, "Only the task's assignee, an owner or admin of its project, or an AI runs manager "
                .. "can start AI work on this task")
        end
        local b = body(self)
        local d, errors = sdk.validate(b, {
            terminal_uuid = { required = true, type = "uuid" }, path = { required = true, max = 1024 },
            agent = { required = true, max = 32 }, prompt = { type = "text", max = T.MAX_PROMPT },
        })
        if not d then U.invalid(errors) end
        local term = T.find(ns, d.terminal_uuid)
        if not term or not term.is_active then U.fail(404, "Web terminal not found") end
        local path = U.path(d.path)
        if not path or path:find("[%c]") then
            U.invalid({ path = "must be a full folder path, like /Users/you/projects/app" })
        end
        local agent
        for _, a in ipairs(T.agents(term)) do if a.id == d.agent then agent = a end end
        if not agent then U.invalid({ agent = "isn't one of this terminal's agents" }) end
        local prompt = type(d.prompt) == "string" and d.prompt ~= "" and U.clean(d.prompt) or T.prompt(ns, task)
        prompt = T.with_folder(prompt, path)
        if #prompt > T.MAX_PROMPT then U.invalid({ prompt = "is too long (at most " .. T.MAX_PROMPT .. " bytes)" }) end
        local me = U.one("SELECT " .. R.name_sql("u") .. " AS name FROM users u WHERE u.uuid = ?", sdk.user(self).uuid)
        local row, launch_url = T.launch(ns, task, sdk.user(self).uuid, {
            terminal = term, path = path, agent = agent, prompt = prompt, by = me and me.name or nil,
            ws = self.namespace and self.namespace.name or nil,
        })
        return sdk.created({ session = T.session_view(T.session(ns, row.uuid)), launch_url = launch_url })
    end))
    app:post("/tasks/:task_uuid/terminal-sessions", launch)

    app:get("/tasks/:task_uuid/terminal-sessions", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not R.task(ns, self.params.task_uuid) then U.fail(404, "Task not found") end
        local out = {}
        for i, s in ipairs(T.list_for_task(ns, self.params.task_uuid)) do out[i] = T.session_view(s) end
        return sdk.ok(U.array(out))
    end)))

    app:post("/public/terminal/webhook", sdk.handler({ namespace = false }, U.guard(function()
        ngx.req.read_body()
        local sig = ngx.req.get_headers()["x-opsapi-signature"]
        if type(sig) == "table" then sig = sig[1] end
        local view, status, message = T.webhook(ngx.req.get_body_data() or "", sig)
        if not view then return sdk.error(status, message) end
        return sdk.ok(view)
    end)))
end
