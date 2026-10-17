--[[
    Workspace AI providers (core, gap map D11)
    ==========================================
    A workspace brings its own models: a cloud API with its own key, a local
    OpenAI-compatible server, or a JobShout link (an agent platform, not a
    model — callers that support it read the row; Providers.chat skips it).

      provider_type      adapter (lib/agent/llm.lua)   default base_url
      anthropic          anthropic                      https://api.anthropic.com
      openai             openai                         https://api.openai.com/v1
      gemini             openai                         https://generativelanguage.googleapis.com/v1beta/openai
      mistral            openai                         https://api.mistral.ai/v1
      azure_openai       openai (+ api-key header)      https://<resource>.openai.azure.com  (options.deployment,
                                                        options.api_version)
      openai_compatible  openai                         required: LM Studio, vLLM, llama.cpp server, LocalAI, …
      ollama             openai (Ollama's /v1)          http://localhost:11434/v1
      jobshout           —                              required (JobShout server; username + password, or a jsk_ API key)
      platform           the deployment's own model     — (AI_PROVIDER / OLLAMA_URL env: the self-hosted model the
                                                          chat assistant uses). Opt-in per workspace; only offered
                                                          when that model is self-hosted (Ollama), for GDPR. Only
                                                          models in AI_PLATFORM_MODELS (comma-separated; default:
                                                          the platform's own model) can be chosen.

    Secrets are sealed with AES-256-GCM (helper/secret-box.lua) and never
    returned: a browser sees `has_secret` and `secret_hint` ("…a1b2").

    URLs must resolve to public addresses. A model server on the private
    network (e.g. Ollama on the LAN) is allowed by listing it in
    OPSAPI_AI_PRIVATE_HOSTS (host or host:port, comma-separated).
    OPSAPI_AI_ALLOW_PRIVATE=true allows every private address: local
    development only (it is logged as a warning). Link-local addresses (cloud
    metadata) are always refused, and calls connect to the address that was
    checked, so DNS can't be swapped in between (Providers.target).

    Failures are reported as a short reason (Providers.reason: "Authentication
    failed (401) …", "Timed out", …), never the provider's own words: a URL's
    response must not be echoed back to the workspace. Details go to the log.

    Providers.chat(ns, chain, messages, tools, opts) tries each { provider_uuid,
    model } in order (the workspace's fallback order) and returns the first
    answer with the provider used and its cost. opts.local_only skips every
    provider not flagged is_local (data residency for sensitive work). The
    platform's own fallback model is never used: a workspace's data only goes
    where the workspace said.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Box = require("helper.secret-box")

local Providers = {}

local PURPOSE = "ai_provider"

Providers.TYPES = {
    anthropic = { adapter = "anthropic", url = "https://api.anthropic.com", key = true },
    openai = { adapter = "openai", url = "https://api.openai.com/v1", key = true },
    gemini = { adapter = "openai", url = "https://generativelanguage.googleapis.com/v1beta/openai", key = true },
    mistral = { adapter = "openai", url = "https://api.mistral.ai/v1", key = true },
    azure_openai = { adapter = "openai", key = true, needs_url = true },
    -- AWS Bedrock Runtime (OpenAI-compatible proxy URL, e.g. Bedrock Access Gateway / LiteLLM).
    bedrock = { adapter = "openai", needs_url = true, key = true, stream = true },
    -- xAI Grok
    xai = { adapter = "openai", url = "https://api.x.ai/v1", key = true },
    -- stream: local servers answer slowly; streaming keeps bytes flowing past proxies that cut silent connections.
    openai_compatible = { adapter = "openai", needs_url = true, stream = true },
    ollama = { adapter = "openai", url = "http://localhost:11434/v1", is_local = true, stream = true },
    jobshout = { needs_url = true, user = true },
    platform = { platform = true, is_local = true },
}

--- The deployment's own model, when it is self-hosted (Ollama). nil, reason otherwise.
function Providers.platform_cfg()
    local Llm = require("lib.agent.llm")
    local d = Llm.default
    if not d or d.provider ~= "ollama" then
        return nil, "the platform model is not self-hosted here (only a self-hosted Ollama can be shared)"
    end
    if not Llm.configured(d) then return nil, "no platform model is configured (OLLAMA_URL)" end
    return { provider = d.provider, label = "Platform model", model = d.model, key = d.key, url = d.url }
end

local function null(v) return v == nil or v == db.NULL end
local function blank(v) return null(v) or v == "" end

local function allow_private()
    return os.getenv("OPSAPI_AI_ALLOW_PRIVATE") == "true"
end
if allow_private() then
    ngx.log(ngx.WARN, "[ai-providers] OPSAPI_AI_ALLOW_PRIVATE=true: workspaces can point AI providers at ANY private ",
        "address (databases, cluster APIs). Development only: list model servers in OPSAPI_AI_PRIVATE_HOSTS instead.")
end

-- A private address this URL may reach: OPSAPI_AI_PRIVATE_HOSTS entries are host or host:port.
local function private_ok(t)
    if allow_private() then return true end
    for entry in (os.getenv("OPSAPI_AI_PRIVATE_HOSTS") or ""):lower():gmatch("[^,%s]+") do
        if entry == t.host or entry == t.host .. ":" .. t.port then return true end
    end
    return false
end

--- Vet a workspace's URL and resolve it once (SSRF guard, on save and on every call).
-- @return { scheme, host, port, path, ip } (connect to ip; host stays the Host/SNI) | nil, reason
function Providers.target(url)
    if type(url) ~= "string" or url == "" then return nil, "base_url is required" end
    local Webhooks = require("lib.outbound-webhooks")
    local parsed = Webhooks.parseUrl(url, { allow_private = true, allow_http = true })
    if not parsed then return nil, "base_url must be a URL starting with http:// or https://" end
    local private = private_ok(parsed)
    local t, err = Webhooks.target(url, { allow_private = private, allow_http = private })
    if t then return t end
    if err:find("private address", 1, true) then err = "base_url must not resolve to a private address" end
    err = err:gsub("^URL ", "base_url ")
    if not err:find("^base_url") then return nil, "base_url: " .. err end
    if not private then err = err .. " (a local model server can be listed in OPSAPI_AI_PRIVATE_HOSTS)" end
    return nil, err
end

--- Can the server call this URL? (Providers.target, for callers that only need yes/no.)
function Providers.url_ok(url)
    local t, err = Providers.target(url)
    if not t then return nil, err end
    return true
end

--- request_uri for a workspace's URL: same guard, connected to the checked address.
-- @return { status, headers, body } | nil, err (a base_url rule, or a network error to classify)
function Providers.request(url, params, timeout_ms)
    local t, err = Providers.target(url)
    if not t then return nil, err end
    return require("lib.outbound-webhooks").fetch(t, params, { timeout_ms = timeout_ms })
end

--- A failed call as a workspace may see it. Never the server's own words: they can echo whatever a URL
-- returned, so the details stay in the log.
function Providers.reason(err, status)
    err, status = tostring(err or ""), tonumber(status)
    if err:find("^base_url") then return err end -- our own URL rule
    if err == require("lib.agent.llm").LIMIT_MESSAGE then return err end
    if status == 401 or status == 403 then return "Authentication failed (" .. status .. ") — check the API key" end
    if status == 404 then return "Not found (404) — check the model name and URL" end
    if status == 429 then return "Rate limited (429) — try again shortly" end
    if status and status >= 500 then return "The server had an error (HTTP " .. status .. ")" end
    if status then return "The request was refused (HTTP " .. status .. ")" end
    if err:find("timeout", 1, true) then return "Timed out" end
    if err:find("connect", 1, true) or err:find("request failed", 1, true) then return "Couldn't connect" end
    return "Unexpected answer from the server"
end

--- Models a workspace may run on the platform's shared model server: AI_PLATFORM_MODELS
-- (comma-separated), default the platform's own model. Anything else could load arbitrary large models.
function Providers.platform_models()
    local list = {}
    for m in (os.getenv("AI_PLATFORM_MODELS") or ""):gmatch("[^,%s]+") do list[#list + 1] = m end
    if #list == 0 then list[1] = require("lib.agent.llm").default.model end
    return list
end

local function platform_model_ok(model)
    for _, m in ipairs(Providers.platform_models()) do
        if m == model then return true end
    end
    return false
end

local function decode(v)
    if type(v) == "table" then return v end
    if type(v) ~= "string" then return {} end
    local ok, t = pcall(cjson.decode, v)
    return ok and type(t) == "table" and t or {}
end

--- What the API returns: everything but the sealed secret.
function Providers.present(row)
    if not row then return nil end
    local out = {}
    for k, v in pairs(row) do
        if k ~= "secret_sealed" and k ~= "id" and k ~= "namespace_id" and not null(v) then out[k] = v end
    end
    out.has_secret = not blank(row.secret_sealed)
    out.models = decode(row.models)
    out.options = decode(row.options)
    return out
end

function Providers.list(ns, only_enabled)
    return db.query("SELECT * FROM namespace_ai_providers WHERE namespace_id = ?"
        .. (only_enabled and " AND enabled" or "") .. " ORDER BY name", ns)
end

function Providers.get(ns, uuid)
    if type(uuid) ~= "string" or not uuid:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then return nil end
    return db.query("SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", ns, uuid)[1]
end

local function num(v)
    local n = tonumber(v)
    return n and n >= 0 and n or nil
end

--- Create (existing = nil) or update. Only the fields sent change; `secret`
-- replaces the stored one ("" clears it). Returns the row or nil, errors table.
function Providers.save(ns, actor, b, existing)
    local errors, row = {}, {}
    local ptype = b.provider_type or (existing and existing.provider_type)
    local spec = Providers.TYPES[ptype or ""]
    if not spec then errors.provider_type = "one of anthropic, openai, gemini, azure_openai, mistral, "
        .. "bedrock, xai, openai_compatible, ollama, jobshout, platform" end
    if spec and spec.platform then
        local ok, why = Providers.platform_cfg()
        if not ok then errors.provider_type = why end
        if b.base_url ~= nil and b.base_url ~= "" and b.base_url ~= cjson.null then
            errors.base_url = "the platform model has no URL to set"
        end
        local asked = {}
        for _, m in ipairs(type(b.models) == "table" and b.models or {}) do asked[#asked + 1] = m end
        if type(b.default_model) == "string" and b.default_model ~= "" then asked[#asked + 1] = b.default_model end
        for _, m in ipairs(asked) do
            if not platform_model_ok(m) then
                errors.default_model = "the platform model server offers only: "
                    .. table.concat(Providers.platform_models(), ", ")
            end
        end
    end
    if not existing or b.name ~= nil then
        if type(b.name) ~= "string" or b.name == "" or #b.name > 120 then errors.name = "required, up to 120 characters"
        else row.name = b.name end
    end
    if b.provider_type ~= nil then row.provider_type = b.provider_type end
    if b.base_url ~= nil then row.base_url = (b.base_url ~= "" and b.base_url ~= cjson.null) and b.base_url or db.NULL end
    local url = row.base_url or (existing and existing.base_url)
    if null(url) then url = nil end
    if spec and spec.needs_url and not url then errors.base_url = "required for " .. ptype end
    if url then
        local ok, err = Providers.url_ok(url)
        if not ok then errors.base_url = err end
    end
    if b.default_model ~= nil then row.default_model = b.default_model ~= "" and b.default_model or db.NULL end
    if b.models ~= nil then
        if type(b.models) ~= "table" then errors.models = "list of model ids" else row.models = cjson.encode(b.models) end
    end
    if b.options ~= nil then
        if type(b.options) ~= "table" then errors.options = "object" else row.options = cjson.encode(b.options) end
    end
    if ptype == "azure_openai" then
        local opts = b.options or decode(existing and existing.options)
        if blank(opts.deployment) and blank(row.default_model or (existing and existing.default_model)) then
            errors.options = "azure_openai needs options.deployment (or default_model as the deployment name)"
        end
    end
    if b.username ~= nil then row.username = b.username ~= "" and b.username or db.NULL end
    if spec and spec.user and blank(row.username or (existing and existing.username)) then
        errors.username = "required for " .. ptype
    end
    if b.secret ~= nil then
        if b.secret == "" or b.secret == cjson.null then row.secret_sealed, row.secret_hint = db.NULL, db.NULL
        elseif type(b.secret) ~= "string" then errors.secret = "string"
        else
            local ok, sealed = pcall(Box.seal, b.secret, PURPOSE)
            if ok then row.secret_sealed, row.secret_hint = sealed, Box.hint(b.secret)
            else
                ngx.log(ngx.ERR, "[ai-providers] can't seal a secret: ", tostring(sealed))
                errors.secret = "can't be stored on this server right now (encryption isn't configured)"
            end
        end
    end
    if b.is_local ~= nil then row.is_local = b.is_local == true
    elseif not existing and spec then row.is_local = spec.is_local == true end
    if b.enabled ~= nil then row.enabled = b.enabled ~= false end
    for _, k in ipairs({ "input_cost_per_mtok", "output_cost_per_mtok" }) do
        if b[k] ~= nil then
            if not num(b[k]) then errors[k] = "a number ≥ 0 (USD per million tokens)" else row[k] = num(b[k]) end
        end
    end
    if next(errors) then return nil, errors end
    row.updated_by, row.updated_at = actor, db.raw("NOW()")
    local saved
    if existing then
        db.update("namespace_ai_providers", row, { id = existing.id })
        saved = Providers.get(ns, existing.uuid)
    else
        row.namespace_id, row.created_by = ns, actor
        local ok, res = pcall(db.insert, "namespace_ai_providers", row, { returning = "*" })
        if not ok then
            if tostring(res):find("duplicate key", 1, true) then return nil, { name = "already used in this workspace" } end
            error(res)
        end
        saved = res[1]
    end
    -- The assistant's model, or what it runs on, changed: it has to take a tool call, or every Ask AI turn fails.
    local now_opts = decode(saved.options)
    if now_opts.assistant == true and (decode(existing and existing.options).assistant ~= true
            or b.default_model ~= nil or b.base_url ~= nil or b.secret ~= nil or b.provider_type ~= nil) then
        local ok, why = Providers.assistant_ok(ns, saved)
        if not ok then
            now_opts.assistant = false
            db.update("namespace_ai_providers", { options = cjson.encode(now_opts) }, { id = saved.id })
            return nil, { options = saved.name .. " can't run the AI assistant (" .. why .. "). It needs a chat "
                .. "model that can call tools, not a speech, image or embedding model; the rest was saved." }
        end
    end
    return saved
end

-- A tool the assistant check offers; answering in text instead of calling it is fine too.
local PROBE_TOOL = { type = "function", ["function"] = { name = "ping", description = "Call this to answer.",
    parameters = { type = "object", properties = {} } } }

--- Can this provider run the assistant? One small request with a tool: a provider that refuses it (a model
-- without tool calling, a wrong model name, a bad key) can't. Timeouts, rate limits and server errors say
-- nothing about the model, so they don't count against it.
function Providers.assistant_ok(ns, row)
    local msg, _, attempts = Providers.chat(ns, { { provider_uuid = row.uuid } },
        { { role = "user", content = "Call the ping tool." } }, { PROBE_TOOL },
        { feature = "provider_test", max_tokens = 64, timeout_ms = 30000 })
    if msg then return true end
    local last = attempts and attempts[#attempts] or {}
    local status = tonumber(last.status)
    if status and status >= 400 and status < 500 and status ~= 408 and status ~= 429 then return nil, last.error end
    if last.error and not status and last.error:find(" has no model set", 1, true) then return nil, last.error end
    return true
end

function Providers.secret(row)
    if not row or blank(row.secret_sealed) then return nil end
    local plain, err = Box.open(row.secret_sealed, PURPOSE)
    if not plain then ngx.log(ngx.ERR, "[ai-providers] ", row.uuid, ": ", err) end
    return plain
end

--- Llm.chat config for a provider row (nil, err for jobshout or a missing key/model). It carries
-- workspace_provider (the row's uuid): lib/agent/llm then never falls back to the platform's model and
-- keeps its circuit breaker per provider; user_url: the URL is SSRF-checked and pinned on every call.
function Providers.cfg(row, model)
    local spec = Providers.TYPES[row.provider_type]
    if spec and spec.platform then
        local cfg, err = Providers.platform_cfg()
        if not cfg then return nil, err end
        if not blank(model) then cfg.model = model elseif not blank(row.default_model) then cfg.model = row.default_model end
        if not platform_model_ok(cfg.model) then return nil, "the platform model server doesn't offer " .. cfg.model end
        cfg.workspace_provider = row.uuid
        return cfg
    end
    if not spec or not spec.adapter then return nil, row.provider_type .. " is not a model provider" end
    local url = (not blank(row.base_url) and row.base_url or spec.url or ""):gsub("/+$", "")
    local opts = decode(row.options)
    model = not blank(model) and model or (not blank(row.default_model) and row.default_model) or nil
    local key = Providers.secret(row)
    if not key and not blank(row.secret_sealed) then
        return nil, row.name .. ": the stored key can't be opened (tampered, or the deployment key changed); "
            .. "save it again"
    end
    local cfg = { provider = spec.adapter, label = row.name, model = model, key = key, url = url,
        workspace_provider = row.uuid, user_url = true, stream = spec.stream }
    if row.provider_type == "azure_openai" then
        local deployment = not blank(opts.deployment) and opts.deployment or model
        cfg.chat_url = url .. "/openai/deployments/" .. ngx.escape_uri(deployment)
            .. "/chat/completions?api-version=" .. ngx.escape_uri(opts.api_version or "2024-10-21")
        cfg.headers = { ["api-key"] = key }
        cfg.model = cfg.model or deployment
    end
    if not cfg.model then return nil, row.name .. " has no model set" end
    return cfg
end

function Providers.cost(row, usage)
    usage = usage or {}
    return ((usage.input or 0) * (tonumber(row.input_cost_per_mtok) or 0)
        + (usage.output or 0) * (tonumber(row.output_cost_per_mtok) or 0)) / 1e6
end

--- Try each { provider_uuid, model } in turn. opts: local_only, feature, json,
-- max_tokens, temperature, timeout_ms, user_uuid, run_uuid.
-- @return msg, info { provider_uuid, provider_type, provider_name, model, cost_usd, attempts } | nil, err, attempts
function Providers.chat(ns, chain, messages, tools, opts)
    opts = opts or {}
    local Llm = require("lib.agent.llm")
    local attempts = {}
    for _, link in ipairs(chain or {}) do
        local row = Providers.get(ns, link.provider_uuid)
        local skip
        if not row then skip = "provider not found"
        elseif not row.enabled then skip = "disabled"
        elseif row.provider_type == "jobshout" then skip = "JobShout is not a model provider"
        elseif opts.local_only and not row.is_local then skip = "not local (this job is local-only)" end
        if skip then
            attempts[#attempts + 1] = { provider_uuid = link.provider_uuid, skipped = skip }
        else
            local cfg, cerr = Providers.cfg(row, link.model)
            if not cfg then
                attempts[#attempts + 1] = { provider_uuid = row.uuid, error = cerr }
            else
                ngx.update_time()
                local started = ngx.now()
                local msg, err, status = Llm.chat(messages, tools, {
                    cfg = cfg, no_fallback = true, json = opts.json, max_tokens = opts.max_tokens,
                    temperature = opts.temperature, timeout_ms = opts.timeout_ms,
                    usage = { feature = opts.feature or "workspace_ai", namespace_id = ns,
                        user_uuid = opts.user_uuid, run_uuid = opts.run_uuid },
                })
                ngx.update_time()
                local ms = math.floor((ngx.now() - started) * 1000)
                if msg then
                    local info = { provider_uuid = row.uuid, provider_type = row.provider_type, provider_name = row.name,
                        model = cfg.model, cost_usd = Providers.cost(row, msg.usage), latency_ms = ms,
                        attempts = attempts }
                    return msg, info
                end
                ngx.log(ngx.WARN, "[ai-providers] ", row.uuid, " ", tostring(cfg.model), ": ",
                    tostring(err):sub(1, 300))
                attempts[#attempts + 1] = { provider_uuid = row.uuid, model = cfg.model, status = status,
                    error = Providers.reason(err, status) }
            end
        end
    end
    if #attempts == 0 then return nil, "no AI provider is set for this job", attempts end
    local last = attempts[#attempts]
    return nil, "every provider failed (last: " .. tostring(last.error or last.skipped) .. ")", attempts
end

--- One tiny request, recorded on the row.
function Providers.test(ns, row)
    if row.provider_type == "jobshout" then
        local ok, JobShout = pcall(require, "lib.jobshout-client")
        if not ok then return nil, "JobShout client unavailable" end
        local res, err = JobShout.ping(ns, row)
        db.update("namespace_ai_providers", { last_tested_at = db.raw("NOW()"), last_error = res and db.NULL or err },
            { id = row.id })
        return res, err
    end
    local msg, info, attempts = Providers.chat(ns, { { provider_uuid = row.uuid } },
        { { role = "user", content = "Reply with the single word: ok" } }, nil,
        { feature = "provider_test", max_tokens = 16, timeout_ms = 30000 })
    local last = not msg and attempts and attempts[#attempts]
    local err = not msg and (last and (last.error or last.skipped) or info) or nil
    db.update("namespace_ai_providers", { last_tested_at = db.raw("NOW()"), last_error = err or db.NULL }, { id = row.id })
    if not msg then return nil, err end
    return { ok = true, model = info.model, latency_ms = info.latency_ms, reply = (msg.content or ""):sub(1, 80) }
end

return Providers
