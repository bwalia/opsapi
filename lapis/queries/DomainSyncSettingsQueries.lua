--[[
    Domain Sync Settings Queries
    ============================

    One row per namespace (upsert). Stores the sync target (owner/repo/branch),
    the linked Services GitHub integration id, and optional overrides. The token
    itself lives in the integration (encrypted) — never here.
]]

local DomainSyncSettingsModel = require("models.DomainSyncSettingsModel")
local Global = require("helper.global")
local db = require("lapis.db")

local DomainSyncSettingsQueries = {}

local WRITABLE = {
    "owner", "repo", "branch", "github_integration_id", "data_base", "default_environment",
    -- Template-driven wslproxy rendering (see helper/wslproxy-server.lua).
    -- All optional; blank/NULL falls back to the built-in defaults.
    "server_template", "rule_template", "default_rule_id", "default_backend", "sync_rules",
}

--- Get the namespace's settings (or nil).
function DomainSyncSettingsQueries.get(namespace_id)
    local rows = db.query("SELECT * FROM domain_sync_settings WHERE namespace_id = ? LIMIT 1", namespace_id)
    return rows and rows[1] or nil
end

--- Create or update the single settings row for a namespace.
function DomainSyncSettingsQueries.upsert(namespace_id, params)
    local existing = DomainSyncSettingsQueries.get(namespace_id)

    local set = {}
    for _, f in ipairs(WRITABLE) do
        if params[f] ~= nil then set[f] = params[f] end
    end

    if existing then
        if next(set) == nil then return existing end
        local model = DomainSyncSettingsModel:find({ id = existing.id })
        set.updated_at = db.raw("NOW()")
        return model:update(set, { returning = "*" })
    end

    set.uuid = Global.generateUUID()
    set.namespace_id = namespace_id
    set.branch = set.branch or "main"
    set.created_at = db.raw("NOW()")
    set.updated_at = db.raw("NOW()")
    return DomainSyncSettingsModel:create(set, { returning = "*" })
end

--- Resolve effective sync params: request overrides win over saved settings.
-- Returns { owner, repo, branch, github_integration_id, data_base, environment }
-- and a list of missing required fields.
function DomainSyncSettingsQueries.resolve(namespace_id, req)
    req = req or {}
    local s = DomainSyncSettingsQueries.get(namespace_id) or {}
    -- sync_rules is a tri-state (true/false/nil). Only treat an explicit false
    -- as "off"; nil anywhere means "use default (on)".
    local function first_defined(a, b)
        if a ~= nil then return a end
        return b
    end
    local eff = {
        owner = req.owner or s.owner,
        repo = req.repo or s.repo,
        branch = req.branch or s.branch or "main",
        github_integration_id = req.github_integration_id or s.github_integration_id,
        data_base = req.data_base or s.data_base,
        environment = req.environment or s.default_environment or "prod",
        -- Template-driven rendering (nil -> helper uses its built-in default).
        server_template = req.server_template or s.server_template,
        rule_template = req.rule_template or s.rule_template,
        default_rule_id = req.default_rule_id or s.default_rule_id,
        default_backend = req.default_backend or s.default_backend,
        sync_rules = first_defined(req.sync_rules, s.sync_rules),
    }
    local missing = {}
    if not eff.owner or eff.owner == "" then table.insert(missing, "owner") end
    if not eff.repo or eff.repo == "" then table.insert(missing, "repo") end
    return eff, missing
end

return DomainSyncSettingsQueries
