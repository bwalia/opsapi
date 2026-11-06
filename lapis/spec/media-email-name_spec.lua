--[[
    Spec: media library image addresses + the product name in sign-in emails.

    Standalone, from the repo root:
        luajit lapis/spec/media-email-name_spec.lua
    (CI runs it in the OpenResty image: .github/workflows/lapis-checks.yml.)
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
    local h = assert(io.open(path))
    local s = h:read("*a")
    h:close()
    return s
end

-- Only request_base is exercised: stub what needs a running app.
package.loaded["lapis.db"] = {}
package.loaded["helper.minio"] = {}
local Media = require("lib.media-library")

print("image addresses: https on every public host (the proxies in front say http)")
for host, want in pairs({
    ["opsapi.workstation.co.uk"] = "https://opsapi.workstation.co.uk",
    ["int-opsapi.workstation.co.uk:443"] = "https://int-opsapi.workstation.co.uk:443",
    ["127.0.0.1:4020"] = "http://127.0.0.1:4020",
    ["localhost:4010"] = "http://localhost:4010",
    ["[::1]:4010"] = "http://[::1]:4010",
    ["opsapi.localhost"] = "http://opsapi.localhost",
    ["api.test"] = "http://api.test",
    ["localhost.evil.com"] = "https://localhost.evil.com",
}) do
    local got = Media.request_base(host)
    check(host .. " -> " .. want, got == want, got)
end

print("website storage: every CMS_PUBLIC_* setting is visible to the app")
local names = {}
for name in read("lapis/helper/cms-public-media.lua"):gmatch('env%("([A-Z0-9_]+)"') do names[name] = true end
check("cms-public-media reads CMS_PUBLIC_* settings", next(names) ~= nil)
for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    local text = read(conf)
    for name in pairs(names) do
        check(conf .. " declares " .. name, text:find("\nenv " .. name .. ";", 1, true) ~= nil)
    end
end
check("no AWS_* fallback (only the CMS_PUBLIC_S3 keys switch storage)",
    not read("lapis/helper/cms-public-media.lua"):find('env%("AWS_'))

print("sign-in emails: no product name baked in")
check("otp.lua has no DIY Tax Return fallback", not read("lapis/helper/otp.lua"):find("or \"DIY Tax Return\"", 1, true))
check("otp.lua falls back to the workspace / deployment name",
    read("lapis/helper/otp.lua"):find("emailNameForUser(user.id)", 1, true) ~= nil)
check("password reset uses the same name",
    read("lapis/routes/auth.lua"):find("NamespaceQueries.emailNameForUser(user.id)", 1, true) ~= nil)

if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("all passed")
