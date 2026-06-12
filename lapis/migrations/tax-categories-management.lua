--[[
    Tax Categories Management migration

    1. Adds namespace_id to tax_categories so a tenant can own custom categories.
       namespace_id IS NULL  -> global seed category, shared by every namespace.
       namespace_id = <id>   -> created by that namespace (tenant-editable).
    2. Adds the "Categories" sidebar menu item under the Tax parent and enables it
       for all existing namespaces.

    The tax_categories RBAC module and owner/admin permission grants already exist
    (see migrations/tax-copilot-menu-items.lua), so no new modules/roles here.

    Idempotent: safe to re-run.
]]

local db = require("lapis.db")

return {
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- 1. namespace_id column + index
        pcall(function()
            db.query("ALTER TABLE tax_categories ADD COLUMN IF NOT EXISTS namespace_id integer")
        end)
        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS tax_categories_namespace_id_idx ON tax_categories (namespace_id)")
        end)

        -- 2. "Categories" menu item under the Tax parent
        local parent = db.select("* FROM menu_items WHERE key = ?", "tax")
        local parent_id = (#parent > 0) and parent[1].id or nil

        local key = "tax_categories"
        if #db.select("* FROM menu_items WHERE key = ?", key) == 0 then
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = key,
                name = "Categories",
                icon = "Tags",
                path = "/dashboard/tax/categories",
                module = "tax_categories",
                required_action = "read",
                priority = 35,
                parent_id = parent_id,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = timestamp,
                updated_at = timestamp,
            })
        end

        -- 3. Enable the menu item for every existing namespace
        local menu_rows = db.select("* FROM menu_items WHERE key = ?", key)
        if #menu_rows > 0 then
            local menu_item = menu_rows[1]
            for _, ns in ipairs(db.select("* FROM namespaces")) do
                local exists = db.select(
                    "* FROM namespace_menu_config WHERE namespace_id = ? AND menu_item_id = ?",
                    ns.id, menu_item.id)
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

        print("[Tax Copilot] tax_categories namespace_id + Categories menu item ready")
    end,
}
