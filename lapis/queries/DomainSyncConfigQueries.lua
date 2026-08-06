--[[
    Domain Sync Config Queries
    ==========================

    Namespace-scoped configuration for the k3s domain-sync job: where to push the
    exported domains.json (GitHub repo/branch/path), on what cron schedule, and
    which Kubernetes Secret (populated by ESO / the external vault) carries the
    GitHub token. The token itself is NEVER stored here — only the secret name.
]]

local DomainSyncConfigModel = require("models.DomainSyncConfigModel")
local Global = require("helper.global")
local db = require("lapis.db")

local DomainSyncConfigQueries = {}

local WRITABLE_FIELDS = {
    "name", "destination_type", "github_repo", "github_branch", "file_path",
    "commit_author_name", "commit_author_email",
    "github_token_secret_ref", "github_token_secret_key",
    "opsapi_base_url", "opsapi_token_secret_key",
    "schedule", "is_enabled",
}

function DomainSyncConfigQueries.create(params)
    if not params.uuid then params.uuid = Global.generateUUID() end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    return DomainSyncConfigModel:create(params, { returning = "*" })
end

function DomainSyncConfigQueries.list(namespace_id)
    return db.query([[
        SELECT * FROM domain_sync_configs
        WHERE namespace_id = ? AND deleted_at IS NULL
        ORDER BY created_at DESC
    ]], namespace_id)
end

function DomainSyncConfigQueries.get(uuid)
    local rows = db.query([[
        SELECT * FROM domain_sync_configs WHERE uuid = ? AND deleted_at IS NULL
    ]], uuid)
    return rows and rows[1] or nil
end

function DomainSyncConfigQueries.update(uuid, params)
    local cfg = DomainSyncConfigModel:find({ uuid = uuid })
    if not cfg then return nil end

    local update_params = {}
    for _, field in ipairs(WRITABLE_FIELDS) do
        if params[field] ~= nil then
            update_params[field] = params[field]
        end
    end
    if next(update_params) == nil then return cfg end
    update_params.updated_at = db.raw("NOW()")
    return cfg:update(update_params, { returning = "*" })
end

function DomainSyncConfigQueries.recordRun(uuid, status, err)
    local cfg = DomainSyncConfigModel:find({ uuid = uuid })
    if not cfg then return nil end
    return cfg:update({
        last_synced_at = db.raw("NOW()"),
        last_status = status,
        last_error = err,
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

function DomainSyncConfigQueries.delete(uuid)
    local cfg = DomainSyncConfigModel:find({ uuid = uuid })
    if not cfg then return nil end
    return cfg:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

return DomainSyncConfigQueries
