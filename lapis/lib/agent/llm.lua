--[[
    LLM provider for the AI assistant — the model is chosen by env/secrets only
    ============================================================================

      AI_PROVIDER   ollama (default) | anthropic | openai
      AI_MODEL      model id. Defaults: ollama -> OLLAMA_MODEL or qwen3.8:latest,
                    anthropic -> claude-opus-5-5, openai -> gpt-4.1
      AI_API_KEY    API key. Falls back to OLLAMA_API_KEY / ANTHROPIC_API_KEY /
                    OPENAI_API_KEY for the chosen provider.
      AI_BASE_URL   endpoint. Falls back to OLLAMA_URL (ollama),
                    https://api.anthropic.com, https://api.openai.com/v1.
                    "openai" speaks the OpenAI Chat Completions protocol, so any
                    compatible server works: OpenAI, OpenRouter, Groq, Together,
                    Mistral, vLLM, LM Studio, Ollama's /v1 ...

    Switching to e.g. Claude in production = set AI_PROVIDER=anthropic,
    AI_MODEL=claude-opus-5-5 and AI_API_KEY in the secret, restart. No code.

    The agent loop speaks ONE message format and this module converts it to and
    from each provider's wire format:
      { role = "system" | "user" | "assistant" | "tool", content = "...",
        tool_calls = { { id, ["function"] = { name, arguments = {table} } } },  -- assistant
        tool_call_id, tool_name }                                              -- tool result
    Llm.chat(messages, tools, opts) -> assistant message | nil, err, http_status
    `tools` are OpenAI/Ollama-style function definitions.
]]

local http = require("resty.http")
local jwt = require("resty.jwt")

-- Private cjson instance: the shared one is set to encode {} as [] by other
-- modules, which providers reject for empty tool arguments / schemas.
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)

local Llm = {}

local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return nil
end

local PROVIDER = (env("AI_PROVIDER") or "ollama"):lower()
if PROVIDER == "claude" then PROVIDER = "anthropic" end

local DEFAULTS = {
    ollama = {
        model = env("OLLAMA_MODEL") or "qwen3.8:latest",
        key = env("OLLAMA_API_KEY"),
        url = env("OLLAMA_URL") or "https://ollama.workstation.co.uk",
    },
    anthropic = {
        model = "claude-opus-5-5",
        key = env("ANTHROPIC_API_KEY"),
        url = "https://api.anthropic.com",
    },
    openai = {
        model = "gpt-4.1",
        key = env("OPENAI_API_KEY"),
        url = "https://api.openai.com/v1",
    },
}
local D = DEFAULTS[PROVIDER] or DEFAULTS.ollama
if not DEFAULTS[PROVIDER] then PROVIDER = "ollama" end

Llm.provider = PROVIDER
Llm.model = env("AI_MODEL") or D.model
local API_KEY = env("AI_API_KEY") or D.key
local BASE_URL = (env("AI_BASE_URL") or D.url):gsub("/+$", "")

--- Is a model configured at all? (the footer shows "off" otherwise)
function Llm.configured()
    if PROVIDER == "ollama" then
        return env("AI_BASE_URL") ~= nil or env("OLLAMA_URL") ~= nil or API_KEY ~= nil
    end
    return API_KEY ~= nil
end

local function text_of(v)
    if v == nil or v == cjson.null then return "" end
    return tostring(v)
end

local function args_table(a)
    if type(a) == "table" then return a end
    if type(a) == "string" and a ~= "" then
        local t = cjson.decode(a)
        if type(t) == "table" then return t end
    end
    return {}
end

