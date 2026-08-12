--[[
    Document Templates — sidebar menu item

    The invoicing Document Templates feature (routes/document-templates.lua,
    /dashboard/templates) had a page and an API but no sidebar entry, so it was
    unreachable from the nav. This seeds the menu_items row and enables it for
    existing namespaces. Gated under FEATURES.INVOICING (same as the feature) and
    permissioned on the "invoices" RBAC module owner/admin already hold.
]]

local db = require("lapis.db")

return {
    -- [1] Insert the Templates menu item
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()

        local existing = db.select("* FROM menu_items WHERE key = ?", "document_templates")
        if #existing == 0 then
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = "document_templates",
                name = "Document Templates",
                icon = "LayoutTemplate",
                path = "/dashboard/templates",
                module = "invoices",
                required_action = "read",
                priority = 48,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = ts,
                updated_at = ts,
            })
            print("[DocTemplates] Added menu item: document_templates")
        end
    end,

    -- [2] Enable the menu item for all existing namespaces
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()

        local menu_rows = db.select("* FROM menu_items WHERE key = ?", "document_templates")
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
                    created_at = ts,
                    updated_at = ts,
                })
            end
        end
    end,

    -- [3] Relabel the item to "Document Templates" on deployments where an
    -- earlier run seeded it as "Templates" (disambiguates it from the CMS
    -- Content → Templates library). Idempotent.
    [3] = function()
        db.query([[
            UPDATE menu_items SET name = 'Document Templates', updated_at = NOW()
            WHERE key = 'document_templates' AND name <> 'Document Templates'
        ]])
    end,
}
