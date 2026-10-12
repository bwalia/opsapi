-- PA workspace setup (idempotent): Property Deals set up first (board, roles), PA permissions added to the
-- Property Deals roles (only modules a role doesn't have yet — a workspace's own edits stick), and the first
-- seller playbook seeded as approved company knowledge.
local cjson = require("cjson")
local db = require("lapis.db")

local S = {}

local CRU, R = { "create", "read", "update" }, { "read" }
S.GRANTS = {
    pd_operator = { property_pa_records = CRU, property_pa_updates = CRU, property_pa_knowledge = { "create", "read" },
                    property_pa_handoffs = CRU },
    pd_manager = { property_pa_records = { "manage" }, property_pa_updates = { "manage" },
                   property_pa_knowledge = { "manage" }, property_pa_handoffs = { "manage" } },
    -- The JobShout agents call in as a pd_agent service account: read, propose, never confirm.
    pd_agent = { property_pa_records = R, property_pa_updates = { "create", "read" },
                 property_pa_knowledge = { "create", "read" }, property_pa_handoffs = { "create", "read" } },
    pd_read_only = { property_pa_records = R, property_pa_updates = R, property_pa_knowledge = R, property_pa_handoffs = R },
}

--- Add the PA modules to the Property Deals roles, through NamespaceRoleQueries (validation, permission-cache
-- invalidation) and with a namespace audit row, as a role edit in the dashboard would be.
local function grant(ns, user_uuid)
    local Roles = require("queries.NamespaceRoleQueries")
    local actor = user_uuid and db.query("SELECT id FROM users WHERE uuid = ?", user_uuid)[1]
    local added = {}
    for role_name, mods in pairs(S.GRANTS) do
        local role = Roles.findByName(ns, role_name)
        if role then
            local before = role.permissions
            local ok, perms = pcall(cjson.decode, type(before) == "string" and before or cjson.encode(before or {}))
            if not ok or type(perms) ~= "table" then perms = {} end
            local changed = false
            for mod, actions in pairs(mods) do
                if perms[mod] == nil then perms[mod], changed = actions, true end
            end
            if changed then
                local updated = Roles.update(role.id, { permissions = perms })
                local Audit = require("queries.NamespaceAuditLogQueries")
                pcall(Audit.log, { namespace_id = ns, user_id = actor and actor.id,
                    action = "role.permissions_updated", entity_type = "namespace_role", entity_id = role.id,
                    old_values = { permissions = before, by = "property_pa setup" },
                    new_values = { permissions = updated and updated.permissions } })
                added[#added + 1] = role_name
            end
        end
    end
    table.sort(added)
    return added
end

--- The PA builds on Property Deals (tasks, properties, the mail it imports): it must be on in the workspace.
function S.deals_on(ns)
    return require("helper.plugin-workspaces").isEnabled("property_deals", ns)
end

function S.require_deals(ns)
    if not S.deals_on(ns) then
        require("property_deals.util").fail(409, "Turn Property Deals on for this workspace first: the PA builds on it")
    end
end

--- @return { roles_updated, knowledge_added }
function S.run(ns, user_uuid)
    S.require_deals(ns)
    local sdk = require("helper.plugin-sdk")
    require("property_deals.workspace").ensure(ns, user_uuid, sdk.settings("property_deals", ns))
    return {
        roles_updated = setmetatable(grant(ns, user_uuid), cjson.array_mt),
        knowledge_added = require("property_pa.knowledge").ensure(ns, user_uuid),
    }
end

return S
