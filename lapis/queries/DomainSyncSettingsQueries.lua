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

--- Parse a GitHub repo reference into { owner, repo, branch? }. Lets a caller
--- paste the repo URL instead of entering owner + repo separately (fewer
--- fields, no misconfiguration). Accepts, case-insensitively:
---   https://github.com/owner/repo(.git)         git@github.com:owner/repo.git
---   https://github.com/owner/repo/tree/<branch> ssh://git@github.com/owner/repo
---   github.com/owner/repo                        owner/repo   (shorthand)
--- Returns nil if it cannot find both owner and repo.
function DomainSyncSettingsQueries.parse_repo_url(url)
    if type(url) ~= "string" then return nil end
    local s = url:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    s = s:gsub("[?#].*$", "")                 -- drop ?query / #fragment
    s = s:gsub("^git@[Gg]it[Hh]ub%.com:", "") -- scp-style ssh
    s = s:gsub("^ssh://git@[Gg]it[Hh]ub%.com/", "")
    s = s:gsub("^%w+://", "")                 -- http(s):// etc.
    s = s:gsub("^www%.", "")
    s = s:gsub("^[Gg]it[Hh]ub%.com/", "")     -- host
    s = s:gsub("^/+", "")                      -- leading slashes
    local owner, repo = s:match("^([^/]+)/([^/]+)")
    if not owner or not repo or owner == "" or repo == "" then return nil end
    repo = repo:gsub("%.git$", "")
    if repo == "" then return nil end
    local branch = s:match("^[^/]+/[^/]+/tree/([^/]+)")
    return { owner = owner, repo = repo, branch = branch }
end

-- If params carry a repo_url, derive owner/repo (and branch, when the URL
-- includes /tree/<branch>) from it. The pasted URL is the single source of
-- truth for the target, so it wins over any stray owner/repo the caller sent.
-- Mutates and returns the same table. A repo_url that cannot be parsed is left
-- for the caller's missing-owner/repo validation to reject with a clear error.
local function apply_repo_url(t)
    if type(t) ~= "table" or t.repo_url == nil then return t end
    local parsed = DomainSyncSettingsQueries.parse_repo_url(t.repo_url)
    if parsed then
        t.owner = parsed.owner
        t.repo = parsed.repo
        local b = t.branch
        if parsed.branch and parsed.branch ~= "" and (b == nil or tostring(b):gsub("%s+", "") == "") then
            t.branch = parsed.branch
        end
    end
    return t
end

--- Get the namespace's settings (or nil).
function DomainSyncSettingsQueries.get(namespace_id)
    local rows = db.query("SELECT * FROM domain_sync_settings WHERE namespace_id = ? LIMIT 1", namespace_id)
    return rows and rows[1] or nil
end

--- Create or update the single settings row for a namespace.
function DomainSyncSettingsQueries.upsert(namespace_id, params)
    params = apply_repo_url(params or {}) -- pasted repo_url -> owner/repo/branch
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
    req = apply_repo_url(req or {}) -- a per-request repo_url overrides the target
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
