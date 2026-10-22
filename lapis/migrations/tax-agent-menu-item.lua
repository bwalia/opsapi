--[[
    Adds the "File with AI" sidebar item under the Tax group, pointing at the
    conversational tax agent (/dashboard/tax/agent). Backend-driven menu; new
    items default to enabled (COALESCE(is_enabled, true)) so no per-namespace
    config rows are needed. Gated on tax_copilot. Idempotent.
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
            name = "File with AI",
            icon = "Sparkles",
            path = "/dashboard/tax/agent",
            module = "tax_transactions",
            required_action = "read",
            priority = 30, -- featured: first child under the Tax group
            parent_id = parent_id,
            is_active = true,
            is_admin_only = false,
            always_show = false,
            settings = "{}",
            created_at = ts,
            updated_at = ts,
        })
    end,
}
