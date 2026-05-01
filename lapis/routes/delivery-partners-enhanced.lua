--[[
    Enhanced Delivery Partner Routes with Geolocation Support

    Professional implementation of delivery partner management with:
    - Real-time location capture
    - Service radius configuration
    - Automatic geospatial indexing
    - Distance-based matching

    Author: Senior Backend Engineer
    Date: 2025-01-19
]]--

local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

return function(app)
    -- Helper function to parse JSON body
    local function parse_json_body()
        local ok, result = pcall(function()
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cjson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    --[[
        Register as Delivery Partner with Geolocation

        This endpoint captures the user's current location and creates a delivery partner profile
        with geospatial capabilities for intelligent order matching.

        Required fields:
        - company_name: Business name
        - contact_person_name: Main contact person
        - contact_person_phone: Contact phone number
        - latitude: Current location latitude (from browser geolocation API)
        - longitude: Current location longitude (from browser geolocation API)
        - service_radius_km: Service coverage radius in kilometers (default: 10)
        - address_line1: Street address
        - city: City name
        - state: State/Province
        - postal_code: ZIP/Postal code

        Optional fields:
        - address_line2: Apartment, suite, etc.
        - country: Country (default: India)
        - vehicle_types: Array of vehicle types (bike, car, van, truck)
        - max_daily_capacity: Maximum orders per day
        - pricing_model: flat, per_km, percentage, hybrid
        - base_charge: Base delivery fee
        - per_km_charge: Fee per kilometer
        - percentage_charge: Percentage of order value
    ]]--
    app:match("register_delivery_partner_geo", "/api/v2/delivery-partners/register", respond_to({
        POST = function(self)
            -- Parse JSON body
            local params = parse_json_body()

            -- Fallback to form params if JSON body is empty
            if not params or not params.company_name then
                params = self.params
            end

            ngx.log(ngx.INFO, "=== DELIVERY PARTNER REGISTRATION (GEOLOCATION) ===")

            -- Authenticate user manually
            local user, auth_err = AuthMiddleware.authenticate(self)
            if auth_err then
                ngx.log(ngx.ERR, "Authentication failed: " .. (auth_err.error or "unknown"))
                return { json = { error = auth_err.error }, status = auth_err.status }
            end

            -- Validate required fields
            local required_fields = {
                "company_name",
                "contact_person_name",
                "contact_person_phone",
                "latitude",
                "longitude",
                "address_line1",
                "city",
                "state",
                "postal_code"
            }

            for _, field in ipairs(required_fields) do
                if not params[field] or params[field] == "" then
                    return {
                        status = 400,
                        json = {
                            error = "Missing required field: " .. field,
                            required_fields = required_fields
                        }
                    }
                end
            end

            -- Validate coordinates
            local latitude = tonumber(params.latitude)
            local longitude = tonumber(params.longitude)

            if not latitude or not longitude then
                return {
                    status = 400,
                    json = { error = "Invalid latitude or longitude. Must be valid numbers." }
                }
            end

            if latitude < -90 or latitude > 90 then
                return {
                    status = 400,
                    json = { error = "Latitude must be between -90 and 90 degrees" }
                }
            end

            if longitude < -180 or longitude > 180 then
                return {
                    status = 400,
                    json = { error = "Longitude must be between -180 and 180 degrees" }
                }
            end

            -- Validate service radius
            local service_radius_km = tonumber(params.service_radius_km) or 10
            if service_radius_km <= 0 or service_radius_km > 100 then
                return {
                    status = 400,
                    json = { error = "Service radius must be between 0 and 100 kilometers" }
                }
            end

            local success, result = pcall(function()
                -- Get user info
                local user_uuid = user.uuid
                local user_result = db.select("id, email from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    error("User not found")
                end
                local user_id = user_result[1].id
                local user_email = user_result[1].email

                -- Check if already registered as delivery partner
                local existing = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
                if existing then
                    return { status = 400, json = { error = "Already registered as delivery partner" } }
                end

                -- Prepare vehicle types as JSON array
                local vehicle_types = params.vehicle_types or {"bike"}
                if type(vehicle_types) == "string" then
                    vehicle_types = cjson.decode(vehicle_types)
                end

                -- Create delivery partner profile with geolocation
                local partner_uuid = Global.generateStaticUUID()
                local timestamp = Global.getCurrentTimestamp()

                local insert_query = [[
                    INSERT INTO delivery_partners (
                        uuid, user_id, company_name, company_registration_number,
                        contact_person_name, contact_person_phone, contact_person_email,
                        business_address, service_type, vehicle_types,
                        max_daily_capacity, service_radius_km,
                        base_charge, per_km_charge, percentage_charge, pricing_model,
                        is_verified, is_active,
                        latitude, longitude,
                        address_line1, address_line2, city, state, country, postal_code,
                        created_at, updated_at
                    ) VALUES (
                        ?, ?, ?, ?,
                        ?, ?, ?,
                        ?, ?, ?::jsonb,
                        ?, ?,
                        ?, ?, ?, ?,
                        ?, ?,
                        ?, ?,
                        ?, ?, ?, ?, ?, ?,
                        ?, ?
                    ) RETURNING *
                ]]

                local business_address = string.format("%s, %s, %s, %s %s",
                    params.address_line1,
                    params.address_line2 or "",
                    params.city,
                    params.state,
                    params.postal_code
                )

                local new_partner = db.query(insert_query,
                    partner_uuid,
                    user_id,
                    params.company_name,
                    params.company_registration_number or nil,
                    params.contact_person_name,
                    params.contact_person_phone,
                    params.contact_person_email or user_email,
                    business_address,
                    params.service_type or "standard",
                    cjson.encode(vehicle_types),
                    tonumber(params.max_daily_capacity) or 10,
                    service_radius_km,
                    tonumber(params.base_charge) or 50,
                    tonumber(params.per_km_charge) or 5,
                    tonumber(params.percentage_charge) or 0,
                    params.pricing_model or "per_km",
                    false, -- is_verified (requires admin approval)
                    true,  -- is_active
                    latitude,
                    longitude,
                    params.address_line1,
                    params.address_line2 or nil,
                    params.city,
                    params.state,
                    params.country or "India",
                    params.postal_code,
                    timestamp,
                    timestamp
                )[1]

                -- Assign delivery_partner role to user
                local delivery_partner_role = db.query("SELECT id FROM roles WHERE role_name = ?", "delivery_partner")[1]
                if delivery_partner_role then
                    -- Check if user already has the role
                    local existing_role = db.query(
                        "SELECT * FROM user__roles WHERE user_id = ? AND role_id = ?",
                        user_id,
                        delivery_partner_role.id
                    )[1]

                    if not existing_role then
                        db.query([[
                            INSERT INTO user__roles (uuid, user_id, role_id, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?)
                        ]],
                        Global.generateStaticUUID(),
                        user_id,
                        delivery_partner_role.id,
                        timestamp,
                        timestamp
                        )
                    end
                end

                ngx.log(ngx.INFO, string.format(
                    "Delivery partner created: %s at location (%.6f, %.6f) with %d km radius",
                    new_partner.company_name,
                    latitude,
                    longitude,
                    service_radius_km
                ))

                return {
                    partner = {
                        uuid = new_partner.uuid,
                        company_name = new_partner.company_name,
                        contact_person_name = new_partner.contact_person_name,
                        contact_person_phone = new_partner.contact_person_phone,
                        latitude = new_partner.latitude,
                        longitude = new_partner.longitude,
                        service_radius_km = new_partner.service_radius_km,
                        city = new_partner.city,
                        state = new_partner.state,
                        is_verified = new_partner.is_verified,
                        is_active = new_partner.is_active,
                        pricing_model = new_partner.pricing_model,
                        base_charge = new_partner.base_charge,
                        per_km_charge = new_partner.per_km_charge,
                        verification_status = "pending_verification",
                        message = "Registration successful. Your profile will be reviewed for verification."
                    }
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to create delivery partner: " .. tostring(result))
                return { status = 500, json = { error = "Failed to create delivery partner profile" } }
            end

            -- Check if result is already a response object
            if result.status then
                return result
            end

            return { json = result, status = 201 }
        end
    }))

    --[[
        Update Delivery Partner Location

        Allows delivery partners to update their current location and service radius.
        Useful for partners who work from different locations.
    ]]--
    app:match("update_delivery_partner_location", "/api/v2/delivery-partners/location", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local params = parse_json_body()
            if not params or not params.latitude then
                params = self.params
            end

            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Validate coordinates
            local latitude = tonumber(params.latitude)
            local longitude = tonumber(params.longitude)

            if not latitude or not longitude then
                return { status = 400, json = { error = "Valid latitude and longitude are required" } }
            end

            if latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180 then
                return { status = 400, json = { error = "Invalid coordinates" } }
            end

            -- Update location
            db.update("delivery_partners", {
                latitude = latitude,
                longitude = longitude,
                service_radius_km = tonumber(params.service_radius_km) or delivery_partner.service_radius_km,
                updated_at = db.format_date()
            }, "id = ?", delivery_partner.id)

            ngx.log(ngx.INFO, string.format(
                "Location updated for partner %s: (%.6f, %.6f)",
                delivery_partner.company_name,
                latitude,
                longitude
            ))

            return {
                json = {
                    message = "Location updated successfully",
                    latitude = latitude,
                    longitude = longitude,
                    service_radius_km = tonumber(params.service_radius_km) or delivery_partner.service_radius_km
                }
            }
        end)
    }))

    --[[
        Get Delivery Partner Profile with Geolocation Data
    ]]--
    app:match("get_delivery_partner_profile_geo", "/api/v2/delivery-partners/profile", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query([[
                SELECT
                    dp.*,
                    u.email as user_email,
                    u.first_name,
                    u.last_name
                FROM delivery_partners dp
                INNER JOIN users u ON dp.user_id = u.id
                WHERE dp.user_id = ?
            ]], user.id)[1]

            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Parse JSON fields
            local vehicle_types = {}
            if delivery_partner.vehicle_types then
                local ok, parsed = pcall(cjson.decode, delivery_partner.vehicle_types)
                if ok then
                    vehicle_types = parsed
                end
            end

            return {
                json = {
                    profile = {
                        uuid = delivery_partner.uuid,
                        company_name = delivery_partner.company_name,
                        company_registration_number = delivery_partner.company_registration_number,
                        contact_person_name = delivery_partner.contact_person_name,
                        contact_person_phone = delivery_partner.contact_person_phone,
                        contact_person_email = delivery_partner.contact_person_email,

                        -- Location data
                        latitude = tonumber(delivery_partner.latitude),
                        longitude = tonumber(delivery_partner.longitude),
                        service_radius_km = tonumber(delivery_partner.service_radius_km),
                        address_line1 = delivery_partner.address_line1,
                        address_line2 = delivery_partner.address_line2,
                        city = delivery_partner.city,
                        state = delivery_partner.state,
                        country = delivery_partner.country,
                        postal_code = delivery_partner.postal_code,

                        -- Business info
                        service_type = delivery_partner.service_type,
                        vehicle_types = vehicle_types,
                        max_daily_capacity = delivery_partner.max_daily_capacity,
                        current_active_orders = delivery_partner.current_active_orders,

                        -- Pricing
                        pricing_model = delivery_partner.pricing_model,
                        base_charge = tonumber(delivery_partner.base_charge),
                        per_km_charge = tonumber(delivery_partner.per_km_charge),
                        percentage_charge = tonumber(delivery_partner.percentage_charge),

                        -- Status
                        is_verified = delivery_partner.is_verified,
                        is_active = delivery_partner.is_active,
                        rating = tonumber(delivery_partner.rating),
                        total_deliveries = delivery_partner.total_deliveries,
                        successful_deliveries = delivery_partner.successful_deliveries,

                        -- Banking
                        bank_account_number = delivery_partner.bank_account_number,
                        bank_name = delivery_partner.bank_name,
                        bank_ifsc_code = delivery_partner.bank_ifsc_code
                    }
                }
            }
        end)
    }))
end
