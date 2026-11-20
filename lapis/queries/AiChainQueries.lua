--[[
    The platform's AI try-order (core): which configured models are tried, in
    what order, for every AI feature — set by platform admins in the dashboard
    (Workspace → AI models → Platform fallback chain). Stored in
    ai_chain_settings; read at runtime by lib/agent/llm.lua (Llm.saved_chains).

    Keys and endpoints never pass through here: they stay in env / Vault
    (AI_PROVIDER, BEDROCK_*, ANTHROPIC_API_KEY, AI_HOPS …). A new model is wired
    in by adding it there (e.g. a custom OpenAI-compatible host in AI_HOPS);
    it then shows up in this page's catalogue to be placed in a chain.

    A hop is { name, model?, enabled }: name = a built-in provider (ollama,
    anthropic, openai, google, bedrock, azure, vertex) or a custom hop name;
    model = optional, another model on that provider (e.g. Bedrock Haiku as a
    cheaper second hop after Bedrock Sonnet).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Llm = require("lib.agent.llm")

local Q = {}

-- What each scope covers. "default" = every call that would use the main model; the others are usage
-- features (the `feature` each caller meters under — see lib/agent/llm.lua).
Q.SCOPES = {
    { key = "default", label = "All AI features",
        description = "Used by every AI feature without a chain of its own below." },
    { key = "tax_classify", label = "Tax: classifying transactions",
        description = "Sorting bank transactions into tax categories. A fast, cheap model is fine here." },
    { key = "statement_extract", label = "Tax: reading bank statements",
        description = "Reading statement images and PDFs. Every model here must accept images (vision).",
        vision = true },
    { key = "assistant", label = "AI assistant",
        description = "The chat assistant. Models that can't call tools are skipped here.", tools = true },
}

local SCOPE_BY_KEY = {}
for _, s in ipairs(Q.SCOPES) do SCOPE_BY_KEY[s.key] = s end

local MAX_HOPS = 10

--- The model a scope's callers ask for before any chain (statement reading asks for the vision model).
local function base_cfg(scope)
    return SCOPE_BY_KEY[scope] and SCOPE_BY_KEY[scope].vision and Llm.vision or Llm.default
end

local function hop_out(c)
    local d = Llm.describe(c)
    d.name = c.name or c.provider -- the main / vision model carries no hop name: its provider is its name
    d.is_main = c.name == Llm.main_name or (c.provider == Llm.default.provider and c.model == Llm.default.model)
    return d
end

--- Every model a chain may use, as operators may see it (never a key).
function Q.catalogue()
    local out = {}
    for _, name in ipairs(Llm.known_hop_names()) do
        local c = Llm.resolve_hop(name)
        local d = hop_out(c)
        d.name = name
        out[#out + 1] = d
    end
    return out
end

local function env_hops(scope)
    local feature = scope ~= "default" and scope or nil
    local cfg = base_cfg(scope)
    -- The env order: the model the caller asks for, then the env chain for this feature (or the global one).
    local list = { { name = cfg.name or cfg.provider, model = cfg.model, enabled = true } }
    for _, h in ipairs(Llm.chain_for(feature)) do
        if h.name ~= cfg.name then list[#list + 1] = { name = h.name, model = h.model, enabled = true } end
    end
    return list
end

--- Each scope: its saved chain (if any), what env alone gives, and the order a call would try right now.
function Q.overview()
    local rows = db.query("SELECT scope, hops, updated_by, updated_at FROM ai_chain_settings")
    local saved = {}
    for _, r in ipairs(rows) do saved[r.scope] = r end
    local scopes = {}
    for _, s in ipairs(Q.SCOPES) do
        local row = saved[s.key]
        local hops = row and (type(row.hops) == "string" and cjson.decode(row.hops) or row.hops) or nil
        local plan, source = Llm.plan_for(s.key ~= "default" and s.key or nil, base_cfg(s.key))
        local effective = {}
        for i, c in ipairs(plan) do
            local d = hop_out(c)
            d.position = i
            effective[i] = d
        end
        scopes[#scopes + 1] = {
            key = s.key, label = s.label, description = s.description, vision = s.vision == true,
            tools = s.tools == true,
            saved = row ~= nil, hops = hops or env_hops(s.key), env_hops = env_hops(s.key),
            source = source, env_feature_chain = s.key ~= "default" and Llm.chain_by_feature[s.key] ~= nil,
            effective = effective,
            updated_by = row and row.updated_by ~= db.NULL and row.updated_by or nil,
            updated_at = row and row.updated_at or nil,
        }
    end
    return {
        scopes = scopes,
        catalogue = Q.catalogue(),
        main = Llm.main_name,
        vision = Llm.vision_name,
        breaker_seconds = Llm.BREAKER_SECONDS,
    }
end

--- A chain as sent by the dashboard -> { { name, model?, enabled }, … } | nil, error.
function Q.validate(scope, hops)
    if not SCOPE_BY_KEY[scope] then return nil, "unknown scope '" .. tostring(scope) .. "'" end
    if type(hops) ~= "table" or #hops == 0 then return nil, "hops must be a non-empty list" end
    if #hops > MAX_HOPS then return nil, "at most " .. MAX_HOPS .. " hops" end
    local known = {}
    for _, n in ipairs(Llm.known_hop_names()) do known[n] = true end
    local out, seen, enabled = {}, {}, 0
    for i, h in ipairs(hops) do
        if type(h) ~= "table" or type(h.name) ~= "string" or h.name == "" then
            return nil, "hop " .. i .. ": name is required"
        end
        if not known[h.name] then
            return nil, "hop " .. i .. ": unknown model '" .. h.name .. "' (add it to AI_HOPS in the environment first)"
        end
        local model = h.model
        if model == cjson.null or model == "" then model = nil end
        if model ~= nil and (type(model) ~= "string" or #model > 200 or not model:match("^[%w%._:/@%-]+$")) then
            return nil, "hop " .. i .. ": model must be a model id (letters, digits and . _ : / @ -)"
        end
        local on = h.enabled ~= false
        if h.enabled ~= nil and type(h.enabled) ~= "boolean" then
            return nil, "hop " .. i .. ": enabled must be true or false"
        end
        local key = h.name .. "|" .. (model or Llm.resolve_hop(h.name).model or "")
        if seen[key] then return nil, "hop " .. i .. ": " .. h.name .. " with that model is already in the chain" end
        seen[key] = true
        if on then enabled = enabled + 1 end
        out[#out + 1] = { name = h.name, model = model, enabled = on }
    end
    if enabled == 0 then return nil, "keep at least one hop enabled" end
    return out
end

--- Save a scope's chain (replaces it whole).
function Q.save(scope, hops, actor)
    local clean, err = Q.validate(scope, hops)
    if not clean then return nil, err end
    db.query([[
        INSERT INTO ai_chain_settings (scope, hops, updated_by, updated_at) VALUES (?, ?::jsonb, ?, NOW())
        ON CONFLICT (scope) DO UPDATE SET hops = EXCLUDED.hops, updated_by = EXCLUDED.updated_by,
            updated_at = NOW()
    ]], scope, cjson.encode(clean), actor or db.NULL)
    Llm.saved_changed()
    return Q.overview()
end

--- Forget a scope's saved chain: it goes back to the environment's order.
function Q.reset(scope)
    if not SCOPE_BY_KEY[scope] then return nil, "unknown scope '" .. tostring(scope) .. "'" end
    db.query("DELETE FROM ai_chain_settings WHERE scope = ?", scope)
    Llm.saved_changed()
    return Q.overview()
end

--- Try the hops in order, as a real call would, until one answers. Hops after the one that answers are
-- reported as not tried. A tiny prompt, billed to no one (usage.system).
-- @return { serving = name|nil, results = { { name, model, position, ok, latency_ms, error, skipped } } }
function Q.test(scope, hops)
    local list
    if hops ~= nil then
        local clean, err = Q.validate(scope or "default", hops)
        if not clean then return nil, err end
        list = clean
    else
        -- The saved chain as saved (unconfigured hops included, so the result says why they're skipped),
        -- else the environment's order.
        if not SCOPE_BY_KEY[scope] then return nil, "unknown scope '" .. tostring(scope) .. "'" end
        list = Llm.saved_chains()[scope] or env_hops(scope)
    end
    local results, serving = {}, nil
    for i, h in ipairs(list) do
        local c = Llm.resolve_hop(h.name, h.model)
        local r = { name = h.name, model = c.model, label = c.label, position = i }
        if not h.enabled then
            r.skipped = "disabled"
        elseif serving then
            r.skipped = "not tried (an earlier model answered)"
        elseif not Llm.configured(c) then
            r.skipped = "not configured: " .. tostring(c.missing or "no key / URL in the environment")
        else
            ngx.update_time()
            local started = ngx.now()
            local msg, err, status = Llm.chat({ { role = "user", content = "Reply with the single word: ok" } }, nil, {
                cfg = c, no_fallback = true, max_tokens = 16, timeout_ms = 30000,
                usage = { feature = "provider_test", system = true },
            })
            ngx.update_time()
            r.latency_ms = math.floor((ngx.now() - started) * 1000)
            if msg then
                r.ok, r.reply = true, tostring(msg.content or ""):sub(1, 60)
                serving = h.name
            else
                r.ok, r.status, r.error = false, status, tostring(err or "failed"):sub(1, 300)
            end
        end
        results[#results + 1] = r
    end
    return { serving = serving, results = results }
end

return Q
