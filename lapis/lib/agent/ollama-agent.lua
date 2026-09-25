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
local jwt = require("resty.jwt")

-- Private cjson instance. Several opsapi modules call
-- cjson.encode_empty_table_as_object(false) on the SHARED instance (global
-- per-worker state), which would re-encode a no-argument tool call's
-- `arguments: {}` as `[]` and make Ollama reject the request as malformed.
-- A fresh instance keeps the agent's encoding independent of load order.
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)

local Agent = {}

local OLLAMA_URL = os.getenv("OLLAMA_URL") or "https://ollama.workstation.co.uk"
local OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or "qwen3.8:latest"
local OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY")

-- The gateway authenticates with a JWT in the x-api-key header. OLLAMA_API_KEY
-- may be set to EITHER a ready-made token (header.payload.signature) OR the
-- signing secret — in which case we mint a short-lived HS256 token from it per
-- request. This lets operators drop just the secret in the env.
local function resolve_api_key()
    local key = OLLAMA_API_KEY
    if not key or key == "" then
        return nil
    end
    local _, dots = key:gsub("%.", "")
    if dots == 2 and key:sub(1, 2) == "ey" then
        return key -- already a JWT
    end
    local now = ngx.time()
    local ok, token = pcall(function()
        return jwt:sign(key, {
            header = { typ = "JWT", alg = "HS256" },
            payload = { sub = "opsapi-agent", name = "OpsAPI Agent", admin = true, iat = now, exp = now + 300 },
        })
    end)
    if ok and token then
        return token
    end
    return key -- fall back to sending it raw
end

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
    local api_key = resolve_api_key()
    if api_key then
        headers["x-api-key"] = api_key
    end

    local encoded, enc_err = cjson.encode(body)
    if not encoded then
        return nil, "Could not encode the Ollama request: " .. tostring(enc_err)
    end

    local res, req_err = httpc:request_uri(OLLAMA_URL .. "/api/chat", {
        method = "POST",
        body = encoded,
        headers = headers,
        -- ponytail: TLS verify off to match lib/llm-client; turn on with a
        -- trusted CA bundle in prod (lua_ssl_trusted_certificate is set there).
        ssl_verify = false,
    })

    if not res then
        return nil, "Ollama request failed: " .. tostring(req_err)
    end
    if res.status >= 400 then
        -- Diagnostics only on failure: what we actually sent (bounded).
        ngx.log(ngx.ERR, "[ollama-agent] rejected request (", #encoded, " bytes) tail: ",
            encoded:sub(-600))
        return nil, "Ollama HTTP " .. res.status .. ": " .. tostring(res.body)
    end

    local data = cjson.decode(res.body)
    if not data or not data.message then
        return nil, "Ollama: unexpected response"
    end
    return data.message
end

-- Does a reply claim it performed a write ("Done — created …", "has been added")?
-- ponytail: keyword heuristic; a false positive only costs one extra model call.
local CLAIM_PATTERNS = {
    "^%s*done", "has been %a+ed", "have been %a+ed", "successfully", "i've created", "i have created",
    "i've added", "i've logged", "i've sent", "i've invited", "i've updated", "is now created",
}
function Agent.claims_action(text)
    local t = (text or ""):lower()
    for _, p in ipairs(CLAIM_PATTERNS) do
        if t:find(p) then return true end
    end
    return false
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
    local nudged = false

    for _ = 1, MAX_ITERATIONS do
        local msg, err = call_ollama(messages, opts.tools)
        if not msg then
            return nil, err
        end

        -- Keep the assistant turn (with any tool_calls) in history.
        messages[#messages + 1] = msg

        local tool_calls = msg.tool_calls
        if not tool_calls or #tool_calls == 0 then
            local reply = msg.content or ""
            -- Hallucination guard: the model sometimes answers "Done — created X"
            -- without calling any tool (seen live: fake customer + fake INV-0004).
            -- Push back once so it actually calls the tool; if it still claims
            -- success with nothing executed, say so honestly instead.
            if #actions == 0 and Agent.claims_action(reply) then
                if not nudged then
                    nudged = true
                    messages[#messages + 1] = {
                        role = "system",
                        content = "You did NOT call any tool in this turn, so nothing was created or changed. "
                            .. "If the user asked you to do something, call the appropriate tool now "
                            .. "(or ask_user for a missing detail). Do not claim it is done.",
                    }
                    goto continue
                end
                return {
                    reply = "I wasn't able to complete that — no records were created or changed. "
                        .. "Please try again, and include any details (name, email, amount) in one message.",
                    actions = actions,
                }
            end
            return { reply = reply, actions = actions }
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
        ::continue::
    end

    return {
        reply = "I couldn't complete that within a few steps — could you break it into a smaller request or add more detail?",
        actions = actions,
    }
end

return Agent
