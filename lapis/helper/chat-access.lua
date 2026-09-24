local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")

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

return ChatAccess
