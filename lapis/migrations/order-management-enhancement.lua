-- Order Management Enhancement Migrations
-- Adds tables and fields needed for proper order management

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Create order_history table for audit trail
    [1] = function()
        schema.create_table("order_history", {
            {"id", types.serial},
            {"order_id", types.foreign_key},
            {"user_id", types.foreign_key({ null = true})},
            {"action", types.varchar},  -- status_update, note_added, refund_issued, etc.
            {"old_status", types.varchar({ null = true })},
            {"new_status", types.varchar({ null = true })},
            {"old_financial_status", types.varchar({ null = true })},
            {"new_financial_status", types.varchar({ null = true })},
            {"old_fulfillment_status", types.varchar({ null = true })},
            {"new_fulfillment_status", types.varchar({ null = true })},
            {"notes", types.text({ null = true })},
            {"tracking_number", types.varchar({ null = true })},
            {"carrier", types.varchar({ null = true })},
            {"metadata", types.text({ null = true })},  -- JSON for additional data
            {"created_at", types.time({ null = true })},
            "PRIMARY KEY (id)",
            "FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE",
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL"
        })

        schema.create_index("order_history", "order_id")
        schema.create_index("order_history", "action")
        schema.create_index("order_history", "created_at")
    end,

    -- Create notifications table for email/SMS tracking
    [2] = function()
        schema.create_table("notifications", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"type", types.varchar},  -- email, sms, push
            {"recipient", types.varchar},  -- email address or phone number
            {"subject", types.varchar({ null = true })},
            {"message", types.text},
            {"status", types.varchar({ default = "'pending'" })},  -- pending, sent, failed, bounced
            {"template_name", types.varchar({ null = true })},
            {"related_type", types.varchar({ null = true })},  -- order, product, user
            {"related_id", types.integer({ null = true })},
            {"error_message", types.text({ null = true })},
            {"sent_at", types.time({ null = true })},
            {"created_at", types.time({ null = true })},
            {"updated_at", types.time({ null = true })},
            "PRIMARY KEY (id)"
        })

        schema.create_index("notifications", "type")
        schema.create_index("notifications", "status")
        schema.create_index("notifications", "recipient")
        schema.create_index("notifications", "related_type", "related_id")
        schema.create_index("notifications", "created_at")
    end,

    -- Create shipping_tracking table
    [3] = function()
        schema.create_table("shipping_tracking", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"order_id", types.foreign_key},
            {"tracking_number", types.varchar},
            {"carrier", types.varchar({ null = true })},
            {"carrier_code", types.varchar({ null = true })},  -- usps, fedex, ups, dhl
            {"status", types.varchar({ default = "'pending'" })},  -- pending, in_transit, delivered, exception
            {"estimated_delivery", types.date({ null = true })},
            {"actual_delivery", types.time({ null = true })},
            {"current_location", types.varchar({ null = true })},
            {"tracking_url", types.text({ null = true })},
            {"notes", types.text({ null = true })},
            {"created_at", types.time({ null = true })},
            {"updated_at", types.time({ null = true })},
            "PRIMARY KEY (id)",
            "FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE"
        })

        schema.create_index("shipping_tracking", "order_id")
        schema.create_index("shipping_tracking", "tracking_number")
        schema.create_index("shipping_tracking", "status")
    end,

    -- Create returns/refunds table
    [4] = function()
        schema.create_table("order_refunds", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"order_id", types.foreign_key},
            {"refund_number", types.varchar({ unique = true })},
            {"reason", types.varchar},  -- customer_request, defective, wrong_item, etc.
            {"refund_type", types.varchar},  -- full, partial
            {"refund_amount", types.numeric},
            {"refund_method", types.varchar},  -- original_payment, store_credit, manual
            {"status", types.varchar({ default = "'pending'" })},  -- pending, approved, processing, completed, rejected
            {"notes", types.text({ null = true })},
            {"processed_by", types.foreign_key({ null = true })},
            {"processed_at", types.time({ null = true })},
            {"created_at", types.time({ null = true })},
            {"updated_at", types.time({ null = true })},
            "PRIMARY KEY (id)",
            "FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE",
            "FOREIGN KEY (processed_by) REFERENCES users(id) ON DELETE SET NULL"
        })

        schema.create_index("order_refunds", "order_id")
        schema.create_index("order_refunds", "refund_number", { unique = true })
        schema.create_index("order_refunds", "status")
        schema.create_index("order_refunds", "created_at")
    end,

    -- Add missing fields to orders table
    [5] = function()
        -- Add tracking and carrier fields (with error handling for existing columns)
        pcall(function() schema.add_column("orders", "tracking_number", types.varchar({ null = true })) end)
        pcall(function() schema.add_column("orders", "carrier", types.varchar({ null = true })) end)
        pcall(function() schema.add_column("orders", "estimated_delivery", types.date({ null = true })) end)
        pcall(function() schema.add_column("orders", "actual_delivery", types.time({ null = true })) end)

        -- Add customer communication fields
        pcall(function() schema.add_column("orders", "customer_notified", types.boolean({ default = false })) end)
        pcall(function() schema.add_column("orders", "last_notification_sent", types.time({ null = true })) end)

        -- Create indexes
        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS orders_tracking_number_idx ON orders (tracking_number)")
        end)
    end,

    -- Add seller note templates table
    [6] = function()
        schema.create_table("seller_note_templates", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"user_id", types.foreign_key},  -- seller who created template
            {"title", types.varchar},
            {"content", types.text},
            {"category", types.varchar({ null = true })},  -- shipping, delay, quality, general
            {"is_active", types.boolean({ default = true })},
            {"usage_count", types.integer({ default = 0 })},
            {"created_at", types.time({ null = true })},
            {"updated_at", types.time({ null = true })},
            "PRIMARY KEY (id)",
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"
        })

        schema.create_index("seller_note_templates", "user_id")
        schema.create_index("seller_note_templates", "category")
    end,

    -- Create order_tags table for better organization
    [7] = function()
        schema.create_table("order_tags", {
            {"id", types.serial},
            {"order_id", types.foreign_key},
            {"tag", types.varchar},
            {"created_at", types.time({ null = true })},
            "PRIMARY KEY (id)",
            "FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE"
        })

        schema.create_index("order_tags", "order_id")
        schema.create_index("order_tags", "tag")
        schema.create_index("order_tags", "order_id", "tag", { unique = true })
    end,

    -- Add indexes for better query performance
    [8] = function()
        -- Composite indexes for common seller queries
        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS orders_seller_dashboard_idx ON orders (store_id, status, created_at DESC)")
        end)

        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS orders_seller_financial_idx ON orders (store_id, financial_status, created_at DESC)")
        end)

        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS orders_seller_fulfillment_idx ON orders (store_id, fulfillment_status, created_at DESC)")
        end)
    end,
}
