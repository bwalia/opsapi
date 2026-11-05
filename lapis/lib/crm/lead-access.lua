--[[
    Who sees and works which lead
    =============================

    Managers (crm_leads "manage", i.e. workspace owners and admins by default,
    and any role given it) see and work every lead. Everyone else with
    crm_leads access sees the leads they own plus unassigned ones, so a new
    lead in the queue can be picked up. Platform admins count as managers.

    Routes call these with the Lapis request (`self`); background jobs never
    need them (they act for the system).
]]

local db = require("lapis.db")
local NamespaceMiddleware = require("middleware.namespace")

local Access = {}

function Access.is_manager(self)
    return NamespaceMiddleware.hasPermission(self, "crm_leads", "manage")
end

function Access.can(self, action)
    return NamespaceMiddleware.hasPermission(self, "crm_leads", action)
end

function Access.me(self)
    return self.current_user and self.current_user.uuid or nil
end

--- SQL fragment (for alias `alias`, default "l") restricting rows to what
-- this person may see, and its parameters.
function Access.scope(self, alias)
    alias = alias or "l"
    if Access.is_manager(self) then return "TRUE", {} end
    return "(" .. alias .. ".owner_user_uuid = ? OR " .. alias .. ".owner_user_uuid IS NULL)", { Access.me(self) }
end

local function owner_of(lead)
    local o = lead and lead.owner_user_uuid
    if o == nil or o == db.NULL or o == "" then return nil end
    return o
end

function Access.can_see(self, lead)
    if Access.is_manager(self) then return true end
    local o = owner_of(lead)
    return o == nil or o == Access.me(self)
end

--- May this person change the lead (stage, notes, calls, meetings)?
function Access.can_work(self, lead)
    if not Access.can(self, "update") then return false end
    return Access.can_see(self, lead)
end

--- May this person give the lead to `owner_uuid`? Managers give any lead to
-- anyone who can work leads; others may only take an unassigned lead for
-- themselves or hand their own lead back to the queue.
function Access.can_assign(self, lead, owner_uuid)
    if Access.is_manager(self) then return true end
    if not Access.can(self, "update") then return false end
    local current, me = owner_of(lead), Access.me(self)
    if current == nil and owner_uuid == me then return true end
    if current == me and owner_uuid == nil then return true end
    return false
end

-- crm_leads actions from a member's role permissions.
local function lead_actions(member_id)
    local ok, perms = pcall(require("queries.NamespaceMemberQueries").getPermissions, member_id)
    if not ok or type(perms) ~= "table" then return {} end
    local set = {}
    for _, a in ipairs(type(perms.crm_leads) == "table" and perms.crm_leads or {}) do set[a] = true end
    return set
end

--- Can this user (by uuid) work leads in the workspace? (active member with
-- crm_leads update/manage, or the owner). @return member row | nil
function Access.worker(ns, user_uuid)
    if type(user_uuid) ~= "string" or user_uuid == "" then return nil end
    local m = db.query([[
        SELECT m.id AS member_id, m.is_owner, u.id AS user_id, u.uuid, u.email, u.first_name, u.last_name
        FROM namespace_members m JOIN users u ON u.id = m.user_id
        WHERE m.namespace_id = ? AND u.uuid = ? AND m.status = 'active'
    ]], ns, user_uuid)[1]
    if not m then return nil end
    local set = lead_actions(m.member_id)
    if set.manage or set.update or set.create then
        m.is_lead_manager = set.manage == true
        return m
    end
    return nil
end

--- Everyone who can work leads (for the owner picker and the round-robin
-- pool). Capped: a workspace with thousands of members picks from the first 500.
function Access.workers(ns)
    local out = {}
    local rows = db.query([[
        SELECT m.id AS member_id, m.is_owner, u.uuid, u.email, u.first_name, u.last_name
        FROM namespace_members m JOIN users u ON u.id = m.user_id
        WHERE m.namespace_id = ? AND m.status = 'active'
        ORDER BY lower(COALESCE(NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), ''), u.email)) LIMIT 500
    ]], ns)
    for _, r in ipairs(rows) do
        local set = lead_actions(r.member_id)
        if set.manage or set.update or set.create then
            local name = ((r.first_name or "") .. " " .. (r.last_name or "")):match("^%s*(.-)%s*$")
            out[#out + 1] = { uuid = r.uuid, name = name ~= "" and name or r.email, email = r.email,
                is_manager = set.manage == true }
        end
    end
    return out
end

--- People who hear about escalations: the configured managers, else every
-- lead manager in the workspace.
function Access.managers(ns, settings)
    local list = settings and settings.manager_user_uuids or {}
    if #list > 0 then return list end
    local out = {}
    for _, w in ipairs(Access.workers(ns)) do
        if w.is_manager then out[#out + 1] = w.uuid end
    end
    return out
end

return Access
