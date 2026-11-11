-- luacheck: max line length 140
--[[
    Order Authorisation (FEATURES.SHOP)
    ===================================

    Staff build an order in the back office (a shop quote of kind 'order'), send it to the customer as an
    "Order Authorisation" (email + PDF + link), the customer confirms it and accepts the terms, then pays
    online. Quotes keep their status flow: draft → sent (awaiting authorisation) → accepted (authorised)
    → converted (paid, has an order).

    [1] shop_quotes
          kind                  quote | order ("Order Authorisation" on the documents)
          discount_minor        staff discount, ex VAT, off the whole quote (with discount_label)
          trade_discount_minor  VIP Trade discount, ex VAT, worked out from the membership terms
          delivery_method       free text, e.g. "Courier, next working day"
          delivery_address      jsonb {name, company, line1, line2, city, postcode, country, email, phone, vat_number}
          sent_at               last time it was emailed for authorisation
          authorised_at / authorised_by_name   when and by whom the customer confirmed it
        shop_orders: discount_minor (staff + Trade discount carried from the quote), delivery_method,
        delivery_address.

    Registered in migrations.lua as zzs39. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            ALTER TABLE shop_quotes
                ADD COLUMN IF NOT EXISTS kind varchar(8) NOT NULL DEFAULT 'quote',
                ADD COLUMN IF NOT EXISTS discount_minor integer NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS discount_label varchar(120),
                ADD COLUMN IF NOT EXISTS trade_discount_minor integer NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS delivery_method varchar(160),
                ADD COLUMN IF NOT EXISTS delivery_address jsonb,
                ADD COLUMN IF NOT EXISTS sent_at timestamptz,
                ADD COLUMN IF NOT EXISTS authorised_at timestamptz,
                ADD COLUMN IF NOT EXISTS authorised_by_name varchar(160)
        ]])
        db.query([[
            DO $$ BEGIN
                ALTER TABLE shop_quotes ADD CONSTRAINT shop_quotes_kind_chk CHECK (kind IN ('quote', 'order'));
            EXCEPTION WHEN duplicate_object THEN NULL; END $$
        ]])
        db.query([[
            DO $$ BEGIN
                ALTER TABLE shop_quotes ADD CONSTRAINT shop_quotes_discounts_chk
                    CHECK (discount_minor >= 0 AND trade_discount_minor >= 0);
            EXCEPTION WHEN duplicate_object THEN NULL; END $$
        ]])
        db.query([[
            ALTER TABLE shop_orders
                ADD COLUMN IF NOT EXISTS discount_minor integer NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS delivery_method varchar(160),
                ADD COLUMN IF NOT EXISTS delivery_address jsonb
        ]])
    end,
}
