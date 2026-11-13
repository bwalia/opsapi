-- luacheck: max line length 140
--[[
    Shop: bank transfer for Order Authorisations, manual "mark paid", invoice link (FEATURES.SHOP)
    =============================================================================================

    [1] shop_orders
          payment_method   card (Stripe Checkout; null on older orders = card) | bank_transfer | cheque | other
          paid_reference   the reference staff recorded when marking the order paid (bank statement line)
          paid_amount_minor what staff recorded as received (null for Stripe payments)
          invoice_uuid     the accounting invoice raised from this order (POST /orders/:uuid/invoice)

    Registered in migrations.lua as zzs41. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            ALTER TABLE shop_orders
                ADD COLUMN IF NOT EXISTS payment_method varchar(24),
                ADD COLUMN IF NOT EXISTS paid_reference varchar(120),
                ADD COLUMN IF NOT EXISTS paid_amount_minor integer,
                ADD COLUMN IF NOT EXISTS invoice_uuid varchar(64)
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_shop_orders_bank_transfer_due
                   ON shop_orders (namespace_id, created_at) WHERE status = 'pending_payment'
                   AND payment_method = 'bank_transfer']])
    end,
}
