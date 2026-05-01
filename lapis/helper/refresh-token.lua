--[[
    Refresh Token Helper (helper/refresh-token.lua)

    Generates, stores, validates, rotates, and revokes opaque refresh tokens.
    Tokens are stored as SHA-256 hashes in the refresh_tokens DB table so that
    a database leak does not expose usable credentials.

    Design:
    - Opaque token: 64-char hex string (32 random bytes)
    - Stored as SHA-256 hash (token itself is never persisted)
    - 30-day expiry (configurable)
    - Automatic rotation: each use issues a new token and revokes the old one
    - Family-based revocation: if a rotated-out token is reused, the entire
      family is revoked (detects token theft)
    - Cleanup of expired tokens on every create (opportunistic)
    - Per-user limit: max 10 active tokens (oldest pruned on new login)
]]

local db = require("lapis.db")
local Global = require("helper.global")

local RefreshToken = {}

local EXPIRY_SECONDS = 30 * 24 * 60 * 60  -- 30 days
local MAX_TOKENS_PER_USER = 10             -- max active sessions per user

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Generate a cryptographically random opaque token (64 hex chars).
-- @return string The raw token to send to the client
local function generate_opaque_token()
    local resty_random = require("resty.random")
    local bytes = resty_random.bytes(32)
    if not bytes then
        -- Fallback (less secure, but functional)
        math.randomseed(ngx.now() * 1000 + ngx.worker.pid())
        local parts = {}
        for _ = 1, 32 do
            parts[#parts + 1] = string.format("%02x", math.random(0, 255))
        end
        return table.concat(parts)
    end

    local hex = {}
    for i = 1, #bytes do
        hex[#hex + 1] = string.format("%02x", string.byte(bytes, i))
    end
    return table.concat(hex)
end

--- Hash a token with SHA-256 for storage.
-- @param token string The raw opaque token
-- @return string Hex-encoded SHA-256 hash
local function hash_token(token)
    local resty_sha256 = require("resty.sha256")
    local str = require("resty.string")
    local sha = resty_sha256:new()
    sha:update(token)
    return str.to_hex(sha:final())
end

--- Cleanup expired tokens (opportunistic, called on create).
local function cleanup_expired()
    pcall(function()
        db.query("DELETE FROM refresh_tokens WHERE expires_at < NOW()")
    end)
end

--- Prune oldest tokens if a user exceeds MAX_TOKENS_PER_USER.
-- @param user_id number
local function prune_excess_tokens(user_id)
    pcall(function()
        db.query([[
            DELETE FROM refresh_tokens
            WHERE id IN (
                SELECT id FROM refresh_tokens
                WHERE user_id = ? AND revoked_at IS NULL
                ORDER BY created_at DESC
                OFFSET ?
            )
        ]], user_id, MAX_TOKENS_PER_USER)
    end)
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Create a new refresh token for a user.
-- @param user_id number The user's internal DB id
-- @param device_info string|nil Optional device description (e.g. "Chrome/Win", "iOS App")
-- @return string The raw opaque token (send to client, never stored)
-- @return string|nil Error message
function RefreshToken.create(user_id, device_info)
    if not user_id then
        return nil, "user_id is required"
    end

    -- Housekeeping
    cleanup_expired()
    prune_excess_tokens(user_id)

    local raw_token = generate_opaque_token()
    local token_hash = hash_token(raw_token)

    -- Generate a family ID for rotation tracking
    local family_id = Global.generateUUID()

    db.query([[
        INSERT INTO refresh_tokens (user_id, token_hash, family_id, device_info, expires_at, created_at)
        VALUES (?, ?, ?, ?, NOW() + INTERVAL ']] .. EXPIRY_SECONDS .. [[ seconds', NOW())
    ]], user_id, token_hash, family_id, device_info or db.NULL)

    return raw_token
end

--- Validate a refresh token and return user info.
-- Does NOT consume the token — call rotate() after validation to issue a new one.
-- @param raw_token string The opaque token from the client
-- @return table|nil { id, user_id, family_id } if valid
-- @return string|nil Error message
function RefreshToken.validate(raw_token)
    if not raw_token or raw_token == "" then
        return nil, "Refresh token is required"
    end

    local token_hash = hash_token(raw_token)

    local rows = db.query([[
        SELECT id, user_id, family_id, revoked_at, expires_at
        FROM refresh_tokens
        WHERE token_hash = ?
        LIMIT 1
    ]], token_hash)

    if not rows or #rows == 0 then
        return nil, "Invalid refresh token"
    end

    local row = rows[1]

    -- Check if the token was revoked
    if row.revoked_at then
        -- A revoked token was reused — possible theft.
        -- Revoke the entire family as a safety measure.
        ngx.log(ngx.WARN, "[REFRESH] Revoked token reused (family=", row.family_id,
            ", user=", row.user_id, ") — revoking entire family")
        db.query([[
            UPDATE refresh_tokens SET revoked_at = NOW()
            WHERE family_id = ? AND revoked_at IS NULL
        ]], row.family_id)
        return nil, "Token has been revoked. Please login again."
    end

    -- Check expiry (belt-and-suspenders; DB might have stale rows)
    local expired = db.query([[
        SELECT 1 FROM refresh_tokens WHERE id = ? AND expires_at < NOW()
    ]], row.id)
    if expired and #expired > 0 then
        return nil, "Refresh token has expired. Please login again."
    end

    return {
        id = row.id,
        user_id = row.user_id,
        family_id = row.family_id,
    }
end

--- Rotate a refresh token: revoke the old one and issue a new one in the same family.
-- @param old_token_id number The DB id of the current refresh token
-- @param user_id number The user's internal DB id
-- @param family_id string The token family UUID
-- @param device_info string|nil Optional device description
-- @return string The new raw opaque token
-- @return string|nil Error message
function RefreshToken.rotate(old_token_id, user_id, family_id, device_info)
    -- Revoke the old token
    db.query("UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = ?", old_token_id)

    -- Issue a new token in the same family
    local raw_token = generate_opaque_token()
    local token_hash = hash_token(raw_token)

    db.query([[
        INSERT INTO refresh_tokens (user_id, token_hash, family_id, device_info, expires_at, created_at)
        VALUES (?, ?, ?, ?, NOW() + INTERVAL ']] .. EXPIRY_SECONDS .. [[ seconds', NOW())
    ]], user_id, token_hash, family_id, device_info or db.NULL)

    return raw_token
end

--- Revoke a specific refresh token (e.g. on logout).
-- @param raw_token string The opaque token from the client
-- @return boolean success
function RefreshToken.revoke(raw_token)
    if not raw_token or raw_token == "" then
        return false
    end

    local token_hash = hash_token(raw_token)
    db.query("UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = ?", token_hash)
    return true
end

--- Revoke all refresh tokens for a user (e.g. on password change, "logout everywhere").
-- @param user_id number
-- @return boolean success
function RefreshToken.revokeAllForUser(user_id)
    if not user_id then return false end
    db.query("UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = ? AND revoked_at IS NULL", user_id)
    return true
end

--- Get active session count for a user.
-- @param user_id number
-- @return number
function RefreshToken.activeSessionCount(user_id)
    local rows = db.query([[
        SELECT COUNT(*) as count FROM refresh_tokens
        WHERE user_id = ? AND revoked_at IS NULL AND expires_at > NOW()
    ]], user_id)
    return rows and rows[1] and tonumber(rows[1].count) or 0
end

return RefreshToken
