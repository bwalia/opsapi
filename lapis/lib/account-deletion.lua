--[[
    Account deletion (POST /auth/delete-account) and the Apple tokens it revokes.

    Apple App Store guideline 5.1.1(v): an app that lets people create an
    account must let them delete it in the app, and an app offering Sign in
    with Apple must revoke the user's Apple tokens when they do
    (https://developer.apple.com/documentation/sign_in_with_apple/revoke_tokens).

    Who may delete: the caller of a user JWT who EITHER
      * gives the account password (password users, unchanged), OR
      * signed in within the last REAUTH_WINDOW seconds: the access JWT's
        auth_time (when its sign-in chain started; refresh keeps it, see
        helper/jwt-helper.lua and helper/refresh-token.lua). OAuth-only users
        (Google / Apple) have random passwords, so this is their only way.
    Anyone else gets 403 {"error":"Sign in again to delete your account",
    "code":"reauth_required"}: the app sends them through sign-in again
    (hosted sign-in: GET /auth/signin?prompt=login) and retries.

    What deletion does: users.active = false, every refresh token revoked,
    the auth cookies cleared, every Apple token on file revoked with Apple
    and its row deleted, the user's push device tokens deleted, the
    account_deactivation event logged. The response adds apple_revoked:
      true   every Apple token on file was revoked
      false  a revoke failed, or the user signs in with Apple but no token
             is on file (logged; deletion still succeeds)
      null   nothing to revoke (not an Apple user)

    Apple refresh tokens are kept in user_oauth_tokens, sealed with
    helper/secret-box.lua (purpose APPLE_PURPOSE). Never logged.

    Every collaborator is injectable (deps) so spec/account-deletion_spec.lua
    can run this without nginx or Postgres.
]]

local AccountDeletion = {}

AccountDeletion.REAUTH_WINDOW = 600
AccountDeletion.APPLE_PURPOSE = "apple-refresh-token"
-- Our own clock and the token's may differ by a little across pods.
local CLOCK_SKEW = 60

local function log(level, ...)
    if ngx and ngx.log then ngx.log(level, ...) end
end
local WARN = ngx and ngx.WARN or 5
local ERR = ngx and ngx.ERR or 4

-- Collaborators, required only when first used and not injected.
local MODULES = {
    db = "lapis.db",
    Box = "helper.secret-box",
    Apple = "helper.apple-signin",
    RefreshToken = "helper.refresh-token",
}
local function defaults(deps)
    deps = deps or {}
    if deps.resolved then return deps end
    return setmetatable({
        resolved = true,
        now = deps.now or (ngx and ngx.time) or os.time,
        log = deps.log or log,
    }, {
        __index = function(t, k)
            local v = deps[k]
            if v == nil and MODULES[k] then v = require(MODULES[k]) end
            if v == nil and k == "matchPassword" then v = require("helper.global").matchPassword end
            if v ~= nil then rawset(t, k, v) end
            return v
        end,
    })
end

--- Did this sign-in happen within the re-auth window?
-- @param auth_time number|string|nil  the access JWT's auth_time (epoch seconds)
-- @param now number
function AccountDeletion.recent_sign_in(auth_time, now)
    local t = tonumber(auth_time)
    if not t or not now then return false end
    local age = now - t
    return age >= -CLOCK_SKEW and age <= AccountDeletion.REAUTH_WINDOW
end

--- May this caller delete the account?
-- @param record table  users row (needs .password)
-- @param password string|nil  body.password / body.current_password
-- @param auth_time number|nil  the caller's access JWT auth_time
-- @return method ("password"|"recent_sign_in") | nil, response table
function AccountDeletion.authorize(record, password, auth_time, deps)
    local d = defaults(deps)
    local has_password = type(password) == "string" and password ~= ""
    if has_password and record.password and d.matchPassword(password, record.password) then
        return "password"
    end
    if AccountDeletion.recent_sign_in(auth_time, d.now()) then
        return "recent_sign_in"
    end
    if has_password then
        return nil, { status = 403, json = { error = "Password is incorrect", code = "password_incorrect" } }
    end
    return nil, { status = 403, json = { error = "Sign in again to delete your account", code = "reauth_required" } }
end

--- Keep the Apple refresh token from a token exchange, sealed.
-- @param user_id number  users.id
-- @param token_data table  Apple's /auth/token response
-- @param client_id string  the client_id the code was exchanged with
-- @return boolean stored
function AccountDeletion.store_apple_token(user_id, token_data, client_id, deps)
    local token = type(token_data) == "table" and token_data.refresh_token or nil
    if not user_id or type(token) ~= "string" or token == "" or not client_id or client_id == "" then
        return false
    end
    local d = defaults(deps)
    local ok, sealed = pcall(d.Box.seal, token, AccountDeletion.APPLE_PURPOSE)
    if not ok or type(sealed) ~= "string" then
        -- No OPENSSL_SECRET_KEY: nothing is stored unsealed. The reason, never the token.
        d.log(WARN, "[account-deletion] Apple refresh token not stored (sealing unavailable): ", tostring(sealed))
        return false
    end
    local stored, err = pcall(d.db.query, [[
        INSERT INTO user_oauth_tokens (user_id, provider, client_id, token_sealed, token_type, created_at, updated_at)
        VALUES (?, 'apple', ?, ?, 'refresh_token', NOW(), NOW())
        ON CONFLICT (user_id, provider, client_id)
        DO UPDATE SET token_sealed = EXCLUDED.token_sealed, token_type = EXCLUDED.token_type, updated_at = NOW()
    ]], user_id, client_id, sealed)
    if not stored then
        d.log(WARN, "[account-deletion] Apple refresh token not stored for user_id=", tostring(user_id),
            ": ", tostring(err))
        return false
    end
    return true
end

local function is_apple_user(record)
    return record and record.oauth_provider == "apple"
end

--- Revoke (with Apple) and delete every Apple token on file for the user.
-- @param record table  users row (id, oauth_provider)
-- @return true (all revoked) | false (a failure, or an Apple user with none on file) | nil (nothing to revoke)
function AccountDeletion.revoke_apple_tokens(record, deps)
    local d = defaults(deps)
    local ok, rows = pcall(d.db.query, [[
        SELECT id, client_id, token_sealed, token_type FROM user_oauth_tokens
        WHERE user_id = ? AND provider = 'apple'
    ]], record.id)
    if not ok then
        d.log(WARN, "[account-deletion] user_oauth_tokens unreadable: ", tostring(rows))
        rows = {}
    end
    if type(rows) ~= "table" or #rows == 0 then
        if is_apple_user(record) then
            d.log(WARN, "[account-deletion] user_id=", tostring(record.id),
                " signs in with Apple but has no Apple token on file; nothing revoked")
            return false
        end
        return nil
    end

    local all_revoked = true
    for _, row in ipairs(rows) do
        local opened, plain = pcall(d.Box.open, row.token_sealed, AccountDeletion.APPLE_PURPOSE)
        if not opened or type(plain) ~= "string" then
            -- Unreadable (deployment key changed): useless to keep.
            all_revoked = false
            d.log(ERR, "[account-deletion] Apple token row ", tostring(row.id), " could not be opened")
            pcall(d.db.query, "DELETE FROM user_oauth_tokens WHERE id = ?", row.id)
        else
            local token_type = (row.token_type and row.token_type ~= "") and row.token_type or "refresh_token"
            local called, revoked, why = pcall(d.Apple.revoke_token, plain, token_type, row.client_id)
            if called and revoked == true then
                pcall(d.db.query, "DELETE FROM user_oauth_tokens WHERE id = ?", row.id)
            else
                -- Kept for a retry by support; ON DELETE CASCADE removes it with the user.
                all_revoked = false
                d.log(ERR, "[account-deletion] Apple revoke failed for token row ", tostring(row.id), ": ",
                    tostring(called and why or revoked))
            end
        end
    end
    return all_revoked
end

--- Delete the user's push device tokens, when push notifications are installed.
function AccountDeletion.delete_device_tokens(user_uuid, deps)
    local d = defaults(deps)
    local ok, exists = pcall(d.db.query, "SELECT to_regclass('public.device_tokens') IS NOT NULL AS present")
    if not ok or not (exists and exists[1] and (exists[1].present == true or exists[1].present == "t")) then
        return false
    end
    local deleted, err = pcall(d.db.query, "DELETE FROM device_tokens WHERE user_uuid = ?", user_uuid)
    if not deleted then
        d.log(WARN, "[account-deletion] device_tokens not deleted: ", tostring(err))
        return false
    end
    return true
end

--- The whole request.
-- @param req { user = current_user, body = decoded JSON, auth_time = number|nil, api_key = bool }
-- @param deps  also: clear_cookies(), audit(method, user), null (JSON null)
-- @return response table
function AccountDeletion.handle(req, deps)
    local d = defaults(deps)
    local user = req.user
    if not user or not user.uuid or req.api_key then
        return { status = 401, json = { error = "Authentication required" } }
    end
    local body = type(req.body) == "table" and req.body or {}
    local password = body.password or body.current_password

    local rows = d.db.select("id, uuid, password, oauth_provider FROM users WHERE uuid = ? LIMIT 1", user.uuid)
    local record = rows and rows[1]
    if not record then
        return { status = 404, json = { error = "User not found" } }
    end

    local method, refused = AccountDeletion.authorize(record, password, req.auth_time, d)
    if not method then return refused end

    d.db.query("UPDATE users SET active = false, updated_at = NOW() WHERE uuid = ?", user.uuid)
    pcall(d.RefreshToken.revokeAllForUser, record.id)
    if deps and deps.clear_cookies then pcall(deps.clear_cookies) end

    local revoked_ok, apple_revoked = pcall(AccountDeletion.revoke_apple_tokens, record, d)
    if not revoked_ok then
        d.log(ERR, "[account-deletion] Apple revocation errored: ", tostring(apple_revoked))
        apple_revoked = false
    end
    AccountDeletion.delete_device_tokens(user.uuid, d)

    if deps and deps.audit then pcall(deps.audit, method, user) end

    local null = deps and deps.null
    if apple_revoked == nil then apple_revoked = null end
    return {
        status = 200,
        json = {
            message = "Your account has been deactivated. Contact support to permanently delete your data.",
            apple_revoked = apple_revoked,
        },
    }
end

return AccountDeletion
