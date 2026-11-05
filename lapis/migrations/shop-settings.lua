--[[
    Shop settings (FEATURES.SHOP) — registered as zzs36 in migrations.lua
    =====================================================================
    One row per namespace; no row = the defaults.

    checkout_enabled: customers can pay for orders online (cart and quote
    checkout). Off by default: the shop takes enquiries instead (a quote plus a
    CRM lead) and staff confirm the final price. Membership checkout is not
    affected. Toggled in the dashboard (Shop → Settings).
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_settings (
                namespace_id integer PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
                checkout_enabled boolean NOT NULL DEFAULT false,
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
    end,
}
