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

return AdminCheck
