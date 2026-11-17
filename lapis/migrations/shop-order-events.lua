-- luacheck: max line length 140
--[[
    Order updates the customer sees (FEATURES.SHOP)
    ===============================================

    A log on the customer's order page (shop /orders/:uuid?t=): staff comments plus events recorded as they
    happen (status changes, a delivery address changed by staff). Older events (order placed, paid, shipped,
    emails sent, approved delivery changes) are read from the order itself, so nothing is backfilled here.
    See queries/ShopOrderEventQueries.lua.

    [1] shop_order_events
          kind            comment | status | delivery_address
          status          the new order status (kind status)
          message         what the customer reads (plain text, ≤ 2000 characters); null for a bare status change
          author          staff name or email (never shown to the customer)
          author_user_id
          deleted_at      hidden from the customer (staff removed it); kept for the record

    Registered in migrations.lua as zzs62. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_order_events (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                order_id integer NOT NULL REFERENCES shop_orders(id) ON DELETE CASCADE,
                kind varchar(30) NOT NULL DEFAULT 'comment',
                status varchar(30),
                message text CHECK (message IS NULL OR char_length(message) <= 2000),
                author varchar(254),
                author_user_id integer,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                deleted_at timestamptz,
                deleted_by varchar(254)
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_order_events_order_idx
                ON shop_order_events (order_id, created_at)
        ]])
    end,
}
