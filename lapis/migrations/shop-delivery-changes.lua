-- luacheck: max line length 140
--[[
    Delivery change requests (FEATURES.SHOP)
    ========================================

    A signed-in customer asks to change where and when their order is delivered. Nothing changes on
    the order until staff approve it (queries/ShopDeliveryChangeQueries.lua, lib/shop-delivery-change.lua).

    [1] shop_orders.delivery_date / delivery_window: the agreed delivery day and time window
        (all_day | am | pm), set when staff approve a request.
        shop_delivery_change_requests: one row per request.
          status                    pending | approved | declined | cancelled (at most one pending per order)
          requested_address         jsonb {name, company, line1, line2, city, county, postcode, country, phone, email}
          requested_date / _window  null = keep what the order has
          customer_note             ≤ 1000 characters
          requested_by_email        the signed-in customer's email (= the order's email)
          requester_ip_hash / requester_ua_hash   salted sha256, never the raw values
          previous_delivery_*       what the order said before (at request time; refreshed on approval)
          staff_note                shown to the customer (e.g. why it was declined)
          decided_by / decided_at   the staff member who approved or declined it
          customer_notified_at      when the customer was told (only while customer notifications are on)
    [2] shop_settings.customer_delivery_notifications (default false): email the customer when staff
        approve or decline a request. Off until the shop's sending address is changed.

    Registered in migrations.lua as zzs51 ([1]) and zzs52 ([2]). Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            ALTER TABLE shop_orders
                ADD COLUMN IF NOT EXISTS delivery_date date,
                ADD COLUMN IF NOT EXISTS delivery_window varchar(16)
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_delivery_change_requests (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                order_id integer NOT NULL REFERENCES shop_orders(id) ON DELETE CASCADE,
                status varchar(12) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'approved', 'declined', 'cancelled')),
                requested_address jsonb NOT NULL,
                requested_date date,
                requested_window varchar(16) CHECK (requested_window IN ('all_day', 'am', 'pm')),
                customer_note text CHECK (char_length(customer_note) <= 1000),
                requested_by_email varchar(254) NOT NULL,
                requester_ip_hash varchar(64),
                requester_ua_hash varchar(64),
                previous_delivery_address jsonb,
                previous_delivery_date date,
                previous_delivery_window varchar(16),
                staff_note text CHECK (char_length(staff_note) <= 1000),
                decided_by varchar(254),
                decided_at timestamptz,
                cancelled_at timestamptz,
                customer_notified_at timestamptz,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_delivery_change_requests_order_idx
                ON shop_delivery_change_requests (order_id, created_at DESC)
        ]])
        -- At most one pending request per order, whatever races the application check.
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS shop_delivery_change_requests_one_pending
                ON shop_delivery_change_requests (order_id) WHERE status = 'pending'
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_delivery_change_requests_pending_ns_idx
                ON shop_delivery_change_requests (namespace_id) WHERE status = 'pending'
        ]])
    end,
    [2] = function()
        db.query([[ALTER TABLE shop_settings
                     ADD COLUMN IF NOT EXISTS customer_delivery_notifications boolean NOT NULL DEFAULT false]])
    end,
}
