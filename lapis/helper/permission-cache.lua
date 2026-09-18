--[[
    Permission Cache
    ================

    Cache-aside for a namespace member's resolved permission map
    (NamespaceMemberQueries.getPermissions). Resolving permissions runs a role
    query + a JSON decode per role, and the namespace middleware does it on
    EVERY authenticated namespaced request — so at load it is the hottest RBAC
    cost. This caches the computed map in Redis, keyed by member id.

    Correctness (why a cache is safe for a security-sensitive path): every write
    that can change a member's effective permissions busts the cache explicitly,
    so a role change / revocation is reflected on the next request across ALL
    pods (Redis is shared; a per-worker/per-pod cache could not do this):
      - a member's role set changes  -> invalidateMember(member_id)
        (setRoles / assignRole / removeRole / ownership transfer)
      - a role's permissions change  -> invalidateRole(role_id)
        (busts every member holding that role)
    The short TTL is only a safety net for a path not wired to a bust (e.g. a
    platform admin adding a new global module, which only *widens* an owner map).

    Fail-open: missing / unreachable / disabled Redis degrades to direct DB
    resolution — the getter returns nil (a miss) and nothing here throws, so a
    Redis outage can never take down auth. Behaviour is identical to the
    pre-cache code when REDIS_ENABLED is off.

    Env: REDIS_HOST/PORT/PASSWORD/DB (shared with theme-cache) and REDIS_ENABLED.
]]

local cjson = require("cjson")

local PermissionCache = {}

local KEY_PREFIX      = "nsperm:v1:"
local CONNECT_TIMEOUT = 500   -- ms
local READ_TIMEOUT    = 500   -- ms
-- ponytail: safety net only — explicit invalidation covers every real write
-- path, so this bounds staleness solely for a path not wired to a bust.
local TTL_SECONDS     = 300

local function redis_enabled()
    local val = os.getenv("REDIS_ENABLED")
    if val == nil or val == "" then return true end
    val = val:lower()
    return val ~= "false" and val ~= "0" and val ~= "no"
end

-- Acquire a pooled Redis client; returns nil on any failure (fail-open).
local function connect()
    if not redis_enabled() then return nil end

    local ok, redis_mod = pcall(require, "resty.redis")
    if not ok then return nil end
    if not ngx or not ngx.socket then return nil end

    local red = redis_mod:new()
    red:set_timeouts(CONNECT_TIMEOUT, READ_TIMEOUT, READ_TIMEOUT)

    local ok_conn = red:connect(os.getenv("REDIS_HOST") or "127.0.0.1",
        tonumber(os.getenv("REDIS_PORT")) or 6379)
    if not ok_conn then return nil end

    local password = os.getenv("REDIS_PASSWORD")
    if password and password ~= "" then
        if not red:auth(password) then return nil end
    end

    local dbnum = tonumber(os.getenv("REDIS_DB")) or 0
    if dbnum > 0 then red:select(dbnum) end

    return red
end

-- Return the connection to the pool (or close if pooling fails).
local function release(red)
    if not red then return end
    local ok = pcall(function() red:set_keepalive(10000, 50) end)
    if not ok then pcall(function() red:close() end) end
end

local function key(member_id)
    return KEY_PREFIX .. tostring(member_id)
end

--- Read a member's cached permission map. Returns nil on miss / any failure.
-- @param member_id number|string Namespace member id
-- @return table|nil The permission map, or nil for a miss
function PermissionCache.get(member_id)
    if member_id == nil then return nil end
    local red = connect()
    if not red then return nil end

    local res = red:get(key(member_id))
    release(red)

    if not res or res == ngx.null or res == "" then return nil end
    local ok, perms = pcall(cjson.decode, res)
    if not ok or type(perms) ~= "table" then return nil end
    return perms
end

--- Store a member's permission map with the safety-net TTL.
-- An empty map (a member with no grants) is a valid, cacheable deny-all value.
-- @param member_id number|string Namespace member id
-- @param perms table The permission map to cache
function PermissionCache.set(member_id, perms)
    if member_id == nil or type(perms) ~= "table" then return end
    local red = connect()
    if not red then return end

    local ok, encoded = pcall(cjson.encode, perms)
    if ok and encoded then
        pcall(function()
            red:set(key(member_id), encoded)
            red:expire(key(member_id), TTL_SECONDS)
        end)
    end
    release(red)
end

--- Invalidate one member's cached permissions (their role set changed).
-- @param member_id number|string Namespace member id
function PermissionCache.invalidateMember(member_id)
    if member_id == nil then return end
    local red = connect()
    if not red then return end
    pcall(function() red:del(key(member_id)) end)
    release(red)
end

--- Invalidate every member holding a role (the role's permissions changed).
-- Enumerates the role's assignees so the bust is exact and cross-pod.
-- @param role_id number Namespace role id
function PermissionCache.invalidateRole(role_id)
    if role_id == nil then return end
    local db = require("lapis.db")
    local ok_rows, rows = pcall(db.query,
        "SELECT namespace_member_id FROM namespace_user_roles WHERE namespace_role_id = ?",
        role_id)
    if not ok_rows or not rows or #rows == 0 then return end

    local red = connect()
    if not red then return end
    local keys = {}
    for _, r in ipairs(rows) do
        table.insert(keys, key(r.namespace_member_id))
    end
    if #keys > 0 then
        pcall(function() red:del(unpack(keys)) end)
    end
    release(red)
end

return PermissionCache
