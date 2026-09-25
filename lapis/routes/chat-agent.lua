--[[
    Chat AI agent route
    ===================

    POST /api/chat/agent — the "chat with agent" endpoint. The user sends the
    conversation so far ({messages:[{role,content}]}); the backend runs a
    tool-calling agent loop (lib/agent/ollama-agent) against the workspace Ollama
    model, executing opsapi actions (lib/agent/tools) WITH the user's namespace +
    RBAC, and returns the agent's reply plus the actions it took.

    Auth + namespace: wrapped in requireAuth + requireNamespace so the tools run
    with a real tenant context and the caller's permissions.
]]

local cjson = require("cjson")
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

    app:post(
        "/api/chat/agent",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local user = self.current_user
            if not user or not user.uuid then
                return { status = 401, json = { error = "Unauthorized" } }
            end

            local data = parse_json_body()
            local raw = data.messages
            if type(raw) ~= "table" or #raw == 0 then
                return { status = 400, json = { error = "messages array is required" } }
            end

            -- Only trust role + content (+ prior actions, folded in as context);
            -- drop anything else the client sends. Keep the most recent turns
            -- only, so long chats don't grow the prompt without bound.
            local MAX_TURNS = 20
            local start = math.max(1, #raw - MAX_TURNS + 1)
            local conversation = {}
            for i = start, #raw do
                local m = raw[i]
                if (m.role == "user" or m.role == "assistant") and m.content ~= nil then
                    conversation[#conversation + 1] = { role = m.role, content = strip_marker(tostring(m.content)) }
                    -- The model only sees text, so give it the DATA its earlier
                    -- tools returned (uuids etc.) — otherwise "log time on that
                    -- task" loses the task it just listed. This goes in a
                    -- separate SYSTEM note, never inside the assistant's own
                    -- words: when it lived there the model learned to imitate it
                    -- and "report" actions it never actually performed.
                    if m.role == "assistant" and type(m.actions) == "table" and #m.actions > 0 then
                        local summary = {}
                        for _, act in ipairs(m.actions) do
                            if type(act) == "table" and act.name and act.name ~= "ask_user" then
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
            end
            if #conversation == 0 then
                return { status = 400, json = { error = "No user/assistant messages provided" } }
            end

            local ns = self.namespace or {}
            local ctx = {
                namespace_id = ns.id,
                namespace = ns,
                user_uuid = user.uuid,
                has_permission = function(module, action)
                    return NamespaceMiddleware.hasPermission(self, module, action)
                end,
            }

            local result, err = Agent.run({
                system = build_system_prompt(user, ns),
                messages = conversation,
                tools = Tools.definitions(),
                execute = function(name, args)
                    local res, terr = Tools.execute(ctx, name, args)
                    -- Audit trail: every action the agent takes, who for, and outcome.
                    ngx.log(ngx.INFO, "[chat-agent] tool=", name, " user=", user.uuid,
                        " ns=", tostring(ns.id), " ok=", tostring(terr == nil),
                        terr and (" err=" .. tostring(terr)) or "")
                    return res, terr
                end,
            })

            if not result then
                ngx.log(ngx.ERR, "[chat-agent] ", tostring(err))
                return {
                    status = 502,
                    json = { error = "The assistant is unavailable right now. Please try again." },
                }
            end

            return {
                status = 200,
                json = { reply = strip_marker(result.reply or ""), actions = result.actions },
            }
        end))
    )
end
