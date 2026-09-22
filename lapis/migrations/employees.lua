--[[
    Employees (staff directory) — promote to a CORE module
    ======================================================

    Employees was introduced under field service but is a generic staff
    directory any namespace should have. This migration makes it core:
      - ensures the `employees` table exists (deployments WITHOUT field service
        never ran field-service-assets [863], so the table would be missing),
      - registers / re-categorises the `employees` RBAC module (category "Team"),
      - re-paths the "Employees" menu item to the neutral /dashboard/employees,
      - grants the module to owner/admin roles and enables the menu item for
        every existing namespace.

    Gated on FEATURES.CORE (always enabled) so it runs for every deployment.
    Everything is idempotent (existence guards), so it is safe to run on a
    field-service DB that already has the table / module / menu, and on re-runs.
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

local function index(sql)
    pcall(function() db.query(sql) end)
end

local MENU_KEY = "employees"
local MENU_PATH = "/dashboard/employees"

-- Add the `employees` permission to the named roles that don't already have it.
local function grant(role_names, actions)
    local cjson = require("cjson")
    local roles = db.select("* FROM namespace_roles WHERE role_name IN ?", db.list(role_names))
    for _, role in ipairs(roles) do
        local perms = {}
        if role.permissions and role.permissions ~= "" then
            local ok, decoded = pcall(cjson.decode, role.permissions)
            if ok and type(decoded) == "table" then perms = decoded end
        end
        if not perms["employees"] then
            perms["employees"] = actions
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end
    end
end

return {
    -- [1] Ensure the employees table (field-service-assets [863] only creates it
    -- when field service is enabled; core-only deployments need it here).
    [1] = function()
        if table_exists("employees") then return end
        db.query([[
            CREATE TABLE employees (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                user_uuid TEXT NOT NULL,
                employee_code TEXT,
                job_title TEXT,
                is_engineer BOOLEAN NOT NULL DEFAULT false,
                is_active BOOLEAN NOT NULL DEFAULT true,
                phone TEXT,
                email TEXT,
                region TEXT,
                skills JSONB NOT NULL DEFAULT '[]',
                hourly_cost_rate DECIMAL(10,2),
                metadata JSONB DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])
        index([[CREATE UNIQUE INDEX employees_ns_user_active_idx
                ON employees (namespace_id, user_uuid) WHERE deleted_at IS NULL]])
        index([[CREATE INDEX employees_ns_engineer_idx ON employees (namespace_id, is_engineer, is_active)]])
        print("[Employees] Created employees table (core)")
    end,

    -- [2] Register/re-categorise the module (Team) and place/re-path the menu item.
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- Module catalog row: insert if missing, else move it to the Team category.
        local mod = db.select("* FROM modules WHERE machine_name = ?", "employees")
        if #mod == 0 then
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(),
                machine_name = "employees",
                name = "Employees",
                description = "Staff directory: team members, their workspace logins, roles and skills",
                category = "Team",
                priority = 41,
                created_at = timestamp,
                updated_at = timestamp,
            })
            print("[Employees] Registered employees module (core / Team)")
        else
            db.update("modules", { category = "Team", updated_at = timestamp }, { machine_name = "employees" })
        end

        -- Menu item: re-path an existing "employees" item to the neutral URL, or
        -- insert it (deployments that never ran the field-service menu seed).
        local menu = db.select("* FROM menu_items WHERE key = ?", MENU_KEY)
        if #menu == 0 then
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = MENU_KEY,
                name = "Employees",
                icon = "Users",
                path = MENU_PATH,
                module = "employees",
                required_action = "read",
                priority = 41,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = timestamp,
                updated_at = timestamp,
            })
            print("[Employees] Added Employees menu item at " .. MENU_PATH)
        else
            db.update("menu_items", { path = MENU_PATH, module = "employees", updated_at = timestamp },
                { key = MENU_KEY })
            print("[Employees] Re-pathed Employees menu item to " .. MENU_PATH)
        end
    end,

    -- [3] Grant the module to owner + admin roles (namespaces that never had
    -- field service have no employees permission yet).
    [3] = function()
        grant({ "Owner", "owner", "Namespace Owner" }, { "create", "read", "update", "delete", "manage" })
        grant({ "Admin", "admin", "Namespace Admin" }, { "create", "read", "update", "delete" })
    end,

    -- [4] Enable the menu item for every existing namespace (no config row means
    -- it defaults visible, but seed one so the toggle is explicit).
    [4] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()
        local menu_rows = db.select("* FROM menu_items WHERE key = ?", MENU_KEY)
        if #menu_rows == 0 then return end
        local menu_item = menu_rows[1]
        local namespaces = db.select("* FROM namespaces")
        for _, ns in ipairs(namespaces) do
            local exists = db.select([[
                * FROM namespace_menu_config WHERE namespace_id = ? AND menu_item_id = ?
            ]], ns.id, menu_item.id)
            if #exists == 0 then
                db.insert("namespace_menu_config", {
                    uuid = MigrationUtils.generateUUID(),
                    namespace_id = ns.id,
                    menu_item_id = menu_item.id,
                    is_enabled = true,
                    created_at = timestamp,
                    updated_at = timestamp,
                })
            end
        end
    end,
}
