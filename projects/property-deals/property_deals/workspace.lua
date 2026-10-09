-- Per-workspace setup: the kanban project deal tasks live in, the Property
-- Deals roles, the seed workflow templates and the bank-holiday calendar.
-- Idempotent: run it again and it only adds what's missing. Never overwrites
-- a workspace's own edits.
local cjson = require("cjson")
local db = require("lapis.db")

local W = {}

local SEED_TEMPLATES = { "uk_guaranteed_sale", "sell_via_estate_agent" }

local function one(sql, ...)
    return db.query(sql, ...)[1]
end

--- The workspace's plugin state row, or nil when setup hasn't run.
function W.get(ns)
    return one("SELECT * FROM property_deals_workspaces WHERE namespace_id = ?", ns)
end

local function ensure_kanban(ns, state, user_uuid)
    if state.kanban_project_uuid and state.kanban_board_uuid then return end
    local project
    if state.kanban_project_uuid then
        project = one("SELECT * FROM kanban_projects WHERE uuid = ? AND namespace_id = ?", state.kanban_project_uuid, ns)
    end
    if not project then
        project = require("queries.KanbanProjectQueries").create({
            namespace_id = ns,
            name = "Property deals",
            description = "Tasks created by the Property Deals workflow. One epic per deal.",
            owner_user_uuid = user_uuid,
            icon = "Home",
        })
    end
    local board = one([[
        SELECT uuid FROM kanban_boards WHERE project_id = ? AND archived_at IS NULL
        ORDER BY is_default DESC, position LIMIT 1
    ]], project.id)
    db.update("property_deals_workspaces", {
        kanban_project_uuid = project.uuid,
        kanban_board_uuid = board and board.uuid or db.NULL,
        updated_at = db.raw("NOW()"),
    }, { namespace_id = ns })
end

local function ensure_roles(ns)
    local valid = {}
    for _, m in ipairs(db.query("SELECT machine_name FROM modules WHERE is_active = true")) do
        valid[m.machine_name] = true
    end
    local created = {}
    for _, def in ipairs(require("property_deals.seed.roles")) do
        if not one("SELECT 1 FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", ns, def.role_name) then
            local perms = {}
            for mod, actions in pairs(def.permissions) do
                if valid[mod] then perms[mod] = actions end
            end
            require("queries.NamespaceRoleQueries").create({
                namespace_id = ns, role_name = def.role_name, display_name = def.display_name,
                description = def.description, permissions = perms, priority = def.priority,
                landing_path = def.landing_path,
            })
            created[#created + 1] = def.role_name
        end
    end
    return created
end

local function ensure_templates(ns, user_uuid)
    local Store = require("property_deals.templates_store")
    local created = {}
    for _, key in ipairs(SEED_TEMPLATES) do
        if not one("SELECT 1 FROM property_deals_workflow_templates WHERE namespace_id = ? AND key = ?", ns, key) then
            -- Deep copy through JSON: validate() normalises in place.
            local def = cjson.decode(cjson.encode(require("property_deals.seed." .. key)))
            local tpl, errs = Store.create(ns, def, user_uuid, "Seed template")
            if not tpl then error("seed template " .. key .. ": " .. table.concat(errs, "; ")) end
            created[#created + 1] = key
        end
    end
    return created
end

local function ensure_holidays(ns, jurisdiction)
    local rows = require("property_deals.seed.holidays")[jurisdiction]
    if not rows then return 0 end
    local added = 0
    for _, h in ipairs(rows) do
        local res = db.query([[
            INSERT INTO property_deals_holidays (namespace_id, jurisdiction, holiday_date, name)
            VALUES (?, ?, ?, ?) ON CONFLICT (namespace_id, jurisdiction, holiday_date) DO NOTHING
        ]], ns, jurisdiction, h[1], h[2])
        added = added + (res.affected_rows or 0)
    end
    return added
end

--- Set the workspace up (or top it up). `user_uuid` owns the kanban project.
-- @return { state, created = { roles, templates, holidays } }
function W.setup(ns, user_uuid, settings)
    settings = settings or {}
    db.query([[
        INSERT INTO property_deals_workspaces (namespace_id) VALUES (?)
        ON CONFLICT (namespace_id) DO NOTHING
    ]], ns)
    local state = W.get(ns)
    ensure_kanban(ns, state, user_uuid)
    local created = {
        roles = ensure_roles(ns),
        templates = ensure_templates(ns, user_uuid),
        holidays = ensure_holidays(ns, settings.jurisdiction or "england-and-wales"),
    }
    db.update("property_deals_workspaces", {
        setup_at = db.raw("NOW()"), setup_by_user_uuid = user_uuid, updated_at = db.raw("NOW()"),
    }, { namespace_id = ns })
    return { state = W.get(ns), created = created }
end

--- The state, setting the workspace up first if it never was.
function W.ensure(ns, user_uuid, settings)
    local state = W.get(ns)
    if state and state.setup_at and state.kanban_board_uuid then return state end
    return W.setup(ns, user_uuid, settings).state
end

return W
