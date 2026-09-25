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
            "You help the user get things done by CALLING the provided tools — you can create and list "
                .. "customers, add team members, and log timesheets, all scoped to the user's current "
                .. "workspace and their permissions.",
            "",
            "Rules:",
            "- When you have enough information, CALL the appropriate tool to actually perform the action. "
                .. "Do not merely describe what you would do.",
            "- If a required detail is missing (for example the hours for a timesheet, or a customer's name), "
                .. "call ask_user with one clear, specific question instead of guessing or inventing values.",
            "- After a tool runs, confirm the result briefly in plain language.",
            "- If a tool returns an error (for example a permission denial), tell the user plainly and, if "
                .. "relevant, suggest asking a workspace admin.",
            "- Keep replies concise and friendly.",
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

            -- Only trust role + content; drop anything else the client sends.
            local conversation = {}
            for _, m in ipairs(raw) do
                if (m.role == "user" or m.role == "assistant") and m.content ~= nil then
                    conversation[#conversation + 1] = { role = m.role, content = tostring(m.content) }
                end
            end
            if #conversation == 0 then
                return { status = 400, json = { error = "No user/assistant messages provided" } }
            end

            local ns = self.namespace or {}
            local ctx = {
                namespace_id = ns.id,
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
                    return Tools.execute(ctx, name, args)
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
                json = { reply = result.reply, actions = result.actions },
            }
        end))
    )
end
