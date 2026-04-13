-- Multi-Currency Support Migration
-- Adds currency fields to all monetary tables for international support
-- Enables stores and products to operate in their local currency

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Add currency to store_products table (products have store-specific pricing)
    [1] = function()
        pcall(function()
            schema.add_column("store_products", "currency", types.varchar({
                default = "'USD'",
                null = false
            }))
        end)
        print("[MIGRATION] Added currency field to store_products")
    end,

    -- Add currency to cart_items table
    [2] = function()
        pcall(function()
            schema.add_column("cart_items", "currency", types.varchar({
                default = "'USD'",
                null = false
            }))
        end)

        -- Update existing cart_items to inherit currency from their store
        pcall(function()
            db.query([[
                UPDATE cart_items ci
                SET currency = COALESCE(s.currency, 'USD')
                FROM store_products sp
                INNER JOIN stores s ON sp.store_id = s.id
                WHERE ci.product_id = sp.id
            ]])
        end)

        print("[MIGRATION] Added currency field to cart_items")
    end,

    -- Add currency to order_items table
    [3] = function()
        pcall(function()
            schema.add_column("order_items", "currency", types.varchar({
                default = "'USD'",
                null = false
            }))
        end)

        -- Update existing order_items to inherit currency from their order
        pcall(function()
            db.query([[
                UPDATE order_items oi
                SET currency = COALESCE(o.currency, 'USD')
                FROM orders o
                WHERE oi.order_id = o.id
            ]])
        end)

        print("[MIGRATION] Added currency field to order_items")
    end,

    -- Add currency to delivery_requests table
    [4] = function()
        pcall(function()
            schema.add_column("delivery_requests", "currency", types.varchar({
                default = "'USD'",
                null = false
            }))
        end)

        -- Update existing delivery_requests to inherit currency from their order
        pcall(function()
            db.query([[
                UPDATE delivery_requests dr
                SET currency = COALESCE(o.currency, 'USD')
                FROM orders o
                WHERE dr.order_id = o.id
            ]])
        end)

        print("[MIGRATION] Added currency field to delivery_requests")
    end,

    -- Add currency to order_delivery_assignments table
    [5] = function()
        pcall(function()
            schema.add_column("order_delivery_assignments", "currency", types.varchar({
                default = "'USD'",
                null = false
            }))
        end)

        -- Update existing assignments to inherit currency from their order
        pcall(function()
            db.query([[
                UPDATE order_delivery_assignments oda
                SET currency = COALESCE(o.currency, 'USD')
                FROM orders o
                WHERE oda.order_id = o.id
            ]])
        end)

        print("[MIGRATION] Added currency field to order_delivery_assignments")
    end,

    -- Add currency to order_refunds table
    [6] = function()
        pcall(function()
            schema.add_column("order_refunds", "currency", types.varchar({
                default = "'USD'",
                null = false
            }))
        end)

        -- Update existing refunds to inherit currency from their order
        pcall(function()
            db.query([[
                UPDATE order_refunds r
                SET currency = COALESCE(o.currency, 'USD')
                FROM orders o
                WHERE r.order_id = o.id
            ]])
        end)

        print("[MIGRATION] Added currency field to order_refunds")
    end,

    -- Add preferred_currency to delivery_partners table
    [7] = function()
        pcall(function()
            schema.add_column("delivery_partners", "preferred_currency", types.varchar({
                default = "'USD'",
                null = false
            }))
        end)

        print("[MIGRATION] Added preferred_currency field to delivery_partners")
    end,

    -- Add currency settings to users table for buyer preferences
    [8] = function()
        pcall(function()
            schema.add_column("users", "preferred_currency", types.varchar({
                default = "'USD'",
                null = true
            }))
        end)

        pcall(function()
            schema.add_column("users", "country_code", types.varchar({
                null = true,
                length = 2
            }))
        end)

        print("[MIGRATION] Added currency preferences to users table")
    end,

    -- Create supported_currencies configuration table
    [9] = function()
        schema.create_table("supported_currencies", {
            {"id", types.serial},
            {"code", types.varchar({ length = 3, unique = true })},
            {"name", types.varchar},
            {"symbol", types.varchar},
            {"decimal_places", types.integer({ default = 2 })},
            {"is_active", types.boolean({ default = true })},
            {"exchange_rate_to_usd", types.numeric({ null = true })},
            {"stripe_supported", types.boolean({ default = true })},
            {"created_at", types.time({ null = true })},
            {"updated_at", types.time({ null = true })},
            "PRIMARY KEY (id)"
        })

        schema.create_index("supported_currencies", "code", { unique = true })
        schema.create_index("supported_currencies", "is_active")

        print("[MIGRATION] Created supported_currencies table")
    end,

    -- Populate supported currencies with initial data
    [10] = function()
        local currencies = {
            { code = 'USD', name = 'US Dollar', symbol = '$', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 1.00 },
            { code = 'EUR', name = 'Euro', symbol = '€', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 1.10 },
            { code = 'GBP', name = 'British Pound', symbol = '£', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 1.27 },
            { code = 'INR', name = 'Indian Rupee', symbol = '₹', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 0.012 },
            { code = 'CAD', name = 'Canadian Dollar', symbol = 'CA$', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 0.74 },
            { code = 'AUD', name = 'Australian Dollar', symbol = 'A$', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 0.66 },
            { code = 'JPY', name = 'Japanese Yen', symbol = '¥', decimal_places = 0, stripe_supported = true, exchange_rate_to_usd = 0.0067 },
            { code = 'CNY', name = 'Chinese Yuan', symbol = '¥', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 0.14 },
            { code = 'CHF', name = 'Swiss Franc', symbol = 'CHF', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 1.13 },
            { code = 'SGD', name = 'Singapore Dollar', symbol = 'S$', decimal_places = 2, stripe_supported = true, exchange_rate_to_usd = 0.74 },
        }

        for _, currency in ipairs(currencies) do
            pcall(function()
                db.insert("supported_currencies", {
                    code = currency.code,
                    name = currency.name,
                    symbol = currency.symbol,
                    decimal_places = currency.decimal_places,
                    is_active = true,
                    stripe_supported = currency.stripe_supported,
                    exchange_rate_to_usd = currency.exchange_rate_to_usd,
                    created_at = db.format_date(),
                    updated_at = db.format_date()
                })
            end)
        end

        print("[MIGRATION] Populated supported_currencies with initial data")
    end,

    -- Add indexes for better currency query performance
    [11] = function()
        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS orders_currency_idx ON orders (currency)")
        end)

        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS stores_currency_idx ON stores (currency)")
        end)

        print("[MIGRATION] Created currency indexes for performance")
    end,
}
