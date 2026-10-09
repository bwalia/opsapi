--[[
    A pooled Redis connection (REDIS_ENABLED / REDIS_HOST / REDIS_PORT /
    REDIS_PASSWORD / REDIS_DB, as helper/permission-cache.lua). Fail-open:
    connect() returns nil when Redis is off or unreachable and callers fall
    back to the database or per-pod shared memory.
]]

local RedisClient = {}

function RedisClient.enabled()
    local val = os.getenv("REDIS_ENABLED")
    if val == nil or val == "" then return true end
    val = val:lower()
    return val ~= "false" and val ~= "0" and val ~= "no"
end

function RedisClient.connect()
    if not RedisClient.enabled() or not ngx or not ngx.socket then return nil end
    local ok, redis_mod = pcall(require, "resty.redis")
    if not ok then return nil end
    local red = redis_mod:new()
    red:set_timeouts(300, 300, 300)
    if not red:connect(os.getenv("REDIS_HOST") or "127.0.0.1", tonumber(os.getenv("REDIS_PORT")) or 6379) then
        return nil
    end
    -- A pooled connection is already authenticated and on the right database.
    if (red:get_reused_times() or 0) > 0 then return red end
    local password = os.getenv("REDIS_PASSWORD")
    if password and password ~= "" and not red:auth(password) then
        red:close()
        return nil
    end
    local dbnum = tonumber(os.getenv("REDIS_DB")) or 0
    if dbnum > 0 then red:select(dbnum) end
    return red
end

function RedisClient.release(red)
    if red and not pcall(function() red:set_keepalive(10000, 50) end) then pcall(function() red:close() end) end
end

return RedisClient
