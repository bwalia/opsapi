local schema = require("lapis.db.schema")
local types = schema.types

return {
    -- Create payments table for transaction records
    [1] = function()
        schema.create_table("payments", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"order_id", types.foreign_key({ null = true })},
            {"user_id", types.foreign_key({ null = true })},
            {"stripe_payment_intent_id", types.varchar({ null = true })},
            {"stripe_charge_id", types.varchar({ null = true })},
            {"stripe_customer_id", types.varchar({ null = true })},
            {"stripe_payment_method_id", types.varchar({ null = true })},
            {"amount", types.numeric},
            {"currency", types.varchar({ default = "usd" })},
            {"status", types.varchar},  -- pending, succeeded, failed, refunded, canceled
            {"payment_method_type", types.varchar({ null = true })},  -- card, bank_transfer, etc
            {"card_brand", types.varchar({ null = true })},  -- visa, mastercard, amex, etc
            {"card_last4", types.varchar({ null = true })},
            {"receipt_email", types.varchar({ null = true })},
            {"receipt_url", types.text({ null = true })},
            {"metadata", types.text({ null = true })},  -- JSON string
            {"stripe_raw_response", types.text({ null = true })},  -- Full webhook payload
            {"created_at", types.time},
            {"updated_at", types.time},
            "PRIMARY KEY (id)"
        })
    end,

    -- Add indexes for payments table
    [2] = function()
        schema.create_index("payments", "uuid")
        schema.create_index("payments", "order_id")
        schema.create_index("payments", "user_id")
        schema.create_index("payments", "stripe_payment_intent_id")
        schema.create_index("payments", "status")
        schema.create_index("payments", "created_at")
    end,

    -- Add payment_id to orders table
    [3] = function()
        schema.add_column("orders", "payment_id", types.foreign_key({ null = true }))
    end,

    -- Update order status constraint to include new statuses
    [4] = function()
        local db = require("lapis.db")

        -- Drop old constraint if exists
        pcall(function()
            db.query("ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_status_valid")
        end)

        -- Add new constraint with all valid statuses
        db.query([[
            ALTER TABLE orders ADD CONSTRAINT orders_status_valid
            CHECK (status IN (
                'pending', 'accepted', 'preparing', 'packing',
                'shipping', 'shipped', 'delivered',
                'cancelled', 'refunded',
                'confirmed', 'processing'
            ))
        ]])

        -- Add comment to document valid order statuses
        pcall(function()
            db.query([[
                COMMENT ON COLUMN orders.status IS 'Valid statuses: pending, accepted, preparing, packing, shipping, shipped, delivered, cancelled, refunded'
            ]])
        end)
    end,

    -- Create order status history table
    [5] = function()
        schema.create_table("order_status_history", {
            {"id", types.serial},
            {"order_id", types.foreign_key},
            {"old_status", types.varchar({ null = true })},
            {"new_status", types.varchar},
            {"changed_by_user_id", types.foreign_key({ null = true })},
            {"notes", types.text({ null = true })},
            {"created_at", types.time},
            "PRIMARY KEY (id)"
        })
    end,

    -- Add indexes for order status history
    [6] = function()
        schema.create_index("order_status_history", "order_id")
        schema.create_index("order_status_history", "created_at")
    end,

    -- Add tracking information to orders (skip if already exists from previous migration)
    [7] = function()
        -- Check and add columns only if they don't exist
        pcall(function() schema.add_column("orders", "tracking_number", types.varchar({ null = true })) end)
        pcall(function() schema.add_column("orders", "tracking_url", types.text({ null = true })) end)
        pcall(function() schema.add_column("orders", "carrier", types.varchar({ null = true })) end)
        pcall(function() schema.add_column("orders", "estimated_delivery_date", types.date({ null = true })) end)
    end,

    -- Create refunds table
    [8] = function()
        schema.create_table("refunds", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"order_id", types.foreign_key},
            {"payment_id", types.foreign_key({ null = true })},
            {"stripe_refund_id", types.varchar({ null = true })},
            {"amount", types.numeric},
            {"reason", types.text({ null = true })},
            {"status", types.varchar},  -- pending, succeeded, failed, cancelled
            {"refund_type", types.varchar},  -- full, partial
            {"processed_by_user_id", types.foreign_key({ null = true })},
            {"created_at", types.time},
            {"updated_at", types.time},
            "PRIMARY KEY (id)"
        })
    end,

    -- Add indexes for refunds
    [9] = function()
        schema.create_index("refunds", "uuid")
        schema.create_index("refunds", "order_id")
        schema.create_index("refunds", "stripe_refund_id")
        schema.create_index("refunds", "status")
    end,

    -- Fix order status constraint (migration #56)
    [10] = function()
        local db = require("lapis.db")

        -- Drop old constraint
        pcall(function()
            db.query("ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_status_valid")
        end)

        -- Add new constraint with all valid statuses including new workflow statuses
        db.query([[
            ALTER TABLE orders ADD CONSTRAINT orders_status_valid
            CHECK (status IN (
                'pending', 'accepted', 'preparing', 'packing',
                'shipping', 'shipped', 'delivered',
                'cancelled', 'refunded',
                'confirmed', 'processing'
            ))
        ]])
    end
}
