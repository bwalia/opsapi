--[[
    Regression spec: /api/v2/users/:id is scoped to the caller's workspace.

    Standalone — run from the repo root with:
        luajit lapis/spec/users-tenant-scope_spec.lua

    GET/PUT/DELETE /api/v2/users/:id used to reach EVERY account in the system
    for anyone holding users.* in any workspace: read any user (including the
    PIN hash), change any user's email (→ password reset → account takeover)
    or delete any account. They now resolve the target through target_user()
    (members of the caller's namespace; platform admins see all) and refuse
    account-wide changes for people who also belong to other workspaces.
]]

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

local routes = read("lapis/routes/users.lua")
local queries = read("lapis/queries/UserQueries.lua")

local function handler(method)
    local s = routes:find('app:' .. method .. '%("/api/v2/users/:id"')
    if not s then return "" end
    local e = routes:find("\n    app:", s + 10) or #routes
    return routes:sub(s, e)
end

print("users.lua :id routes")
for _, m in ipairs({ "get", "put", "delete" }) do
    check(m:upper() .. " resolves the target within the workspace", handler(m):find("target_user%(self, user_id%)") ~= nil)
end
check("target_user joins namespace_members on the caller's namespace",
    routes:find("JOIN namespace_members nm ON nm.user_id = u.id") ~= nil
        and routes:find("nm.namespace_id = %?") ~= nil)
check("PUT refuses identity changes for shared accounts",
    handler("put"):find("changes_identity") ~= nil and handler("put"):find("SHARED_ACCOUNT") ~= nil)
check("DELETE refuses shared accounts", handler("delete"):find("not target.exclusive") ~= nil)

print("UserQueries")
check("no bare `user.password = nil` left (use strip_secrets)",
    select(2, queries:gsub("user%.password = nil", "")) == 1) -- the one inside strip_secrets
check("strip_secrets removes the PIN hash", queries:find("user%.pin_hash = nil") ~= nil)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
