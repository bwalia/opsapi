--[[
    VAT screens (VAT plan phase 5): "VAT" under the Tax menu -> /dashboard/tax/vat.
    Shown to whoever can use File My Tax (module tax_statements). Idempotent; skips
    when there is no menu or no Tax parent (e.g. a deployment without tax_copilot).
]]

local db = require("lapis.db")

return {
    [1] = function()
        local ok = db.query("SELECT to_regclass('public.menu_items') IS NOT NULL AS ok")[1]
        if not (ok and (ok.ok == true or ok.ok == "t")) then return end
        local parent = db.select("id FROM menu_items WHERE key = ? LIMIT 1", "tax")
        if not parent[1] then return end
        if #db.select("id FROM menu_items WHERE key = ?", "tax_vat") > 0 then return end
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()
        db.insert("menu_items", {
            uuid = MigrationUtils.generateUUID(),
            key = "tax_vat", name = "VAT", icon = "Receipt", path = "/dashboard/tax/vat",
            module = "tax_statements", required_action = "read", priority = 36,
            parent_id = parent[1].id, is_active = true, is_admin_only = false, always_show = false,
            settings = "{}", created_at = ts, updated_at = ts,
        })
        print("[VAT] menu item: Tax -> VAT")
    end,
}
