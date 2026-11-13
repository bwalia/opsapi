--[[
    Spec: statements uploaded from the File My Tax chat are classified with the
    right business profile.

    Without a saved profile the classifier falls back to "sole_trader", which filed a
    landlord's rents as other income and their repairs as equipment repairs. The worker
    (routes/tax-process.lua) now passes profile_type=landlord when the chat session's
    income types are property only and the user hasn't saved a profile of their own.

    From the repo root: luajit lapis/spec/tax-process-profile_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then print("  ok   - " .. name) else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

_G.ngx = setmetatable({ var = {}, ctx = {}, log = function() end, ERR = 3, INFO = 7, time = os.time },
    { __index = function() return function() end end })

-- Stubs: just enough for the route module to load outside nginx.
local saved_profile = nil
package.loaded["lapis.db"] = {
    query = function() return {} end,
    select = function(q) if q:find("tax_user_profiles", 1, true) then return saved_profile and { { default_profile_key = saved_profile } } or {} end return {} end,
    raw = function(x) return x end, escape_literal = function(x) return "'" .. tostring(x) .. "'" end, NULL = {},
}
package.loaded["resty.http"] = { new = function() return {} end }
package.loaded["middleware.auth"] = { requireAuth = function(f) return f end }
package.loaded["helper.jwt-helper"] = { verifyToken = function() return { valid = false } end, reissue = function() return nil end }
package.loaded["cjson"] = package.loaded["cjson"] or (function()
    local ok, c = pcall(require, "cjson"); if ok then return c end
    return { encode = function() return "{}" end, decode = function(s)
        local t = {}; for w in tostring(s):gmatch('"([%w_]+)"') do t[#t + 1] = w end; return t end }
end)()

local route = require("routes.tax-process")
local profile = route._classify_profile
check("module exposes classify_profile for tests", type(profile) == "function")

if type(profile) == "function" then
    print("which profile the worker asks for")
    check("property only (chat key) -> landlord", profile({ income_types = { "uk_property" } }, 1) == "landlord")
    check("property only (My Income keys) -> landlord", profile({ income_types = { "rental", "overseas_property" } }, 1) == "landlord")
    check("jsonb as a string -> landlord", profile({ income_types = '["uk_property"]' }, 1) == "landlord")
    check("property + self-employment -> leave it to the classifier", profile({ income_types = { "uk_property", "self_employment" } }, 1) == nil)
    check("self-employment only -> leave it", profile({ income_types = { "self_employment" } }, 1) == nil)
    check("no income types yet -> leave it", profile({ income_types = {} }, 1) == nil)
    check("no chat session -> leave it", profile(nil, 1) == nil)
    saved_profile = "construction"
    check("user's saved profile wins", profile({ income_types = { "uk_property" } }, 1) == nil)
    saved_profile = nil
end

print("wiring (source)")
local h = io.open("lapis/routes/tax-process.lua"); local src = h:read("*a"); h:close()
check("classify call sends profile_type when set", src:find('body .. "&profile_type=" .. job.profile_type', 1, true) ~= nil)
check("session query reads income_types", src:find("SELECT id, namespace_id, user_id, income_types FROM tax_agent_sessions", 1, true) ~= nil)
check("job carries the profile", src:find("profile_type = classify_profile(session, user_id)", 1, true) ~= nil)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
