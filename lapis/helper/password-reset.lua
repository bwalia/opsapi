-- Password reset token helper for /auth/forgot-password and /auth/reset-password.
--
-- Mirrors the design of helper/refresh-token.lua: plaintext token only
-- ever lives in the email link, the DB stores SHA-256(token), validation
-- compares hashes with constant-time semantics (postgres ``=`` on a fixed-
-- length string is constant-time at the storage layer), single-use is
-- enforced by ``used_at`` instead of deletion so audits can show "this
-- token was consumed at T".
--
-- Not coupled to mail or routing — this module only handles token
-- lifecycle (create, validate-and-consume, revoke). Routes call it.
--
-- Usage:
--   local PasswordReset = require("helper.password-reset")
--
--   local raw, err = PasswordReset.create(user_id, ip_address)
--   -- send `raw` in email link
--
--   local user_id, err = PasswordReset.validateAndConsume(raw)
--   -- on success, raw is now marked used_at; subsequent calls with the
--   -- same raw will fail with "already_used"

local db = require("lapis.db")

local PasswordReset = {}

-- Token lifetime. 30 minutes is the industry sweet spot — long enough
-- for a user to dig the email out of spam without enabling drive-by
-- token replay if a forwarded email leaks. Reset endpoints typically
-- pair this with refresh-token revocation on consume, so a stolen
-- token after consume is moot anyway.
local TOKEN_TTL_SECONDS = 30 * 60

-- Token byte length. 32 random bytes → 256 bits of entropy → 43-char
-- URL-safe base64. Way more than enough to resist online brute force
-- given our rate limit + per-token TTL.
local TOKEN_BYTE_LENGTH = 32


-- ---------------------------------------------------------------------------
-- Crypto-grade random + hash. We're inside OpenResty so resty.random and
-- resty.sha256 are available without extra deps.
-- ---------------------------------------------------------------------------

local function generate_random_token()
    local resty_random = require("resty.random")
    local str = require("resty.string")
    -- bytes_strict() keeps requesting more bytes from the kernel until
    -- it gets `len`. The non-strict variant can return short reads
    -- when the entropy pool is low — strict is the right call for
    -- security-sensitive tokens.
    local bytes = resty_random.bytes(TOKEN_BYTE_LENGTH, true)
    if not bytes or #bytes < TOKEN_BYTE_LENGTH then
        -- This should never happen on a healthy box. Surface as a
        -- hard error rather than silently issuing a weak token.
        error("password-reset: failed to generate cryptographic random bytes")
    end
    -- to_hex gives 64 chars of [0-9a-f]. URL-safe by definition,
    -- no escaping needed in the email link or in the URL bar.
    return str.to_hex(bytes)
end

local function hash_token(raw_token)
    if type(raw_token) ~= "string" or raw_token == "" then
        return nil
    end
    local resty_sha256 = require("resty.sha256")
    local str = require("resty.string")
    local sha = resty_sha256:new()
    sha:update(raw_token)
    return str.to_hex(sha:final())
