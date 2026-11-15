-- luacheck: max line length 140
--[[
    Order update emails (FEATURES.SHOP)
    ===================================

    Staff email a customer an update about their order from the dashboard order page
    (queries/ShopOrderUpdateQueries.lua, lib/shop-order-updates.lua). Every send is logged here, test sends
    to staff included, so the order page shows a history.

    [1] shop_order_emails: one row per email.
          kind          the preset used (received_reserved | in_stock_book_delivery | dispatched | delayed | custom)
          headline      ≤ 120 characters
          body          the message as sent (plain text, ≤ 4000 characters)
          subject       the subject line as sent
          to_email      the recipient (the customer, or the staff member for a test)
          sent_by       the staff member's name or email
          sent_by_user_id
          test          true = a test copy sent to staff, not to the customer

    Registered in migrations.lua as zzs53. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_order_emails (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                order_id integer NOT NULL REFERENCES shop_orders(id) ON DELETE CASCADE,
                kind varchar(40) NOT NULL DEFAULT 'custom',
                headline varchar(120) NOT NULL,
                body text NOT NULL CHECK (char_length(body) <= 4000),
                subject varchar(255),
                to_email varchar(254) NOT NULL,
                sent_by varchar(254),
                sent_by_user_id integer,
                test boolean NOT NULL DEFAULT false,
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_order_emails_order_idx
                ON shop_order_emails (order_id, created_at DESC)
        ]])
    end,
}
