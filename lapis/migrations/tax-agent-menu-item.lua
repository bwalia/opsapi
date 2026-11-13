--[[
    Seeds the `tax_agent` menu row (conversational tax agent, /dashboard/tax/agent).
    It used to be the "File with AI" sidebar item; the assistant is now opened from
    File My Tax, so the row is seeded INACTIVE (hidden) and existing installs are
    deactivated by migrations/tax-menu-file-my-tax.lua. Kept so an admin can
    re-enable it. Gated on tax_copilot. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()

        if #db.select("* FROM menu_items WHERE key = ?", "tax_agent") > 0 then
            return
        end

        local parent = db.select("id FROM menu_items WHERE key = ? LIMIT 1", "tax")
        local parent_id = parent[1] and parent[1].id or nil

        db.insert("menu_items", {
            uuid = MigrationUtils.generateUUID(),
            key = "tax_agent",
            name = "File My Tax — AI assistant",
            icon = "Sparkles",
            path = "/dashboard/tax/agent",
            module = "tax_transactions",
            required_action = "read",
            priority = 30, -- featured: first child under the Tax group
            parent_id = parent_id,
            is_active = false, -- reached from File My Tax, not the sidebar
            is_admin_only = false,
            always_show = false,
            settings = "{}",
            created_at = ts,
            updated_at = ts,
        })
    end,
}
