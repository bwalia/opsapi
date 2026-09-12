--[[
    Field Service Menu Items Seeding Migration

    Surfaces the field service module in the backend-driven sidebar:
    - "Service Jobs" (/dashboard/field-service)         → module fs_jobs
    - "Site Visits"  (/dashboard/field-service/visits)  → module fs_visits
    Sites and Job Types are reached from the field-service sub-navigation.

    Mirrors the timesheet-menu-items pattern. Feature-gated under
    FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")

local MODULES = {
    { machine_name = "fs_jobs", name = "Service Jobs", description = "Field service jobs, phases, parts and invoicing", priority = 38 },
    { machine_name = "fs_visits", name = "Site Visits", description = "Engineer site visits: scheduling, check-in/out, work reports", priority = 39 },
    { machine_name = "fs_sites", name = "Service Sites", description = "Customer site addresses for field service", priority = 39 },
    { machine_name = "fs_job_types", name = "Job Types", description = "Job types and their phase templates", priority = 39 },
}

local MENU_KEYS = { "field_service_jobs", "field_service_visits" }

local function grant(role_names, actions)
    local cjson = require("cjson")
    local roles = db.select("* FROM namespace_roles WHERE role_name IN ?", db.list(role_names))
    for _, role in ipairs(roles) do
        local perms = {}
        if role.permissions and role.permissions ~= "" then
            local ok, decoded = pcall(cjson.decode, role.permissions)
            if ok and type(decoded) == "table" then perms = decoded end
        end
        for _, mod in ipairs(MODULES) do
            if not perms[mod.machine_name] then perms[mod.machine_name] = actions end
        end
        db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
    end
end

return {
    -- [1] Insert the menu items
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local items = {
            {
                key = "field_service_jobs",
                name = "Service Jobs",
                icon = "Wrench",
                path = "/dashboard/field-service",
                module = "fs_jobs",
                required_action = "read",
                priority = 38,
            },
            {
                key = "field_service_visits",
                name = "Site Visits",
                icon = "MapPin",
                path = "/dashboard/field-service/visits",
                module = "fs_visits",
                required_action = "read",
                priority = 39,
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
                print("[FieldService] Added menu item: " .. item.key)
            end
        end
    end,

    -- [2] Register the RBAC modules
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        for _, mod in ipairs(MODULES) do
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
                print("[FieldService] Registered module: " .. mod.machine_name)
            end
        end
    end,

    -- [3] Grant permissions to owner + admin roles
    [3] = function()
        grant({ "Owner", "owner", "Namespace Owner" }, { "create", "read", "update", "delete", "manage" })
        grant({ "Admin", "admin", "Namespace Admin" }, { "create", "read", "update", "delete" })
    end,

    -- [4] Enable the menu items for all existing namespaces
    [4] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        for _, key in ipairs(MENU_KEYS) do
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
