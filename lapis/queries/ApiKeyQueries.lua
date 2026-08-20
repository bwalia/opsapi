--[[
    API Key Queries

    Persistence for namespace-scoped machine credentials (api_keys table).
    The raw key never reaches this layer — helper/api-key.lua generates it
    and hands over only key_prefix + key_hash. key_hash is never selected
    back out except by the authenticator's hash lookup.
]]

local db = require("lapis.db")
local Global = require("helper.global")
local ApiKeys = require("models.ApiKeyModel")

local ApiKeyQueries = {}

--- Persist a new key.
-- @param params table {namespace_id, name, key_prefix, key_hash, scopes(json string), created_by?, expires_at?}
-- @return table The created row (without key_hash)
function ApiKeyQueries.create(params)
    local row = ApiKeys:create({
        uuid = Global.generateUUID(),
        namespace_id = params.namespace_id,
        name = params.name,
        key_prefix = params.key_prefix,
        key_hash = params.key_hash,
        scopes = params.scopes,
        created_by = params.created_by,
        expires_at = params.expires_at,
    }, { returning = "*" })
    row.key_hash = nil
    return row
end

--- List a namespace's keys, newest first. Never exposes key_hash.
-- @param namespace_id number
-- @return table[] rows
function ApiKeyQueries.listByNamespace(namespace_id)
    return db.query([[
        SELECT uuid, name, key_prefix, scopes, last_used_at,
               expires_at, revoked_at, created_at
        FROM api_keys
        WHERE namespace_id = ?
        ORDER BY created_at DESC
    ]], namespace_id)
end

--- Fetch one key by uuid, scoped to a namespace (ownership check).
-- @param uuid string
-- @param namespace_id number
-- @return table|nil
function ApiKeyQueries.findByUuidAndNamespace(uuid, namespace_id)
    local rows = db.query([[
        SELECT uuid, name, key_prefix, scopes, last_used_at,
               expires_at, revoked_at, created_at
        FROM api_keys
        WHERE uuid = ? AND namespace_id = ?
        LIMIT 1
    ]], uuid, namespace_id)
    return rows and rows[1] or nil
end

--- Revoke a key. Idempotent: revoking an already-revoked key is a no-op.
-- @param uuid string
-- @param namespace_id number
-- @return boolean whether a live key was revoked by this call
function ApiKeyQueries.revoke(uuid, namespace_id)
    local result = db.query([[
        UPDATE api_keys SET revoked_at = NOW(), updated_at = NOW()
        WHERE uuid = ? AND namespace_id = ? AND revoked_at IS NULL
    ]], uuid, namespace_id)
    return result and result.affected_rows and result.affected_rows > 0 or false
end

return ApiKeyQueries
