--[[
    Regression spec: in the tax app (PROJECT_CODE includes tax_copilot) a user
    can't make a workspace of their own, and can't write into another user's
    data. Any self-made namespace made its creator owner with every
    permission; FastAPI then treated that as access to every user's tax data.

    Standalone — run from the repo root with:
        luajit lapis/spec/tax-tenant-isolation_spec.lua
]]

package.path = "lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok)
    print((ok and "  ok   - " or "  FAIL - ") .. name)
    if not ok then failures = failures + 1 end
end

local function read(path)
    local f = assert(io.open(path))
    local src = f:read("*a")
    f:close()
    return src
end

-- Self-service workspaces follow PROJECT_CODE, with an explicit override.
local env = {}
local real_getenv = os.getenv
os.getenv = function(k) return env[k] end
local ProjectConfig = require("helper.project-config")
local function allows(code, override)
    env = { PROJECT_CODE = code, ALLOW_SELF_SERVICE_WORKSPACES = override }
    return ProjectConfig.allowsSelfServiceWorkspaces()
end
check("tax app: off", allows("tax_copilot") == false)
check("tax app + services (int/test/acc/prod): off", allows("tax_copilot,services") == false)
check("other products keep self-service", allows("billing") == true and allows("all") == true)
check("override true wins", allows("tax_copilot", "true") == true)
check("override false wins", allows("billing", "false") == false)
os.getenv = real_getenv

local ns = read("lapis/routes/namespaces.lua")
check("create route checks the switch before creating",
    ns:find("allowsSelfServiceWorkspaces%(%)", 1) ~= nil
    and ns:find("isPlatformAdmin%(self%.current_user%)", 1) ~= nil)

local bank = read("lapis/queries/TaxBankAccountQueries.lua")
check("bank account owner comes from the caller, not the body",
    bank:find("data%.namespace_id = nil") ~= nil
    and bank:find("if not data%.user_id then") == nil)

local docs = read("lapis/queries/DocumentQueries.lua")
check("documents never fall back to user 1 or a body user_id",
    docs:find("data%.user_id = 1") == nil and docs:find("data%.user_id or user_uuid") == nil)
check("documents insert an allowlisted row", docs:find("DocumentModel:create%(row") ~= nil)

local _, guards = read("lapis/routes/auth.lua"):gsub("if is_deactivated%(userWithRoles%) then", "")
check("deactivated accounts get no session on every sign-in path", guards == 4)
check("password check refuses deactivated accounts",
    read("lapis/queries/UserQueries.lua"):find("user%.active ~= false and bcrypt%.verify") ~= nil)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
