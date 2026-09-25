--[[
    Ollama tool-calling agent loop
    ==============================

    Drives a multi-step "agent" conversation against an Ollama model that
    supports tool calling (e.g. qwen3): send the conversation + a set of tool
    definitions, and if the model responds with tool_calls, execute them, feed
    the results back as `role:"tool"` messages, and loop until the model returns
    a plain text answer (or the iteration cap is hit).

    Tool-agnostic: the caller supplies the tool *definitions* (JSON-schema) and
    an `execute(name, args)` function. This module knows nothing about opsapi's
    domain — see lib/agent/tools.lua for the actual opsapi tools and their RBAC.

    Endpoint: OLLAMA_URL/api/chat, auth via `x-api-key: OLLAMA_API_KEY` (the
    workstation Ollama gateway). Model from OLLAMA_MODEL.
]]

local http = require("resty.http")
local cjson = require("cjson.safe")

local Agent = {}

local OLLAMA_URL = os.getenv("OLLAMA_URL") or "https://ollama.workstation.co.uk"
local OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or "qwen3.8:latest"
local OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY")

-- Bounds the tool-call loop so a confused model can't spin forever. Each
-- iteration is one model round-trip (~seconds on the local model).
local MAX_ITERATIONS = 6
local REQUEST_TIMEOUT_MS = 120000

-- One round-trip to Ollama /api/chat. Returns the assistant `message` table.
local function call_ollama(messages, tools)
    local httpc, new_err = http.new()
    if not httpc then
        return nil, "http client: " .. tostring(new_err)
    end
    httpc:set_timeout(REQUEST_TIMEOUT_MS)

    local body = {
        model = OLLAMA_MODEL,
        messages = messages,
        stream = false,
        think = false,
        options = { temperature = 0.2 },
    }
    if tools and #tools > 0 then
        body.tools = tools
    end

    local headers = { ["Content-Type"] = "application/json" }
    if OLLAMA_API_KEY and OLLAMA_API_KEY ~= "" then
        headers["x-api-key"] = OLLAMA_API_KEY
    end

    local res, req_err = httpc:request_uri(OLLAMA_URL .. "/api/chat", {
        method = "POST",
        body = cjson.encode(body),
        headers = headers,
        -- ponytail: TLS verify off to match lib/llm-client; turn on with a
        -- trusted CA bundle in prod (lua_ssl_trusted_certificate is set there).
        ssl_verify = false,
    })

    if not res then
        return nil, "Ollama request failed: " .. tostring(req_err)
    end
    if res.status >= 400 then
        return nil, "Ollama HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local data = cjson.decode(res.body)
    if not data or not data.message then
        return nil, "Ollama: unexpected response"
    end
    return data.message
end

--- Run the agent loop.
-- @param opts.system   string  system prompt
-- @param opts.messages table   prior conversation [{role="user"|"assistant", content=...}]
-- @param opts.tools    table   tool definitions (Ollama function schema)
-- @param opts.execute  function(name, args) -> (result_table|nil, err_string|nil)
-- @return { reply=string, actions={ {name,args,result,error}, ... } } | nil, err
function Agent.run(opts)
    local messages = {}
    if opts.system then
        messages[#messages + 1] = { role = "system", content = opts.system }
    end
    for _, m in ipairs(opts.messages or {}) do
        if m.role and m.content ~= nil then
            messages[#messages + 1] = { role = m.role, content = tostring(m.content) }
        end
    end

    local actions = {}

    for _ = 1, MAX_ITERATIONS do
        local msg, err = call_ollama(messages, opts.tools)
        if not msg then
            return nil, err
        end

        -- Keep the assistant turn (with any tool_calls) in history.
        messages[#messages + 1] = msg

        local tool_calls = msg.tool_calls
        if not tool_calls or #tool_calls == 0 then
            return { reply = msg.content or "", actions = actions }
        end

        -- Execute each requested tool, appending its result as a tool message.
        for _, tc in ipairs(tool_calls) do
            local fn = tc["function"] or {}
            local name = fn.name or ""
            local args = fn.arguments or {}
            if type(args) == "string" then
                args = cjson.decode(args) or {}
            end

            -- The model asks for missing info by calling an ask-style tool
            -- (qwen sometimes invents "ask_followup"). Treat any of these as the
            -- agent asking the user: return the question and end the turn.
            if name == "ask_user" or name == "ask_followup"
                or name == "ask_clarification" or name == "ask_question" then
                local question = args.question or args.message or args.text or msg.content or ""
                return { reply = question, actions = actions }
            end

            local result, terr = opts.execute(name, args)
            actions[#actions + 1] = {
                name = name,
                args = args,
                result = (not terr) and result or nil,
                error = terr,
            }

            local payload = terr and { ok = false, error = terr } or { ok = true, result = result }
            messages[#messages + 1] = {
                role = "tool",
                tool_name = name,
                content = cjson.encode(payload) or "{}",
            }
        end
    end

    return {
        reply = "I couldn't complete that within a few steps — could you break it into a smaller request or add more detail?",
        actions = actions,
    }
end

return Agent
