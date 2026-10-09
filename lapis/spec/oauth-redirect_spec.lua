--[[
    Regression spec: a Google sign-in only sends the token to a trusted origin.

    Standalone — run from the repo root with:
        luajit lapis/spec/oauth-redirect_spec.lua

    /auth/google/callback redirected to <frontend_url from the OAuth state>
    /auth/callback?token=<JWT>. The state is attacker-controlled (the Google
    client id is public), so a link with frontend_url=https://evil.example
    handed the victim's session token to the attacker.
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

local trusted = require("middleware.cors").trustedFrontend
local configured = { ["https://app.diytaxreturn.co.uk"] = true }

print("refused:")
for _, url in ipairs({
    "https://evil.example",
    "https://evil.example/",
    "https://app.diytaxreturn.co.uk.evil.example",
    "https://app.diytaxreturn.co.uk@evil.example",
    "https://app.diytaxreturn.co.uk/redirect?to=https://evil.example",
    "//evil.example",
    "javascript:alert(1)",
    "",
}) do
    check(url, trusted(url, configured) == nil, trusted(url, configured))
end
check("not a string", trusted({}, configured) == nil and trusted(nil, configured) == nil)

print("accepted:")
local app = "https://app.diytaxreturn.co.uk"
check("a configured frontend", trusted(app, configured) == app)
check("trailing slash dropped", trusted(app .. "/", configured) == app)
check("localhost (CORS always trusts it)", trusted("http://localhost:8039", {}) == "http://localhost:8039")

print("wired into the callback:")
local h = assert(io.open("lapis/routes/auth.lua") or io.open("routes/auth.lua"))
local src = h:read("*a")
h:close()
check("state.frontend_url goes through trustedFrontend",
    src:find('state_frontend_url = require("middleware.cors").trustedFrontend(state_data.frontend_url,', 1, true) ~= nil
    and not src:find("state_frontend_url = state_data.frontend_url", 1, true))

print(failures == 0 and "\nall OAuth redirect checks passed" or ("\n" .. failures .. " check(s) FAILED"))
os.exit(failures == 0 and 0 or 1)
