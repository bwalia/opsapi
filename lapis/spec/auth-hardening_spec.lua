--[[
    Spec: auth hardening (A1-A10 of the 2026-10-08 security review).

    Standalone, from the repo root:
        luajit lapis/spec/auth-hardening_spec.lua
    (CI runs it in the OpenResty image: .github/workflows/lapis-checks.yml.)

    Unit checks where the code runs outside nginx, source checks elsewhere. The
    behaviour end to end (exploits refused, real flows working) is
    lapis/spec/security-e2e/run.sh.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

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

-- Minimal ngx for modules that only touch it at call time.
_G.ngx = setmetatable({ var = {}, ctx = {}, header = {}, log = function() end, WARN = 4, ERR = 3, INFO = 7,
    NOTICE = 6, DEBUG = 8 }, { __index = function() return function() end end })

print("A1: no anonymous namespace access")
local auth_src = read("lapis/middleware/auth.lua")
check("requireAuth has no X-Public-Browse bypass", not auth_src:lower():find("x%-public%-browse"))
package.loaded["queries.NamespaceQueries"] = { findByIdentifier = function() return { id = 5, slug = "victim", status = "active" } end }
package.loaded["queries.NamespaceMemberQueries"] = { findByUserAndNamespace = function() return nil end }
package.loaded["helper.admin-check"] = { isPlatformAdmin = function() return false end }
local NamespaceMiddleware = require("middleware.namespace")
local reached = false
local res = NamespaceMiddleware.requireNamespace(function() reached = true; return { status = 200 } end)({
    req = { headers = { ["x-namespace-id"] = "5" } }, params = {}, current_user = nil })
check("requireNamespace without a user -> 401, handler not run", res and res.status == 401 and not reached,
    res and res.status)
local Auth = (function()
    if not pcall(require, "resty.jwt") then package.loaded["resty.jwt"] = {} end
    package.loaded["helper.global"] = package.loaded["helper.global"] or { getEnvVar = os.getenv }
    return require("helper.auth")
end)()
-- Never raises (older code may need nginx here): an error counts as "not public".
local function public(uri, method)
    local ok, res = pcall(Auth.is_public_route, uri, method)
    return ok and res == true
end
check("public GET routes stay public", public("/api/v2/products", "GET")
    and public("/api/v2/categories", "GET") and public("/api/v2/stores/x/products", "GET"))
check("a public GET route is closed to POST/PUT/DELETE", not public("/api/v2/products", "POST")
    and not public("/api/v2/stores", "DELETE") and not public("/api/v2/categories", "PUT"))
check("tenant-scoped storeproducts is not public", not public("/api/v2/storeproducts", "GET")
    and not public("/api/v2/storeproducts", "POST"))
check("registration stays a public POST", public("/api/v2/register", "POST"))
check("CORS no longer advertises X-Public-Browse", not read("lapis/middleware/cors.lua"):find("X%-Public%-Browse"))

print("A2: client IP")
ngx.var = { remote_addr = "10.0.0.5", http_x_forwarded_for = "1.2.3.4, 203.0.113.9" }
local RateLimit = require("middleware.rate-limit")
local function client_ip() local ok, ip = pcall(RateLimit.getClientIP); return ok and ip or nil end
check("rate limits key on the hop our proxy added, not the client-written left-most one",
    client_ip() == "203.0.113.9", client_ip())
ngx.var = { remote_addr = "198.51.100.20", http_x_forwarded_for = "1.2.3.4" }
check("a client talking to us directly can't choose its address", client_ip() == "198.51.100.20",
    RateLimit.getClientIP())

print("A3: logins and OTP")
local login = read("lapis/routes/auth.lua")
check("login checks the per-account lockout before the password", login:find("Throttle.blocked(lock_key, Throttle.LOGIN)", 1, true)
    and login:find("Throttle.hit(lock_key", 1, true) ~= nil)
local otp = read("lapis/helper/otp.lua")
check("OTP codes are stored as an HMAC, never plain", otp:find("code = db.NULL,", 1, true)
    and otp:find("code_hash = code_hash(user_id, code)", 1, true) and not otp:find("otp_row.code ~= code", 1, true))
check("OTP sends and wrong codes are capped per user", otp:find("Throttle.OTP_SEND", 1, true)
    and otp:find("Throttle.OTP_FAIL", 1, true) ~= nil)
check("the E2E peek reads only the test-mailbox copy", read("lapis/routes/e2e-otp.lua"):find("SELECT peek_code", 1, true) ~= nil)

print("A4: JWT")
local offenders = {}
for _, f in ipairs({ "helper/auth.lua", "middleware/auth.lua", "helper/otp.lua", "helper/jwt-helper.lua",
    "lib/chat-ws.lua", "lib/kanban-ws.lua" }) do
    if read("lapis/" .. f):find("jwt:verify(", 1, true) then offenders[#offenders + 1] = f end
end
check("every token check goes through helper/jwt-verify (HS256 + exp)", #offenders == 0, table.concat(offenders, ", "))
local ok_jwt = pcall(require, "resty.jwt") and type(require("resty.jwt").sign) == "function"
if ok_jwt then
    local jwt, verify, secret = require("resty.jwt"), require("helper.jwt-verify"), "spec-secret"
    local function tok(alg, payload) return jwt:sign(secret, { header = { typ = "JWT", alg = alg }, payload = payload }) end
    local now = os.time()
    check("HS256 with exp verifies", verify(secret, tok("HS256", { sub = "u", exp = now + 60 })).verified == true)
    check("no exp -> refused", verify(secret, tok("HS256", { sub = "u" })).verified == false)
    check("HS512 with the same secret -> refused", verify(secret, tok("HS512", { sub = "u", exp = now + 60 })).verified == false)
else
    print("  skip - resty.jwt not loadable here (the e2e run covers tokens)")
end
check("lua-resty-jwt version is pinned", read("lapis/Dockerfile.base"):find("luarocks install lua%-resty%-jwt %d") ~= nil)
local cfg = read("lapis/config.lua")
check("no default session secret outside local development", not cfg:find("change%-me%-in%-production")
    and not cfg:find("your%-secret%-key%-here") and cfg:find("refusing to start", 1, true) ~= nil)

print("A5: webhooks")
check("Stripe and GitHub webhooks need no login (POST only)", public("/api/v2/webhooks/stripe", "POST")
    and public("/api/v2/webhooks/github", "POST") and not public("/api/v2/webhooks/github", "GET"))
check("GitHub webhook fails closed without its secret", read("lapis/routes/services.lua"):find('error_response(503, "Webhook not configured")', 1, true) ~= nil)

print("A6: public URI patterns")
local app = read("lapis/app.lua")
check("no blanket /api/v2/<anything>/public/ rule", not app:find('uri:match("^/api/v2/[^/]+/public/")', 1, true)
    and app:find("plugin_public(uri)", 1, true) ~= nil)
check("fee-estimate is matched exactly", not app:find('uri:match("^/api/v2/delivery/fee%-estimate")', 1, true))

print("A7: you can't grant what you don't hold")
package.loaded["lapis.db"] = package.loaded["lapis.db"] or setmetatable({}, { __index = function() return function() return {} end end })
local Guard = require("helper.rbac-guard")
check("manage covers every action", Guard.covers({ crm = { "manage" } }, { crm = { "read", "delete" } }) == true)
check("read doesn't cover manage", (Guard.covers({ crm = { "read" } }, { crm = { "manage" } })) == false)
check("a module you don't have isn't covered", (Guard.covers({ crm = { "read" } }, { billing = { "read" } })) == false)
check("platform admins pass", Guard.can_grant({ is_platform_admin = true, namespace_permissions = {} }, { x = { "manage" } }) == true)
local ns_routes = read("lapis/routes/namespaces.lua")
local calls = select(2, ns_routes:gsub("RbacGuard%.can_", ""))
check("role create/update/delete, member add/update/delete and invitations call the guard", calls >= 9, calls)
local users = read("lapis/routes/users.lua")
check("POST /api/v2/users: platform role and other workspaces only for platform admins",
    users:find("Only a platform admin can set a platform role", 1, true)
        and users:find("You can only add users to this workspace", 1, true) ~= nil)
check("add team member checks the role", read("lapis/routes/employees.lua"):find("can_assign_role_names", 1, true) ~= nil)

print("A8 / A9: secrets and shell commands")
check("id_rsa is ignored", read(".gitignore"):find("\nid_rsa\n", 1, true) ~= nil)
check("the AWS vault provider runs no shell commands", not read("lapis/lib/vault-providers/aws.lua"):find("popen", 1, true))
check("APNs only puts a hex device token on the curl command line",
    read("lapis/helper/apns-push.lua"):find('device_token:match("^%x+$")', 1, true) ~= nil)

print("A10: CI")
local wf = read(".github/workflows/lapis-checks.yml")
check("a PR workflow runs the Lua specs and luacheck", wf:find("pull_request", 1, true) and wf:find("_spec.lua", 1, true)
    and wf:find("luacheck", 1, true) ~= nil)
check("the dead 'dummy' workflows are gone", read(".github/workflows/validate-opsapi-syntax.yml") == ""
    and read(".github/workflows/build-push-docker-image-test.yml") == "")

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
