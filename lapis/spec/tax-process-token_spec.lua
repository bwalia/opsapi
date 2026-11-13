--[[
    Spec: the tax statement worker keeps working past the user's 1-hour token.

    The File-with-AI worker (routes/tax-process.lua) extracts and classifies each
    uploaded statement by calling the tax endpoints AS the user. It used to reuse
    the user's own access token, which expires after an hour, so a year of
    statements on a slow model failed with every statement still queued marked
    ERROR at once. It now re-signs the verified identity with a fresh 15-minute
    token for each call (JWTHelper.reissue).

    Needs resty.jwt, so run it inside nginx, from the app directory of an opsapi
    container (JWT_SECRET_KEY is already set there):
        lapis exec 'package.path="./?.lua;"..package.path; dofile("spec/tax-process-token_spec.lua")'
    Source paths below are read relative to the repo root or the app directory.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;./?/init.lua;" .. package.path

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

-- Inside nginx (lapis exec) use the real ngx; standalone, a minimal stub.
local NOW
if ngx and ngx.time then
    NOW = ngx.time()
else
    NOW = 1794571934
    _G.ngx = setmetatable({ var = {}, ctx = {}, header = {}, log = function() end, WARN = 4, ERR = 3, INFO = 7,
        NOTICE = 6, DEBUG = 8, time = function() return NOW end, now = function() return NOW end },
        { __index = function() return function() end end })
end
local JWTHelper = require("helper.jwt-helper")

print("reissue: same identity, fresh expiry")
local userinfo = { uuid = "u-123", email = "landlord@example.com", roles = "member",
    namespace = { id = 3, slug = "workstation" } }
-- A sign-in from 2 hours ago whose access token has long expired.
local original = { userinfo = userinfo, iat = NOW - 7200, exp = NOW - 3600, auth_time = NOW - 7200, iss = "opsapi" }
local tok, err = JWTHelper.reissue(original, 900)
check("returns a token", type(tok) == "string" and #tok > 20, err)
local v = JWTHelper.verifyToken(tok or "")
check("new token verifies", v.valid == true, v.reason)
local p = v.payload or {}
check("keeps the user", p.userinfo and p.userinfo.uuid == "u-123" and p.userinfo.email == "landlord@example.com")
check("keeps the namespace", p.userinfo and p.userinfo.namespace and p.userinfo.namespace.slug == "workstation")
check("fresh iat/exp, 15 minutes", p.iat == NOW and p.exp == NOW + 900, tostring(p.iat) .. "/" .. tostring(p.exp))
check("keeps the session chain (auth_time)", p.auth_time == NOW - 7200)
check("issuer opsapi", p.iss == "opsapi")

print("reissue: refuses what it shouldn't extend")
check("no payload", JWTHelper.reissue(nil, 900) == nil)
check("no userinfo.uuid", JWTHelper.reissue({ userinfo = {}, iss = "opsapi" }, 900) == nil)
check("foreign issuer", JWTHelper.reissue({ userinfo = userinfo, iss = "someone-else" }, 900) == nil)
check("sign-in older than the max session",
    JWTHelper.reissue({ userinfo = userinfo, iss = "opsapi", auth_time = NOW - 31 * 24 * 3600 }, 900) == nil)

print("worker wiring (source)")
local ROOT = rawget(_G, "SPEC_ROOT") -- set when the files under test live elsewhere
local src = ROOT and read(ROOT .. "routes/tax-process.lua") or read("lapis/routes/tax-process.lua")
if src == "" then src = read("routes/tax-process.lua") end
check("extract uses a fresh token", src:find('/api/v2/tax/extract", "statement_id=" .. s.uuid, auth_for(job)', 1, true) ~= nil)
check("classify uses a fresh token", src:find('/api/v2/tax/classify", "statement_id=" .. s.uuid, auth_for(job)', 1, true) ~= nil)
check("no call still reuses the job's original header", src:find("s.uuid, job.auth", 1, true) == nil)
check("verified payload kept on the job", src:find("jwt_payload = jwt_payload", 1, true) ~= nil)
check("API keys passed through", src:find('raw:match("^opsk_")', 1, true) ~= nil)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILED"))
if failures > 0 then error(failures .. " check(s) failed") end
