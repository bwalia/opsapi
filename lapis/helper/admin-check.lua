--[[
    Centralized Platform Admin Check

    Single source of truth for determining if a user has the platform
    "administrative" role. Used across middleware, routes, and helpers.

    Strategy:
    1. Fast path: exact match on JWT claims (no DB hit)
    2. Fallback: DB query for reliability (JWT may be stale or incomplete)
]]

local db = require("lapis.db")

local AdminCheck = {}

--- Check if a role name string is the platform admin role
-- Uses exact match on "administrative" — NOT substring matching
-- @param role_name string The role name to check
-- @return boolean
local function isAdministrativeRole(role_name)
    if not role_name or role_name == "" then return false end
    return role_name:lower() == "administrative"
end

--- Check if user is a platform admin (has "administrative" role)
-- Fast path via JWT claims, DB fallback for reliability
-- @param user table User object from JWT (must have .uuid for DB fallback)
-- @return boolean
function AdminCheck.isPlatformAdmin(user)
    if not user then return false end

    -- Fast path: Check JWT claims first (avoids DB hit)

    -- Check primary role (string - userinfo.roles)
    if user.roles then
        if type(user.roles) == "string" then
            if isAdministrativeRole(user.roles) then
                return true
            end
        elseif type(user.roles) == "table" then
            for _, role in ipairs(user.roles) do
                local role_name = type(role) == "string" and role or (role.role_name or role.name or "")
                if isAdministrativeRole(role_name) then
                    return true
                end
            end
        end
    end

    -- Check user_roles array (userinfo.user_roles)
    if user.user_roles then
        if type(user.user_roles) == "table" then
            for _, role in ipairs(user.user_roles) do
                local role_name = type(role) == "string" and role or (role.role_name or role.name or "")
                if isAdministrativeRole(role_name) then
                    return true
                end
            end
        end
    end

    -- DB fallback: JWT may be stale, missing, or generated without roles
    if user.uuid then
        local ok, admin_check = pcall(db.query, [[
            SELECT ur.id FROM user__roles ur
            JOIN roles r ON ur.role_id = r.id
            JOIN users u ON ur.user_id = u.id
            WHERE u.uuid = ? AND LOWER(r.role_name) = 'administrative'
            LIMIT 1
        ]], user.uuid)

        if ok and admin_check and #admin_check > 0 then
            return true
        end
    end

    return false
end

--- Does the user hold any of these platform roles? Exact names, never
-- substrings ("admin" must not match "sysadmin" or "administrative_viewer").
-- JWT claims first, then the database (claims can be stale).
-- @param user table   JWT user info (uuid for the DB fallback)
-- @param names table  role names, e.g. { "administrative", "tax_admin" }
-- @return boolean
function AdminCheck.hasAnyRole(user, names)
    if not user or type(names) ~= "table" or #names == 0 then return false end
    local wanted, lowered = {}, {}
    for i, n in ipairs(names) do
        wanted[n:lower()] = true
        lowered[i] = n:lower()
    end
    local function claims(v)
        if type(v) == "string" then
            for role in v:gmatch("[^,]+") do
                if wanted[role:match("^%s*(.-)%s*$"):lower()] then return true end
            end
        elseif type(v) == "table" then
            for _, role in ipairs(v) do
                local name = type(role) == "string" and role or (type(role) == "table" and (role.role_name or role.name))
                if type(name) == "string" and wanted[name:lower()] then return true end
            end
        end
        return false
    end
    if claims(user.roles) or claims(user.user_roles) then return true end

    local uuid = user.uuid
    if type(uuid) ~= "string" or uuid == "" then return false end
    local placeholders = {}
    for i = 1, #lowered do placeholders[i] = "?" end
    local ok, rows = pcall(db.query, [[
        SELECT 1 FROM user__roles ur
        JOIN roles r ON r.id = ur.role_id
        JOIN users u ON u.id = ur.user_id
        WHERE u.uuid = ? AND LOWER(r.role_name) IN (]] .. table.concat(placeholders, ", ") .. [[)
        LIMIT 1
    ]], uuid, unpack(lowered))
    return ok and rows ~= nil and #rows > 0
end

return AdminCheck
