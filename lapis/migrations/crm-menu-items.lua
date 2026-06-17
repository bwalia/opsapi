--[[
    CRM Menu Items Seeding Migration

    CRM had backend (routes/crm-accounts.lua etc.), DB tables, RBAC modules and a
    frontend page (/dashboard/crm) but no menu_items row. Mirrors the
    tax-copilot-menu-items pattern. Feature-gated under FEATURES.CRM.

    The menu item's `module` is crm_accounts (the entry-point module), matching
    PROJECT_MODULES.crm so it passes the PROJECT_CODE gate in MenuQueries.
]]

local db = require("lapis.db")

return {
    -- [1] Insert the CRM menu item
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local items = {
            {
                key = "crm",
                name = "CRM",
                icon = "Contact",
                path = "/dashboard/crm",
                module = "crm_accounts",
                required_action = "read",
                priority = 46,
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
                print("[CRM] Added menu item: " .. item.key)
            end
        end
    end,

    -- [2] Register the CRM RBAC modules
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local modules = {
            { machine_name = "crm_accounts", name = "CRM Accounts", description = "Company/organization management", priority = 46 },
            { machine_name = "crm_contacts", name = "CRM Contacts", description = "Contact management", priority = 47 },
            { machine_name = "crm_deals", name = "CRM Deals", description = "Deal pipeline management", priority = 48 },
            { machine_name = "crm_pipelines", name = "CRM Pipelines", description = "Sales pipeline configuration", priority = 49 },
            { machine_name = "crm_activities", name = "CRM Activities", description = "Activity tracking", priority = 50 },
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
                print("[CRM] Registered module: " .. mod.machine_name)
            end
        end
    end,

    -- [3] Grant permissions to owner + admin roles
    [3] = function()
        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        local crm_modules = {
            "crm_accounts", "crm_contacts", "crm_deals", "crm_pipelines", "crm_activities"
        }

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
            for _, mod_name in ipairs(crm_modules) do
                if not perms[mod_name] then perms[mod_name] = owner_actions end
            end
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
            for _, mod_name in ipairs(crm_modules) do
                if not perms[mod_name] then perms[mod_name] = admin_actions end
            end
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end
    end,

    -- [4] Enable the menu item for all existing namespaces
    [4] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        for _, key in ipairs({ "crm" }) do
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
