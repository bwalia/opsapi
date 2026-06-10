--[[
    Invoicing Menu Items Seeding Migration

    The invoicing feature had a full backend (routes/invoices.lua), DB tables,
    RBAC modules and a frontend page (/dashboard/invoices) — but no menu_items
    row, so it never appeared in the sidebar. This migration closes that gap the
    same way tax-copilot-menu-items.lua does:
      [1] insert the menu item(s)
      [2] register the RBAC modules in the modules table
      [3] grant owner/admin roles permission on those modules
      [4] enable the menu item for every existing namespace

    Feature-gated under FEATURES.INVOICING in migrations.lua, so it only seeds
    where invoicing is part of the project. PROJECT_CODE gating in
    MenuQueries.getForNamespace then hides it for projects that don't include it.
]]

local db = require("lapis.db")

return {
    -- =========================================================================
    -- [1] Insert the Invoices menu item
    -- =========================================================================
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local items = {
            {
                key = "invoices",
                name = "Invoices",
                icon = "FileText",
                path = "/dashboard/invoices",
                module = "invoices",
                required_action = "read",
                priority = 40,
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
                print("[Invoicing] Added menu item: " .. item.key)
            end
        end
    end,

    -- =========================================================================
    -- [2] Register the invoicing RBAC modules
    -- =========================================================================
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local modules = {
            { machine_name = "invoices", name = "Invoices", description = "Invoice creation and management", priority = 40 },
            { machine_name = "payments", name = "Payments", description = "Payment recording and tracking", priority = 41 },
            { machine_name = "tax_rates_config", name = "Tax Rates", description = "Tax rate configuration", priority = 42 },
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
                print("[Invoicing] Registered module: " .. mod.machine_name)
            end
        end
    end,

    -- =========================================================================
    -- [3] Grant permissions to namespace owner + admin roles
    -- =========================================================================
    [3] = function()
        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        local invoicing_modules = { "invoices", "payments", "tax_rates_config" }

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
            for _, mod_name in ipairs(invoicing_modules) do
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
            for _, mod_name in ipairs(invoicing_modules) do
                if not perms[mod_name] then perms[mod_name] = admin_actions end
            end
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end
    end,

    -- =========================================================================
    -- [4] Enable the menu item for all existing namespaces
    -- =========================================================================
    [4] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        for _, key in ipairs({ "invoices" }) do
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
