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

local function grant(ns)
    local added = {}
    for role_name, mods in pairs(S.GRANTS) do
        local role = db.query("SELECT id, permissions FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", ns,
            role_name)[1]
        if role then
            local perms = role.permissions
            if type(perms) == "string" then perms = select(2, pcall(cjson.decode, perms)) end
            if type(perms) ~= "table" then perms = {} end
            local changed = false
            for mod, actions in pairs(mods) do
                if perms[mod] == nil then perms[mod], changed = actions, true end
            end
            if changed then
                db.update("namespace_roles", { permissions = cjson.encode(perms), updated_at = db.raw("NOW()") }, { id = role.id })
                added[#added + 1] = role_name
            end
        end
    end
    table.sort(added)
    return added
end

--- @return { roles_updated, knowledge_added }
function S.run(ns, user_uuid)
    local sdk = require("helper.plugin-sdk")
    require("property_deals.workspace").ensure(ns, user_uuid, sdk.settings("property_deals", ns))
    return {
        roles_updated = setmetatable(grant(ns), cjson.array_mt),
        knowledge_added = require("property_pa.knowledge").ensure(ns, user_uuid),
    }
end

return S
