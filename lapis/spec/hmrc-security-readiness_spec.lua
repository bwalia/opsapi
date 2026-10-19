--[[
    Regression spec: HMRC Developer Hub security terms (19 Oct 2026 review).

    Encrypted secrets are AES-GCM with a random nonce ("v2:"), outbound TLS to
    Google/Apple/HMRC is verified, OAuth sign-in carries a CSRF nonce and needs
    a provider-verified email, CORS trusts localhost only when asked, and a
    legacy-refresh chain can't outlive JWT_MAX_SESSION_SECONDS.
    The Lua<->Python v2 round trip itself is exercised in the opsapi image
    (see the PR); this checks the code can't quietly regress.

    Standalone — run from the repo root with:
        luajit lapis/spec/hmrc-security-readiness_spec.lua
]]

local failures = 0
local function check(name, ok)
    print((ok and "  ok   - " or "  FAIL - ") .. name)
    if not ok then failures = failures + 1 end
end
local function read(path)
    local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s
end

local global = read("lapis/helper/global.lua")
check("secrets written as v2 AES-GCM", global:find('"aes%-256%-gcm"') and global:find('SECRET_V2 = "v2:"'))
check("each value gets a fresh random nonce", global:find('resty%.openssl%.rand"%)%.bytes%(12%)'))
check("v2 values are decrypted with their tag", global:find("decryptGcm%(encodedSecret"))

local mig = read("lapis/migrations/tax-copilot-system.lua")
check("migration re-encrypts HMRC tokens and NINOs", mig:find("%[92%] = function")
    and mig:find('db%.update%("hmrc_tokens"') and mig:find('db%.update%("tax_user_profiles"'))

for _, f in ipairs({ "lapis/routes/auth.lua", "lapis/helper/apple-signin.lua", "lapis/helper/fcm-push.lua",
                     "lapis/helper/hibp.lua", "lapis/routes/tax-hmrc-auth.lua" }) do
    check(f .. " verifies TLS", read(f):find("ssl_verify *= *false") == nil)
end
check("HMRC calls always verify TLS", read("lapis/helper/hmrc.lua"):find("local function tls_verify%(%)\n    return true"))

local auth = read("lapis/routes/auth.lua")
local _, issued = auth:gsub("nonce = issue_oauth_nonce%(%)", "")
local _, checked = auth:gsub("not oauth_nonce_matches%(state_data%)", "")
check("Google and Apple sign-in start with a nonce", issued == 2)
check("both callbacks require it", checked == 2)
check("Google web sign-in needs a verified email", auth:find("google_user%.verified_email ~= true"))
check("Google id_token sign-in needs a verified email", auth:find('token_info%.email_verified ~= "true"'))

check("localhost CORS is opt-in", read("lapis/middleware/cors.lua"):find("if ALLOW_LOCALHOST and isLocalhostOrigin"))

local jwt = read("lapis/helper/jwt-helper.lua")
check("tokens carry auth_time", jwt:find("auth_time = options%.auth_time or now"))
check("legacy refresh stops after the max session", jwt:find("ngx%.time%(%) %- auth_time > MAX_SESSION_SECONDS"))

local app = read("lapis/app.lua")
local _, gated = app:gsub("local hidden = api_docs_hidden%(%); if hidden then return hidden end", "")
check("API docs and OpenAPI spec are off unless EXPOSE_API_DOCS=true", gated == 4)

local nginx = read("lapis/nginx.conf")
check("/metrics refuses requests that came through the edge",
    nginx:find("location /metrics {[^}]-if %(%$http_x_forwarded_for%)"))
for _, var in ipairs({ "SECRETS_ENCRYPTION_FORMAT", "CORS_ALLOW_LOCALHOST", "JWT_MAX_SESSION_SECONDS",
                       "ALLOW_SELF_SERVICE_WORKSPACES", "EXPOSE_API_DOCS" }) do
    check("nginx passes " .. var .. " to Lua", nginx:find("\nenv " .. var .. ";\n", 1, true))
end

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
