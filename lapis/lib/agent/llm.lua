--[[
    LLM provider for every AI feature — the model is chosen by env/secrets only
    ===========================================================================

    One switch for the whole platform: the page assistant + chat agent, tax
    transaction classification, bookkeeping AI and bank-statement extraction
    all call Llm.chat. Changing provider or model is a secret change + restart.

      AI_PROVIDER     ollama (default) | anthropic | openai | google (= gemini)
                      | bedrock | azure | vertex (see "Cloud providers" below)
                      ("openai" = the OpenAI Chat Completions protocol, so any
                      compatible API works: OpenAI, OpenRouter, Groq, Together,
                      Mistral, vLLM, LM Studio, Ollama's /v1 ...). Switching the
                      model in production is PURELY an env change — no code change:
                        Anthropic: AI_PROVIDER=anthropic AI_API_KEY=sk-ant-… AI_MODEL=claude-opus-5-5
                        OpenAI:    AI_PROVIDER=openai    AI_API_KEY=sk-…      AI_MODEL=gpt-4.1
                        Gemini:    AI_PROVIDER=gemini    AI_API_KEY=…         AI_MODEL=gemini-2.5-flash
                        Any OpenAI-compatible host: AI_PROVIDER=openai + AI_BASE_URL=…
      AI_MODEL        model id
      AI_API_KEY      API key
      AI_BASE_URL     endpoint (override; e.g. an OpenAI-compatible gateway)
      AI_VISION_PROVIDER / AI_VISION_MODEL
                      optional: reading statement images/PDFs needs a model that
                      can see (e.g. Claude, gpt-4.1, gemini-2.5-flash, or minicpm-v on Ollama).

    Unset AI_* values fall back to the provider's own settings, which the
    deployments already carry: OLLAMA_URL / OLLAMA_MODEL / OLLAMA_API_KEY,
    ANTHROPIC_API_KEY / ANTHROPIC_MODEL / ANTHROPIC_VISION_MODEL,
    OPENAI_API_KEY / OPENAI_MODEL, GEMINI_API_KEY / GEMINI_MODEL / GEMINI_BASE_URL
    — then built-in defaults (qwen3.8:latest, claude-opus-5-5, gpt-4.1,
    gemini-2.5-flash). The diy stack's LLM_PROVIDER is deliberately NOT read, so
    its setting can't silently move OpsAPI's models.

    Until AI_PROVIDER is set, vision keeps what it used before: Claude when an
    Anthropic key exists, else Ollama.

    Cloud providers (as AI_PROVIDER, or as fallback hops — see below):
      bedrock   AWS Bedrock Runtime, Converse API. SigV4-signed with AWS_ACCESS_KEY_ID /
                AWS_SECRET_ACCESS_KEY (+ AWS_SESSION_TOKEN), or a Bedrock API key
                (AWS_BEARER_TOKEN_BEDROCK / BEDROCK_API_KEY) sent as a bearer token.
                Region: BEDROCK_REGION / AWS_REGION / AWS_DEFAULT_REGION. Model: BEDROCK_MODEL —
                a model id (anthropic.claude-…-v1:0) or an inference-profile id (eu.anthropic.…).
      azure     Azure OpenAI: AZURE_OPENAI_ENDPOINT (https://<resource>.openai.azure.com),
                AZURE_OPENAI_API_KEY (sent as `api-key`), AZURE_OPENAI_DEPLOYMENT,
                AZURE_OPENAI_API_VERSION (default 2024-10-21; "v1" = the /openai/v1 API).
      vertex    Google Vertex AI: a service account (GCP_CREDENTIALS_JSON = the key JSON, raw or
                base64; or GOOGLE_APPLICATION_CREDENTIALS = its path) is traded for an OAuth token
                (cached until it expires). GCP_PROJECT (default: the key's project_id),
                GCP_LOCATION (default us-central1), VERTEX_MODEL (default gemini-2.5-flash).
                gemini-* models use generateContent; claude-* models use Anthropic on Vertex.

    Fallback chain: when the main provider fails, the same request goes to the
    next hop, in order, so a provider outage or a bad key never takes AI down.
      AI_FALLBACK_CHAIN     comma-separated hop names, tried in order after the main
                            provider, e.g. "bedrock,azure,vertex,vast1,vast2,anthropic".
                            "none" = no fallback. Unset = the single legacy fallback below.
      A hop is a NAME plus settings, read (first found wins) from
        AI_HOP_<NAME>_<FIELD>  env (only visible in nginx when declared: `env AI_HOP_…;`)
        AI_HOPS                one JSON env holding every custom hop, keyed by name:
                               {"vast1":{"provider":"openai","base_url":"https://…/v1",
                                         "api_key":"…","model":"qwen3-32b"}, "vast2":{…}}
        the provider's standard env — ONLY when the hop's name IS the provider
                               (bedrock / azure / vertex / anthropic / openai / gemini / ollama),
                               so a custom host (vast1) never receives OPENAI_API_KEY etc.
      Fields: provider (default: the name), model, base_url, api_key, region,
        access_key_id, secret_access_key, session_token (bedrock), deployment,
        api_version (azure), project, location, credentials_json, credentials_file
        (vertex), tools ("false" = this hop can't call tools: skipped for tool-using
        calls), enabled ("false" = keep it listed but never use it).
      provider aliases: claude, gemini, azure_openai, aws_bedrock, vertex_ai,
        openai_compatible / vllm (= openai: any OpenAI-compatible server, e.g. vast.ai).
      AI_FALLBACK_CHAIN_BY_FEATURE  optional per-task chains, by usage feature:
                            "tax_classify=vast1,bedrock;statement_extract=vertex,azure"
                            (features without an entry use AI_FALLBACK_CHAIN).
      A hop that isn't configured (no key / model / region …) is skipped with one INFO
      log line at start-up. Legacy (AI_FALLBACK_CHAIN unset), unchanged:
      AI_FALLBACK_PROVIDER  ollama (default) | anthropic | openai | gemini | none
      AI_FALLBACK_MODEL     default: that provider's own model setting
                            (OLLAMA_MODEL for Ollama, on OLLAMA_URL / OLLAMA_API_KEY)
    If the main provider or a chain hop is down (timeout, 5xx, rate limit, bad key,
    unknown model), it is skipped for the next 60s (a per-hop circuit breaker,
    shared by every worker) instead of each call waiting out the failure. The
    health check keeps probing the main provider. The answer says who answered:
    .model, .provider, and .fallback = true + .hop = <name> when a fallback did.
    Llm.chain_status() describes the chain for operators (no secrets):
    GET /api/v2/admin/ai-chain (platform admins).
    A workspace's own provider (lib/ai-providers: cfg.workspace_provider) never
    falls back to the platform's model — its data only goes where the workspace
    said — and has its own breaker, so one workspace's bad key can't trip another's.

    Time: opts.timeout_ms is the TOTAL budget of one Llm.chat — a streamed
    answer and every fallback included (a socket timeout alone restarts on every
    streamed chunk). With fallbacks, the main provider gets 2/3 of it and each
    hop an equal share of what is left (the last hop: all of it); a hop that fails
    fast hands its time on. Default:
    AI_REQUEST_TIMEOUT_MS (2 min) while serving a request, someone is waiting;
    AI_TIMEOUT_MS (5 min) in background work (timers, jobs), since self-hosted
    models on shared hardware can queue.

    TLS certificates are verified (lua_ssl_trusted_certificate in nginx.conf);
    AI_TLS_VERIFY=false turns that off for local development against a
    self-signed endpoint. Plain http:// URLs are unaffected.

    The callers speak ONE message format; each adapter converts it:
      { role = "system" | "user" | "assistant" | "tool", content = "...",
        attachments = { { mime = "image/png" | "application/pdf", data = <base64> } },  -- user
        tool_calls = { { id, ["function"] = { name, arguments = {table} } } },          -- assistant
        tool_call_id, tool_name }                                                      -- tool result
    Llm.chat(messages, tools, opts) -> assistant message (+ .usage, .model, .provider, .fallback, .hop)
                                       | nil, err, http_status
      opts: cfg (default Llm.default), json, max_tokens, temperature, timeout_ms (total),
            usage = { feature, user_uuid, namespace_id, scope, run_uuid, system },
            no_fallback (the health check measures the main provider itself)

    Metering: every call is one ai_usage row (who, workspace, feature, model,
    tokens in/out (+ how many input tokens came from the provider's prompt
    cache, billed far lower), latency, outcome). User and workspace default to the current
    request's (ngx.ctx); `usage.system` calls (health checks) are billed to no one.
      AI_USER_DAILY_TOKEN_LIMIT  optional: tokens one user may use per UTC day
                                 across every AI feature (unset = no limit).
]]

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

-- Each provider declares which wire PROTOCOL it speaks (which adapter sends the
-- request); it defaults to the provider name. Gemini and other OpenAI-compatible
-- services set protocol = "openai" so they reuse the OpenAI adapter with their own
-- base URL. Adding a new provider is data here, not new code.
-- env: the provider's standard settings, field -> env name (or names, first set wins).
local PROVIDERS = {
    ollama = { model = "qwen3.8:latest", url = "https://ollama.workstation.co.uk", label = "Ollama",
        env = { model = "OLLAMA_MODEL", api_key = "OLLAMA_API_KEY", base_url = "OLLAMA_URL" } },
    anthropic = { model = "claude-opus-5-5", url = "https://api.anthropic.com", label = "Anthropic Claude",
        env = { model = "ANTHROPIC_MODEL", api_key = "ANTHROPIC_API_KEY" } },
    openai = { model = "gpt-4.1", url = "https://api.openai.com/v1", label = "OpenAI-compatible",
        env = { model = "OPENAI_MODEL", api_key = "OPENAI_API_KEY" } },
    -- Google Gemini via its OpenAI-compatible endpoint → reuses the OpenAI adapter.
    google = { model = "gemini-2.5-flash", url = "https://generativelanguage.googleapis.com/v1beta/openai",
        protocol = "openai", label = "Google Gemini",
        env = { model = "GEMINI_MODEL", api_key = "GEMINI_API_KEY", base_url = "GEMINI_BASE_URL" } },
    -- AWS Bedrock Runtime, Converse API (SigV4, or a Bedrock API key as a bearer token).
    bedrock = { protocol = "bedrock", label = "AWS Bedrock",
        env = { model = "BEDROCK_MODEL", api_key = { "AWS_BEARER_TOKEN_BEDROCK", "BEDROCK_API_KEY" },
            region = { "BEDROCK_REGION", "AWS_REGION", "AWS_DEFAULT_REGION" },
            access_key_id = "AWS_ACCESS_KEY_ID", secret_access_key = "AWS_SECRET_ACCESS_KEY",
            session_token = "AWS_SESSION_TOKEN" } },
    -- Azure OpenAI: the OpenAI adapter on a deployment URL with an `api-key` header.
    azure = { protocol = "openai", label = "Azure OpenAI", api_version = "2024-10-21",
        env = { base_url = "AZURE_OPENAI_ENDPOINT", api_key = "AZURE_OPENAI_API_KEY",
            deployment = "AZURE_OPENAI_DEPLOYMENT", api_version = "AZURE_OPENAI_API_VERSION",
            model = "AZURE_OPENAI_MODEL" } },
    -- Google Vertex AI: service account -> OAuth token; Gemini generateContent, or Claude on Vertex.
    vertex = { protocol = "vertex", label = "Google Vertex AI", model = "gemini-2.5-flash", location = "us-central1",
        env = { model = "VERTEX_MODEL", project = { "GCP_PROJECT", "GOOGLE_CLOUD_PROJECT" },
            location = { "GCP_LOCATION", "GOOGLE_CLOUD_LOCATION" }, credentials_json = "GCP_CREDENTIALS_JSON",
            credentials_file = "GOOGLE_APPLICATION_CREDENTIALS" } },
}

local ALIASES = { claude = "anthropic", gemini = "google", azure_openai = "azure", aws_bedrock = "bedrock",
    vertex_ai = "vertex", gcp = "vertex", openai_compatible = "openai", vllm = "openai" }

local function normalise(p)
    p = (p or ""):lower()
    p = ALIASES[p] or p
    return PROVIDERS[p] and p or nil
end

-- The first set env var of one name or a list of names.
local function env_any(names)
    if type(names) ~= "table" then return names and env(names) end
    for _, n in ipairs(names) do
        local v = env(n)
        if v then return v end
    end
    return nil
end

--- A service account key: raw JSON, or base64 of it. nil, reason.
local function service_account(json_text, file)
    if not json_text and file then
        local f = io.open(file, "r")
        if not f then return nil, "GOOGLE_APPLICATION_CREDENTIALS file can't be read" end
        json_text = f:read("*a")
        f:close()
    end
    if not json_text then return nil, "no service account (credentials_json / GCP_CREDENTIALS_JSON)" end
    local sa = cjson.decode(json_text)
    if type(sa) ~= "table" then sa = cjson.decode(require("lib.agent.llm-auth").unbase64(json_text)) end
    if type(sa) ~= "table" or type(sa.client_email) ~= "string" or type(sa.private_key) ~= "string" then
        return nil, "the service account JSON has no client_email / private_key"
    end
    return sa
end

--- Settings for one provider. get(field) = the caller's own override (AI_* for the main
-- provider, a hop's settings for a hop); std = also read the provider's standard env.
-- hop = a fallback hop (a custom OpenAI-compatible host may run without a key).
local function build(provider, get, std, hop)
    local d = PROVIDERS[provider]
    local function field(f)
        local v = get(f)
        if v then return v, true end
        if std and d.env[f] then return env_any(d.env[f]), false end
        return nil
    end
    local base_url, own_url = field("base_url")
    local cfg = {
        provider = provider,
        protocol = d.protocol or provider,
        label = d.label,
        model = field("model") or d.model,
        key = field("api_key"),
        url = (base_url or d.url or ""):gsub("/+$", ""),
    }
    local p = provider
    if p == "bedrock" then
        cfg.region = field("region")
        cfg.aws = { access_key = field("access_key_id"), secret_key = field("secret_access_key"),
            session_token = field("session_token") }
        if not base_url and cfg.region then cfg.url = "https://bedrock-runtime." .. cfg.region .. ".amazonaws.com" end
        cfg.missing = (not cfg.model and "no model (BEDROCK_MODEL / model)")
            or (not cfg.region and "no region (AWS_REGION / region)")
            or (not cfg.key and not (cfg.aws.access_key and cfg.aws.secret_key)
                and "no credentials (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, or a Bedrock API key)")
            or nil
    elseif p == "azure" then
        local deployment = field("deployment") or cfg.model
        cfg.model = cfg.model or deployment
        cfg.api_version = field("api_version") or d.api_version
        if cfg.api_version == "v1" then
            cfg.chat_url = cfg.url .. "/openai/v1/chat/completions"
        elseif deployment then
            cfg.chat_url = cfg.url .. "/openai/deployments/" .. require("lib.agent.llm-auth").uri_encode(deployment)
                .. "/chat/completions?api-version=" .. require("lib.agent.llm-auth").uri_encode(cfg.api_version)
        end
        cfg.headers = { ["api-key"] = cfg.key }
        cfg.missing = (cfg.url == "" and "no endpoint (AZURE_OPENAI_ENDPOINT / base_url)")
            or (not cfg.key and "no key (AZURE_OPENAI_API_KEY / api_key)")
            or (not cfg.model and "no deployment (AZURE_OPENAI_DEPLOYMENT / deployment)") or nil
    elseif p == "vertex" then
        local sa, why = service_account(field("credentials_json"), field("credentials_file"))
        cfg.sa = sa
        cfg.project = field("project") or (sa and sa.project_id)
        cfg.location = field("location") or d.location
        if not base_url then
            local prefix = cfg.location == "global" and "" or (cfg.location .. "-")
            cfg.url = "https://" .. prefix .. "aiplatform.googleapis.com"
        end
        cfg.missing = (not sa and why) or (not cfg.project and "no project (GCP_PROJECT / project)") or nil
    elseif p == "ollama" then
        -- Configured when it has somewhere to go (a URL of its own) or a key.
        cfg.missing = not (base_url or cfg.key) and "no URL (OLLAMA_URL / base_url)" or nil
    else
        -- A custom OpenAI-compatible host (vast.ai, vLLM …) may need no key.
        local keyless = hop and p == "openai" and own_url
        cfg.missing = not (cfg.key or keyless) and "no API key" or nil
    end
    return cfg
end

local MAIN = normalise(env("AI_PROVIDER")) or "ollama"
local MAIN_FIELDS = { model = "AI_MODEL", api_key = "AI_API_KEY", base_url = "AI_BASE_URL" }

--- Settings for one provider: { provider, protocol, label, model, key, url, … }. The AI_*
-- overrides apply to the main (AI_PROVIDER) provider only.
function Llm.config(provider, model)
    local main = provider == MAIN
    local cfg = build(provider, function(f)
        if f == "model" and model then return model end
        return main and MAIN_FIELDS[f] and env(MAIN_FIELDS[f]) or nil
    end, true)
    local protocol = PROVIDERS[provider].protocol
    if protocol ~= "bedrock" and protocol ~= "vertex" and provider ~= "azure" then
        cfg.missing = nil -- the long-standing providers keep Llm.configured's own rule (below)
    end
    return cfg
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
    if cfg.hop or cfg.protocol == "bedrock" or cfg.protocol == "vertex" or cfg.provider == "azure" then
        return cfg.missing == nil
    end
    if cfg.provider == "ollama" then
        return env("AI_BASE_URL") ~= nil or env("OLLAMA_URL") ~= nil or cfg.key ~= nil
    end
    return cfg.key ~= nil
end

local function same(a, b)
    return a.provider == b.provider and a.model == b.model and a.url == b.url
end

-- ---------------------------------------------------------------------------
-- The fallback chain (see the header)
-- ---------------------------------------------------------------------------

local HOPS_JSON = cjson.decode(env("AI_HOPS") or "")
if env("AI_HOPS") and type(HOPS_JSON) ~= "table" then
    ngx.log(ngx.ERR, "[llm] AI_HOPS is not a JSON object; its hops are ignored")
end

local function hop_field(name, f)
    local v = env("AI_HOP_" .. name:upper() .. "_" .. f:upper())
    if v then return v end
    local h = type(HOPS_JSON) == "table" and HOPS_JSON[name] or nil
    if type(h) ~= "table" then return nil end
    local x = h[f]
    if x == nil or x == cjson.null or x == "" then return nil end
    if type(x) == "table" then return cjson.encode(x) end
    return tostring(x)
end

--- One named hop (configured or not; .missing says why not).
function Llm.hop(name)
    local raw = hop_field(name, "provider")
    local provider = normalise(raw or name)
    if not provider then
        return { name = name, hop = true, provider = raw or name, label = raw or name, url = "", tools = false,
            missing = "unknown provider '" .. tostring(raw or name) .. "' (set AI_HOP_" .. name:upper()
                .. "_PROVIDER or AI_HOPS." .. name .. ".provider)" }
    end
    local cfg = build(provider, function(f) return hop_field(name, f) end, normalise(name) == provider, true)
    cfg.name, cfg.hop = name, true
    cfg.tools = hop_field(name, "tools") ~= "false"
    cfg.enabled = hop_field(name, "enabled") ~= "false"
    if not cfg.model then cfg.missing = cfg.missing or "no model" end
    cfg.breaker_key = "ai:down:hop:" .. name .. ":" .. provider .. ":" .. tostring(cfg.model)
    return cfg
end

local function names_of(list)
    local out, seen = {}, {}
    for n in tostring(list or ""):lower():gmatch("[^,%s;]+") do
        if n ~= "none" and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    return out
end

Llm.hops = {}  -- every hop named anywhere, configured or not (for Llm.chain_status)

-- A usable chain from hop names: unconfigured / disabled / same-as-main hops are
-- skipped with one INFO line each.
local function chain_of(names)
    local chain = {}
    for _, name in ipairs(names) do
        local cfg = Llm.hops[name]
        local first = cfg == nil
        cfg = cfg or Llm.hop(name)
        Llm.hops[name] = cfg
        local why = cfg.missing or (cfg.enabled == false and "disabled (enabled=false)")
            or (same(cfg, Llm.default) and "same model as the main provider") or nil
        if why then
            if first then ngx.log(ngx.INFO, "[llm] fallback hop ", name, " skipped: ", why) end
        else
            chain[#chain + 1] = cfg
        end
    end
    return chain
end

Llm.chain_source = env("AI_FALLBACK_CHAIN") and "AI_FALLBACK_CHAIN" or "AI_FALLBACK_PROVIDER"
Llm.chain_names = names_of(env("AI_FALLBACK_CHAIN"))
if env("AI_FALLBACK_CHAIN") then
    Llm.chain = chain_of(Llm.chain_names)
else
    -- Legacy single fallback (nil = none): a different, configured model. No breaker of
    -- its own, exactly as before the chain existed.
    local FALLBACK = (env("AI_FALLBACK_PROVIDER") or "ollama"):lower()
    local fb = normalise(FALLBACK) and Llm.config(normalise(FALLBACK), env("AI_FALLBACK_MODEL")) or nil
    if fb and (same(fb, Llm.default) or not Llm.configured(fb)) then fb = nil end
    if fb then fb.name, fb.legacy, fb.tools = fb.provider, true, true end
    Llm.chain = { fb }
end
-- The first hop: what the dashboard footer shows when the main model is down.
Llm.fallback = Llm.chain[1]

-- Per-task chains: "feature=a,b;feature2=c".
Llm.chain_by_feature = {}
for feature, list in tostring(env("AI_FALLBACK_CHAIN_BY_FEATURE") or ""):gmatch("([%w_%-%.]+)%s*=%s*([^;]*)") do
    Llm.chain_by_feature[feature] = chain_of(names_of(list))
end

--- The chain one call falls through (by its usage feature).
function Llm.chain_for(feature)
    return feature and Llm.chain_by_feature[feature] or Llm.chain
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

-- Total time for one Llm.chat (see the header): background work, and calls made while serving a request.
Llm.TIMEOUT_MS = tonumber(env("AI_TIMEOUT_MS") or "") or 300000
local REQUEST_TIMEOUT_MS = tonumber(env("AI_REQUEST_TIMEOUT_MS") or "") or 120000

--- Verify model servers' TLS certificates? (AI_TLS_VERIFY=false: local development only.)
function Llm.tls_verify()
    return os.getenv("AI_TLS_VERIFY") ~= "false"
end

--- Ollama with stream = true answers as NDJSON lines; merge them into one non-streamed answer.
-- Streaming keeps bytes flowing while the model writes, so a proxy in front of the model never
-- sees a long silent connection (they cut those, e.g. at 120 s).
local function merge_ndjson(text)
    local out, last, content, calls = nil, nil, {}, nil
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local chunk = cjson.decode(line)
        if type(chunk) == "table" then
            if chunk.error then return { error = chunk.error } end
            local m = type(chunk.message) == "table" and chunk.message or {}
            if type(m.content) == "string" then content[#content + 1] = m.content end
            if type(m.tool_calls) == "table" and #m.tool_calls > 0 then
                calls = calls or {}
                for _, tc in ipairs(m.tool_calls) do calls[#calls + 1] = tc end
            end
            last = chunk
            if chunk.done then out = chunk end
        end
    end
    out = out or last  -- a server that ignored stream and sent one object
    if not out then return nil end
    out.message = { role = "assistant", content = table.concat(content), tool_calls = calls }
    return out
end

--- OpenAI-compatible SSE ("data: {chunk}" lines, then "data: [DONE]"): merged into one non-streamed
-- Chat Completions answer (content, tool calls by index, usage from the last chunk).
local function merge_sse(text)
    local content, calls, usage, streamed = {}, {}, nil, false
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local payload = line:match("^data:%s*(.-)%s*$")
        local chunk = payload and payload ~= "[DONE]" and cjson.decode(payload)
        if type(chunk) == "table" then
            streamed = true
            if chunk.error then return { error = chunk.error } end
            if type(chunk.usage) == "table" then usage = chunk.usage end
            local choice = type(chunk.choices) == "table" and chunk.choices[1]
            local d = type(choice) == "table" and type(choice.delta) == "table" and choice.delta or {}
            if type(d.content) == "string" then content[#content + 1] = d.content end
            for _, tc in ipairs(type(d.tool_calls) == "table" and d.tool_calls or {}) do
                local i = tonumber(tc.index) and tonumber(tc.index) + 1 or (tc.id and #calls + 1) or math.max(#calls, 1)
                calls[i] = calls[i] or { type = "function", ["function"] = { name = "", arguments = "" } }
                local fn = type(tc["function"]) == "table" and tc["function"] or {}
                if type(tc.id) == "string" then calls[i].id = tc.id end
                if type(fn.name) == "string" then calls[i]["function"].name = calls[i]["function"].name .. fn.name end
                if type(fn.arguments) == "string" then
                    calls[i]["function"].arguments = calls[i]["function"].arguments .. fn.arguments
                end
            end
        end
    end
    if not streamed then return cjson.decode(text or "") end -- a server that ignored stream and sent one object
    return { usage = usage, choices = { { message = { role = "assistant", content = table.concat(content),
        tool_calls = #calls > 0 and calls or nil } } } }
end

-- deadline: ngx.now() by which the whole answer must be in (Llm.chat). merge: how a streamed body
-- (body.stream) is put back together. sign(encoded, headers) -> headers: signs the exact bytes
-- sent (AWS SigV4).
local function post(cfg, url, headers, body, deadline, merge, sign)
    local encoded, enc_err = cjson.encode(body)
    if not encoded then return nil, "Could not encode the model request: " .. tostring(enc_err) end
    local Webhooks = require("lib.outbound-webhooks")
    local target, terr
    if cfg.user_url then
        -- A workspace's URL: SSRF-checked now and connected to the checked address (lib/ai-providers).
        target, terr = require("lib.ai-providers").target(url)
        if not target then return nil, terr end
    else
        target, terr = Webhooks.parseUrl(url, { allow_private = true, allow_http = true }) -- operator config
        if not target then return nil, "Model URL " .. tostring(terr) end
    end
    headers["Content-Type"] = "application/json"
    if sign then headers = sign(encoded, headers, target) end
    local res, err = Webhooks.fetch(target, { method = "POST", body = encoded, headers = headers,
        ssl_verify = Llm.tls_verify() }, { deadline = deadline })
    if not res then return nil, "Model request failed: " .. tostring(err) end
    local data
    if body.stream == true and res.status < 400 then data = merge(res.body) else data = cjson.decode(res.body or "") end
    local status = res.status
    if status < 400 and type(data) == "table" and data.error then status = 502 end -- failed mid-stream
    if status >= 400 then
        -- { error = … } (most), { message = … } (AWS), [ { error = … } ] (some Google errors)
        if type(data) == "table" and data[1] ~= nil and type(data[1]) == "table" then data = data[1] end
        local e = type(data) == "table" and (data.error or data.message or data.Message)
        local msg = type(e) == "table" and (e.message or cjson.encode(e)) or e or res.body
        ngx.log(ngx.ERR, "[llm] ", cfg.provider, " HTTP ", status, " (", #encoded, " bytes): ",
            tostring(msg):sub(1, 400))
        return nil, cfg.provider .. " HTTP " .. status .. ": " .. tostring(msg):sub(1, 400), status
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

local CALL_SEQ = 0

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
        model = cfg.model, messages = wire, stream = true, think = false,
        format = opts.json and "json" or nil,
        -- num_predict caps each reply: a looping model otherwise generates
        -- forever and pins an Ollama slot after we time out (seen on hh193).
        options = { temperature = opts.temperature or 0.2, num_predict = opts.max_tokens or 2048 },
    }
    if tools and #tools > 0 then body.tools = tools end
    local data, err, status = post(cfg, cfg.url .. "/api/chat", { ["x-api-key"] = Llm.ollama_auth(cfg.key) },
        body, opts.deadline, merge_ndjson)
    if not data then return nil, err, status end
    local msg = data.message
    if type(msg) ~= "table" then return nil, "ollama: no message in response" end
    local out = { role = "assistant", content = text_of(msg.content),
        usage = { input = data.prompt_eval_count or 0, output = data.eval_count or 0 } }
    if type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
        out.tool_calls = {}
        for i, tc in ipairs(msg.tool_calls) do
            local fn = tc["function"] or {}
            -- Unique ids: a run that falls back mid-way mixes providers, and
            -- Claude rejects repeated tool_use ids.
            CALL_SEQ = CALL_SEQ + 1
            out.tool_calls[i] = { id = "call_" .. CALL_SEQ, ["function"] = { name = fn.name or "",
                arguments = args_table(fn.arguments) } }
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
                    name = tc["function"].name, arguments = cjson.encode(tc["function"].arguments or {}) or "{}" },
                    -- Gemini 3 (OpenAI-compatible endpoint) needs its thought signature back with each call.
                    extra_content = tc.extra_content }
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
    -- Workspace local servers (cfg.stream): streamed like Ollama's native API, for the same proxies.
    if cfg.stream then body.stream, body.stream_options = true, { include_usage = true } end
    local headers = { ["Authorization"] = cfg.key and ("Bearer " .. cfg.key) or nil }
    -- A workspace provider (lib/ai-providers.lua) may bring its own URL and
    -- auth header, e.g. Azure OpenAI: .../deployments/<name>/chat/completions?api-version=…
    -- with `api-key` instead of a bearer token.
    for k, v in pairs(cfg.headers or {}) do headers[k] = v or nil end
    if cfg.headers and cfg.headers["api-key"] then headers["Authorization"] = nil end
    local url = cfg.chat_url or (cfg.url .. "/chat/completions")
    local data, err, status = post(cfg, url, headers, body, opts.deadline, merge_sse)
    -- A compatible server that rejects streaming (or stream_options): once more, not streamed.
    if not data and status == 400 and body.stream and err:find("stream", 1, true) then
        body.stream, body.stream_options = nil, nil
        data, err, status = post(cfg, url, headers, body, opts.deadline, merge_sse)
    end
    -- Newer OpenAI models reject max_tokens / a custom temperature: retry once
    -- with what they accept.
    if not data and status == 400 and (err:find("max_tokens", 1, true) or err:find("temperature", 1, true)) then
        body.max_completion_tokens, body.max_tokens, body.temperature = body.max_tokens, nil, nil
        data, err, status = post(cfg, url, headers, body, opts.deadline, merge_sse)
    end
    if not data then return nil, err, status end
    local msg = type(data.choices) == "table" and data.choices[1] and data.choices[1].message
    if type(msg) ~= "table" then return nil, "openai: no message in response" end
    local usage = type(data.usage) == "table" and data.usage or {}
    local details = type(usage.prompt_tokens_details) == "table" and usage.prompt_tokens_details or {}
    local out = { role = "assistant", content = text_of(msg.content), usage = {
        input = usage.prompt_tokens or 0, output = usage.completion_tokens or 0, cached = details.cached_tokens or 0 } }
    if type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
        out.tool_calls = {}
        for i, tc in ipairs(msg.tool_calls) do
            local fn = tc["function"] or {}
            out.tool_calls[i] = { id = tc.id or ("call_" .. i),
                ["function"] = { name = fn.name or "", arguments = args_table(fn.arguments) },
                extra_content = type(tc.extra_content) == "table" and tc.extra_content or nil }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- anthropic: Messages API
-- ---------------------------------------------------------------------------

-- Newer Claude models (Opus 4.7 on, Opus 5.x, Sonnet 5.x, Fable) reject
-- `temperature` with a 400. Remembered per model after the first refusal
-- rather than kept as a model list that goes stale.
local NO_SAMPLING = {}

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
            if #wire == 0 then
                system[#system + 1] = { type = "text", text = text }
            else
                push("user", { type = "text", text = "[Note] " .. text })
            end
        elseif m.role == "tool" then
            push("user", { type = "tool_result", tool_use_id = m.tool_call_id, content = text })
        elseif m.role == "assistant" and m.raw then
            -- This run's own Claude turn: replayed verbatim, thinking blocks
            -- included (Claude keeps its reasoning between tool calls).
            for _, block in ipairs(m.raw) do push("assistant", block) end
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
    -- Prompt caching: the FIRST system message is the stable part (instructions
    -- + page guide, the same for everyone on a page); it and the tools before
    -- it are cached, so repeat calls pay ~10% for them. Later system messages
    -- (who the user is, today's date) stay uncached.
    if system[1] then system[1].cache_control = { type = "ephemeral" } end
    local max_tokens = opts.max_tokens or 2048
    -- Thinking (always on for newer models) counts against max_tokens: give
    -- real replies headroom; only what is generated is billed. Tiny caps (the
    -- 1-token health probe) stay as asked.
    if max_tokens >= 256 then max_tokens = math.max(max_tokens, 8192) end
    local body = {
        model = cfg.model, max_tokens = max_tokens,
        temperature = not NO_SAMPLING[cfg.model] and (opts.temperature or 0.2) or nil,
        system = #system > 0 and system or nil, messages = wire,
    }
    if tools and #tools > 0 then
        body.tools = {}
        for i, t in ipairs(tools) do
            local fn = t["function"] or t
            body.tools[i] = { name = fn.name, description = fn.description, input_schema = fn.parameters }
        end
    end
    local headers = { ["x-api-key"] = cfg.key, ["anthropic-version"] = "2023-06-01" }
    -- Claude on Vertex AI: its own URL and bearer token; the model is in the URL and
    -- anthropic_version in the body.
    if cfg.messages_url then
        headers = cfg.messages_headers or {}
        for k, v in pairs(cfg.messages_body or {}) do body[k] = v end
        body.model = nil
    end
    local url = cfg.messages_url or (cfg.url .. "/v1/messages")
    local data, err, status = post(cfg, url, headers, body, opts.deadline)
    if not data and status == 400 and body.temperature and err:find("temperature", 1, true) then
        NO_SAMPLING[cfg.model], body.temperature = true, nil
        data, err, status = post(cfg, url, headers, body, opts.deadline)
    end
    if not data then return nil, err, status end
    local texts, calls = {}, {}
    for _, block in ipairs(type(data.content) == "table" and data.content or {}) do
        if block.type == "text" then
            texts[#texts + 1] = text_of(block.text)
        elseif block.type == "tool_use" then
            calls[#calls + 1] = { id = block.id, ["function"] = { name = block.name or "", arguments = args_table(block.input) } }
        end
    end
    -- input_tokens is only the uncached part: the prompt's full size adds the
    -- cache writes and reads; reads (billed at ~10%) are reported as `cached`.
    local usage = type(data.usage) == "table" and data.usage or {}
    local cached = usage.cache_read_input_tokens or 0
    return { role = "assistant", content = table.concat(texts, "\n"), tool_calls = #calls > 0 and calls or nil,
        raw = type(data.content) == "table" and data.content or nil,
        usage = { input = (usage.input_tokens or 0) + (usage.cache_creation_input_tokens or 0) + cached,
            output = usage.output_tokens or 0, cached = cached } }
end

-- ---------------------------------------------------------------------------
-- bedrock: AWS Bedrock Runtime Converse API (one request shape for every model)
-- ---------------------------------------------------------------------------

local LlmAuth = require("lib.agent.llm-auth")

-- Same-role turns merged, the first one the user's (Converse requires both, like Claude).
local function alternating()
    local wire = {}
    return wire, function(role, block)
        local last = wire[#wire]
        if last and last.role == role then
            last.content[#last.content + 1] = block
        else
            wire[#wire + 1] = { role = role, content = { block } }
        end
    end
end

--- Our messages -> a Converse request body (exposed for the specs).
function Llm.bedrock_body(cfg, messages, tools, opts)
    local system, wire, push = {}, alternating()
    for _, m in ipairs(messages) do
        local text = text_of(m.content)
        if m.role == "system" then
            if #wire == 0 then system[#system + 1] = { text = text }
            else push("user", { text = "[Note] " .. text }) end
        elseif m.role == "tool" then
            push("user", { toolResult = { toolUseId = m.tool_call_id, content = { { text = text } } } })
        elseif m.role == "assistant" then
            if text ~= "" then push("assistant", { text = text }) end
            for _, tc in ipairs(m.tool_calls or {}) do
                local input = tc["function"].arguments
                push("assistant", { toolUse = { toolUseId = tc.id, name = tc["function"].name,
                    input = type(input) == "table" and input or {} } })
            end
            if text == "" and not m.tool_calls then push("assistant", { text = "(no reply)" }) end
        else
            for _, a in ipairs(m.attachments or {}) do
                local mime = tostring(a.mime)
                if mime == "application/pdf" then
                    push("user", { document = { format = "pdf", name = "document", source = { bytes = a.data } } })
                else
                    push("user", { image = { format = (mime:match("^image/(%w+)") or "png"):gsub("jpg", "jpeg"),
                        source = { bytes = a.data } } })
                end
            end
            if text ~= "" then push("user", { text = text }) end
        end
    end
    if wire[1] and wire[1].role ~= "user" then
        table.insert(wire, 1, { role = "user", content = { { text = "(continuing our conversation)" } } })
    end
    local body = { messages = wire, system = #system > 0 and system or nil,
        inferenceConfig = { maxTokens = opts.max_tokens or 2048,
            temperature = not NO_SAMPLING[cfg.model] and (opts.temperature or 0.2) or nil } }
    if tools and #tools > 0 then
        local specs = {}
        for i, t in ipairs(tools) do
            local fn = t["function"] or t
            specs[i] = { toolSpec = { name = fn.name, description = fn.description,
                inputSchema = { json = fn.parameters or { type = "object", properties = {} } } } }
        end
        body.toolConfig = { tools = specs }
    end
    return body
end

--- A Converse response -> our assistant message (exposed for the specs).
function Llm.bedrock_message(data)
    local msg = type(data.output) == "table" and data.output.message
    if type(msg) ~= "table" then return nil, "bedrock: no message in response" end
    local texts, calls = {}, {}
    for _, block in ipairs(type(msg.content) == "table" and msg.content or {}) do
        if type(block.text) == "string" then
            texts[#texts + 1] = block.text
        elseif type(block.toolUse) == "table" then
            calls[#calls + 1] = { id = block.toolUse.toolUseId, ["function"] = { name = block.toolUse.name or "",
                arguments = args_table(block.toolUse.input) } }
        end
    end
    local usage = type(data.usage) == "table" and data.usage or {}
    return { role = "assistant", content = table.concat(texts, "\n"), tool_calls = #calls > 0 and calls or nil,
        usage = { input = usage.inputTokens or 0, output = usage.outputTokens or 0,
            cached = usage.cacheReadInputTokens or 0 } }
end

local function bedrock_chat(cfg, messages, tools, opts)
    local body = Llm.bedrock_body(cfg, messages, tools, opts)
    -- The model id goes in the path, percent-encoded (ids carry ':'); SigV4 encodes it once more.
    local url = cfg.url .. "/model/" .. LlmAuth.uri_encode(cfg.model) .. "/converse"
    local headers, sign = {}, nil
    if cfg.key then
        headers["Authorization"] = "Bearer " .. cfg.key -- a Bedrock API key
    else
        sign = function(encoded, h, target)
            local signed = LlmAuth.sigv4({ method = "POST", host = target.host, path = target.path,
                headers = h, payload = encoded, access_key = cfg.aws.access_key, secret_key = cfg.aws.secret_key,
                session_token = cfg.aws.session_token, region = cfg.region, service = "bedrock" })
            signed.host = nil -- lib/outbound-webhooks sends Host itself (the same value)
            return signed
        end
    end
    local data, err, status = post(cfg, url, headers, body, opts.deadline, nil, sign)
    local sampling = body.inferenceConfig.temperature
    if not data and status == 400 and sampling and tostring(err):find("temperature", 1, true) then
        NO_SAMPLING[cfg.model], body.inferenceConfig.temperature = true, nil
        data, err, status = post(cfg, url, { Authorization = headers["Authorization"] }, body, opts.deadline, nil, sign)
    end
    if not data then return nil, err, status end
    return Llm.bedrock_message(data)
end

-- ---------------------------------------------------------------------------
-- vertex: Google Vertex AI — Gemini generateContent, or Claude (rawPredict)
-- ---------------------------------------------------------------------------

--- Our messages -> a generateContent body (exposed for the specs).
function Llm.gemini_body(messages, tools, opts)
    local system, wire, push = {}, alternating()
    local names = {} -- tool_call_id -> tool name (a functionResponse needs the name)
    for _, m in ipairs(messages) do
        local text = text_of(m.content)
        if m.role == "system" then
            if #wire == 0 then system[#system + 1] = { text = text }
            else push("user", { text = "[Note] " .. text }) end
        elseif m.role == "tool" then
            local result = cjson.decode(text)
            push("user", { functionResponse = { name = m.tool_name or names[m.tool_call_id] or "tool",
                response = type(result) == "table" and result[1] == nil and result or { content = text } } })
        elseif m.role == "assistant" then
            if text ~= "" then push("model", { text = text }) end
            for _, tc in ipairs(m.tool_calls or {}) do
                names[tc.id or ""] = tc["function"].name
                local input = tc["function"].arguments
                local google = type(tc.extra_content) == "table" and tc.extra_content.google or {}
                push("model", { thoughtSignature = google.thought_signature,
                    functionCall = { name = tc["function"].name, args = type(input) == "table" and input or {} } })
            end
            if text == "" and not m.tool_calls then push("model", { text = "(no reply)" }) end
        else
            for _, a in ipairs(m.attachments or {}) do
                push("user", { inlineData = { mimeType = a.mime, data = a.data } })
            end
            if text ~= "" then push("user", { text = text }) end
        end
    end
    if wire[1] and wire[1].role ~= "user" then
        table.insert(wire, 1, { role = "user", content = { { text = "(continuing our conversation)" } } })
    end
    -- Gemini calls a turn's blocks `parts`.
    for _, turn in ipairs(wire) do turn.parts, turn.content = turn.content, nil end
    local body = { contents = wire, systemInstruction = #system > 0 and { parts = system } or nil,
        generationConfig = { temperature = opts.temperature or 0.2, maxOutputTokens = opts.max_tokens or 2048,
            responseMimeType = opts.json and "application/json" or nil } }
    if tools and #tools > 0 then
        local decls = {}
        for i, t in ipairs(tools) do
            local fn = t["function"] or t
            decls[i] = { name = fn.name, description = fn.description,
                parametersJsonSchema = fn.parameters or { type = "object", properties = {} } }
        end
        body.tools = { { functionDeclarations = decls } }
    end
    return body
end

--- A generateContent response -> our assistant message (exposed for the specs).
function Llm.gemini_message(data)
    local cand = type(data.candidates) == "table" and data.candidates[1]
    if type(cand) ~= "table" then
        local fb = type(data.promptFeedback) == "table" and data.promptFeedback.blockReason
        return nil, "vertex: no answer" .. (fb and (" (blocked: " .. tostring(fb) .. ")") or "")
    end
    local texts, calls = {}, {}
    local parts = type(cand.content) == "table" and cand.content.parts or {}
    for _, part in ipairs(type(parts) == "table" and parts or {}) do
        if type(part.functionCall) == "table" then
            CALL_SEQ = CALL_SEQ + 1
            calls[#calls + 1] = { id = part.functionCall.id or ("call_" .. CALL_SEQ),
                ["function"] = { name = part.functionCall.name or "", arguments = args_table(part.functionCall.args) },
                extra_content = part.thoughtSignature
                    and { google = { thought_signature = part.thoughtSignature } } or nil }
        elseif type(part.text) == "string" and not part.thought then
            texts[#texts + 1] = part.text
        end
    end
    local usage = type(data.usageMetadata) == "table" and data.usageMetadata or {}
    return { role = "assistant", content = table.concat(texts), tool_calls = #calls > 0 and calls or nil,
        usage = { input = usage.promptTokenCount or 0, output = usage.candidatesTokenCount or 0,
            cached = usage.cachedContentTokenCount or 0 } }
end

local function vertex_token(cfg, deadline)
    local Webhooks = require("lib.outbound-webhooks")
    return LlmAuth.google_token(cfg.sa, function(url, form)
        local target, terr = Webhooks.parseUrl(url, { allow_private = true, allow_http = true })
        if not target then return nil, "token URL " .. tostring(terr) end
        return Webhooks.fetch(target, { method = "POST", body = form, ssl_verify = Llm.tls_verify(),
            headers = { ["Content-Type"] = "application/x-www-form-urlencoded" } }, { deadline = deadline })
    end)
end

local function vertex_chat(cfg, messages, tools, opts)
    local token, terr, tstatus = vertex_token(cfg, opts.deadline)
    if not token then return nil, "vertex: " .. tostring(terr), tstatus end
    local base = cfg.url .. "/v1/projects/" .. LlmAuth.uri_encode(cfg.project) .. "/locations/"
        .. LlmAuth.uri_encode(cfg.location)
    if tostring(cfg.model):match("^claude") then
        -- Anthropic on Vertex: the Messages API body, the model in the URL.
        local c = setmetatable({ messages_url = base .. "/publishers/anthropic/models/" .. cfg.model .. ":rawPredict",
            messages_headers = { Authorization = "Bearer " .. token },
            messages_body = { anthropic_version = "vertex-2023-10-16" } }, { __index = cfg })
        return anthropic_chat(c, messages, tools, opts)
    end
    local url = base .. "/publishers/google/models/" .. cfg.model .. ":generateContent"
    local data, err, status = post(cfg, url, { Authorization = "Bearer " .. token },
        Llm.gemini_body(messages, tools, opts), opts.deadline)
    if not data then return nil, err, status end
    return Llm.gemini_message(data)
end

local ADAPTERS = { ollama = ollama_chat, openai = openai_chat, anthropic = anthropic_chat,
    bedrock = bedrock_chat, vertex = vertex_chat }

-- ---------------------------------------------------------------------------
-- Metering (ai_usage) and the optional per-user daily limit
-- ---------------------------------------------------------------------------

local DAILY_LIMIT = tonumber(env("AI_USER_DAILY_TOKEN_LIMIT") or "")
Llm.LIMIT_MESSAGE = "You've reached today's AI usage limit. It resets at midnight UTC; "
    .. "ask a workspace admin if you need more."

local function attribution(opts)
    local u = opts.usage or {}
    local ctx = (not u.system and ngx.ctx) or {}
    return u, u.user_uuid or (type(ctx.user) == "table" and ctx.user.uuid) or nil, u.namespace_id or ctx.namespace_id
end

-- Never fails the AI call: a lost row is logged, not raised.
local function record(cfg, u, user, ns, msg, err, ms)
    local ok_db, db = pcall(require, "lapis.db")
    if not ok_db then return end
    local usage = msg and msg.usage or {}
    local ok, ierr = pcall(db.insert, "ai_usage", {
        namespace_id = ns, user_uuid = user, feature = u.feature or "other", scope = u.scope,
        run_uuid = u.run_uuid, provider = cfg.provider, model = cfg.model,
        input_tokens = usage.input or 0, output_tokens = usage.output or 0, cached_input_tokens = usage.cached or 0,
        latency_ms = ms or 0,
        ok = msg ~= nil, error = (not msg and err) and tostring(err):sub(1, 300) or nil,
    })
    if not ok then ngx.log(ngx.ERR, "[llm] usage not recorded: ", tostring(ierr)) end
end

--- Meter a call made outside Llm.chat (e.g. a provider's own API): cfg { provider, model }, u { feature,
-- run_uuid, scope? }, msg { usage = { input, output } } or nil with err, ms. Never fails.
function Llm.meter(cfg, u, user, ns, msg, err, ms)
    record(cfg, u or {}, user, ns, msg, err, ms)
end

local function over_limit(user)
    if not DAILY_LIMIT or not user then return false end
    local ok, rows = pcall(function()
        return require("lapis.db").query([[
            SELECT COALESCE(SUM(input_tokens + output_tokens), 0) AS used FROM ai_usage
            WHERE user_uuid = ? AND created_at >= date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
              AND feature <> 'web_terminal' -- Claude in a web terminal is counted, not limited, here (§11.3)
        ]], user)
    end)
    return ok and rows[1] ~= nil and tonumber(rows[1].used) >= DAILY_LIMIT
end

-- ---------------------------------------------------------------------------
-- Circuit breaker: a provider (the main one, or a chain hop) that is down is
-- skipped for a minute, shared by every worker (ngx.shared.cache). A workspace
-- provider's key is its own (its URL and key are the workspace's).
-- ---------------------------------------------------------------------------

local BREAKER_SECONDS = 60
Llm.BREAKER_SECONDS = BREAKER_SECONDS

local function breaker(cfg)
    local cache = ngx.shared and ngx.shared.cache
    return cache, cfg.breaker_key or ("ai:down:" .. cfg.provider .. ":" .. tostring(cfg.model)
        .. (cfg.workspace_provider and (":" .. cfg.workspace_provider) or ""))
end

local function is_open(cfg)
    local cache, key = breaker(cfg)
    return cache ~= nil and cache:get(key) ~= nil
end
Llm.is_down = is_open -- is this provider / hop's circuit open (skipped for now)?

-- Failures that mean the provider itself is unusable right now (not this one
-- request): no answer / timeout, 5xx, rate limit, bad key, unknown model.
local function provider_down(status)
    return status == nil or status >= 500 or status == 429 or status == 401 or status == 403 or status == 404
end

-- deadline: ngx.now() by which this attempt must be done (adapters read opts.deadline).
local function attempt(cfg, messages, tools, opts, u, user, ns, deadline)
    ngx.update_time()
    local started = ngx.now()
    if deadline <= started then return nil, "Model request failed: timeout (no time left)" end
    local adapter = ADAPTERS[cfg.protocol or cfg.provider]
    if not adapter then return nil, "No adapter for provider '" .. tostring(cfg.provider) .. "'" end
    local ok, msg, err, status = pcall(adapter, cfg, messages, tools,
        setmetatable({ deadline = deadline }, { __index = opts }))
    if not ok then -- a bug in one adapter must not stop the chain
        ngx.log(ngx.ERR, "[llm] ", cfg.provider, " adapter error: ", tostring(msg))
        msg, err, status = nil, cfg.provider .. ": " .. tostring(msg):sub(1, 200), nil
    end
    ngx.update_time()
    record(cfg, u, user, ns, msg, err, math.floor((ngx.now() - started) * 1000))
    if msg then msg.model, msg.provider = cfg.model, cfg.provider end
    return msg, err, status
end

--- The hops one call may use, in order: tool-using calls skip hops that can't call tools.
local function hops_for(cfg, tools, opts)
    -- A workspace's own provider never falls back to the platform's model (see the header).
    if opts.no_fallback or cfg.workspace_provider then return {} end
    local out = {}
    for _, hop in ipairs(Llm.chain_for(opts.usage and opts.usage.feature)) do
        if not same(hop, cfg) and (hop.tools ~= false or not (tools and #tools > 0)) then out[#out + 1] = hop end
    end
    return out
end

--- One model round-trip (see the header for the message format and opts).
function Llm.chat(messages, tools, opts)
    opts = opts or {}
    local cfg = opts.cfg or Llm.default
    local u, user, ns = attribution(opts)
    if over_limit(user) then
        record(cfg, u, user, ns, nil, "daily limit reached", 0)
        return nil, Llm.LIMIT_MESSAGE, 429
    end
    ngx.update_time()
    local budget = (opts.timeout_ms or (ngx.get_phase() == "timer" and Llm.TIMEOUT_MS or REQUEST_TIMEOUT_MS)) / 1000
    local deadline = ngx.now() + budget

    -- Who to try, in order: the main provider unless its breaker is open, then every
    -- chain hop whose breaker is closed (the legacy single fallback has none).
    local hops = hops_for(cfg, tools, opts)
    local order = {}
    if #hops == 0 or not is_open(cfg) then order[1] = cfg end
    for _, hop in ipairs(hops) do
        if hop.legacy or not is_open(hop) then order[#order + 1] = hop end
    end
    if #order == 0 then order[1] = cfg end -- everything is marked down: try the main provider anyway

    local first_err, first_status, notes = nil, nil, {}
    for i, c in ipairs(order) do
        ngx.update_time()
        local left = deadline - ngx.now()
        local remaining = #order - i + 1
        -- With fallbacks still to come, the main provider keeps 2/3 of the budget and each
        -- hop an equal share of what is left; the last one gets all of it.
        local share = remaining == 1 and left or (c == cfg and left * 2 / 3 or left / remaining)
        local msg, err, status = attempt(c, messages, tools, opts, u, user, ns, ngx.now() + share)
        if msg then
            if c == cfg then
                if opts.no_fallback then -- the health check saw it recover
                    local cache, key = breaker(cfg)
                    if cache then cache:delete(key) end
                end
            else
                msg.fallback, msg.hop = true, c.name
            end
            return msg
        end
        if #order == 1 then return nil, err, status end
        local cache, key = breaker(c)
        if cache and not c.legacy and provider_down(status) then cache:set(key, true, BREAKER_SECONDS) end
        if not first_err then
            first_err, first_status = err, status
        else
            notes[#notes + 1] = " (fallback " .. tostring(c.model) .. " also failed: " .. tostring(err) .. ")"
        end
        local nxt = order[i + 1]
        ngx.log(ngx.WARN, "[llm] ", c.name or c.provider, " ", c.provider, " ", tostring(c.model), " failed (",
            tostring(err):sub(1, 200), ")", nxt and ("; falling back to " .. (nxt.name or nxt.provider) .. " "
            .. nxt.provider .. " " .. tostring(nxt.model)) or "; no fallback left")
    end
    return nil, tostring(first_err) .. table.concat(notes), first_status
end

--- The configured chain, for operators (never a key or token): the main provider,
-- every hop named in AI_FALLBACK_CHAIN / AI_FALLBACK_CHAIN_BY_FEATURE with whether
-- it is configured (and why not), can call tools, and is down (circuit open).
function Llm.chain_status()
    local function row(c, role)
        local host = tostring(c.chat_url or c.url or ""):match("^%a+://([^/?#]+)")
        return { name = c.name or role, provider = c.provider, label = c.label, model = c.model, host = host,
            configured = Llm.configured(c), reason = c.missing,
            enabled = c.enabled ~= false, tools = c.tools ~= false,
            circuit_open = not c.legacy and is_open(c) or false }
    end
    local in_chain = {}
    for _, c in ipairs(Llm.chain) do in_chain[c.name] = true end
    local hops = {}
    if Llm.chain_source == "AI_FALLBACK_CHAIN" then
        for _, name in ipairs(Llm.chain_names) do
            local c = Llm.hops[name]
            local r = row(c, name)
            r.active = in_chain[name] == true
            if not r.active and not r.reason then
                r.reason = c.enabled == false and "disabled (enabled=false)" or "same model as the main provider"
            end
            hops[#hops + 1] = r
        end
    elseif Llm.fallback then
        local r = row(Llm.fallback, "fallback")
        r.active = true
        hops[1] = r
    end
    local by_feature = {}
    for feature, chain in pairs(Llm.chain_by_feature) do
        local names = {}
        for i, c in ipairs(chain) do names[i] = c.name end
        by_feature[feature] = names
    end
    return { main = row(Llm.default, "main"), source = Llm.chain_source, hops = hops,
        by_feature = by_feature, breaker_seconds = BREAKER_SECONDS }
end

return Llm
