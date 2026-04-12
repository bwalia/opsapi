--[[
    Hospital Menu Items Seeding Migration

    Adds Hospitals, Patients, and Care Home menu items to the backend-driven menu,
    registers the corresponding modules, grants owner-role permissions, and enables
    them for all existing namespaces so they appear in the sidebar.
]]

local schema = require("lapis.db.schema")
local db = require("lapis.db")

return {
    -- =========================================================================
    -- [1] Insert menu items (hospitals, patients, care_home)
    -- =========================================================================
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local items = {
            {
                key = "hospitals",
                name = "Hospitals",
                icon = "Building2",
                path = "/dashboard/hospitals",
                module = "hospitals",
                required_action = "read",
                priority = 20,
            },
            {
                key = "patients",
                name = "Patients",
                icon = "UserCircle",
                path = "/dashboard/patients",
                module = "patients",
                required_action = "read",
                priority = 21,
            },
            {
                key = "care_home",
                name = "Care Home",
                icon = "Heart",
                path = "/dashboard/care-home",
                module = "care_home",
                required_action = "read",
                priority = 22,
            },
        }

        for _, item in ipairs(items) do
            local existing = db.select("* FROM menu_items WHERE key = ?", item.key)
            if #existing == 0 then
                db.insert("menu_items", {
                    uuid = MigrationUtils.generateUUID(),
                    key = item.key,
                    name = item.name,
                    icon = item.icon,
                    path = item.path,
                    module = item.module,
                    required_action = item.required_action,
                    priority = item.priority,
                    is_active = true,
                    is_admin_only = false,
                    always_show = false,
                    settings = "{}",
                    created_at = timestamp,
                    updated_at = timestamp,
                })
            end
        end
    end,

    -- =========================================================================
    -- [2] Register modules (hospitals, patients, care_home)
    -- =========================================================================
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local modules = {
            { machine_name = "hospitals", name = "Hospitals", description = "Hospital and care home facility management", priority = 20 },
            { machine_name = "patients",  name = "Patients",  description = "Patient records, care plans, and medical history", priority = 21 },
            { machine_name = "care_home", name = "Care Home", description = "Dementia care, daily logs, and risk monitoring",    priority = 22 },
        }

        for _, mod in ipairs(modules) do
            local existing = db.select("* FROM modules WHERE machine_name = ?", mod.machine_name)
            if #existing == 0 then
                db.insert("modules", {
                    uuid = MigrationUtils.generateUUID(),
                    machine_name = mod.machine_name,
                    name = mod.name,
                    description = mod.description,
                    priority = mod.priority,
                    created_at = timestamp,
                    updated_at = timestamp,
                })
            end
        end
    end,

    -- =========================================================================
    -- [3] Grant permissions to system namespace owner role
    -- =========================================================================
    [3] = function()
        local namespace = db.select("* FROM namespaces WHERE slug = ?", "system")
        if #namespace == 0 then return end
        local namespace_id = namespace[1].id

        -- Fetch the current owner role for the system namespace
        local owner_roles = db.select(
            "* FROM namespace_roles WHERE namespace_id = ? AND name = ?",
            namespace_id, "Owner"
        )
        if #owner_roles == 0 then
            -- Try lowercase or system role variant
            owner_roles = db.select(
                "* FROM namespace_roles WHERE namespace_id = ? AND (name = ? OR name = ?)",
                namespace_id, "owner", "Namespace Owner"
            )
        end
        if #owner_roles == 0 then return end

        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        for _, role in ipairs(owner_roles) do
            local perms = {}
            if role.permissions and role.permissions ~= "" then
                local ok, decoded = pcall(cjson.decode, role.permissions)
                if ok and type(decoded) == "table" then perms = decoded end
            end

            local actions = { "create", "read", "update", "delete", "manage" }
            perms.hospitals = actions
            perms.patients = actions
            perms.care_home = actions

            db.update("namespace_roles", {
                permissions = cjson.encode(perms),
            }, { id = role.id })
        end
    end,

    -- =========================================================================
    -- [4] Enable menu items in namespace_menu_config for all existing namespaces
    -- =========================================================================
    [4] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local keys = { "hospitals", "patients", "care_home" }
        for _, key in ipairs(keys) do
            local menu_rows = db.select("* FROM menu_items WHERE key = ?", key)
            if #menu_rows > 0 then
                local menu_item = menu_rows[1]
                local namespaces = db.select("* FROM namespaces")
                for _, ns in ipairs(namespaces) do
                    local exists = db.select([[
                        * FROM namespace_menu_config
                        WHERE namespace_id = ? AND menu_item_id = ?
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
            end
        end
    end,
}
