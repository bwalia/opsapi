--[[
    CRM Leads Menu Item Seeding Migration

    Adds a dedicated "Leads" sidebar entry pointing at the standalone Leads
    inbox (/dashboard/leads), alongside the existing "CRM" entry
    (/dashboard/crm) seeded by crm-menu-items. Leads are the highest-churn CRM
    object (captured from public website forms, API/webhooks, referrals), so
    they get their own top-level entry for quick triage.

    Feature-gated under FEATURES.CRM. The menu item's `module` is crm_accounts
    (the CRM entry-point module, already registered + granted by
    crm-menu-items) so it passes the PROJECT_CODE gate in MenuQueries and
    inherits the same read permission — no new RBAC module needed (the
    /api/v2/crm/leads route itself only requires namespace membership).

    Idempotent: both steps guard on existence, so re-runs no-op.
]]

local db = require("lapis.db")

return {
    -- [1] Insert the Leads menu item
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local item = {
            key = "crm_leads",
            name = "Leads",
            icon = "UserPlus",
            path = "/dashboard/leads",
            module = "crm_accounts",
            required_action = "read",
            priority = 45, -- just above "CRM" (46)
        }

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
    end,

    -- [2] Enable the menu item for all existing namespaces.
    -- (MenuQueries treats a missing config row as enabled via COALESCE, so this
    -- is belt-and-braces for parity with crm-menu-items.)
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local menu_rows = db.select("* FROM menu_items WHERE key = ?", "crm_leads")
        if #menu_rows == 0 then return end
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
    end,
}
