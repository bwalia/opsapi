--[[
    Chat AI agent route
    ===================

    The conversation lives server-side (chat_agent_runs) and each turn runs in
    the BACKGROUND (ngx.timer), so it keeps going if the user reloads, changes
    page or closes the tab. When it finishes, "agent:done" is pushed over the
    chat WebSocket (lib/chat-ws) to every tab of that user.

      GET    /api/chat/agent/conversation  latest conversation + run status
      POST   /api/chat/agent               {message} -> 202, starts a run
      DELETE /api/chat/agent/conversation  "New chat" (archives the old one)

    Each run: tool-calling loop (lib/agent/ollama-agent) against the workspace
    Ollama model, executing opsapi actions (lib/agent/tools) WITH the user's
    namespace + RBAC (captured from the request that started the run).

    Auth + namespace: wrapped in requireAuth + requireNamespace so the tools run
    with a real tenant context and the caller's permissions.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local Global = require("helper.global")
local ChatWS = require("lib.chat-ws")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local Agent = require("lib.agent.ollama-agent")
local Tools = require("lib.agent.tools")

return function(app)
    local function parse_json_body()
        local ok, result = pcall(function()
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cjson.decode(body)
        end)
        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    -- Marker for the reference-data system notes; also stripped from any reply
    -- that echoes it (belt and braces against the model imitating it).
    local DATA_MARKER = "[Reference data]"

    local function strip_marker(text)
        local i = text:find(DATA_MARKER, 1, true) or text:find("[Data from the actions above", 1, true)
        if i then
            text = text:sub(1, i - 1)
        end
        return (text:gsub("%s+$", ""))
    end

    local function display_name(user)
        local first = user.first_name
        local last = user.last_name
        if first and first ~= "" then
            return last and last ~= "" and (first .. " " .. last) or first
        end
        return user.username or user.email or "there"
    end

    local function build_system_prompt(user, ns)
        return table.concat({
            "You are OpsAPI Assistant, an AI agent embedded in the OpsAPI business platform.",
            "You help the user get real work done by CALLING the provided tools — creating and looking up "
                .. "records across their workspace (customers, team members, timesheets, CRM accounts and "
                .. "leads, projects and tasks, and more). Everything is scoped to the user's current "
                .. "workspace and their permissions; you can only do what the tools allow.",
            "",
            "How to act:",
            "- You can ONLY create or change data by CALLING a tool. Never say something was created, "
                .. "updated, logged or sent unless a tool call in THIS turn returned success. If you didn't "
                .. "call the tool, you didn't do it — call it now instead of claiming it.",
            "- When you have what you need, CALL the appropriate tool to actually perform the action — "
                .. "don't just describe what you would do.",
            "- If a required detail is missing (e.g. the hours for a timesheet, or which customer), call "
                .. "ask_user with ONE clear, specific question. Never guess or invent names, emails, ids, "
                .. "amounts or dates.",
            "- Before creating something that might already exist, or when the user refers to a record by "
                .. "name, use a list/find tool first to look it up, then act on the right one.",
            "- You may chain several tools to complete a task (e.g. find a task, then log a timesheet on it).",
            "- After acting, confirm what you did in one short sentence. When you LIST records, format them "
                .. "as a compact markdown list or table so they're easy to read.",
            "- If a tool returns an error (e.g. permission denied), say so plainly and, when relevant, "
                .. "suggest the user ask a workspace admin for access.",
            "- Be concise, friendly, and professional. Use markdown for structure.",
            "",
            "Context:",
            "- User: " .. display_name(user),
            "- Workspace: " .. (ns.name or "current workspace"),
            "- Today's date (UTC): " .. os.date("!%Y-%m-%d"),
        }, "\n")
    end

    -- A run still "running" after this long died with its worker (restart /
    -- deploy) — report it as failed rather than spinning forever.
    local STALE_SECONDS = 600
    local MAX_STORED_TURNS = 40
    local MAX_MODEL_TURNS = 20

    -- Keep only role/content/(trimmed) actions — never trust extra fields.
    local function clean_turn(m)
        if type(m) ~= "table" or (m.role ~= "user" and m.role ~= "assistant") or m.content == nil then
            return nil
        end
        local t = { role = m.role, content = strip_marker(tostring(m.content)) }
        if m.role == "assistant" and type(m.actions) == "table" and #m.actions > 0 then
            t.actions = {}
            for _, a in ipairs(m.actions) do
                if type(a) == "table" and a.name then
                    t.actions[#t.actions + 1] = { name = a.name, result = a.result, error = a.error }
                end
            end
        end
        return t
    end

    -- Stored turns -> model messages. The DATA earlier tools returned (uuids
    -- etc.) goes in a separate SYSTEM note, never inside the assistant's own
    -- words: when it lived there the model learned to imitate it and "report"
    -- actions it never actually performed.
    local function to_model_conversation(turns)
        local conversation = {}
        for i = math.max(1, #turns - MAX_MODEL_TURNS + 1), #turns do
            local m = turns[i]
            conversation[#conversation + 1] = { role = m.role, content = m.content }
            if m.actions then
                local summary = {}
                for _, act in ipairs(m.actions) do
                    if act.name ~= "ask_user" then
                        summary[#summary + 1] = { tool = act.name, result = act.result, error = act.error }
                    end
                end
                if #summary > 0 then
                    local encoded = cjson.encode(summary) or ""
                    if #encoded > 2000 then encoded = encoded:sub(1, 2000) .. "..." end
                    conversation[#conversation + 1] = {
                        role = "system",
                        content = DATA_MARKER .. " (records returned by tools in the previous turn — "
                            .. "use their uuids when acting on them; this is NOT a reply format and "
                            .. "does not mean anything new was done): " .. encoded,
                    }
                end
            end
        end
        return conversation
    end

    local function decode(v)
        if type(v) == "table" then return v end
        return (type(v) == "string" and cjson.decode(v)) or {}
    end

    local function latest_run(user_uuid, namespace_id)
        local rows = db.query([[
            SELECT uuid, status, turns, reply, actions,
                   EXTRACT(EPOCH FROM (NOW() - updated_at)) AS age
            FROM chat_agent_runs
            WHERE user_uuid = ? AND namespace_id = ? AND NOT archived
            ORDER BY id DESC LIMIT 1
        ]], user_uuid, namespace_id)
        local r = rows and rows[1]
        if not r then return nil end
        r.turns = decode(r.turns)
        r.actions = decode(r.actions)
        if r.status == "running" and tonumber(r.age or 0) > STALE_SECONDS then
            r.status = "error"
            r.reply = "The assistant was interrupted before finishing. Please try again."
        end
        return r
    end

    -- Full conversation for display / the next turn: inputs + the run's reply.
    local function full_turns(run)
        if not run then return {} end
        local turns = {}
        for _, t in ipairs(run.turns) do turns[#turns + 1] = t end
        if run.status ~= "running" and run.reply then
            turns[#turns + 1] = clean_turn({ role = "assistant", content = run.reply, actions = run.actions })
        end
        return turns
    end

    -- Background worker (ngx.timer): runs the agent, stores the outcome, and
    -- pushes "agent:done" to the user's open tabs.
    local function run_in_background(premature, job)
        if premature then return end
        local ok, result, err = pcall(Agent.run, {
            system = job.system,
            messages = job.conversation,
            tools = Tools.definitions(),
            execute = function(name, args)
                local res, terr = Tools.execute(job.ctx, name, args)
                -- Audit trail: every action the agent takes, who for, and outcome.
                ngx.log(ngx.INFO, "[chat-agent] tool=", name, " user=", job.ctx.user_uuid,
                    " ns=", tostring(job.ctx.namespace_id), " ok=", tostring(terr == nil),
                    terr and (" err=" .. tostring(terr)) or "")
                return res, terr
            end,
        })
        if not ok then err, result = result, nil end

        local status, reply, actions = "done", nil, {}
        if result then
            reply = strip_marker(result.reply or "")
            actions = result.actions or {}
        else
            ngx.log(ngx.ERR, "[chat-agent] run ", job.run_uuid, ": ", tostring(err))
            status = "error"
            reply = "Sorry — the assistant is unavailable right now. Please try again."
        end

        db.update("chat_agent_runs", {
            status = status,
            reply = reply,
            actions = db.raw(db.escape_literal(cjson.encode(actions) or "[]") .. "::jsonb"),
            updated_at = db.raw("NOW()"),
        }, { uuid = job.run_uuid })

        ChatWS.push_user(job.ctx.user_uuid, "agent:done", {
            run_uuid = job.run_uuid,
            namespace_id = job.ctx.namespace_id,
            status = status,
            reply = reply,
        })
    end

    local function require_user(self)
        local user = self.current_user
        if not user or not user.uuid then return nil end
        return user
    end

    app:get(
        "/api/chat/agent/conversation",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local user = require_user(self)
            if not user then return { status = 401, json = { error = "Unauthorized" } } end
            local run = latest_run(user.uuid, self.namespace.id)
            return {
                status = 200,
                json = {
                    run_uuid = run and run.uuid or nil,
                    status = run and run.status or "idle",
                    turns = full_turns(run),
                },
            }
        end))
    )

    app:delete(
        "/api/chat/agent/conversation",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local user = require_user(self)
            if not user then return { status = 401, json = { error = "Unauthorized" } } end
            -- A running turn keeps going and still saves; it just won't be shown.
            db.query("UPDATE chat_agent_runs SET archived = TRUE WHERE user_uuid = ? AND namespace_id = ?",
                user.uuid, self.namespace.id)
            return { status = 200, json = { success = true } }
        end))
    )

    app:post(
        "/api/chat/agent",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local user = require_user(self)
            if not user then return { status = 401, json = { error = "Unauthorized" } } end

            local data = parse_json_body()
            local text = type(data.message) == "string" and data.message:gsub("^%s+", ""):gsub("%s+$", "") or ""
            if text == "" then
                return { status = 400, json = { error = "message is required" } }
            end
            if #text > 4000 then
                return { status = 400, json = { error = "message is too long (max 4000 characters)" } }
            end

            local ns = self.namespace or {}
            local prev = latest_run(user.uuid, ns.id)
            if prev and prev.status == "running" then
                return { status = 409, json = { error = "The assistant is still working on your last request." } }
            end

            local turns = full_turns(prev)
            turns[#turns + 1] = { role = "user", content = text }
            while #turns > MAX_STORED_TURNS do table.remove(turns, 1) end

            local run_uuid = Global.generateUUID()
            db.insert("chat_agent_runs", {
                uuid = run_uuid,
                namespace_id = ns.id,
                user_uuid = user.uuid,
                status = "running",
                turns = db.raw(db.escape_literal(cjson.encode(turns)) .. "::jsonb"),
            })

            -- The request's auth/RBAC context is captured here; the timer runs
            -- after this response is sent, independent of the browser.
            local ctx = {
                namespace_id = ns.id,
                namespace = ns,
                user_uuid = user.uuid,
                has_permission = function(module, action)
                    return NamespaceMiddleware.hasPermission(self, module, action)
                end,
            }
            local ok, terr = ngx.timer.at(0, run_in_background, {
                run_uuid = run_uuid,
                ctx = ctx,
                system = build_system_prompt(user, ns),
                conversation = to_model_conversation(turns),
            })
            if not ok then
                ngx.log(ngx.ERR, "[chat-agent] could not start run: ", tostring(terr))
                db.update("chat_agent_runs", { status = "error", reply = "Could not start the assistant." },
                    { uuid = run_uuid })
                return { status = 503, json = { error = "The assistant is busy right now. Please try again." } }
            end

            return { status = 202, json = { run_uuid = run_uuid, status = "running", turns = turns } }
        end))
    )
end
