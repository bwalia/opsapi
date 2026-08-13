--[[
    Domain Sync Repo Queries
    ========================

    Namespace-scoped list of GitHub repos a namespace syncs domains to (the
    "additional" repos beyond the single default in domain_sync_settings). Each
    domain is assigned to one via domains.sync_repo_uuid; the sync groups domains
    by repo and opens one PR per repo, using that repo's github_integration_id.
]]

local Global = require("helper.global")
local SyncSettings = require("queries.DomainSyncSettingsQueries")
local db = require("lapis.db")

local DomainSyncRepoQueries = {}

local function row_to_public(r)
    if not r then return nil end
    return {
        uuid = r.uuid,
        name = r.name,
        owner = r.owner,
        repo = r.repo,
        branch = r.branch or "main",
        github_integration_id = r.github_integration_id,
        created_at = r.created_at,
        updated_at = r.updated_at,
    }
end

--- All managed repos for a namespace (does NOT include the settings default).
function DomainSyncRepoQueries.list(namespace_id)
    local rows = db.query(
        "SELECT * FROM domain_sync_repos WHERE namespace_id = ? ORDER BY name ASC, owner ASC, repo ASC",
        namespace_id)
    local out = {}
    for _, r in ipairs(rows or {}) do table.insert(out, row_to_public(r)) end
    return out
end

function DomainSyncRepoQueries.getByUuid(namespace_id, uuid)
    local rows = db.query(
        "SELECT * FROM domain_sync_repos WHERE namespace_id = ? AND uuid = ? LIMIT 1", namespace_id, uuid)
    return rows and rows[1] or nil
end

-- Derive owner/repo/branch from params: a pasted repo_url wins, else explicit
-- owner/repo. Returns owner, repo, branch or nil, err.
local function resolve_repo_fields(params)
    local owner, repo, branch = params.owner, params.repo, params.branch
    if params.repo_url and params.repo_url ~= "" then
        local parsed = SyncSettings.parse_repo_url(params.repo_url)
        if not parsed then return nil, "Could not parse the repository URL" end
        owner, repo = parsed.owner, parsed.repo
        if (not branch or branch == "") and parsed.branch then branch = parsed.branch end
    end
    if not owner or owner == "" or not repo or repo == "" then
        return nil, "owner and repo (or a repo_url) are required"
    end
    return owner, repo, (branch and branch ~= "") and branch or "main"
end

function DomainSyncRepoQueries.create(namespace_id, params)
    local owner, repo, branch = resolve_repo_fields(params)
    if not owner then return nil, repo end -- repo holds the error message here
    local rows = db.query([[
        INSERT INTO domain_sync_repos
            (uuid, namespace_id, name, owner, repo, branch, github_integration_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
        ON CONFLICT (namespace_id, owner, repo, branch) DO UPDATE SET
            name = EXCLUDED.name,
            github_integration_id = EXCLUDED.github_integration_id,
            updated_at = NOW()
        RETURNING *
    ]], Global.generateUUID(), namespace_id, params.name or (owner .. "/" .. repo),
        owner, repo, branch, params.github_integration_id or db.NULL)
    return row_to_public(rows and rows[1] or nil)
end

function DomainSyncRepoQueries.update(namespace_id, uuid, params)
    local existing = DomainSyncRepoQueries.getByUuid(namespace_id, uuid)
    if not existing then return nil, "Repo not found" end
    local owner, repo, branch = resolve_repo_fields({
        repo_url = params.repo_url,
        owner = params.owner or existing.owner,
        repo = params.repo or existing.repo,
        branch = params.branch or existing.branch,
    })
    if not owner then return nil, repo end
    local rows = db.query([[
        UPDATE domain_sync_repos
        SET name = ?, owner = ?, repo = ?, branch = ?, github_integration_id = ?, updated_at = NOW()
        WHERE namespace_id = ? AND uuid = ?
        RETURNING *
    ]], params.name or existing.name, owner, repo, branch,
        params.github_integration_id ~= nil and params.github_integration_id or existing.github_integration_id,
        namespace_id, uuid)
    return row_to_public(rows and rows[1] or nil)
end

function DomainSyncRepoQueries.delete(namespace_id, uuid)
    db.query("DELETE FROM domain_sync_repos WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid)
    return true
end

return DomainSyncRepoQueries