local function post(url, headers, body, timeout_ms)
    local encoded, enc_err = cjson.encode(body)
    if not encoded then return nil, "Could not encode the model request: " .. tostring(enc_err) end
    local httpc = http.new()
    httpc:set_timeout(timeout_ms or 120000)
    headers["Content-Type"] = "application/json"
    local res, err = httpc:request_uri(url, { method = "POST", body = encoded, headers = headers,
        -- ponytail: TLS verify off to match lib/llm-client; turn on with a
        -- trusted CA bundle in prod (lua_ssl_trusted_certificate is set there).
        ssl_verify = false })
    if not res then return nil, "Model request failed: " .. tostring(err) end
    local data = cjson.decode(res.body or "")
    if res.status >= 400 then
        local msg = type(data) == "table" and type(data.error) == "table" and data.error.message
            or type(data) == "table" and data.error or res.body
        ngx.log(ngx.ERR, "[llm] ", PROVIDER, " HTTP ", res.status, " (", #encoded, " bytes): ",
            tostring(msg):sub(1, 400))
        return nil, PROVIDER .. " HTTP " .. res.status .. ": " .. tostring(msg):sub(1, 400), res.status
    end
    if type(data) ~= "table" then return nil, PROVIDER .. ": unexpected response" end
    return data
end

-- ---------------------------------------------------------------------------
-- ollama: native /api/chat (same message shape as ours)
-- ---------------------------------------------------------------------------

-- The workstation gateway wants a JWT in x-api-key. The key may be a ready-made
-- token, or the signing secret — then mint a short-lived HS256 token from it.
local function ollama_key()
    if not API_KEY then return nil end
    local _, dots = API_KEY:gsub("%.", "")
    if dots == 2 and API_KEY:sub(1, 2) == "ey" then return API_KEY end
    local now = ngx.time()
    local ok, token = pcall(function()
        return jwt:sign(API_KEY, {
            header = { typ = "JWT", alg = "HS256" },
            payload = { sub = "opsapi-agent", name = "OpsAPI Agent", admin = true, iat = now, exp = now + 300 },
        })
    end)
    return ok and token or API_KEY
end

local function ollama_chat(messages, tools, opts)
    local wire = {}
    for i, m in ipairs(messages) do
        local w = { role = m.role, content = text_of(m.content) }
        if m.tool_calls then
            w.tool_calls = {}
            for j, tc in ipairs(m.tool_calls) do
                w.tool_calls[j] = { ["function"] = { name = tc["function"].name, arguments = tc["function"].arguments } }
            end
        end
        if m.role == "tool" then w.tool_name = m.tool_name end
        wire[i] = w
    end
    local body = {
        model = Llm.model, messages = wire, stream = false, think = false,
        -- num_predict caps each reply: a looping model otherwise generates
        -- forever and pins an Ollama slot after we time out (seen on hh193).
        options = { temperature = opts.temperature or 0.2, num_predict = opts.max_tokens or 2048 },
    }
    if tools and #tools > 0 then body.tools = tools end
    local headers = {}
    local key = ollama_key()
    if key then headers["x-api-key"] = key end
    local data, err, status = post(BASE_URL .. "/api/chat", headers, body, opts.timeout_ms)
    if not data then return nil, err, status end
    local msg = data.message
    if type(msg) ~= "table" then return nil, "ollama: no message in response" end
    local out = { role = "assistant", content = text_of(msg.content) }
    if type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
        out.tool_calls = {}
        for i, tc in ipairs(msg.tool_calls) do
            local fn = tc["function"] or {}
            out.tool_calls[i] = { id = "call_" .. i, ["function"] = { name = fn.name or "", arguments = args_table(fn.arguments) } }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- openai: Chat Completions (and every compatible server)
-- ---------------------------------------------------------------------------

