--[[
    API Key Helper (helper/api-key.lua)

    Generates and authenticates namespace-scoped machine credentials.

    A raw key is "opsk_" + 48 hex chars (24 random bytes), shown once at
    creation and stored only as a SHA-256 hash (same scheme as
    helper/refresh-token.lua). At request time the key arrives as
    "Authorization: Bearer opsk_..." — the "opsk_" prefix is what routes a
    bearer token here instead of to JWT verification.

    authenticate() returns a *principal* table shaped so the rest of the
    stack works unchanged: it carries api_key = true (the discriminator
    every layer checks), the owning namespace row, and the key's scopes in
    the same {module -> [actions]} shape as namespace role permissions.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local ApiKey = {}

ApiKey.PREFIX = "opsk_"

-- How much of the raw key is kept in clear for display ("opsk_a1b2c3d").
local PREFIX_DISPLAY_LEN = 12

-- last_used_at is on the hot path; only touch it when it is older than this.
local LAST_USED_THROTTLE_SECONDS = 60

--- Does this bearer token look like an API key (vs a JWT)?
-- @param token string|nil
-- @return boolean
function ApiKey.is_api_key(token)
    return type(token) == "string" and token:sub(1, #ApiKey.PREFIX) == ApiKey.PREFIX
end

--- Hash a raw key with SHA-256 for storage/lookup.
-- @param raw string
-- @return string Hex-encoded SHA-256 hash
function ApiKey.hash(raw)
    local resty_sha256 = require("resty.sha256")
    local str = require("resty.string")
    local sha = resty_sha256:new()
    sha:update(raw)
    return str.to_hex(sha:final())
end

--- Generate a new key.
-- @return string raw key ("opsk_" + 48 hex) — send to the caller, never stored
-- @return string key_prefix (first 12 chars, display only)
-- @return string key_hash (SHA-256 hex, what gets persisted)
function ApiKey.generate()
    local resty_random = require("resty.random")
    local bytes = resty_random.bytes(24)
    local hex
    if bytes then
        local parts = {}
        for i = 1, #bytes do
            parts[#parts + 1] = string.format("%02x", string.byte(bytes, i))
        end
        hex = table.concat(parts)
    else
        -- Fallback (less secure, but functional)
        math.randomseed(ngx.now() * 1000 + ngx.worker.pid())
        local parts = {}
        for _ = 1, 24 do
            parts[#parts + 1] = string.format("%02x", math.random(0, 255))
        end
        hex = table.concat(parts)
    end

    local raw = ApiKey.PREFIX .. hex
    return raw, raw:sub(1, PREFIX_DISPLAY_LEN), ApiKey.hash(raw)
end

--- Opportunistically record use, at most once per throttle window.
local function touch_last_used(key_id)
    pcall(function()
        db.query([[
            UPDATE api_keys SET last_used_at = NOW()
            WHERE id = ?
              AND (last_used_at IS NULL OR last_used_at < NOW() - INTERVAL ']] ..
            LAST_USED_THROTTLE_SECONDS .. [[ seconds')
        ]], key_id)
    end)
end

--- Authenticate a raw API key.
-- @param raw string The bearer token (already known to carry the opsk_ prefix)
-- @return table|nil principal (see module docstring) if the key is valid
-- @return string|nil error message
-- @return number|nil HTTP status for the error (401 or 403)
function ApiKey.authenticate(raw)
    if not raw or raw == "" then
        return nil, "API key is required", 401
    end

    local rows = db.query([[
        SELECT ak.id, ak.uuid, ak.name, ak.namespace_id, ak.scopes,
               ak.expires_at, ak.revoked_at,
               (ak.expires_at IS NOT NULL AND ak.expires_at < NOW()) AS is_expired,
               ns.id AS ns_id, ns.uuid AS ns_uuid, ns.slug AS ns_slug,
               ns.name AS ns_name, ns.status AS ns_status
        FROM api_keys ak
        JOIN namespaces ns ON ns.id = ak.namespace_id
        WHERE ak.key_hash = ?
        LIMIT 1
    ]], ApiKey.hash(raw))

    if not rows or #rows == 0 then
        return nil, "Invalid API key", 401
    end
    local row = rows[1]

    if row.revoked_at and row.revoked_at ~= ngx.null then
        return nil, "API key has been revoked", 401
    end
    if row.is_expired then
        return nil, "API key has expired", 401
    end
    if row.ns_status and row.ns_status ~= ngx.null and row.ns_status ~= "active" then
        return nil, "Namespace is not accessible", 403
    end

    local scopes = {}
    if row.scopes and row.scopes ~= ngx.null and row.scopes ~= "" then
        local ok, decoded = pcall(cjson.decode, row.scopes)
        if ok and type(decoded) == "table" then scopes = decoded end
    end

    touch_last_used(row.id)

    return {
        api_key = true,
        key_id = row.id,
        key_uuid = row.uuid,
        key_name = row.name,
        namespace_id = row.namespace_id,
        namespace = {
            id = row.ns_id,
            uuid = row.ns_uuid,
            slug = row.ns_slug,
            name = row.ns_name,
            status = row.ns_status,
        },
        scopes = scopes,
        -- User-ish fields so downstream code that reads a user degrades
        -- gracefully: the uuid matches no users row, so admin lookups and
        -- author resolution simply come back empty.
        uuid = row.uuid,
        username = "api-key:" .. (row.name or row.uuid),
    }, nil, nil
end

return ApiKey
