--[[
    Regression spec: user-scoped API keys ("personal access tokens").

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/api-keys-user-scoped_spec.lua

    An API key may be bound to a user (api_keys.user_uuid): when set,
    authenticate() must make the principal act AS that user (uuid = user's
    uuid), so per-user routes (kanban my-tasks, time-entry attribution) behave
    as the employee. Unbound keys must keep their historical machine identity.
    This guards the wiring that makes the OpsAPI kanban MCP server work.
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
local function has(s, needle)
    return s:find(needle, 1, true) ~= nil
end

print("migration:")
local mig = read("lapis/migrations/api-keys.lua")
check("adds a user_uuid column", has(mig, 'ADD COLUMN user_uuid'))
check("guards the add with column_exists", has(mig, "column_exists"))
local reg = read("lapis/migrations.lua")
check("registers the user_uuid migration step", has(reg, "api_key_migrations[2]"))

print("\nauthenticate (helper/api-key.lua):")
local ak = read("lapis/helper/api-key.lua")
check("selects ak.user_uuid", has(ak, "ak.user_uuid"))
check("joins users to resolve the bound identity", has(ak, "LEFT JOIN users"))
-- A bound key acts as the user; an unbound key keeps the key's own uuid.
check("sets principal.uuid to the bound user", has(ak, "principal.uuid = bound"))
check("falls back to the key uuid when unbound", has(ak, "principal.uuid = row.uuid"))
-- Must stay a key principal — tenant confinement (permits_uri / ns match) rides on it.
check("keeps api_key = true", has(ak, "api_key = true"))

print("\ncreate (queries + route):")
local q = read("lapis/queries/ApiKeyQueries.lua")
check("create() persists user_uuid", has(q, "user_uuid = params.user_uuid"))
local route = read("lapis/routes/api-keys.lua")
check("create route reads body.user_uuid", has(route, "body.user_uuid"))
-- Binding must be capped to the tenant: the user has to be a namespace member.
check("validates the bound user is a namespace member",
    has(route, "NamespaceMemberQueries.findByUserAndNamespace"))
check("passes user_uuid into ApiKeyQueries.create", has(route, "user_uuid = user_uuid"))

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
