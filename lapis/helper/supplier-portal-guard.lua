--[[
    Supplier logins can only use the supplier portal
    ================================================
    Runs from the global before_filter in app.lua for every authenticated request. A user with a
    supplier_portal_users row (any status) is a supplier login: it may call /api/v2/supplier-portal/* and its own
    session routes (/auth/me, /auth/logout, /auth/refresh, /auth/change-password) and nothing else - every
    staff route answers 403, whatever role someone later gives that login in Settings → Roles, and whether or not
    the route checks RBAC itself. The supplier routes then check the supplier's own POs
    (queries/SupplierPortalQueries.lua).

    Per-worker cache of "is this user a supplier login" for 30 seconds (the row is never deleted in practice; a
    new supplier login is a new user, so a stale "no" cannot happen for it).
]]

local db = require("lapis.db")
local lrucache = require("resty.lrucache")

local Guard = {}

local TTL = 30
local cache = lrucache.new(10000)

Guard.ALLOWED = {
    "^/api/v2/supplier%-portal/",
    "^/api/v2/supplier%-portal$",
    "^/auth/me$",
    "^/auth/logout$",
    "^/auth/refresh$",
    "^/auth/change%-password$",
}

local table_ready = false
local function table_exists()
    if table_ready then return true end
    local ok, r = pcall(db.query, "SELECT to_regclass('public.supplier_portal_users') IS NOT NULL AS ok")
    table_ready = ok and r[1] and r[1].ok == true or false
    return table_ready
end

--- Is this user (by uuid) a supplier login?
function Guard.isSupplier(user_uuid)
    if not user_uuid or user_uuid == "" then return false end
    local hit = cache:get(user_uuid)
    if hit ~= nil then return hit end
    if not table_exists() then return false end
    local ok, rows = pcall(db.query, [[SELECT 1 AS x FROM supplier_portal_users spu JOIN users u ON u.id = spu.user_id
                                         WHERE u.uuid = ? LIMIT 1]], user_uuid)
    if not ok then
        -- fail closed for this request, don't remember it
        ngx.log(ngx.ERR, "[supplier-portal-guard] lookup failed: ", tostring(rows))
        return true
    end
    local is = rows[1] ~= nil
    cache:set(user_uuid, is, TTL)
    return is
end

function Guard.allowed(uri)
    for _, p in ipairs(Guard.ALLOWED) do
        if uri:match(p) then return true end
    end
    return false
end

--- nil to continue, or a response table to refuse the request.
function Guard.check(self, uri)
    local user = self.current_user
    if not user or user.api_key or ngx.ctx.api_key_auth then return nil end
    if Guard.allowed(uri) then return nil end
    if not Guard.isSupplier(user.uuid) then return nil end
    return { status = 403,
             json = { error = "Supplier accounts can only use the supplier portal", code = "SUPPLIER_PORTAL_ONLY" } }
end

return Guard
