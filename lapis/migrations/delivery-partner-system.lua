local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Create delivery_partners table
    [1] = function()
        schema.create_table("delivery_partners", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "user_id", types.foreign_key({ null = false, unique = true }) },
            { "company_name", types.varchar({ null = false }) },
            { "company_registration_number", types.varchar({ null = true }) },
            { "contact_person_name", types.varchar({ null = false }) },
            { "contact_person_phone", types.varchar({ null = false }) },
            { "contact_person_email", types.varchar({ null = false }) },
            { "business_address", types.text({ null = false }) },
            { "service_type", types.varchar({ default = "'standard'" }) }, -- standard, express, same_day
            { "vehicle_types", types.text({ default = "'[]'" }) }, -- JSON array: bike, car, van, truck
            { "max_daily_capacity", types.integer({ default = 10 }) },
            { "current_active_orders", types.integer({ default = 0 }) },
            { "service_radius_km", types.numeric({ default = 10 }) },
            { "base_charge", types.numeric({ default = 0 }) },
            { "per_km_charge", types.numeric({ default = 0 }) },
            { "percentage_charge", types.numeric({ default = 0 }) }, -- % of order value
            { "pricing_model", types.varchar({ default = "'flat'" }) }, -- flat, per_km, percentage, hybrid
            { "is_verified", types.boolean({ default = false }) },
            { "is_active", types.boolean({ default = true }) },
            { "verification_documents", types.text({ default = "'[]'" }) }, -- JSON array
            { "rating", types.numeric({ default = 0 }) },
            { "total_deliveries", types.integer({ default = 0 }) },
            { "successful_deliveries", types.integer({ default = 0 }) },
            { "bank_account_number", types.varchar({ null = true }) },
            { "bank_name", types.varchar({ null = true }) },
            { "bank_ifsc_code", types.varchar({ null = true }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for delivery_partners
    [2] = function()
        schema.create_index("delivery_partners", "user_id")
        schema.create_index("delivery_partners", "uuid")
        schema.create_index("delivery_partners", "is_active")
        schema.create_index("delivery_partners", "is_verified")
    end,

    -- Create delivery_partner_areas table (service coverage)
    [3] = function()
        schema.create_table("delivery_partner_areas", {
            { "id", types.serial },
            { "delivery_partner_id", types.foreign_key({ null = false }) },
            { "country", types.varchar({ null = false }) },
            { "state", types.varchar({ null = false }) },
            { "city", types.varchar({ null = false }) },
            { "postal_codes", types.text({ default = "'[]'" }) }, -- JSON array of postal codes
            { "is_active", types.boolean({ default = true }) },
            { "created_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for delivery_partner_areas
    [4] = function()
        schema.create_index("delivery_partner_areas", "delivery_partner_id")
        schema.create_index("delivery_partner_areas", "city")
        schema.create_index("delivery_partner_areas", "state")
        db.query([[
            CREATE INDEX IF NOT EXISTS delivery_partner_areas_location_idx
            ON delivery_partner_areas (country, state, city)
        ]])
    end,

    -- Create store_delivery_partners table (seller's selected partners)
    [5] = function()
        schema.create_table("store_delivery_partners", {
            { "id", types.serial },
            { "store_id", types.foreign_key({ null = false }) },
            { "delivery_partner_id", types.foreign_key({ null = false }) },
            { "is_preferred", types.boolean({ default = false }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(store_id, delivery_partner_id)"
        })
    end,

    -- Create indexes for store_delivery_partners
    [6] = function()
        schema.create_index("store_delivery_partners", "store_id")
        schema.create_index("store_delivery_partners", "delivery_partner_id")
    end,

    -- Create order_delivery_assignments table
    [7] = function()
        schema.create_table("order_delivery_assignments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "order_id", types.foreign_key({ null = false, unique = true }) },
            { "delivery_partner_id", types.foreign_key({ null = false }) },
            { "assignment_type", types.varchar({ default = "'seller_assigned'" }) }, -- seller_assigned, partner_requested, auto_assigned
            { "status", types.varchar({ default = "'pending'" }) }, -- pending, accepted, rejected, picked_up, in_transit, delivered, failed
            { "delivery_fee", types.numeric({ null = false }) },
            { "pickup_address", types.text({ null = false }) },
            { "delivery_address", types.text({ null = false }) },
            { "pickup_instructions", types.text({ null = true }) },
            { "delivery_instructions", types.text({ null = true }) },
            { "estimated_pickup_time", types.time({ null = true }) },
            { "actual_pickup_time", types.time({ null = true }) },
            { "estimated_delivery_time", types.time({ null = true }) },
            { "actual_delivery_time", types.time({ null = true }) },
            { "distance_km", types.numeric({ null = true }) },
            { "tracking_number", types.varchar({ null = true, unique = true }) },
            { "proof_of_delivery", types.text({ null = true }) }, -- JSON: signature, photo, otp
            { "notes", types.text({ null = true }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for order_delivery_assignments
    [8] = function()
        schema.create_index("order_delivery_assignments", "order_id")
        schema.create_index("order_delivery_assignments", "delivery_partner_id")
        schema.create_index("order_delivery_assignments", "status")
        schema.create_index("order_delivery_assignments", "tracking_number")
    end,

    -- Create delivery_requests table (for delivery partner requests)
    [9] = function()
        schema.create_table("delivery_requests", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "order_id", types.foreign_key({ null = false }) },
            { "delivery_partner_id", types.foreign_key({ null = false }) },
            { "request_type", types.varchar({ default = "'partner_to_seller'" }) }, -- partner_to_seller, seller_to_partner
            { "status", types.varchar({ default = "'pending'" }) }, -- pending, accepted, rejected, expired
            { "proposed_fee", types.numeric({ null = false }) },
            { "message", types.text({ null = true }) },
            { "response_message", types.text({ null = true }) },
            { "expires_at", types.time({ null = true }) },
            { "responded_at", types.time({ null = true }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(order_id, delivery_partner_id)"
        })
    end,

    -- Create indexes for delivery_requests
    [10] = function()
        schema.create_index("delivery_requests", "order_id")
        schema.create_index("delivery_requests", "delivery_partner_id")
        schema.create_index("delivery_requests", "status")
    end,

    -- Create delivery_partner_reviews table
    [11] = function()
        schema.create_table("delivery_partner_reviews", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "delivery_partner_id", types.foreign_key({ null = false }) },
            { "order_id", types.foreign_key({ null = false }) },
            { "reviewer_id", types.foreign_key({ null = false }) }, -- user_id (seller or buyer)
            { "reviewer_type", types.varchar({ null = false }) }, -- seller, buyer
            { "rating", types.integer({ null = false }) }, -- 1-5
            { "comment", types.text({ null = true }) },
            { "delivery_speed_rating", types.integer({ null = true }) },
            { "communication_rating", types.integer({ null = true }) },
            { "professionalism_rating", types.integer({ null = true }) },
            { "created_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(order_id, reviewer_id)"
        })
    end,

    -- Create indexes for delivery_partner_reviews
    [12] = function()
        schema.create_index("delivery_partner_reviews", "delivery_partner_id")
        schema.create_index("delivery_partner_reviews", "order_id")
    end,

    -- Add constraints
    [13] = function()
        pcall(function()
            db.query([[
                ALTER TABLE delivery_partners
                ADD CONSTRAINT delivery_partners_rating_valid
                CHECK (rating >= 0 AND rating <= 5)
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE delivery_partners
                ADD CONSTRAINT delivery_partners_pricing_model_valid
                CHECK (pricing_model IN ('flat', 'per_km', 'percentage', 'hybrid'))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE delivery_partner_reviews
                ADD CONSTRAINT delivery_partner_reviews_rating_valid
                CHECK (rating >= 1 AND rating <= 5)
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE order_delivery_assignments
                ADD CONSTRAINT order_delivery_assignments_status_valid
                CHECK (status IN ('pending', 'accepted', 'rejected', 'picked_up', 'in_transit', 'delivered', 'failed'))
            ]])
        end)
    end,

    -- Add can_self_ship column to stores table
    [14] = function()
        pcall(function()
            schema.add_column("stores", "can_self_ship", types.boolean({ default = true }))
        end)
    end,

    -- Add delivery_partner_id to orders for tracking
    [15] = function()
        pcall(function()
            schema.add_column("orders", "delivery_partner_id", types.foreign_key({ null = true }))
            schema.create_index("orders", "delivery_partner_id")
        end)
    end
}