local function openai_chat(messages, tools, opts)
    local wire = {}
    for i, m in ipairs(messages) do
        if m.role == "tool" then
            wire[i] = { role = "tool", tool_call_id = m.tool_call_id, content = text_of(m.content) }
        elseif m.tool_calls then
            local calls = {}
            for j, tc in ipairs(m.tool_calls) do
                calls[j] = { id = tc.id, type = "function", ["function"] = {
                    name = tc["function"].name, arguments = cjson.encode(tc["function"].arguments or {}) or "{}" } }
            end
            wire[i] = { role = "assistant", content = text_of(m.content), tool_calls = calls }
        else
            wire[i] = { role = m.role, content = text_of(m.content) }
        end
    end
    local body = { model = Llm.model, messages = wire, temperature = opts.temperature or 0.2,
        max_tokens = opts.max_tokens or 2048 }
    if tools and #tools > 0 then body.tools = tools end
    local headers = { ["Authorization"] = API_KEY and ("Bearer " .. API_KEY) or nil }
    local data, err, status = post(BASE_URL .. "/chat/completions", headers, body, opts.timeout_ms)
    -- Newer OpenAI models reject max_tokens / a custom temperature: retry once
    -- with what they accept.
    if not data and status == 400 and (err:find("max_tokens", 1, true) or err:find("temperature", 1, true)) then
        body.max_completion_tokens, body.max_tokens, body.temperature = body.max_tokens, nil, nil
        data, err, status = post(BASE_URL .. "/chat/completions", headers, body, opts.timeout_ms)
    end
    if not data then return nil, err, status end
    local msg = type(data.choices) == "table" and data.choices[1] and data.choices[1].message
    if type(msg) ~= "table" then return nil, "openai: no message in response" end
    local out = { role = "assistant", content = text_of(msg.content) }
    if type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
        out.tool_calls = {}
        for i, tc in ipairs(msg.tool_calls) do
            local fn = tc["function"] or {}
            out.tool_calls[i] = { id = tc.id or ("call_" .. i), ["function"] = { name = fn.name or "", arguments = args_table(fn.arguments) } }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- anthropic: Messages API
-- ---------------------------------------------------------------------------

local function anthropic_chat(messages, tools, opts)
    local system, wire = {}, {}
    local function push(role, block)
        local last = wire[#wire]
        -- Consecutive same-role turns merge into one (tool results of one
        -- assistant turn must share a single user message).
        if last and last.role == role then
            last.content[#last.content + 1] = block
        else
            wire[#wire + 1] = { role = role, content = { block } }
        end
    end
    for _, m in ipairs(messages) do
        local text = text_of(m.content)
        if m.role == "system" then
            -- Leading system messages are THE system prompt; later ones (tool
            -- data notes, nudges) become user-side notes.
            if #wire == 0 then system[#system + 1] = text else push("user", { type = "text", text = "[Note] " .. text }) end
        elseif m.role == "tool" then
            push("user", { type = "tool_result", tool_use_id = m.tool_call_id, content = text })
        elseif m.role == "assistant" then
            if text ~= "" then push("assistant", { type = "text", text = text }) end
            for _, tc in ipairs(m.tool_calls or {}) do
                local input = tc["function"].arguments
                push("assistant", { type = "tool_use", id = tc.id, name = tc["function"].name,
                    input = type(input) == "table" and input or {} })
            end
            if text == "" and not m.tool_calls then push("assistant", { type = "text", text = "(no reply)" }) end
        elseif text ~= "" then
            push("user", { type = "text", text = text })
        end
    end
    if wire[1] and wire[1].role ~= "user" then
        table.insert(wire, 1, { role = "user", content = { { type = "text", text = "(continuing our conversation)" } } })
    end
    local body = {
        model = Llm.model, max_tokens = opts.max_tokens or 2048, temperature = opts.temperature or 0.2,
        system = #system > 0 and table.concat(system, "\n\n") or nil, messages = wire,
    }
    if tools and #tools > 0 then
        body.tools = {}
        for i, t in ipairs(tools) do
            local fn = t["function"] or t
            body.tools[i] = { name = fn.name, description = fn.description, input_schema = fn.parameters }
        end
    end
    local headers = { ["x-api-key"] = API_KEY, ["anthropic-version"] = "2023-06-01" }
    local data, err, status = post(BASE_URL .. "/v1/messages", headers, body, opts.timeout_ms)
    if not data then return nil, err, status end
    local texts, calls = {}, {}
    for _, block in ipairs(type(data.content) == "table" and data.content or {}) do
        if block.type == "text" then
            texts[#texts + 1] = text_of(block.text)
        elseif block.type == "tool_use" then
            calls[#calls + 1] = { id = block.id, ["function"] = { name = block.name or "", arguments = args_table(block.input) } }
        end
    end
    return { role = "assistant", content = table.concat(texts, "\n"), tool_calls = #calls > 0 and calls or nil }
end

local ADAPTERS = { ollama = ollama_chat, openai = openai_chat, anthropic = anthropic_chat }

--- One model round-trip. opts: max_tokens, temperature, timeout_ms.
function Llm.chat(messages, tools, opts)
    return ADAPTERS[PROVIDER](messages, tools, opts or {})
end

return Llm
