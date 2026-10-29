-- Web terminals (docs/AI_RUNNER_WEB_TERMINAL.md).
--   GET    /terminals                       ai_runners.manage: this workspace's terminals (never their secrets),
--                                           each with its connection status (§12)
--   POST   /terminals { name, url, agents?, autologin? }   ai_runners.manage -> 201 { terminal, secret } (once)
--   PUT    /terminals/:uuid { name?, url?, agents?, is_active?, autologin? }   ai_runners.manage
--   POST   /terminals/:uuid/rotate-secret   ai_runners.manage -> { terminal, secret }; old links and webhooks stop
--   DELETE /terminals/:uuid                 ai_runners.manage (its sessions stay on their tasks)
--   POST   /tasks/:task_uuid/terminal-sessions { terminal_uuid, path, agent, prompt?, autologin? }
--                                           ai_runs.create + who may start AI work on the task -> 201
--                                           { session, launch_url }; an unattended agent (id *_auto or
--                                           unattended = true) needs ai_runs.manage, else 403
--   GET    /tasks/:task_uuid/terminal-sessions   ai_runs.read
--   POST   /public/terminal/webhook         signed by the terminal (X-Opsapi-Signature: sha256=<hex>)
--   GET    /terminal-autologin              ai_runs.read: may I be signed in automatically, and my step-up (§8)
--   POST   /terminal-autologin/code         ai_terminal_autologin.create or a live key: email me a code
--   POST   /terminal-autologin/verify { code }   same -> the step-up (12 h)
--   DELETE /terminal-autologin              forget my step-up
--   POST   /public/terminal/report { pr_url?, note? }   Authorization: Bearer <the launch's report token> (§9)
--   GET    /terminals/:uuid/keys            ai_runners.manage: { keys, people } (§10)
--   POST   /terminals/:uuid/keys { user_uuid, public_key }   ai_runners.manage -> 201 key (blocks their old one)
--   POST   /terminals/:uuid/keys/:key_uuid/block   ai_runners.manage
--   GET    /public/terminal/keys            the terminal fetches its live keys (signed request, signed answer)
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

-- §8 + §10: power users (the permission) and anyone a manager issued a live key (on that terminal, when given).
local function may_autologin(self, terminal_id)
    return sdk.can(self, T.AUTOLOGIN_PERMISSION[1], T.AUTOLOGIN_PERMISSION[2])
        or T.live_key(sdk.namespace_id(self), sdk.user(self).uuid, terminal_id) ~= nil
end

local function stepup_view(st)
    if not st then return cjson.null end
    return { verified_at = tonumber(st.verified_at), expires_at = tonumber(st.expires_at) }
end

