-- Fix Delivery Request Unique Constraint
-- Allows partners to recreate requests after cancellation
-- Changes constraint to only prevent duplicate ACTIVE requests

local db = require("lapis.db")

return {
    -- Drop old constraint and create partial unique index
    [1] = function()
        print("[MIGRATION] Fixing delivery_requests unique constraint...")

        -- Drop the old unique constraint
        pcall(function()
            db.query([[
                ALTER TABLE delivery_requests
                DROP CONSTRAINT IF EXISTS delivery_requests_order_id_delivery_partner_id_key
            ]])
        end)

        print("[MIGRATION] Dropped old unique constraint")

        -- Create a partial unique index that only applies to active requests
        -- This allows cancelled/rejected/expired requests to be recreated
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX IF NOT EXISTS delivery_requests_active_unique_idx
                ON delivery_requests (order_id, delivery_partner_id)
                WHERE status IN ('pending', 'accepted')
            ]])
        end)

        print("[MIGRATION] Created partial unique index for active requests only")
        print("[MIGRATION] Partners can now recreate requests after cancellation")
    end,
}
