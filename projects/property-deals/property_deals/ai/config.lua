-- Per-workspace AI settings: the model chain per job type (property_deals_ai_routes),
-- per-agent settings (property_deals_agent_configs) and the cost caps
-- (plugin settings ai_max_cost_run_usd / ai_max_cost_day_usd, USD).
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")

local C = {}

C.JOB_TYPES = { "classify", "extract", "draft", "plan", "chat", "summarise" }

local function null(v) return v == nil or v == db.NULL end

--- { chain = { {provider_uuid, model}… }, local_only, max_tokens } for a job type.
-- Without a route of its own a job uses the "draft" route, then any enabled
-- model provider in name order (so one provider is enough to get started).
function C.route(ns, job_type)
    local r = U.one("SELECT * FROM property_deals_ai_routes WHERE namespace_id = ? AND job_type = ?", ns, job_type)
        or (job_type ~= "draft" and U.one("SELECT * FROM property_deals_ai_routes WHERE namespace_id = ? AND job_type = 'draft'", ns))
    if r then
        return { chain = U.json(r.chain) or {}, local_only = r.local_only, max_tokens = not null(r.max_tokens) and r.max_tokens or nil,
            job_type = r.job_type }
    end
    local chain = {}
    for _, p in ipairs(db.query([[
        SELECT uuid FROM namespace_ai_providers
        WHERE namespace_id = ? AND enabled AND provider_type <> 'jobshout' ORDER BY is_local, name
    ]], ns)) do chain[#chain + 1] = { provider_uuid = p.uuid } end
    return { chain = chain, local_only = false, job_type = job_type, implicit = true }
end

function C.routes(ns)
    local out = {}
    for _, r in ipairs(db.query("SELECT * FROM property_deals_ai_routes WHERE namespace_id = ? ORDER BY job_type", ns)) do
        r.chain = U.json(r.chain)
        r.id, r.namespace_id = nil, nil
        out[#out + 1] = r
    end
    return U.array(out)
end

--- Upsert one job type's route. Every provider in the chain must be this workspace's.
function C.save_route(ns, job_type, b)
    local ok_type = false
    for _, t in ipairs(C.JOB_TYPES) do if t == job_type then ok_type = true end end
    if not ok_type then return nil, { job_type = "one of " .. table.concat(C.JOB_TYPES, ", ") } end
    if type(b.chain) ~= "table" or #b.chain == 0 then return nil, { chain = "a list of { provider_uuid, model? }" } end
    local chain = {}
    for i, link in ipairs(b.chain) do
        if type(link) ~= "table" or not U.is_uuid(link.provider_uuid) then
            return nil, { chain = "item " .. i .. " needs provider_uuid" }
        end
        local p = U.one("SELECT provider_type FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", ns, link.provider_uuid)
        if not p then return nil, { chain = "item " .. i .. ": provider not found in this workspace" } end
        if p.provider_type == "jobshout" then return nil, { chain = "item " .. i .. ": JobShout is set per agent, not as a model" } end
        chain[i] = { provider_uuid = link.provider_uuid, model = type(link.model) == "string" and link.model ~= "" and link.model or nil }
    end
    local max_tokens = tonumber(b.max_tokens)
    if b.max_tokens ~= nil and b.max_tokens ~= cjson.null and (not max_tokens or max_tokens < 64 or max_tokens > 200000) then
        return nil, { max_tokens = "64 to 200000" }
    end
    db.query([[
        INSERT INTO property_deals_ai_routes (namespace_id, job_type, chain, local_only, max_tokens)
        VALUES (?, ?, ?::jsonb, ?, ?)
        ON CONFLICT (namespace_id, job_type) DO UPDATE SET chain = EXCLUDED.chain, local_only = EXCLUDED.local_only,
            max_tokens = EXCLUDED.max_tokens, updated_at = NOW()
    ]], ns, job_type, cjson.encode(chain), b.local_only == true, max_tokens or db.NULL)
    for _, r in ipairs(C.routes(ns)) do if r.job_type == job_type then return r end end
end

--- An agent's settings, with defaults when the workspace hasn't saved any.
function C.agent(ns, key)
    local r = U.one("SELECT * FROM property_deals_agent_configs WHERE namespace_id = ? AND agent_key = ?", ns, key)
    if r then return r end
    return { agent_key = key, enabled = true, route = "builtin", fallback_to_builtin = true, local_only = false,
        auto_pickup = false, default = true }
end

function C.agents(ns)
    local saved = {}
    for _, r in ipairs(db.query("SELECT * FROM property_deals_agent_configs WHERE namespace_id = ?", ns)) do
        saved[r.agent_key] = r
    end
    local out = {}
    for _, a in ipairs(require("property_deals.ai.agents").list()) do
        local cfg = saved[a.key] or C.agent(ns, a.key)
        cfg.id, cfg.namespace_id = nil, nil
        a.config = cfg
        out[#out + 1] = a
    end
    return U.array(out)
end

local FIELDS = { enabled = "boolean", route = "string", jobshout_provider_uuid = "uuid", jobshout_agent_id = "string",
    jobshout_project_id = "string", fallback_to_builtin = "boolean", local_only = "boolean", approval_rule = "string",
    auto_pickup = "boolean", auto_pickup_at = "string" }

function C.save_agent(ns, key, b)
    if not require("property_deals.ai.agents").get(key) then return nil, { agent_key = "unknown agent" } end
    local row, errors = {}, {}
    for f, t in pairs(FIELDS) do
        local v = b[f]
        if v == cjson.null then row[f] = db.NULL
        elseif v ~= nil then
            if t == "boolean" and type(v) ~= "boolean" then errors[f] = "true or false"
            elseif t == "uuid" and not U.is_uuid(v) then errors[f] = "a uuid"
            elseif t == "string" and type(v) ~= "string" then errors[f] = "text"
            else row[f] = v end
        end
    end
    if row.route and row.route ~= "builtin" and row.route ~= "jobshout" then errors.route = "builtin or jobshout" end
    if row.approval_rule and not ({ any_operator = 1, manager = 1, two_person = 1 })[row.approval_rule] then
        errors.approval_rule = "any_operator, manager or two_person"
    end
    if row.auto_pickup_at and not tostring(row.auto_pickup_at):match("^[01]%d:[0-5]%d$")
        and not tostring(row.auto_pickup_at):match("^2[0-3]:[0-5]%d$") then
        errors.auto_pickup_at = "HH:MM"
    end
    if row.jobshout_provider_uuid and row.jobshout_provider_uuid ~= db.NULL then
        local p = U.one("SELECT provider_type FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?",
            ns, row.jobshout_provider_uuid)
        if not p or p.provider_type ~= "jobshout" then errors.jobshout_provider_uuid = "a JobShout link in this workspace" end
    end
    if next(errors) then return nil, errors end
    local current = U.one("SELECT * FROM property_deals_agent_configs WHERE namespace_id = ? AND agent_key = ?", ns, key)
    local merged = function(f) if row[f] ~= nil then return row[f] end return current and current[f] end
    if merged("route") == "jobshout" and (null(merged("jobshout_provider_uuid")) or null(merged("jobshout_agent_id"))) then
        return nil, { route = "jobshout needs jobshout_provider_uuid and jobshout_agent_id" }
    end
    row.updated_at = db.raw("NOW()")
    if current then
        db.update("property_deals_agent_configs", row, { id = current.id })
    else
        row.namespace_id, row.agent_key = ns, key
        db.insert("property_deals_agent_configs", row)
    end
    return C.agent(ns, key)
end

--- USD spent by agents in this workspace today (UTC day).
function C.spent_today(ns)
    local r = U.one([[
        SELECT COALESCE(SUM(cost_usd), 0) AS c FROM property_deals_agent_runs
        WHERE namespace_id = ? AND created_at >= date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
    ]], ns)
    return tonumber(r.c) or 0
end

function C.caps(settings)
    settings = settings or {}
    return { run = tonumber(settings.ai_max_cost_run_usd), day = tonumber(settings.ai_max_cost_day_usd),
        max_tokens = tonumber(settings.ai_max_tokens) or 2048 }
end

return C