end


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Create a new password reset token for ``user_id``.
--
-- Inserts the token's hash into ``password_reset_tokens`` with a 30-
-- minute expiry and returns the plaintext token to the caller. The
-- caller is expected to put the plaintext into an email link
-- immediately and never store/log it.
--
-- Side-effect: any *previous* unconsumed tokens for this user are
-- marked used_at = NOW() to prevent multiple-pending-link confusion.
-- A user who clicks "forgot password" twice gets a fresh link; the
-- first link stops working. This also limits the blast radius if an
-- earlier email was intercepted.
--
-- @param user_id    integer  required
-- @param ip_address string|nil optional, recorded for audit
-- @return string|nil raw token (send to user via email)
-- @return string|nil error code on failure
function PasswordReset.create(user_id, ip_address)
    if not user_id or type(user_id) ~= "number" then
        return nil, "invalid_user_id"
    end

    -- Invalidate any older outstanding tokens for this user. Idempotent:
    -- if there are none, this is a no-op. We mark used rather than
    -- DELETE so the audit trail of "user requested reset 3 times in 5
    -- minutes" stays intact.
    db.query([[
        UPDATE password_reset_tokens
        SET used_at = NOW()
        WHERE user_id = ? AND used_at IS NULL AND expires_at > NOW()
    ]], user_id)

    local raw = generate_random_token()
    local token_hash = hash_token(raw)
    if not token_hash then
        return nil, "hash_failed"
    end

    local ok, err = pcall(function()
        db.insert("password_reset_tokens", {
            user_id = user_id,
            token_hash = token_hash,
            expires_at = db.raw(
                ("NOW() + INTERVAL '%d seconds'"):format(TOKEN_TTL_SECONDS)
            ),
            ip_address = ip_address or nil,
            created_at = db.raw("NOW()"),
        })
    end)

    if not ok then
        ngx.log(ngx.ERR, "[password-reset] insert failed: ", tostring(err))
        return nil, "insert_failed"
    end

    return raw
end


--- Validate a raw token and atomically mark it consumed.
--
-- Returns the ``user_id`` on success so the caller can update that
-- user's password. The atomic UPDATE ... RETURNING enforces single-
-- use: even if two concurrent requests arrive with the same token,
-- only one will see ``used_at IS NULL`` at UPDATE time and the other
-- will get a 0-row result.
--
-- Failure modes (returned as the second value, never raised):
--   ``invalid_token`` — hash doesn't match any row
--   ``expired``       — token exists but past ``expires_at``
--   ``already_used``  — token exists but already consumed
--
-- @param raw_token string user-supplied plaintext token
-- @return integer|nil user_id
-- @return string|nil  error code
function PasswordReset.validateAndConsume(raw_token)
    if type(raw_token) ~= "string" or #raw_token < 16 then
        -- Reject obviously-malformed tokens before hitting the DB so
        -- a flood of garbage doesn't index-scan the table.
        return nil, "invalid_token"
    end

    local token_hash = hash_token(raw_token)
    if not token_hash then
        return nil, "invalid_token"
    end

    -- Single atomic statement: find the row, check it's still valid,
    -- mark it used, return the user_id. No race window between
    -- "validate" and "consume".
    local rows = db.query([[
        UPDATE password_reset_tokens
        SET used_at = NOW()
        WHERE token_hash = ?
          AND used_at IS NULL
          AND expires_at > NOW()
        RETURNING user_id
    ]], token_hash)

    if rows and rows[1] and rows[1].user_id then
        return rows[1].user_id
    end

    -- The token didn't update. Distinguish "doesn't exist" vs "exists
    -- but expired" vs "exists but already used" so the caller can
    -- show a precise error. This is a second SELECT — accepted
    -- because the failure path is rare (most validations succeed).
    local existing = db.query([[
        SELECT used_at, expires_at
        FROM password_reset_tokens
        WHERE token_hash = ?
        LIMIT 1
    ]], token_hash)

    if not existing or #existing == 0 then
        return nil, "invalid_token"
    end

    if existing[1].used_at then
        return nil, "already_used"
    end
    return nil, "expired"
end


--- Revoke (mark used) all outstanding tokens for a user.
-- Use case: password just changed via /auth/reset-password — drop any
-- pending reset links so an attacker holding a stolen email link
-- can't beat the user to it. Caller is responsible for revoking
-- refresh tokens too.
function PasswordReset.revokeAllForUser(user_id)
    if not user_id then return false end
    db.query([[
        UPDATE password_reset_tokens
        SET used_at = NOW()
        WHERE user_id = ? AND used_at IS NULL
    ]], user_id)
    return true
end


-- Exposed for tests / observability only. Not for general use.
PasswordReset._TOKEN_TTL_SECONDS = TOKEN_TTL_SECONDS
PasswordReset._TOKEN_BYTE_LENGTH = TOKEN_BYTE_LENGTH

return PasswordReset
