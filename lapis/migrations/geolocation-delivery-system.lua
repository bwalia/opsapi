--[[
    Geolocation-Based Delivery Partner System

    This migration adds professional geospatial capabilities to the delivery partner system:
    - PostGIS extension for geographic calculations
    - Coordinates storage for delivery partners (latitude/longitude)
    - Service area radius in kilometers
    - Geospatial indexes for fast proximity searches
    - Order location coordinates
    - Real-time distance calculations

    Author: Senior Backend Engineer
    Date: 2025-01-19
]]--

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Enable PostGIS extension for geospatial operations
    [1] = function()
        pcall(function()
            db.query([[
                CREATE EXTENSION IF NOT EXISTS postgis;
            ]])
            print("✓ PostGIS extension enabled successfully")
        end)
    end,

    -- Add geolocation columns to delivery_partners table
    [2] = function()
        pcall(function()
            -- Add latitude and longitude for partner's base location
            db.query([[
                ALTER TABLE delivery_partners
                ADD COLUMN IF NOT EXISTS latitude NUMERIC(10, 8),
                ADD COLUMN IF NOT EXISTS longitude NUMERIC(11, 8),
                ADD COLUMN IF NOT EXISTS location GEOGRAPHY(POINT, 4326),
                ADD COLUMN IF NOT EXISTS service_radius_km NUMERIC(6, 2) DEFAULT 10.00,
                ADD COLUMN IF NOT EXISTS address_line1 TEXT,
                ADD COLUMN IF NOT EXISTS address_line2 TEXT,
                ADD COLUMN IF NOT EXISTS city VARCHAR(100),
                ADD COLUMN IF NOT EXISTS state VARCHAR(100),
                ADD COLUMN IF NOT EXISTS country VARCHAR(100) DEFAULT 'India',
                ADD COLUMN IF NOT EXISTS postal_code VARCHAR(20),
                ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMP
            ]])
            print("✓ Added geolocation columns to delivery_partners")
        end)
    end,

    -- Create geospatial index on delivery_partners location
    [3] = function()
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS idx_delivery_partners_location
                ON delivery_partners USING GIST (location);
            ]])
            print("✓ Created GIST index on delivery_partners.location")
        end)
    end,

    -- Create trigger to automatically update location from lat/lng
    [4] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_delivery_partner_location()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
                        NEW.location = ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 4326)::geography;
                        NEW.location_updated_at = NOW();
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])

            db.query([[
                DROP TRIGGER IF EXISTS trg_update_delivery_partner_location ON delivery_partners;
            ]])

            db.query([[
                CREATE TRIGGER trg_update_delivery_partner_location
                BEFORE INSERT OR UPDATE OF latitude, longitude ON delivery_partners
                FOR EACH ROW
                EXECUTE FUNCTION update_delivery_partner_location();
            ]])
            print("✓ Created trigger for automatic location updates")
        end)
    end,

    -- Add geolocation columns to orders table for delivery address
    [5] = function()
        pcall(function()
            db.query([[
                ALTER TABLE orders
                ADD COLUMN IF NOT EXISTS delivery_latitude NUMERIC(10, 8),
                ADD COLUMN IF NOT EXISTS delivery_longitude NUMERIC(11, 8),
                ADD COLUMN IF NOT EXISTS delivery_location GEOGRAPHY(POINT, 4326),
                ADD COLUMN IF NOT EXISTS pickup_latitude NUMERIC(10, 8),
                ADD COLUMN IF NOT EXISTS pickup_longitude NUMERIC(11, 8),
                ADD COLUMN IF NOT EXISTS pickup_location GEOGRAPHY(POINT, 4326)
            ]])
            print("✓ Added geolocation columns to orders")
        end)
    end,

    -- Create geospatial indexes on orders
    [6] = function()
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS idx_orders_delivery_location
                ON orders USING GIST (delivery_location);
            ]])

            db.query([[
                CREATE INDEX IF NOT EXISTS idx_orders_pickup_location
                ON orders USING GIST (pickup_location);
            ]])
            print("✓ Created GIST indexes on orders location columns")
        end)
    end,

    -- Create trigger to automatically update order locations from lat/lng
    [7] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_order_locations()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF NEW.delivery_latitude IS NOT NULL AND NEW.delivery_longitude IS NOT NULL THEN
                        NEW.delivery_location = ST_SetSRID(
                            ST_MakePoint(NEW.delivery_longitude, NEW.delivery_latitude),
                            4326
                        )::geography;
                    END IF;

                    IF NEW.pickup_latitude IS NOT NULL AND NEW.pickup_longitude IS NOT NULL THEN
                        NEW.pickup_location = ST_SetSRID(
                            ST_MakePoint(NEW.pickup_longitude, NEW.pickup_latitude),
                            4326
                        )::geography;
                    END IF;

                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])

            db.query([[
                DROP TRIGGER IF NOT EXISTS trg_update_order_locations ON orders;
            ]])

            db.query([[
                CREATE TRIGGER trg_update_order_locations
                BEFORE INSERT OR UPDATE OF delivery_latitude, delivery_longitude,
                                         pickup_latitude, pickup_longitude ON orders
                FOR EACH ROW
                EXECUTE FUNCTION update_order_locations();
            ]])
            print("✓ Created trigger for automatic order location updates")
        end)
    end,

    -- Create function to find delivery partners within radius of a location
    [8] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION find_nearby_delivery_partners(
                    order_lat NUMERIC,
                    order_lng NUMERIC,
                    max_distance_km NUMERIC DEFAULT 50
                )
                RETURNS TABLE (
                    id INTEGER,
                    uuid VARCHAR,
                    company_name VARCHAR,
                    distance_km NUMERIC,
                    service_radius_km NUMERIC,
                    current_active_orders INTEGER,
                    max_daily_capacity INTEGER,
                    rating NUMERIC,
                    is_verified BOOLEAN,
                    is_active BOOLEAN
                ) AS $$
                BEGIN
                    RETURN QUERY
                    SELECT
                        dp.id,
                        dp.uuid,
                        dp.company_name,
                        ROUND(
                            ST_Distance(
                                dp.location,
                                ST_SetSRID(ST_MakePoint(order_lng, order_lat), 4326)::geography
                            ) / 1000,
                            2
                        ) as distance_km,
                        dp.service_radius_km,
                        dp.current_active_orders,
                        dp.max_daily_capacity,
                        dp.rating,
                        dp.is_verified,
                        dp.is_active
                    FROM delivery_partners dp
                    WHERE
                        dp.is_verified = TRUE
                        AND dp.is_active = TRUE
                        AND dp.current_active_orders < dp.max_daily_capacity
                        AND dp.location IS NOT NULL
                        AND ST_DWithin(
                            dp.location,
                            ST_SetSRID(ST_MakePoint(order_lng, order_lat), 4326)::geography,
                            LEAST(dp.service_radius_km, max_distance_km) * 1000  -- Convert km to meters
                        )
                    ORDER BY distance_km ASC, dp.rating DESC;
                END;
                $$ LANGUAGE plpgsql STABLE;
            ]])
            print("✓ Created find_nearby_delivery_partners function")
        end)
    end,

    -- Create function to check if delivery partner can service an order location
    [9] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION can_service_location(
                    partner_id INTEGER,
                    order_lat NUMERIC,
                    order_lng NUMERIC
                )
                RETURNS BOOLEAN AS $$
                DECLARE
                    partner_location GEOGRAPHY;
                    partner_radius NUMERIC;
                    distance_meters NUMERIC;
                BEGIN
                    SELECT location, service_radius_km
                    INTO partner_location, partner_radius
                    FROM delivery_partners
                    WHERE id = partner_id;

                    IF partner_location IS NULL THEN
                        RETURN FALSE;
                    END IF;

                    distance_meters := ST_Distance(
                        partner_location,
                        ST_SetSRID(ST_MakePoint(order_lng, order_lat), 4326)::geography
                    );

                    RETURN distance_meters <= (partner_radius * 1000);
                END;
                $$ LANGUAGE plpgsql STABLE;
            ]])
            print("✓ Created can_service_location function")
        end)
    end,

    -- Create delivery_partner_notifications table
    [10] = function()
        pcall(function()
            -- Check if table exists first
            local exists = db.query([[
                SELECT EXISTS (
                    SELECT FROM information_schema.tables
                    WHERE table_name = 'delivery_partner_notifications'
                );
            ]])[1].exists

            if not exists then
                schema.create_table("delivery_partner_notifications", {
                    { "id", types.serial },
                    { "uuid", types.varchar({ unique = true, null = false }) },
                    { "delivery_partner_id", types.foreign_key({ null = false }) },
                    { "order_id", types.foreign_key({ null = false }) },
                    { "notification_type", types.varchar({ default = "'new_order_nearby'" }) },
                    { "title", types.varchar({ null = false }) },
                    { "message", types.text({ null = false }) },
                    { "distance_km", types.numeric({ null = true }) },
                    { "is_read", types.boolean({ default = false }) },
                    { "is_sent", types.boolean({ default = false }) },
                    { "sent_at", types.time({ null = true }) },
                    { "read_at", types.time({ null = true }) },
                    { "expires_at", types.time({ null = true }) },
                    { "created_at", types.time({ null = false }) },
                    "PRIMARY KEY (id)"
                })
                print("✓ Created delivery_partner_notifications table")
            else
                print("✓ Table delivery_partner_notifications already exists, skipping")
            end
        end)
    end,

    -- Create indexes for notifications
    [11] = function()
        pcall(function()
            schema.create_index("delivery_partner_notifications", "delivery_partner_id")
            schema.create_index("delivery_partner_notifications", "order_id")
            schema.create_index("delivery_partner_notifications", "is_read")
            schema.create_index("delivery_partner_notifications", "is_sent")
            schema.create_index("delivery_partner_notifications", "created_at")

            db.query([[
                CREATE INDEX IF NOT EXISTS idx_notifications_active
                ON delivery_partner_notifications (delivery_partner_id, is_read)
                WHERE is_read = FALSE;
            ]])
            print("✓ Created indexes on delivery_partner_notifications")
        end)
    end,

    -- Create materialized view for delivery partner statistics with geolocation
    [12] = function()
        pcall(function()
            db.query([[
                CREATE MATERIALIZED VIEW IF NOT EXISTS delivery_partner_geo_stats AS
                SELECT
                    dp.id,
                    dp.uuid,
                    dp.company_name,
                    dp.latitude,
                    dp.longitude,
                    dp.service_radius_km,
                    dp.rating,
                    dp.current_active_orders,
                    dp.max_daily_capacity,
                    dp.total_deliveries,
                    dp.successful_deliveries,
                    dp.city,
                    dp.state,
                    CASE
                        WHEN dp.total_deliveries > 0
                        THEN ROUND((dp.successful_deliveries::NUMERIC / dp.total_deliveries * 100), 2)
                        ELSE 0
                    END as success_rate,
                    COUNT(DISTINCT oda.id) FILTER (WHERE oda.status IN ('pending', 'accepted', 'picked_up', 'in_transit')) as active_assignments,
                    COALESCE(SUM(oda.delivery_fee) FILTER (WHERE oda.status = 'delivered'), 0) as total_earnings,
                    COALESCE(AVG(dpr.rating), 0) as average_review_rating,
                    COUNT(dpr.id) as total_reviews
                FROM delivery_partners dp
                LEFT JOIN order_delivery_assignments oda ON dp.id = oda.delivery_partner_id
                LEFT JOIN delivery_partner_reviews dpr ON dp.id = dpr.delivery_partner_id
                WHERE dp.is_active = TRUE
                GROUP BY dp.id, dp.uuid, dp.company_name, dp.latitude, dp.longitude,
                         dp.service_radius_km, dp.rating, dp.current_active_orders,
                         dp.max_daily_capacity, dp.total_deliveries, dp.successful_deliveries,
                         dp.city, dp.state;
            ]])

            db.query([[
                CREATE UNIQUE INDEX IF NOT EXISTS idx_delivery_partner_geo_stats_id
                ON delivery_partner_geo_stats (id);
            ]])
            print("✓ Created delivery_partner_geo_stats materialized view")
        end)
    end,

    -- Add comment documentation for geolocation columns
    [13] = function()
        pcall(function()
            db.query([[
                COMMENT ON COLUMN delivery_partners.latitude IS
                'Latitude coordinate of delivery partner base location (WGS84)';

                COMMENT ON COLUMN delivery_partners.longitude IS
                'Longitude coordinate of delivery partner base location (WGS84)';

                COMMENT ON COLUMN delivery_partners.location IS
                'PostGIS geography point automatically generated from lat/lng';

                COMMENT ON COLUMN delivery_partners.service_radius_km IS
                'Maximum service radius in kilometers from base location';

                COMMENT ON COLUMN orders.delivery_latitude IS
                'Latitude of delivery destination (customer address)';

                COMMENT ON COLUMN orders.delivery_longitude IS
                'Longitude of delivery destination (customer address)';

                COMMENT ON COLUMN orders.pickup_latitude IS
                'Latitude of pickup location (store/warehouse)';

                COMMENT ON COLUMN orders.pickup_longitude IS
                'Longitude of pickup location (store/warehouse)';
            ]])
            print("✓ Added documentation comments to geolocation columns")
        end)
    end,

    -- Create helper function to calculate delivery fee based on distance
    [14] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION calculate_delivery_fee(
                    partner_id INTEGER,
                    distance_km NUMERIC,
                    order_value NUMERIC DEFAULT 0
                )
                RETURNS NUMERIC AS $$
                DECLARE
                    base_charge NUMERIC;
                    per_km_charge NUMERIC;
                    percentage_charge NUMERIC;
                    pricing_model VARCHAR;
                    calculated_fee NUMERIC;
                BEGIN
                    SELECT
                        dp.base_charge,
                        dp.per_km_charge,
                        dp.percentage_charge,
                        dp.pricing_model
                    INTO base_charge, per_km_charge, percentage_charge, pricing_model
                    FROM delivery_partners dp
                    WHERE dp.id = partner_id;

                    calculated_fee := CASE pricing_model
                        WHEN 'flat' THEN base_charge
                        WHEN 'per_km' THEN base_charge + (distance_km * per_km_charge)
                        WHEN 'percentage' THEN (order_value * percentage_charge / 100)
                        WHEN 'hybrid' THEN base_charge + (distance_km * per_km_charge) +
                                          (order_value * percentage_charge / 100)
                        ELSE base_charge
                    END;

                    RETURN ROUND(calculated_fee, 2);
                END;
                $$ LANGUAGE plpgsql STABLE;
            ]])
            print("✓ Created calculate_delivery_fee function")
        end)
    end,

    -- Add validation constraints for coordinates
    [15] = function()
        pcall(function()
            db.query([[
                ALTER TABLE delivery_partners
                DROP CONSTRAINT IF EXISTS chk_delivery_partners_latitude;
            ]])

            db.query([[
                ALTER TABLE delivery_partners
                ADD CONSTRAINT chk_delivery_partners_latitude
                CHECK (latitude IS NULL OR (latitude >= -90 AND latitude <= 90));
            ]])

            db.query([[
                ALTER TABLE delivery_partners
                DROP CONSTRAINT IF EXISTS chk_delivery_partners_longitude;
            ]])

            db.query([[
                ALTER TABLE delivery_partners
                ADD CONSTRAINT chk_delivery_partners_longitude
                CHECK (longitude IS NULL OR (longitude >= -180 AND longitude <= 180));
            ]])

            db.query([[
                ALTER TABLE delivery_partners
                DROP CONSTRAINT IF EXISTS chk_delivery_partners_service_radius;
            ]])

            db.query([[
                ALTER TABLE delivery_partners
                ADD CONSTRAINT chk_delivery_partners_service_radius
                CHECK (service_radius_km > 0 AND service_radius_km <= 100);
            ]])
            print("✓ Added validation constraints for coordinates")
        end)
    end
}
