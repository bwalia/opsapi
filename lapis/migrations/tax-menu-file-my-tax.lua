--[[
    Tax menu: "File My Tax" rename (idempotent, safe to re-run).

      * "Tax Returns"   (key `tax`, the group/overview) -> "Tax Dashboard"
      * "File your tax" (key `tax_file`, the wizard)     -> "File My Tax"
      * "File with AI"  (key `tax_agent`)                -> deactivated. The AI
        assistant is now opened from File My Tax (choose "Do it with the AI
        assistant"); /dashboard/tax/agent itself keeps working for deep links.

    Existing databases already ran the seeds (tax-copilot-menu-items,
    tax-agent-menu-item), so the rows are updated in place. A per-namespace
    `namespace_menu_config.custom_name` that still carries one of the OLD default
    labels is cleared so the new default shows; a genuinely custom name that an
    admin typed is left alone. Gated on tax_copilot like the other tax menu
    migrations; key sorts after `zz_tax_agent_zz_menu` so the rows exist.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            UPDATE menu_items SET name = 'Tax Dashboard', updated_at = NOW()
            WHERE key = 'tax' AND name <> 'Tax Dashboard'
        ]])
        db.query([[
            UPDATE menu_items SET name = 'File My Tax', updated_at = NOW()
            WHERE key = 'tax_file' AND name <> 'File My Tax'
        ]])
        -- Not deleted: namespace_menu_config rows reference it, and keeping the row
        -- lets an admin re-enable it. is_active = false hides it for every namespace.
        db.query([[
            UPDATE menu_items SET is_active = false, updated_at = NOW()
            WHERE key = 'tax_agent' AND is_active = true
        ]])
        -- Per-namespace overrides that merely pinned an old default label.
        db.query([[
            UPDATE namespace_menu_config nmc SET custom_name = NULL, updated_at = NOW()
            FROM menu_items mi
            WHERE nmc.menu_item_id = mi.id
              AND ((mi.key = 'tax' AND nmc.custom_name = 'Tax Returns')
                OR (mi.key = 'tax_file' AND nmc.custom_name IN ('File your tax', 'File Your Tax')))
        ]])
        print("[Tax Copilot] Menu: 'Tax Dashboard', 'File My Tax'; 'File with AI' hidden")
    end,
}
