--[[
    LLM provider for every AI feature — the model is chosen by env/secrets only
    ===========================================================================

    One switch for the whole platform: the page assistant + chat agent, tax
    transaction classification, bookkeeping AI and bank-statement extraction
    all call Llm.chat. Changing provider or model is a secret change + restart.

      AI_PROVIDER     ollama (default) | anthropic | openai
                      ("openai" = the OpenAI Chat Completions protocol, so any
                      compatible API works: OpenAI, OpenRouter, Groq, Together,
                      Mistral, vLLM, LM Studio, Ollama's /v1 ...)
      AI_MODEL        model id
      AI_API_KEY      API key
      AI_BASE_URL     endpoint
      AI_VISION_PROVIDER / AI_VISION_MODEL
                      optional: reading statement images/PDFs needs a model that
                      can see (e.g. Claude, gpt-4.1, or minicpm-v on Ollama).

    Unset AI_* values fall back to the provider's own settings, which the
    deployments already carry: OLLAMA_URL / OLLAMA_MODEL / OLLAMA_API_KEY,
    ANTHROPIC_API_KEY / ANTHROPIC_MODEL / ANTHROPIC_VISION_MODEL,
    OPENAI_API_KEY / OPENAI_MODEL — then built-in defaults (qwen3.8:latest,
    claude-opus-5-5, gpt-4.1). The diy stack's LLM_PROVIDER is deliberately NOT
    read, so its setting can't silently move OpsAPI's models.

    Until AI_PROVIDER is set, vision keeps what it used before: Claude when an
    Anthropic key exists, else Ollama.

    The callers speak ONE message format; each adapter converts it:
      { role = "system" | "user" | "assistant" | "tool", content = "...",
        attachments = { { mime = "image/png" | "application/pdf", data = <base64> } },  -- user
        tool_calls = { { id, ["function"] = { name, arguments = {table} } } },          -- assistant
        tool_call_id, tool_name }                                                      -- tool result
    Llm.chat(messages, tools, opts) -> assistant message (+ .usage, .model) | nil, err, http_status
      opts: cfg (default Llm.default), json, max_tokens, temperature, timeout_ms
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

local PROVIDERS = {
    ollama = { model = "qwen3.8:latest", model_env = "OLLAMA_MODEL", key_env = "OLLAMA_API_KEY",
        url_env = "OLLAMA_URL", url = "https://ollama.workstation.co.uk", label = "Ollama" },
    anthropic = { model = "claude-opus-5-5", model_env = "ANTHROPIC_MODEL", key_env = "ANTHROPIC_API_KEY",
        url = "https://api.anthropic.com", label = "Anthropic Claude" },
    openai = { model = "gpt-4.1", model_env = "OPENAI_MODEL", key_env = "OPENAI_API_KEY",
        url = "https://api.openai.com/v1", label = "OpenAI-compatible" },
}

local function normalise(p)
    p = (p or ""):lower()
    if p == "claude" then p = "anthropic" end
    return PROVIDERS[p] and p or nil
end

local MAIN = normalise(env("AI_PROVIDER")) or "ollama"

--- Settings for one provider: { provider, label, model, key, url }. The AI_*
-- overrides apply to the main (AI_PROVIDER) provider only.
function Llm.config(provider, model)
    local d = PROVIDERS[provider]
    local main = provider == MAIN
    return {
        provider = provider,
        label = d.label,
        model = model or (main and env("AI_MODEL")) or env(d.model_env) or d.model,
        key = (main and env("AI_API_KEY")) or env(d.key_env),
        url = ((main and env("AI_BASE_URL")) or (d.url_env and env(d.url_env)) or d.url):gsub("/+$", ""),
    }
end

Llm.default = Llm.config(MAIN)
Llm.provider, Llm.model = Llm.default.provider, Llm.default.model

local VISION = normalise(env("AI_VISION_PROVIDER")) or normalise(env("AI_PROVIDER"))
    or (env("ANTHROPIC_API_KEY") and "anthropic") or "ollama"
Llm.vision = Llm.config(VISION, env("AI_VISION_MODEL")
    or (VISION == "anthropic" and VISION ~= MAIN and env("ANTHROPIC_VISION_MODEL")) or nil)

--- Is a model configured at all for this config? (the footer shows "off" otherwise)
function Llm.configured(cfg)
    cfg = cfg or Llm.default
    if cfg.provider == "ollama" then
        return env("AI_BASE_URL") ~= nil or env("OLLAMA_URL") ~= nil or cfg.key ~= nil
    end
    return cfg.key ~= nil
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

local function post(cfg, url, headers, body, timeout_ms)
    local encoded, enc_err = cjson.encode(body)
    if not encoded then return nil, "Could not encode the model request: " .. tostring(enc_err) end
    local httpc = http.new()
    httpc:set_timeout(timeout_ms or 120000)
    headers["Content-Type"] = "application/json"
    local res, err = httpc:request_uri(url, { method = "POST", body = encoded, headers = headers,
        -- ponytail: TLS verify off to match the rest of the AI clients; turn on
        -- with a trusted CA bundle (lua_ssl_trusted_certificate is set in prod).
        ssl_verify = false })
    if not res then return nil, "Model request failed: " .. tostring(err) end
    local data = cjson.decode(res.body or "")
    if res.status >= 400 then
        local e = type(data) == "table" and data.error
        local msg = type(e) == "table" and (e.message or cjson.encode(e)) or e or res.body
        ngx.log(ngx.ERR, "[llm] ", cfg.provider, " HTTP ", res.status, " (", #encoded, " bytes): ",
            tostring(msg):sub(1, 400))
        return nil, cfg.provider .. " HTTP " .. res.status .. ": " .. tostring(msg):sub(1, 400), res.status
    end
    if type(data) ~= "table" then return nil, cfg.provider .. ": unexpected response" end
    return data
end

-- ---------------------------------------------------------------------------
-- ollama: native /api/chat (same message shape as ours)
-- ---------------------------------------------------------------------------

--- x-api-key for the workstation Ollama gateway: the key may be a ready-made
-- JWT, or the signing secret — then mint a short-lived HS256 token from it.
function Llm.ollama_auth(key)
    key = key or Llm.config("ollama").key
    if not key then return nil end
    local _, dots = key:gsub("%.", "")
    if dots == 2 and key:sub(1, 2) == "ey" then return key end
    local now = ngx.time()
    local ok, token = pcall(function()
        return jwt:sign(key, {
            header = { typ = "JWT", alg = "HS256" },
            payload = { sub = "opsapi-agent", name = "OpsAPI Agent", admin = true, iat = now, exp = now + 300 },
        })
    end)
    return ok and token or key
end

local function ollama_chat(cfg, messages, tools, opts)
    local wire = {}
    for i, m in ipairs(messages) do
        local w = { role = m.role, content = text_of(m.content) }
        for _, a in ipairs(m.attachments or {}) do
            if not tostring(a.mime):match("^image/") then
                return nil, "The Ollama model can only read images, not " .. tostring(a.mime)
                    .. ". Upload an image or CSV, or set AI_VISION_PROVIDER to a provider that reads PDFs."
            end
            w.images = w.images or {}
            w.images[#w.images + 1] = a.data
        end
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
        model = cfg.model, messages = wire, stream = false, think = false,
        format = opts.json and "json" or nil,
        -- num_predict caps each reply: a looping model otherwise generates
        -- forever and pins an Ollama slot after we time out (seen on hh193).
        options = { temperature = opts.temperature or 0.2, num_predict = opts.max_tokens or 2048 },
    }
    if tools and #tools > 0 then body.tools = tools end
    local data, err, status = post(cfg, cfg.url .. "/api/chat", { ["x-api-key"] = Llm.ollama_auth(cfg.key) },
        body, opts.timeout_ms)
    if not data then return nil, err, status end
    local msg = data.message
    if type(msg) ~= "table" then return nil, "ollama: no message in response" end
    local out = { role = "assistant", content = text_of(msg.content),
        usage = { input = data.prompt_eval_count or 0, output = data.eval_count or 0 } }
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

local function openai_chat(cfg, messages, tools, opts)
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
        elseif m.attachments and #m.attachments > 0 then
            local parts = {}
            for _, a in ipairs(m.attachments) do
                local uri = "data:" .. tostring(a.mime) .. ";base64," .. a.data
                parts[#parts + 1] = a.mime == "application/pdf"
                    and { type = "file", file = { filename = "document.pdf", file_data = uri } }
                    or { type = "image_url", image_url = { url = uri } }
            end
            parts[#parts + 1] = { type = "text", text = text_of(m.content) }
            wire[i] = { role = m.role, content = parts }
        else
            wire[i] = { role = m.role, content = text_of(m.content) }
        end
    end
    local body = { model = cfg.model, messages = wire, temperature = opts.temperature or 0.2,
        max_tokens = opts.max_tokens or 2048, response_format = opts.json and { type = "json_object" } or nil }
    if tools and #tools > 0 then body.tools = tools end
    local headers = { ["Authorization"] = cfg.key and ("Bearer " .. cfg.key) or nil }
    local url = cfg.url .. "/chat/completions"
    local data, err, status = post(cfg, url, headers, body, opts.timeout_ms)
    -- Newer OpenAI models reject max_tokens / a custom temperature: retry once
    -- with what they accept.
    if not data and status == 400 and (err:find("max_tokens", 1, true) or err:find("temperature", 1, true)) then
        body.max_completion_tokens, body.max_tokens, body.temperature = body.max_tokens, nil, nil
        data, err, status = post(cfg, url, headers, body, opts.timeout_ms)
    end
    if not data then return nil, err, status end
    local msg = type(data.choices) == "table" and data.choices[1] and data.choices[1].message
    if type(msg) ~= "table" then return nil, "openai: no message in response" end
    local usage = type(data.usage) == "table" and data.usage or {}
    local out = { role = "assistant", content = text_of(msg.content),
        usage = { input = usage.prompt_tokens or 0, output = usage.completion_tokens or 0 } }
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

local function anthropic_chat(cfg, messages, tools, opts)
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
        else
            for _, a in ipairs(m.attachments or {}) do
                push("user", { type = a.mime == "application/pdf" and "document" or "image",
                    source = { type = "base64", media_type = a.mime, data = a.data } })
            end
            if text ~= "" then push("user", { type = "text", text = text }) end
        end
    end
    if wire[1] and wire[1].role ~= "user" then
        table.insert(wire, 1, { role = "user", content = { { type = "text", text = "(continuing our conversation)" } } })
    end
    local body = {
        model = cfg.model, max_tokens = opts.max_tokens or 2048, temperature = opts.temperature or 0.2,
        system = #system > 0 and table.concat(system, "\n\n") or nil, messages = wire,
    }
    if tools and #tools > 0 then
        body.tools = {}
        for i, t in ipairs(tools) do
            local fn = t["function"] or t
            body.tools[i] = { name = fn.name, description = fn.description, input_schema = fn.parameters }
        end
    end
    local headers = { ["x-api-key"] = cfg.key, ["anthropic-version"] = "2023-06-01" }
    local data, err, status = post(cfg, cfg.url .. "/v1/messages", headers, body, opts.timeout_ms)
    if not data then return nil, err, status end
    local texts, calls = {}, {}
    for _, block in ipairs(type(data.content) == "table" and data.content or {}) do
        if block.type == "text" then
            texts[#texts + 1] = text_of(block.text)
        elseif block.type == "tool_use" then
            calls[#calls + 1] = { id = block.id, ["function"] = { name = block.name or "", arguments = args_table(block.input) } }
        end
    end
    local usage = type(data.usage) == "table" and data.usage or {}
    return { role = "assistant", content = table.concat(texts, "\n"), tool_calls = #calls > 0 and calls or nil,
        usage = { input = usage.input_tokens or 0, output = usage.output_tokens or 0 } }
end

local ADAPTERS = { ollama = ollama_chat, openai = openai_chat, anthropic = anthropic_chat }

--- One model round-trip (see the header for the message format and opts).
function Llm.chat(messages, tools, opts)
    opts = opts or {}
    local cfg = opts.cfg or Llm.default
    local msg, err, status = ADAPTERS[cfg.provider](cfg, messages, tools, opts)
    if msg then msg.model = cfg.model end
    return msg, err, status
end

return Llm
