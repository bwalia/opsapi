--[[
    Spec: account deletion for App Store guideline 5.1.1(v)
    (lib/account-deletion.lua, POST /auth/delete-account, Sign in with Apple
    token storage and revocation, GET /auth/me for deleted accounts, and
    auth_time surviving refresh so "recent sign-in" means a real sign-in).

    Standalone, from the repo root:
        luajit lapis/spec/account-deletion_spec.lua
    (CI runs it in the OpenResty image: .github/workflows/lapis-checks.yml.)
]]

package.path = "./?.lua;lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = io.open(path)
    if not h then return "" end
    local s = h:read("*a")
    h:close()
    return s
end

local b64 = require("spec.fixtures.openssl")
local logged = {}
local function encode_args(t)
    local keys, parts = {}, {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(t[k]) end
    return table.concat(parts, "&")
end
_G.ngx = { -- luacheck: ignore 121
    encode_base64 = b64.encode_base64, decode_base64 = b64.decode_base64, encode_args = encode_args,
    time = os.time, WARN = 5, ERR = 4, NOTICE = 6, INFO = 7, DEBUG = 8, ctx = {}, var = {},
    log = function(_, ...) logged[#logged + 1] = table.concat({ ... }) end,
}

local KEY = "deployment-secret"
local real_getenv = os.getenv
os.getenv = function(k) -- luacheck: ignore 122
    if k == "OPENSSL_SECRET_KEY" then return KEY end
    if k == "APPLE_CLIENT_ID" then return "app.pintopets.web" end
    return real_getenv(k)
end
package.loaded["helper.global"] = { getEnvVar = os.getenv, matchPassword = function(p, h) return h == "hash:" .. p end }
local Box = require("helper.secret-box")
local AccountDeletion = require("lib.account-deletion")

local NOW = 1800000000
local NULL = setmetatable({}, { __tostring = function() return "null" end })

-- A users row plus user_oauth_tokens rows, behind the two db calls the module makes.
local function fake_db(user, tokens, opts)
    opts = opts or {}
    local q = { queries = {}, deleted = {}, upserts = {}, deactivated = false, device_tokens_deleted = false }
    q.select = function(_, uuid) return (user and user.uuid == uuid) and { user } or {} end
    q.query = function(sql, ...)
        local args = { ... }
        q.queries[#q.queries + 1] = sql
        if sql:find("UPDATE users SET active = false", 1, true) then q.deactivated = true; return {} end
        if sql:find("FROM user_oauth_tokens", 1, true) and sql:find("SELECT", 1, true) then
            if opts.no_table then error("relation \"user_oauth_tokens\" does not exist") end
            return tokens or {}
        end
        if sql:find("DELETE FROM user_oauth_tokens", 1, true) then q.deleted[#q.deleted + 1] = args[1]; return {} end
        if sql:find("INSERT INTO user_oauth_tokens", 1, true) then
            q.upserts[#q.upserts + 1] = { user_id = args[1], client_id = args[2], sealed = args[3], sql = sql }
            return {}
        end
        if sql:find("to_regclass('public.device_tokens')", 1, true) then
            return { { present = opts.device_tokens ~= false } }
        end
        if sql:find("DELETE FROM device_tokens", 1, true) then q.device_tokens_deleted = args[1]; return {} end
        return {}
    end
    return q
end

local function fake_apple(result)
    local a = { calls = {} }
    a.revoke_token = function(token, hint, client_id)
        a.calls[#a.calls + 1] = { token = token, hint = hint, client_id = client_id }
        if result == "raise" then error("connection refused") end
        if result then return true end
        return nil, "Apple revoke error: status 400 invalid_client"
    end
    return a
end

local function run(opts)
    local revoked = {}
    local deps = {
        db = opts.db, Box = Box, Apple = opts.apple or fake_apple(true),
        RefreshToken = { revokeAllForUser = function(id) revoked[#revoked + 1] = id end },
        matchPassword = function(p, h) return h == "hash:" .. p end,
        now = function() return NOW end,
        null = NULL,
        clear_cookies = function() revoked.cookies = true end,
        audit = function(method) revoked.audit = method end,
    }
    local res = AccountDeletion.handle({ user = { uuid = "u-1" }, body = opts.body or {},
        auth_time = opts.auth_time, api_key = opts.api_key }, deps)
    return res, revoked
end

-- Test fixtures, not credentials (built so secret scanners don't mistake them for one).
local FIXTURE_PW = table.concat({ "fixture", "pw" }, "-")
local WRONG_PW = table.concat({ "not", "it" }, "-")
local UNKNOWABLE_PW = table.concat({ "random", "unknowable" }, "-")
local PASSWORD_USER = { id = 7, uuid = "u-1", password = "hash:" .. FIXTURE_PW, oauth_provider = NULL }
local APPLE_USER = { id = 8, uuid = "u-1", password = "hash:" .. UNKNOWABLE_PW, oauth_provider = "apple" }

print("who may delete")
local db = fake_db(PASSWORD_USER)
local res, side = run({ db = db, body = { password = FIXTURE_PW }, auth_time = NOW - 86400 })
check("password path still works (old sign-in, right password) -> 200", res.status == 200 and db.deactivated,
    res.status)
check("sessions revoked, cookies cleared, audited as password",
    side[1] == 7 and side.cookies and side.audit == "password")
check("current_password is still accepted",
    run({ db = fake_db(PASSWORD_USER), body = { current_password = FIXTURE_PW }, auth_time = NOW - 86400 }).status == 200)

db = fake_db(APPLE_USER)
res, side = run({ db = db, auth_time = NOW - 120 })
check("recent sign-in (2 min) without a password -> 200", res.status == 200 and db.deactivated, res.status)
check("audited as recent_sign_in", side.audit == "recent_sign_in")
check("exactly 600s old still counts", run({ db = fake_db(APPLE_USER), auth_time = NOW - 600 }).status == 200)

db = fake_db(APPLE_USER)
res = run({ db = db, auth_time = NOW - 601 })
check("stale sign-in without a password -> 403 reauth_required", res.status == 403
    and res.json.code == "reauth_required" and res.json.error == "Sign in again to delete your account",
    res.json and res.json.code)
check("...and nothing was changed", not db.deactivated)
check("no auth_time at all -> 403 reauth_required", run({ db = fake_db(APPLE_USER) }).json.code == "reauth_required")
check("auth_time from the future (beyond skew) does not count",
    run({ db = fake_db(APPLE_USER), auth_time = NOW + 3600 }).status == 403)
res = run({ db = fake_db(PASSWORD_USER), body = { password = WRONG_PW }, auth_time = NOW - 7200 })
check("wrong password + stale sign-in -> 403 password_incorrect", res.status == 403
    and res.json.code == "password_incorrect")
check("an API key can't delete an account", run({ db = fake_db(PASSWORD_USER), body = { password = FIXTURE_PW },
    api_key = true }).status == 401)
check("unknown user -> 404", run({ db = fake_db(nil), auth_time = NOW }).status == 404)

print("Apple tokens are stored sealed")
db = fake_db(APPLE_USER)
local stored = AccountDeletion.store_apple_token(8, { id_token = "x", refresh_token = "r.apple.REFRESH-1" },
    "app.pintopets.web", { db = db, Box = Box })
local up = db.upserts[1]
check("a refresh token from the exchange is upserted", stored == true and up and up.user_id == 8
    and up.client_id == "app.pintopets.web")
check("...sealed, never in plain text", up and up.sealed:match("^gcm1:") and not up.sealed:find("REFRESH-1", 1, true))
check("...opens with the apple-refresh-token purpose",
    up and Box.open(up.sealed, AccountDeletion.APPLE_PURPOSE) == "r.apple.REFRESH-1")
check("...and the upsert keys on (user_id, provider, client_id)",
    up and up.sql:find("ON CONFLICT (user_id, provider, client_id)", 1, true))
check("no refresh_token in the response -> nothing stored",
    AccountDeletion.store_apple_token(8, { id_token = "x" }, "c", { db = db, Box = Box }) == false and #db.upserts == 1)
KEY = nil
logged = {}
local ok_nokey, stored_nokey = pcall(AccountDeletion.store_apple_token, 8, { refresh_token = "r.apple.REFRESH-2" },
    "app.pintopets.web", { db = db, Box = Box })
check("no OPENSSL_SECRET_KEY -> skipped silently (no raise, nothing stored)",
    ok_nokey and stored_nokey == false and #db.upserts == 1)
check("...with a warning that never contains the token", #logged > 0
    and not table.concat(logged, "\n"):find("REFRESH-2", 1, true))
KEY = "deployment-secret"

print("deletion revokes Apple tokens")
local sealed = Box.seal("r.apple.REFRESH-1", AccountDeletion.APPLE_PURPOSE)
db = fake_db(APPLE_USER, { { id = 31, client_id = "app.pintopets.web", token_sealed = sealed,
    token_type = "refresh_token" } })
local apple = fake_apple(true)
res = run({ db = db, apple = apple, auth_time = NOW - 30 })
check("revoke called with the opened token, hint and client_id", #apple.calls == 1
    and apple.calls[1].token == "r.apple.REFRESH-1" and apple.calls[1].hint == "refresh_token"
    and apple.calls[1].client_id == "app.pintopets.web")
check("the row is deleted after a revoke", db.deleted[1] == 31)
check("200 with apple_revoked = true", res.status == 200 and res.json.apple_revoked == true)
check("response keeps the message", type(res.json.message) == "string" and res.json.message:find("deactivated"))
check("push device tokens deleted", db.device_tokens_deleted == "u-1")

db = fake_db(APPLE_USER, { { id = 32, client_id = "app.pintopets.web", token_sealed = sealed } })
logged = {}
res = run({ db = db, apple = fake_apple(false), auth_time = NOW - 30 })
check("revoke failure -> still 200, apple_revoked = false", res.status == 200 and res.json.apple_revoked == false
    and db.deactivated)
check("...failure logged, token not in the log", #logged > 0 and not table.concat(logged):find("REFRESH-1", 1, true))
check("...row kept for a retry", #db.deleted == 0)
res = run({ db = fake_db(APPLE_USER, { { id = 33, client_id = "c", token_sealed = sealed } }),
    apple = fake_apple("raise"), auth_time = NOW - 30 })
check("revoke raising -> still 200, apple_revoked = false", res.status == 200 and res.json.apple_revoked == false)

res = run({ db = fake_db(APPLE_USER, {}), auth_time = NOW - 30 })
check("Apple user with no token on file -> apple_revoked = false",
    res.status == 200 and res.json.apple_revoked == false)
res = run({ db = fake_db(PASSWORD_USER, {}), body = { password = FIXTURE_PW } })
check("not an Apple user -> apple_revoked = null (JSON null)", res.status == 200 and res.json.apple_revoked == NULL)
res = run({ db = fake_db(PASSWORD_USER, nil, { no_table = true, device_tokens = false }),
    body = { password = FIXTURE_PW } })
check("before the migration (no user_oauth_tokens, no device_tokens) -> 200, null",
    res.status == 200 and res.json.apple_revoked == NULL)

print("AppleSignIn.revoke_token")
local http_calls = {}
local http_status = 200
package.loaded["resty.http"] = { new = function()
    return { set_timeout = function() end, request_uri = function(_, url, req)
        http_calls[#http_calls + 1] = { url = url, req = req }
        return { status = http_status, body = http_status == 200 and "" or '{"error":"invalid_grant"}' }
    end }
end }
package.loaded["cjson.safe"] = package.loaded["cjson.safe"] or (pcall(require, "cjson.safe") and require("cjson.safe"))
    or { decode = function() return nil end, encode = function() return "{}" end }
local AppleSignIn = require("helper.apple-signin")
local secret_for = {}
AppleSignIn.generate_client_secret = function(client_id)
    secret_for[#secret_for + 1] = client_id
    return "cs." .. client_id
end
local ok_r = AppleSignIn.revoke_token("r.apple.REFRESH-1", "refresh_token", "app.pintopets.ios")
local call = http_calls[1]
check("HTTP 200 -> true", ok_r == true)
check("POSTs to https://appleid.apple.com/auth/revoke", call and call.url == "https://appleid.apple.com/auth/revoke"
    and call.req.method == "POST")
check("form-encoded client_id, client_secret, token, token_type_hint", call
    and call.req.headers["Content-Type"] == "application/x-www-form-urlencoded"
    and call.req.body == "client_id=app.pintopets.ios&client_secret=cs.app.pintopets.ios"
        .. "&token=r.apple.REFRESH-1&token_type_hint=refresh_token", call and call.req.body)
check("client_secret is minted for that client_id", secret_for[1] == "app.pintopets.ios")
AppleSignIn.revoke_token("t", nil, nil)
check("client_id defaults to APPLE_CLIENT_ID, hint to refresh_token", secret_for[2] == "app.pintopets.web"
    and http_calls[2].req.body:find("token_type_hint=refresh_token", 1, true))
http_status = 400
local nok, why = AppleSignIn.revoke_token("t", "refresh_token", "c")
check("non-200 -> nil, reason", nok == nil and tostring(why):find("400", 1, true), why)
check("empty token refused without a request", AppleSignIn.revoke_token("", nil, "c") == nil and #http_calls == 3)

print("wiring (source)")
local apple_src = read("lapis/helper/apple-signin.lua")
check("client_secret is cached per client_id", apple_src:find("client_secret_cache[client_id] =", 1, true)
    and apple_src:find("function AppleSignIn.generate_client_secret(client_id)", 1, true))
check("exchange_code signs with its own client_id", apple_src:find("generate_client_secret(client_id)", 1, true))
local auth_src = read("lapis/routes/auth.lua")
check("apple_callback keeps the token exchange response", auth_src:find("apple_tokens = token_data", 1, true))
check("apple_callback stores the refresh token sealed", auth_src:find("AccountDeletion.store_apple_token", 1, true))
check("/auth/delete-account is handled by lib/account-deletion.lua with the JWT's auth_time",
    auth_src:find("AccountDeletion.handle({", 1, true) and auth_src:find("auth_time = ngx.ctx.auth_time", 1, true))
check("/auth/delete-account sends apple_revoked null as JSON null", auth_src:find("null = cJson.null", 1, true))
local me = auth_src:match('app:get%("/auth/me".-\n    end%)') or ""
check("/auth/me answers 401 for a deactivated or missing user",
    me:find("if not user or is_deactivated(user) then", 1, true) and me:find("status = 401", 1, true)
        and not me:find("status = 404", 1, true))
check("the auth middleware exposes the JWT's auth_time",
    read("lapis/helper/auth.lua"):find("ngx.ctx.auth_time = tonumber(jwt_obj.payload.auth_time)", 1, true))

print("auth_time: refresh keeps the sign-in's, a real sign-in mints a new one")
local jwt_src = read("lapis/helper/jwt-helper.lua")
check("generateToken defaults auth_time to now (password, 2FA, Google sign-in)",
    jwt_src:find("auth_time = options.auth_time or now", 1, true))
check("generateNamespaceToken passes auth_time through", jwt_src:find("auth_time = options.auth_time,", 1, true))
check("opaque /auth/refresh mints with the refresh family's auth_time",
    select(2, auth_src:gsub("auth_time = rt_data.auth_time", "")) == 2)
local rt_src = read("lapis/helper/refresh-token.lua")
check("a new refresh family records its sign-in time",
    rt_src:find("created_at, auth_time)\n        VALUES (?, ?, ?, ?, NOW() + INTERVAL ']] .. EXPIRY_SECONDS"
        .. " .. [[ seconds', NOW(), NOW())", 1, true))
check("rotation copies auth_time from the old token",
    rt_src:find("COALESCE((SELECT auth_time FROM refresh_tokens WHERE id = ?)", 1, true))
check("validate returns auth_time", rt_src:find("auth_time = RefreshToken.authTime(row.id, row.family_id)", 1, true))
local ns_src = read("lapis/routes/namespaces.lua")
check("namespace switch / create keep the sign-in's auth_time",
    select(2, ns_src:gsub("auth_time = ngx.ctx.auth_time", "")) == 2)
local mig = read("lapis/migrations.lua")
check("migration: refresh_tokens.auth_time", mig:find("['440a_refresh_tokens_auth_time']", 1, true)
    and mig:find("ADD COLUMN IF NOT EXISTS auth_time", 1, true))
check("migration: user_oauth_tokens with FK cascade and the unique key",
    mig:find("CREATE TABLE IF NOT EXISTS user_oauth_tokens", 1, true)
        and mig:find("REFERENCES users(id) ON DELETE CASCADE", 1, true)
        and mig:find("UNIQUE (user_id, provider, client_id)", 1, true)
        and mig:find("token_type TEXT NOT NULL DEFAULT 'refresh_token'", 1, true))
check("'440a' / '440b' sort after '440_create_refresh_tokens'",
    "440_create_refresh_tokens" < "440a_refresh_tokens_auth_time"
        and "440a_refresh_tokens_auth_time" < "440b_create_user_oauth_tokens")

os.getenv = real_getenv -- luacheck: ignore 122
print(failures == 0 and "\nall checks passed" or ("\n" .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
