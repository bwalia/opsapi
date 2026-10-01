--[[
    Request context for the database
    ================================

    Tells Postgres who is acting, so triggers can record it (the audit trail
    in helper/plugin-events.lua). Session settings on the request's connection:

        opsapi.actor_uuid    signed-in user ('' when anonymous / system)
        opsapi.actor_via     jwt | api_key | anonymous | system
        opsapi.api_key_uuid  the key, when an API key made the request
        opsapi.actor_ip      client IP (helper/client-ip.lua)
        opsapi.request_id    nginx $request_id (matches the activity log)

    Connections are pooled, so the settings are applied EVERY time a request or
    timer takes a connection (never inherited from the previous user of that
    connection) and refreshed when authentication identifies the user later in
    the same request. Timers and the `lapis` CLI act as "system".
]]

local RequestContext = {}

local CTX = "pgmoon_default" -- lapis keeps the request's connection here

local function current()
    local phase = ngx and ngx.get_phase and ngx.get_phase()
    if not phase or phase == "timer" or phase == "init" or phase == "init_worker" then
        return "", "system", "", "", ""
    end
    local user = ngx.ctx.user
    local uuid = type(user) == "table" and user.uuid or nil
    if not uuid then
        return "", "anonymous", "", "", ""
    end
    local ok, ip = pcall(function() return require("helper.client-ip").get() end)
    return tostring(uuid), user.api_key and "api_key" or "jwt", user.api_key and tostring(user.key_uuid or "") or "",
        ok and ip or "", ngx.var.request_id or ""
end

local SQL = "SELECT set_config('opsapi.actor_uuid', %s, false), set_config('opsapi.actor_via', %s, false), "
    .. "set_config('opsapi.api_key_uuid', %s, false), set_config('opsapi.actor_ip', %s, false), "
    .. "set_config('opsapi.request_id', %s, false)"

--- Apply the current context to a pgmoon connection.
function RequestContext.apply(pgmoon)
    local uuid, via, key, ip, request_id = current()
    local e = function(v) return pgmoon:escape_literal(v) end
    local ok, err = pgmoon:query(SQL:format(e(uuid), e(via), e(key), e(ip), e(request_id)))
    if not ok then
        ngx.log(ngx.ERR, "[request-context] could not set actor on connection: ", tostring(err))
    end
end

--- Re-apply after authentication, if this request already holds a connection.
function RequestContext.refresh()
    local pgmoon = ngx and ngx.ctx and ngx.ctx[CTX]
    if pgmoon then
        pcall(RequestContext.apply, pgmoon)
    end
end

--- Hook every new/pooled connection (idempotent). lapis calls
-- logger.db_connection right after each connect, before any query runs.
function RequestContext.install()
    local logging = require("lapis.logging")
    if logging.__opsapi_request_context then return end
    local original = logging.db_connection
    logging.db_connection = function(db, pgmoon, success, connect_err)
        if original then original(db, pgmoon, success, connect_err) end
        if success and pgmoon then
            pcall(RequestContext.apply, pgmoon)
        end
    end
    logging.__opsapi_request_context = true
end

return RequestContext
