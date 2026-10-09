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
      jobshout           —                              required (JobShout server; username + password)

    Secrets are sealed with AES-256-GCM (helper/secret-box.lua) and never
    returned: a browser sees `has_secret` and `secret_hint` ("…a1b2").

    URLs must resolve to public addresses unless OPSAPI_AI_ALLOW_PRIVATE=true
    (set it where local LLMs run on the private network, e.g. Ollama on the LAN).

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
    openai_compatible = { adapter = "openai", needs_url = true },
    ollama = { adapter = "openai", url = "http://localhost:11434/v1", is_local = true },
    jobshout = { needs_url = true, user = true },
}

local function null(v) return v == nil or v == db.NULL end
local function blank(v) return null(v) or v == "" end

local function allow_private()
    return os.getenv("OPSAPI_AI_ALLOW_PRIVATE") == "true"
end

--- Can the server call this URL? (SSRF guard, checked on save and on every call.)
function Providers.url_ok(url)
    if type(url) ~= "string" then return nil, "base_url is required" end
    local scheme, host = url:match("^(https?)://([^/:?#]+)")
    if not scheme then return nil, "base_url must start with http:// or https://" end
    if allow_private() then return true end
    if scheme ~= "https" then return nil, "base_url must use https (or set OPSAPI_AI_ALLOW_PRIVATE for a local server)" end
    if host == "localhost" or host:match("%.local$") or host:match("%.internal$") or host:match("%.svc$")
        or not host:find(".", 1, true) then
        return nil, "base_url must be a public server (or set OPSAPI_AI_ALLOW_PRIVATE for a local one)"
    end
    local Webhooks = require("lib.outbound-webhooks")
    local ips, err = Webhooks.resolve(host)
    if not ips then return nil, "base_url: " .. tostring(err) end
    for _, ip in ipairs(ips) do
        if not Webhooks.isPublicIPv4(ip) then return nil, "base_url must not resolve to a private address" end
    end
    return true
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
        .. "openai_compatible, ollama, jobshout" end
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
        else row.secret_sealed, row.secret_hint = Box.seal(b.secret, PURPOSE), Box.hint(b.secret) end
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
    if existing then
        db.update("namespace_ai_providers", row, { id = existing.id })
        return Providers.get(ns, existing.uuid)
    end
    row.namespace_id, row.created_by = ns, actor
    local ok, res = pcall(db.insert, "namespace_ai_providers", row, { returning = "*" })
    if not ok then
        if tostring(res):find("duplicate key", 1, true) then return nil, { name = "already used in this workspace" } end
        error(res)
    end
    return res[1]
end

function Providers.secret(row)
    if not row or blank(row.secret_sealed) then return nil end
    local plain, err = Box.open(row.secret_sealed, PURPOSE)
    if not plain then ngx.log(ngx.ERR, "[ai-providers] ", row.uuid, ": ", err) end
    return plain
end

--- Llm.chat config for a provider row (nil, err for jobshout or a bad URL).
function Providers.cfg(row, model)
    local spec = Providers.TYPES[row.provider_type]
    if not spec or not spec.adapter then return nil, row.provider_type .. " is not a model provider" end
    local url = (not blank(row.base_url) and row.base_url or spec.url or ""):gsub("/+$", "")
    local ok, err = Providers.url_ok(url)
    if not ok then return nil, err end
    local opts = decode(row.options)
    model = not blank(model) and model or (not blank(row.default_model) and row.default_model) or nil
    local key = Providers.secret(row)
    if not key and not blank(row.secret_sealed) then
        return nil, row.name .. ": the stored key can't be decrypted (tampered, or the deployment key changed); save it again"
    end
    local cfg = { provider = spec.adapter, label = row.name, model = model, key = key, url = url }
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
                local msg, err = Llm.chat(messages, tools, {
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
                attempts[#attempts + 1] = { provider_uuid = row.uuid, model = cfg.model, error = tostring(err):sub(1, 300) }
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
    local msg, info = Providers.chat(ns, { { provider_uuid = row.uuid } },
        { { role = "user", content = "Reply with the single word: ok" } }, nil,
        { feature = "provider_test", max_tokens = 16, timeout_ms = 30000 })
    local err = not msg and info or nil
    db.update("namespace_ai_providers", { last_tested_at = db.raw("NOW()"), last_error = err or db.NULL }, { id = row.id })
    if not msg then return nil, err end
    return { ok = true, model = info.model, latency_ms = info.latency_ms, reply = (msg.content or ""):sub(1, 80) }
end

return Providers
