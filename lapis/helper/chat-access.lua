local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
local NamespaceRoleQueries = require("queries.NamespaceRoleQueries")
local AdminCheck = require("helper.admin-check")

-- Chat-module RBAC / tenancy gate for adding someone to a conversation.
--
-- A user may be pulled into a channel or a DM only when they can actually use
-- chat in that workspace. `user_has_chat` is true only when the target is an
-- ACTIVE member of the given namespace whose effective, role-driven permissions
-- include the `chat` module (owner-fallback included, via getPermissions —
-- the platform's canonical resolver, so this can never drift from how access is
-- computed everywhere else). This closes two holes at once:
--   * RBAC — a member whose role doesn't grant chat is rejected.
--   * tenancy — a member of a *different* namespace has no membership here, so
--     they're rejected (can't be reached across the tenant boundary).
local ChatAccess = {}

-- Dedicated, additive role used to grant a single member chat access without
-- touching any shared role. Created once per namespace, on demand.
local CHAT_ROLE = "chat_access"

function ChatAccess.user_has_chat(user_uuid, namespace_id)
    if not user_uuid or user_uuid == "" or not namespace_id then
        return false
    end

    local membership = NamespaceMemberQueries.findByUserAndNamespace(user_uuid, namespace_id)
    if not membership then
        return false
    end
    if membership.status and membership.status ~= "active" then
        return false
    end

    local perms = NamespaceMemberQueries.getPermissions(membership.id)
    local chat = perms and perms["chat"]
    return type(chat) == "table" and #chat > 0
end

--- Can this actor grant chat access to others in this namespace?
-- True for a platform admin, the namespace owner, or anyone whose role can
-- manage namespace roles/permissions (namespace.manage or roles.manage).
function ChatAccess.can_grant(actor_uuid, namespace_id, current_user)
    if current_user and AdminCheck.isPlatformAdmin(current_user) then
        return true
    end
    if not actor_uuid or not namespace_id then
        return false
    end

    local membership = NamespaceMemberQueries.findByUserAndNamespace(actor_uuid, namespace_id)
    if not membership then
        return false
    end
    if membership.is_owner == true or membership.is_owner == "t" or membership.is_owner == 1 then
        return true
    end

    local perms = NamespaceMemberQueries.getPermissions(membership.id)
    local function can_manage(module)
        local actions = perms and perms[module]
        if type(actions) ~= "table" then return false end
        for _, a in ipairs(actions) do
            if a == "manage" then return true end
        end
        return false
    end
    return can_manage("namespace") or can_manage("roles")
end

-- Ensure the namespace has the additive "chat_access" role and return it.
local function ensure_chat_role(namespace_id)
    local role = NamespaceRoleQueries.findByName(namespace_id, CHAT_ROLE)
    if role then return role end

    local ok, created = pcall(NamespaceRoleQueries.create, {
        namespace_id = namespace_id,
        role_name = CHAT_ROLE,
        display_name = "Chat Access",
        description = "Grants access to the Chat module. Assigned when an admin adds someone to a chat.",
        permissions = { chat = { "read", "create", "update", "delete" } },
        priority = 10
    })
    if ok and created then return created end

    -- Lost a create race (unique role_name per namespace) — re-read.
    return NamespaceRoleQueries.findByName(namespace_id, CHAT_ROLE)
end

--- Grant chat access to a namespace member by assigning the additive chat role.
-- The target MUST already be an active member of the namespace (you can't grant
-- across the tenant boundary). Returns true, or false + reason.
function ChatAccess.grant_chat(user_uuid, namespace_id)
    if not user_uuid or not namespace_id then
        return false, "bad_request"
    end

    local membership = NamespaceMemberQueries.findByUserAndNamespace(user_uuid, namespace_id)
    if not membership then
        return false, "not_a_member"
    end
    if membership.status and membership.status ~= "active" then
        return false, "inactive"
    end

    local role = ensure_chat_role(namespace_id)
    if not role then
        return false, "role_error"
    end

    -- assignRole dedups and busts the member's permission cache itself.
    NamespaceMemberQueries.assignRole(membership.id, role.id)
    return true
end

return ChatAccess
