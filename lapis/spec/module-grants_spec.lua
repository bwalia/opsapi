--[[
    Spec: a module that already existed still reaches owners and admins.
    - scripts/setup-namespace.lua grants a module to owner/admin roles when it creates it
      (owners don't bypass RBAC, so an ungranted module is unusable).
    - migrations/vat-menu.lua step 3 grants vat / vat_agent to owner/admin roles in every
      workspace where no role has the key yet, and leaves a workspace that set it alone.
    Run from the repo root: /usr/local/openresty/luajit/bin/luajit lapis/spec/module-grants_spec.lua
]]
package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
local cjson = require("cjson")

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local roles = {
    { id = 1, namespace_id = 1, role_name = "owner", permissions = '{"crm":["manage"]}' },
    { id = 2, namespace_id = 1, role_name = "admin", permissions = '{"crm":["manage"]}' },
    { id = 3, namespace_id = 1, role_name = "member", permissions = '{}' },
    { id = 4, namespace_id = 2, role_name = "owner", permissions = '{}' },
    { id = 5, namespace_id = 2, role_name = "admin", permissions = '{"vat":[]}' }, -- took VAT away
}
package.loaded["lapis.db"] = {
    query = function(sql)
        if sql:find("to_regclass", 1, true) then return { { ok = true } } end
        return roles
    end,
    update = function(_, fields, where)
        for _, r in ipairs(roles) do if r.id == where.id then r.permissions = fields.permissions end end
    end,
}
local real_print = print
local function quiet(fn) _G.print = function() end; fn(); _G.print = real_print end
local step3 = require("migrations.vat-menu")[3]
quiet(step3)
local function perms(id) return cjson.decode(roles[id].permissions) end
check("workspace 1 owner gets vat + vat_agent", perms(1).vat and perms(1).vat_agent and perms(1).crm)
check("workspace 1 admin gets them too", perms(2).vat and perms(2).vat_agent)
check("members get nothing", perms(3).vat == nil and perms(3).vat_agent == nil)
check("workspace 2 set vat itself: vat left alone", perms(4).vat == nil and #perms(5).vat == 0)
check("...but vat_agent, which it never set, is granted", perms(4).vat_agent and perms(5).vat_agent)
local before = cjson.encode(roles); quiet(step3)
check("running it again changes nothing", cjson.encode(roles) == before)

local f = assert(io.open("lapis/scripts/setup-namespace.lua")); local setup = f:read("*a"); f:close()
local created = setup:find('print("  + Created module: " .. m.machine_name)', 1, true)
local grant = setup:find("propagateToNamespaceAdmins(m.machine_name, project_code)", 1, true)
check("setup-namespace grants a module right after creating it", created and grant and grant > created
    and grant - created < 600)

if failures > 0 then io.stdout:write(failures .. " FAILED\n") os.exit(1) end
io.stdout:write("all passed\n")
