--[[
    Tax Copilot Menu Items Seeding Migration

    Adds Tax dashboard menu items to the backend-driven menu,
    registers the corresponding modules, grants owner-role permissions, and enables
    them for all existing namespaces so they appear in the sidebar.
]]

local db = require("lapis.db")

return {
    -- =========================================================================
    -- [1] Insert menu items for tax copilot
    -- =========================================================================
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- Create a parent menu item for Tax
        local parent_key = "tax"
        local parent_existing = db.select("* FROM menu_items WHERE key = ?", parent_key)
        local parent_id = nil

        if #parent_existing == 0 then
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = parent_key,
                name = "Tax Returns",
                icon = "Calculator",
                path = "/dashboard/tax",
                module = "tax_transactions",
                required_action = "read",
                priority = 30,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = timestamp,
                updated_at = timestamp,
            })
            local inserted = db.select("* FROM menu_items WHERE key = ?", parent_key)
            if #inserted > 0 then
                parent_id = inserted[1].id
            end
        else
            parent_id = parent_existing[1].id
        end

        local items = {
            {
                key = "tax_bank_accounts",
                name = "Bank Accounts",
                icon = "Landmark",
                path = "/dashboard/tax/bank-accounts",
                module = "tax_bank_accounts",
                required_action = "read",
                priority = 31,
            },
            {
                key = "tax_statements",
                name = "Statements",
                icon = "FileUp",
                path = "/dashboard/tax/statements",
                module = "tax_statements",
                required_action = "read",
                priority = 32,
            },
            {
                key = "tax_transactions",
                name = "Transactions",
                icon = "ArrowLeftRight",
                path = "/dashboard/tax/transactions",
                module = "tax_transactions",
                required_action = "read",
                priority = 33,
            },
            {
                key = "tax_reports",
                name = "Reports",
                icon = "BarChart3",
                path = "/dashboard/tax/reports",
                module = "tax_transactions",
                required_action = "read",
                priority = 34,
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
                    parent_id = parent_id,
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
    -- [2] Register modules (tax_bank_accounts, tax_statements, tax_transactions, etc.)
    -- =========================================================================
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local modules = {
            { machine_name = "tax_bank_accounts", name = "Tax Bank Accounts", description = "Bank account management for tax returns", priority = 30 },
            { machine_name = "tax_statements",    name = "Tax Statements",    description = "Bank statement uploads and extraction", priority = 31 },
            { machine_name = "tax_transactions",   name = "Tax Transactions",  description = "Transaction tracking and classification", priority = 32 },
            { machine_name = "tax_categories",     name = "Tax Categories",    description = "Transaction category management", priority = 33 },
            { machine_name = "tax_support",        name = "Tax Support",       description = "Tax support conversations", priority = 34 },
            { machine_name = "tax_file",           name = "HMRC Filing",       description = "Submit tax returns to HMRC", priority = 35 },
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
    -- [3] Grant permissions to namespace owner roles
    -- =========================================================================
    [3] = function()
        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        -- Find all owner roles across namespaces
        local owner_roles = db.select(
            "* FROM namespace_roles WHERE role_name IN ('Owner', 'owner', 'Namespace Owner')"
        )

        local tax_modules = {
            "tax_bank_accounts", "tax_statements", "tax_transactions",
            "tax_categories", "tax_support", "tax_file"
        }
        local actions = { "create", "read", "update", "delete", "manage" }

        for _, role in ipairs(owner_roles) do
            local perms = {}
            if role.permissions and role.permissions ~= "" then
                local ok, decoded = pcall(cjson.decode, role.permissions)
                if ok and type(decoded) == "table" then perms = decoded end
            end

            for _, mod_name in ipairs(tax_modules) do
                perms[mod_name] = actions
            end

            db.update("namespace_roles", {
                permissions = cjson.encode(perms),
            }, { id = role.id })
        end

        -- Also grant to admin roles
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

            for _, mod_name in ipairs(tax_modules) do
                perms[mod_name] = admin_actions
            end

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

        local keys = { "tax", "tax_bank_accounts", "tax_statements", "tax_transactions", "tax_reports" }
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
