local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")
local DeliveryPartnerQueries = require("queries.DeliveryPartnerQueries")
local DeliveryPartnerAreaQueries = require("queries.DeliveryPartnerAreaQueries")
local UserRolesQueries = require("queries.UserRoleQueries")

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

    -- Register as delivery partner
    app:match("register_delivery_partner", "/api/v2/delivery-partners/register", respond_to({
        POST = function(self)
            -- Parse JSON body
            local params = parse_json_body()

            -- Fallback to form params if JSON body is empty
            if not params or not params.company_name then
                params = self.params
            end

            -- Debug: Log all headers and params
            ngx.log(ngx.INFO, "=== DELIVERY PARTNER REGISTRATION DEBUG ===")
            ngx.log(ngx.INFO, "Headers: " .. cjson.encode(self.req.headers or {}))
            ngx.log(ngx.INFO, "Parsed params: " .. cjson.encode(params or {}))

            -- Check for authorization header (case-insensitive)
            local auth_header = self.req.headers["authorization"] or self.req.headers["Authorization"]
            if not auth_header then
                ngx.log(ngx.ERR, "No Authorization header found in request")
                return { json = { error = "Authorization header required. Please ensure you are logged in." }, status = 401 }
            end

            ngx.log(ngx.INFO, "Authorization header found: " .. string.sub(auth_header, 1, 20) .. "...")

            -- Validate required fields
            if not params.company_name or not params.contact_person_name or not params.contact_person_phone then
                return { json = { error = "Missing required fields" }, status = 400 }
            end

            -- Authenticate user manually
            local user, auth_err = AuthMiddleware.authenticate(self)
            if auth_err then
                ngx.log(ngx.ERR, "Authentication failed: " .. (auth_err.error or "unknown"))
                return { json = { error = auth_err.error }, status = auth_err.status }
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
                local existing = DeliveryPartnerQueries.findByUserId(user_id)
                if existing then
                    return { json = { error = "Already registered as delivery partner" }, status = 400 }
                end

                -- Build business address from structured fields
                local business_address = params.business_address
                if not business_address or business_address == "" then
                    -- Build from structured address fields
                    local address_parts = {}
                    if params.address_line1 and params.address_line1 ~= "" then
                        table.insert(address_parts, params.address_line1)
                    end
                    if params.address_line2 and params.address_line2 ~= "" then
                        table.insert(address_parts, params.address_line2)
                    end
                    if params.city and params.city ~= "" then
                        table.insert(address_parts, params.city)
                    end
                    if params.state and params.state ~= "" then
                        table.insert(address_parts, params.state)
                    end
                    if params.postal_code and params.postal_code ~= "" then
                        table.insert(address_parts, params.postal_code)
                    end
                    if params.country and params.country ~= "" then
                        table.insert(address_parts, params.country)
                    end
                    business_address = table.concat(address_parts, ", ")
                end

                -- Geocode the business address to get coordinates
                local Geocoding = require("lib.Geocoding")
                local geocoder = Geocoding.new()
                geocoder:ensureCacheTable()

                local latitude = nil
                local longitude = nil

                -- Try geocoding with structured address
                if params.address_line1 or params.city then
                    local address_obj = {
                        address1 = params.address_line1 or "",
                        address2 = params.address_line2 or "",
                        city = params.city or "",
                        state = params.state or "",
                        zip = params.postal_code or "",
                        country = params.country or "India"
                    }

                    local geocode_result, geocode_err = geocoder:geocode(address_obj)
                    if geocode_result and geocode_result.lat and geocode_result.lng then
                        latitude = geocode_result.lat
                        longitude = geocode_result.lng
                        ngx.log(ngx.INFO, string.format("Geocoded delivery partner address to: %f, %f (source: %s)",
                            latitude, longitude, geocode_result.source or "unknown"))
                    else
                        ngx.log(ngx.WARN, "Geocoding failed for delivery partner address: " .. (geocode_err or "unknown error"))
                    end
                end

                -- Create delivery partner profile
                local delivery_partner = DeliveryPartnerQueries.create({
                    user_id = user_id,
                    company_name = params.company_name,
                    company_registration_number = params.company_registration_number,
                    contact_person_name = params.contact_person_name,
                    contact_person_phone = params.contact_person_phone,
                    contact_person_email = params.contact_person_email or user_email,
                    business_address = business_address,
                    address_line1 = params.address_line1,
                    address_line2 = params.address_line2,
                    city = params.city,
                    state = params.state,
                    postal_code = params.postal_code,
                    country = params.country or "India",
                    latitude = latitude,
                    longitude = longitude,
                    service_type = params.service_type,
                    vehicle_types = cjson.encode(params.vehicle_types or {}),
                    max_daily_capacity = params.max_daily_capacity,
                    service_radius_km = params.service_radius_km,
                    base_charge = params.base_charge,
                    per_km_charge = params.per_km_charge,
                    percentage_charge = params.percentage_charge,
                    pricing_model = params.pricing_model,
                    bank_account_number = params.bank_account_number,
                    bank_name = params.bank_name,
                    bank_ifsc_code = params.bank_ifsc_code
                })

                -- Add service areas
                if params.service_areas and type(params.service_areas) == "table" then
                    for _, area in ipairs(params.service_areas) do
                        DeliveryPartnerAreaQueries.create({
                            delivery_partner_id = delivery_partner.id,
                            country = area.country,
                            state = area.state,
                            city = area.city,
                            postal_codes = cjson.encode(area.postal_codes or {})
                        })
                    end
                end

                -- Add delivery_partner role to user (using proper role system)
                -- Check if user already has delivery_partner role
                local existing_role = db.query([[
                    SELECT ur.id FROM user__roles ur
                    INNER JOIN roles r ON ur.role_id = r.id
                    WHERE ur.user_id = ? AND r.role_name = 'delivery_partner'
                ]], user_id)[1]

                if not existing_role then
                    -- Add delivery_partner role
                    UserRolesQueries.addRole(user_id, "delivery_partner")
                    ngx.log(ngx.INFO, "Added delivery_partner role to user " .. user_id)
                end

                return { json = {
                    message = "Successfully registered as delivery partner",
                    delivery_partner = delivery_partner
                }, status = 201 }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error registering delivery partner: " .. tostring(result))
                return { json = { error = "Registration failed", details = tostring(result) }, status = 500 }
            end

            return result
        end
    }))

    -- Get delivery partner profile
    app:match("get_delivery_partner_profile", "/api/v2/delivery-partners/profile", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local user_uuid = self.current_user.uuid
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    error("User not found")
                end
                local user_id = user_result[1].id

                local delivery_partner = DeliveryPartnerQueries.findByUserId(user_id)
                if not delivery_partner then
                    return { json = { error = "Not registered as delivery partner" }, status = 404 }
                end

                -- Get service areas
                local areas = DeliveryPartnerAreaQueries.findByPartnerId(delivery_partner.id)

                -- Get statistics
                local stats = DeliveryPartnerQueries.getStatistics(delivery_partner.id)

                -- Parse JSON fields safely
                if delivery_partner.vehicle_types and delivery_partner.vehicle_types ~= "" and delivery_partner.vehicle_types ~= ngx.null then
                    local success, result = pcall(cjson.decode, delivery_partner.vehicle_types)
                    if success then
                        delivery_partner.vehicle_types = result
                    else
                        delivery_partner.vehicle_types = {}
                    end
                else
                    delivery_partner.vehicle_types = {}
                end

                if delivery_partner.verification_documents and delivery_partner.verification_documents ~= "" and delivery_partner.verification_documents ~= ngx.null then
                    local success, result = pcall(cjson.decode, delivery_partner.verification_documents)
                    if success then
                        delivery_partner.verification_documents = result
                    else
                        delivery_partner.verification_documents = {}
                    end
                else
                    delivery_partner.verification_documents = {}
                end

                -- Parse areas postal codes
                for _, area in ipairs(areas) do
                    if area.postal_codes then
                        area.postal_codes = cjson.decode(area.postal_codes)
                    end
                end

                -- Add verification status information
                local verification_status = {
                    is_verified = delivery_partner.is_verified or false,
                    verification_required = not delivery_partner.is_verified,
                    verification_url = "/api/v2/delivery-partners/verification/status",
                    can_accept_orders = delivery_partner.is_verified and delivery_partner.is_active,
                    message = not delivery_partner.is_verified
                        and "Your account needs to be verified to accept orders. Please upload required documents."
                        or nil
                }

                return { json = {
                    delivery_partner = delivery_partner,
                    service_areas = areas,
                    statistics = stats,
                    verification_status = verification_status
                }, status = 200 }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error fetching delivery partner profile: " .. tostring(result))
                return { json = { error = "Failed to fetch profile" }, status = 500 }
            end

            return result
        end)
    }))

    -- Update delivery partner profile
    app:match("update_delivery_partner_profile", "/api/v2/delivery-partners/profile", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            local success, result = pcall(function()
                local user_uuid = self.current_user.uuid
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    error("User not found")
                end
                local user_id = user_result[1].id

                local delivery_partner = DeliveryPartnerQueries.findByUserId(user_id)
                if not delivery_partner then
                    return { json = { error = "Not registered as delivery partner" }, status = 404 }
                end

                -- Prepare update data
                local update_data = {
                    updated_at = db.format_date()
                }

                local allowed_fields = {
                    "company_name", "company_registration_number", "contact_person_name",
                    "contact_person_phone", "contact_person_email", "business_address",
                    "service_type", "max_daily_capacity", "service_radius_km",
                    "base_charge", "per_km_charge", "percentage_charge", "pricing_model",
                    "bank_account_number", "bank_name", "bank_ifsc_code"
                }

                for _, field in ipairs(allowed_fields) do
                    if params[field] ~= nil then
                        update_data[field] = params[field]
                    end
                end

                if params.vehicle_types then
                    update_data.vehicle_types = cjson.encode(params.vehicle_types)
                end

                DeliveryPartnerQueries.update(delivery_partner.id, update_data)

                return { json = { message = "Profile updated successfully" }, status = 200 }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error updating delivery partner profile: " .. tostring(result))
                return { json = { error = "Update failed" }, status = 500 }
            end

            return result
        end)
    }))

    -- Add service area
    app:match("add_service_area", "/api/v2/delivery-partners/areas", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            if not params.city or not params.state then
                return { json = { error = "City and state are required" }, status = 400 }
            end

            local success, result = pcall(function()
                local user_uuid = self.current_user.uuid
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                local user_id = user_result[1].id

                local delivery_partner = DeliveryPartnerQueries.findByUserId(user_id)
                if not delivery_partner then
                    return { json = { error = "Not registered as delivery partner" }, status = 404 }
                end

                local area = DeliveryPartnerAreaQueries.create({
                    delivery_partner_id = delivery_partner.id,
                    country = params.country or 'India',
                    state = params.state,
                    city = params.city,
                    postal_codes = cjson.encode(params.postal_codes or {})
                })

                return { json = { message = "Service area added", area = area }, status = 201 }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error adding service area: " .. tostring(result))
                return { json = { error = "Failed to add service area" }, status = 500 }
            end

            return result
        end)
    }))

    -- Search delivery partners (public for sellers)
    app:match("search_delivery_partners", "/api/v2/delivery-partners/search", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            local success, result = pcall(function()
                local search_params = {
                    city = params.city,
                    state = params.state,
                    service_type = params.service_type,
                    min_rating = params.min_rating and tonumber(params.min_rating) or nil,
                    is_verified = params.is_verified == 'true',
                    limit = params.limit and tonumber(params.limit) or 20,
                    offset = params.offset and tonumber(params.offset) or 0
                }

                local partners = DeliveryPartnerQueries.search(search_params)

                -- Parse JSON fields
                for _, partner in ipairs(partners) do
                    if partner.vehicle_types then
                        partner.vehicle_types = cjson.decode(partner.vehicle_types)
                    end
                end

                return { json = { delivery_partners = partners }, status = 200 }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error searching delivery partners: " .. tostring(result))
                return { json = { error = "Search failed" }, status = 500 }
            end

            return result
        end)
    }))

    -- Get delivery partners by area (for sellers selecting partners)
    app:match("get_delivery_partners_by_area", "/api/v2/delivery-partners/by-area", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            if not params.city or not params.state then
                return { json = { error = "City and state are required" }, status = 400 }
            end

            local success, result = pcall(function()
                local partners = DeliveryPartnerQueries.findAvailable(
                    params.city,
                    params.state,
                    params.country or 'India'
                )

                for _, partner in ipairs(partners) do
                    if partner.vehicle_types then
                        partner.vehicle_types = cjson.decode(partner.vehicle_types)
                    end
                end

                return { json = { delivery_partners = partners }, status = 200 }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error fetching delivery partners by area: " .. tostring(result))
                return { json = { error = "Failed to fetch partners" }, status = 500 }
            end

            return result
        end)
    }))
end