local function url_of(v)
    local u = R.secure_base_url(v)
    if not u then
        U.invalid({ url = "must be the terminal's https address, like https://dev.example.com (http only on this "
            .. "machine: localhost or 127.0.0.1)" })
    end
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
            autologin = { type = "boolean" },
        })
        if not d then U.invalid(errors) end
        local plain, sealed, hint = T.new_secret()
        local row = db.insert("ar_terminals", {
            namespace_id = ns, name = U.clean(d.name), url = url_of(d.url), secret_sealed = sealed, secret_hint = hint,
            agents = cjson.encode(T.agents_of(b.agents) or T.DEFAULT_AGENTS), autologin = d.autologin == true,
            created_by = sdk.user(self).uuid,
        }, { returning = "*" })[1]
        return sdk.created({ terminal = T.view(row), secret = plain })
    end)))

    app:put("/terminals/:uuid", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local t = terminal_or_404(ns, self.params.uuid)
        local b = body(self)
        local d, errors = sdk.validate(b, {
            name = { max = 100 }, url = { max = 255 }, is_active = { type = "boolean" },
            autologin = { type = "boolean" },
        }, true)
        if not d or d.name == db.NULL or d.name == "" then U.invalid(errors or { name = "is required" }) end
        local agents = T.agents_of(b.agents)
        local active = t.is_active
        if type(d.is_active) == "boolean" then active = d.is_active end
        local autologin = t.autologin == true
        if type(d.autologin) == "boolean" then autologin = d.autologin end
        db.query([[UPDATE ar_terminals SET name = ?, url = ?, agents = COALESCE(?::jsonb, agents), is_active = ?,
            autologin = ?, updated_at = NOW() WHERE id = ?]],
            d.name and U.clean(d.name) or t.name, d.url and url_of(d.url) or t.url,
            agents and cjson.encode(agents) or db.NULL, active, autologin, t.id)
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

    -- §10: keys managers issue to people for a terminal.
    -- Anyone in the workspace: the terminals they hold a key for (their own "how to sign in" card).
    app:get("/my-terminals", sdk.handler({}, U.guard(function(self)
        return sdk.ok(T.mine(sdk.namespace_id(self), sdk.user(self).uuid))
    end)))

    app:get("/terminals/:uuid/keys", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        return sdk.ok({ keys = T.keys(ns, terminal_or_404(ns, self.params.uuid)), people = T.key_candidates(ns) })
    end)))

    app:post("/terminals/:uuid/keys", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local t = terminal_or_404(ns, self.params.uuid)
        local d, errors = sdk.validate(body(self), {
            user_uuid = { required = true, type = "uuid" }, public_key = { required = true, max = 1000 },
        })
        if not d then U.invalid(errors) end
        local row, status, message = T.issue_key(ns, t, d.user_uuid, d.public_key, sdk.user(self).uuid)
        if not row then return sdk.error(status, message) end
        for _, k in ipairs(T.keys(ns, t)) do
            if k.uuid == row.uuid then return sdk.created(k) end
        end
    end)))

    app:post("/terminals/:uuid/keys/:key_uuid/block", sdk.handler({ permission = "ai_runners.manage" },
        U.guard(function(self)
            local ns = sdk.namespace_id(self)
            local t = terminal_or_404(ns, self.params.uuid)
            if not T.block_key(ns, t, self.params.key_uuid, sdk.user(self).uuid) then
                U.fail(404, "No live key with that id on this terminal")
            end
            return sdk.ok({ blocked = true })
        end)))

    app:get("/public/terminal/keys", sdk.handler({ namespace = false }, U.guard(function()
        local h = ngx.req.get_headers()
        local function one(v) return type(v) == "table" and v[1] or v end
        local out, sig_or_status, message = T.keys_for_terminal(one(h["x-opsapi-terminal"]),
            one(h["x-opsapi-timestamp"]), one(h["x-opsapi-signature"]))
        if not out then return sdk.error(sig_or_status, message) end
        -- The exact bytes signed: the terminal checks X-Opsapi-Signature before trusting a single key.
        return { status = 200, layout = false, out, headers = { ["Content-Type"] = "application/json",
            ["Cache-Control"] = "no-store", ["X-Opsapi-Signature"] = "sha256=" .. sig_or_status } }
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
            autologin = { type = "boolean" },
        })
        if not d then U.invalid(errors) end
        local term = T.find(ns, d.terminal_uuid)
        if not term or not term.is_active then U.fail(404, "Web terminal not found") end
        -- Connected before addresses had to be https: the link would carry the ticket in clear.
        if not R.secure_base_url(term.url) then
            U.fail(409, "This web terminal's address doesn't start with https://, so it can't be opened from a task. "
                .. "Ask an AI runners manager to change it under Machines → Web terminals.")
        end
        local path = U.path(d.path)
        if not path or path:find("[%c]") then
            U.invalid({ path = "must be a full folder path, like /Users/you/projects/app" })
        end
        local agent
        for _, a in ipairs(T.agents(term)) do if a.id == d.agent then agent = a end end
        if not agent then U.invalid({ agent = "isn't one of this terminal's agents" }) end
        if T.is_unattended(agent) and not sdk.can(self, "ai_runs", "manage") then
            return sdk.error(403, agent.label .. " works without stopping to ask before it changes things, so only an "
                .. "AI runs manager can start it. Pick another agent.")
        end
        local prompt = type(d.prompt) == "string" and d.prompt ~= "" and U.clean(d.prompt) or T.prompt(ns, task)
        prompt = T.safe_prompt(T.with_folder(prompt, path))
        if #prompt > T.MAX_PROMPT then U.invalid({ prompt = "is too long (at most " .. T.MAX_PROMPT .. " bytes)" }) end
        local me = U.one("SELECT " .. R.name_sql("u") .. " AS name, u.email FROM users u WHERE u.uuid = ?",
            sdk.user(self).uuid)
        -- §8: signed in by the link only for power users, on a terminal that allows it, after a recent step-up.
        local login
        if d.autologin == true then
            if not may_autologin(self, term.id) then
                return sdk.error(403, "You can't be signed in to this web terminal automatically")
            end
            if not term.autologin then U.fail(409, "This terminal doesn't allow automatic sign-in") end
            local st = T.stepup(ns, sdk.user(self).uuid)
            if not st then
                U.fail(403, "Confirm the code we email you first", { code = "stepup_required" })
            end
            if not me or type(me.email) ~= "string" or me.email == "" then
                U.fail(422, "Your account has no email address")
            end
            login = { email = me.email:lower(), stepup = tonumber(st.verified_at) }
        end
        local row, launch_url = T.launch(ns, task, sdk.user(self).uuid, {
            terminal = term, path = path, agent = agent, prompt = prompt, by = me and me.name or nil,
            ws = self.namespace and self.namespace.name or nil, login = login, report_url = T.report_url(),
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

    app:get("/terminal-autologin", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        local allowed = may_autologin(self)
        return sdk.ok({ allowed = allowed,
            stepup = allowed and stepup_view(T.stepup(sdk.namespace_id(self), sdk.user(self).uuid)) or cjson.null })
    end)))

    app:post("/terminal-autologin/code", sdk.handler({ permission = "ai_runs.read" },
        U.guard(function(self)
            if not may_autologin(self) then return sdk.error(403, "Permission denied") end
            local ok, status, message = T.send_stepup_code(sdk.user(self).uuid)
            if not ok then return sdk.error(status, message) end
            return sdk.ok({ sent = true })
        end)))

    app:post("/terminal-autologin/verify", sdk.handler({ permission = "ai_runs.read" },
        U.guard(function(self)
            if not may_autologin(self) then return sdk.error(403, "Permission denied") end
            local d, errors = sdk.validate(body(self), { code = { required = true, max = 12 } })
            if not d then U.invalid(errors) end
            local st, status, message = T.verify_stepup(sdk.namespace_id(self), sdk.user(self).uuid, d.code)
            if not st then return sdk.error(status, message) end
            return sdk.ok({ allowed = true, stepup = stepup_view(st) })
        end)))

    app:delete("/terminal-autologin", sdk.handler({ permission = "ai_runs.read" }, U.guard(function(self)
        T.forget_stepup(sdk.namespace_id(self), sdk.user(self).uuid)
        return sdk.ok({ allowed = may_autologin(self), stepup = cjson.null })
    end)))

    app:post("/public/terminal/report", sdk.handler({ namespace = false }, U.guard(function()
        local auth = ngx.req.get_headers()["authorization"]
        if type(auth) == "table" then auth = auth[1] end
        local token = type(auth) == "string" and auth:match("^[Bb]earer%s+(%S+)%s*$") or nil
        ngx.req.read_body()
        local out, status, message = T.report(token, require("cjson.safe").decode(ngx.req.get_body_data() or ""))
        if not out then return sdk.error(status, message) end
        return sdk.ok(out)
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
