--[[
    RBAC guard: you can't grant what you don't have
    ================================================

    Every change to who-can-do-what in a workspace goes through here: creating,
    editing or deleting a role, giving a role to a member (add, edit, invite,
    "add team member", create user), and editing or removing a member.

      * You can only grant permissions you hold yourself. `manage` on a module
        covers every action on it; granting `manage` needs `manage`.
      * You can't change or remove a member, or edit or delete a role, that has
        permissions you don't hold (nobody manages someone above them).
      * Only the owner (or a platform admin) can change or remove the owner.

    Platform admins (the `administrative` platform role) pass every check.

    Each check returns true, or false + a message for a 403.
]]

local cjson = require("cjson.safe")
local db = require("lapis.db")

local Guard = {}

local function decode(p)
    if type(p) == "string" then
        p = cjson.decode(p)
    end
    return type(p) == "table" and p or {}
end

--- Does `holder` include every action in `wanted`? (module -> { actions })
-- @return true | false, "module.action" (the first one missing)
function Guard.covers(holder, wanted)
    holder, wanted = decode(holder), decode(wanted)
    for module, actions in pairs(wanted) do
        if type(actions) == "table" then
            local have = {}
            for _, a in ipairs(type(holder[module]) == "table" and holder[module] or {}) do
                have[a] = true
            end
            for _, a in ipairs(actions) do
                if not (have.manage or have[a]) then
                    return false, tostring(module) .. "." .. tostring(a)
                end
            end
        end
    end
    return true
end

local function caller_perms(self)
    return self.namespace_permissions or {}
end

--- May the caller grant this permission map (role create/edit)?
function Guard.can_grant(self, wanted)
    if self.is_platform_admin then return true end
    local ok, missing = Guard.covers(caller_perms(self), wanted)
    if ok then return true end
    return false, "You can't grant " .. missing .. ": you don't have that permission yourself"
end

--- May the caller edit or delete this role? (only roles within their own permissions)
function Guard.can_change_role(self, role)
    if self.is_platform_admin then return true end
    local ok, missing = Guard.covers(caller_perms(self), role.permissions)
    if ok then return true end
    return false, "This role has permissions you don't have (" .. missing .. "), so you can't change it"
end

local function roles_where(self, column, values)
    local list = {}
    for _, v in ipairs(values) do
        if v ~= nil and v ~= "" then list[#list + 1] = v end
    end
    if #list == 0 then return {} end
    return db.select("id, role_name, permissions FROM namespace_roles WHERE namespace_id = ? AND "
        .. column .. " IN ?", self.namespace.id, db.list(list))
end

local function check_roles(self, roles)
    for _, role in ipairs(roles) do
        local ok, missing = Guard.covers(caller_perms(self), role.permissions)
        if not ok then
            return false, "You can't give the role '" .. tostring(role.role_name) .. "': it has permissions you "
                .. "don't have (" .. missing .. ")"
        end
    end
    return true
end

--- May the caller give these roles (by id) to someone?
function Guard.can_assign_role_ids(self, role_ids)
    if self.is_platform_admin then return true end
    if type(role_ids) ~= "table" then role_ids = role_ids ~= nil and { role_ids } or {} end
    local ids = {}
    for _, r in ipairs(role_ids) do ids[#ids + 1] = tonumber(r) end
    return check_roles(self, roles_where(self, "id", ids))
end

--- May the caller give these roles (by role_name) to someone?
function Guard.can_assign_role_names(self, names)
    if self.is_platform_admin then return true end
    if type(names) ~= "table" then names = names ~= nil and { names } or {} end
    return check_roles(self, roles_where(self, "role_name", names))
end

--- May the caller change or remove this member? (member row of this namespace)
function Guard.can_manage_member(self, member)
    if self.is_platform_admin then return true end
    local is_owner = member.is_owner == true or member.is_owner == "t" or member.is_owner == 1
    if is_owner and not self.is_namespace_owner then
        return false, "Only the workspace owner can change or remove the owner"
    end
    local theirs = require("queries.NamespaceMemberQueries").getPermissions(member.id)
    local ok, missing = Guard.covers(caller_perms(self), theirs)
    if ok then return true end
    return false, "This member has permissions you don't have (" .. missing .. "), so you can't change them"
end

return Guard
