--[[
    Timesheet Menu Items Seeding Migration

    Timesheets had backend (routes/timesheets.lua), DB tables, RBAC modules and a
    frontend page (/dashboard/timesheets) but no menu_items row. Mirrors the
    tax-copilot-menu-items pattern. Feature-gated under FEATURES.TIMESHEETS.
]]

local db = require("lapis.db")

return {
    -- [1] Insert the Timesheets menu item
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local items = {
            {
                key = "timesheets",
                name = "Timesheets",
                icon = "Clock",
                path = "/dashboard/timesheets",
                module = "timesheets",
                required_action = "read",
                priority = 42,
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
                print("[Timesheets] Added menu item: " .. item.key)
            end
        end
    end,

    -- [2] Register the timesheet RBAC modules
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local modules = {
            { machine_name = "timesheets", name = "Timesheets", description = "Time tracking and approval", priority = 42 },
            { machine_name = "timesheet_approvals", name = "Timesheet Approvals", description = "Approve/reject timesheets", priority = 43 },
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
                print("[Timesheets] Registered module: " .. mod.machine_name)
            end
        end
    end,

    -- [3] Grant permissions to owner + admin roles
    [3] = function()
        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        local full_modules = { "timesheets" }
        local approval_actions = { "approve", "reject", "read" }

        local owner_roles = db.select(
            "* FROM namespace_roles WHERE role_name IN ('Owner', 'owner', 'Namespace Owner')"
        )
        local owner_actions = { "create", "read", "update", "delete", "manage" }
        for _, role in ipairs(owner_roles) do
            local perms = {}
            if role.permissions and role.permissions ~= "" then
                local ok, decoded = pcall(cjson.decode, role.permissions)
                if ok and type(decoded) == "table" then perms = decoded end
            end
            for _, mod_name in ipairs(full_modules) do
                if not perms[mod_name] then perms[mod_name] = owner_actions end
            end
            if not perms.timesheet_approvals then perms.timesheet_approvals = approval_actions end
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end

        local admin_roles = db.select(
            "* FROM namespace_roles WHERE role_name IN ('Admin', 'admin', 'Namespace Admin')"
        )
        local admin_actions = { "create", "read", "update", "delete" }
        for _, role in ipairs(admin_roles) do
            local perms = {}
            if role.permissions and role.permissions ~= "" then
                local ok, decoded = pcall(cjson.decode, role.permissions)
                if ok and type(decoded) == "table" then perms = decoded end
            end
            for _, mod_name in ipairs(full_modules) do
                if not perms[mod_name] then perms[mod_name] = admin_actions end
            end
            if not perms.timesheet_approvals then perms.timesheet_approvals = approval_actions end
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end
    end,

    -- [4] Enable the menu item for all existing namespaces
    [4] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        for _, key in ipairs({ "timesheets" }) do
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
