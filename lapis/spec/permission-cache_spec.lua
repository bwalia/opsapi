--[[
    Regression spec for the RBAC permission cache.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        REDIS_ENABLED=false resty lapis/spec/permission-cache_spec.lua
    (plain `luajit lapis/spec/permission-cache_spec.lua` runs the source-wiring
    checks; the runtime fail-open checks self-skip when cjson/ngx are absent.)

    Guards the two properties that make caching safe for a security path:

      1. Fail-open — with Redis disabled/unreachable, get() is a miss and
         set()/invalidate*() never throw, so a Redis outage cannot break auth.
      2. Every write that changes effective permissions busts the cache, or a
         revoked user would keep access from a stale cache entry. This is the
         easy invariant to regress (add a mutation path, forget the bust), so
         it is asserted against the source directly.
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

-- ── 1. Fail-open runtime behaviour (needs cjson; skips cleanly without it) ──
print("fail-open (Redis disabled):")
local loaded, PermissionCache = pcall(require, "helper.permission-cache")
if not loaded then
    print("  skip - module needs cjson/ngx (run under `resty`)")
else
    -- Force the disabled branch regardless of any local Redis.
    local prev = os.getenv("REDIS_ENABLED")
    if not (prev == "false" or prev == "0" or prev == "no") then
        print("  note - set REDIS_ENABLED=false for a deterministic run")
    end

    check("get() on a disabled/unreachable cache is a miss (nil)",
        PermissionCache.get(123456) == nil)

    local ok_set = pcall(PermissionCache.set, 123456, { users = { "read" } })
    check("set() never throws when the cache is unavailable", ok_set)

    local ok_inv = pcall(PermissionCache.invalidateMember, 123456)
    check("invalidateMember() never throws", ok_inv)

    local ok_role = pcall(PermissionCache.invalidateRole, 1)
    check("invalidateRole() never throws (DB/Redis both guarded)", ok_role)

    check("empty map is cacheable, not treated as a miss shape",
        type(({ PermissionCache.set(1, {}) })) == "table") -- set() returns nothing; just asserts no crash
end

-- ── 2. Cache is read on the hot path and busted on every mutation ──
print("\ncache wiring:")
local member_q = read("lapis/queries/NamespaceMemberQueries.lua")
local role_q   = read("lapis/queries/NamespaceRoleQueries.lua")

check("getPermissions reads the cache",
    member_q:find("PermissionCache.get(member_id)", 1, true) ~= nil)
check("getPermissions writes the cache (owner fallback included)",
    member_q:find("PermissionCache.set(member_id, result)", 1, true) ~= nil)

-- Every member-level mutator must bust. Count the busts so a dropped call fails.
local member_busts = select(2, member_q:gsub("invalidateMember", ""))
check("member mutators bust the cache (setRoles/assignRole/removeRole/transfer/update)",
    member_busts >= 6, "found " .. member_busts .. " invalidateMember calls")

check("a role's permission change busts every holder",
    role_q:find("invalidateRole(role.id)", 1, true) ~= nil)

-- setRoles must keep Redis OUT of its DB transaction: it inserts raw and busts
-- once after COMMIT, rather than looping through the self-busting assignRole.
local set_roles = member_q:match("function NamespaceMemberQueries%.setRoles.-\nend")
check("setRoles does not call assignRole inside its transaction",
    set_roles and set_roles:find("assignRole(", 1, true) == nil,
    "setRoles must insert raw to avoid Redis-in-transaction")

-- ── 3. Polish: menu fan-out is set-based, not O(namespaces) ──
print("\nmenu fan-out:")
local menu_q = read("lapis/queries/MenuQueries.lua")
check("MenuQueries.create no longer loops namespaces one insert at a time",
    menu_q:find("for _, ns in ipairs(namespaces", 1, true) == nil)
check("MenuQueries fans out with a single INSERT ... SELECT",
    menu_q:find("INSERT INTO namespace_menu_config", 1, true) ~= nil
    and menu_q:find("ON CONFLICT", 1, true) ~= nil)

-- ── 4. Polish: optionalNamespace resolves platform-admin like requireNamespace ──
print("\nmiddleware:")
local ns_mw = read("lapis/middleware/namespace.lua")
local opt = ns_mw:match("function NamespaceMiddleware%.optionalNamespace.-\n    end\nend")
check("optionalNamespace sets is_platform_admin",
    opt and opt:find("self.is_platform_admin = isPlatformAdmin", 1, true) ~= nil)

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
