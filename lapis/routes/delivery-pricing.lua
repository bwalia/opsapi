-- Delivery Pricing API Routes
-- Provides delivery fee estimates and pricing configuration

local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local DeliveryPricing = require("helper.delivery-pricing")

return function(app)
    -- Get delivery fee estimate (Public/Authenticated)
    app:match("/api/v2/delivery/fee-estimate", respond_to({
        GET = function(self)
            local distance_km = tonumber(self.params.distance_km)
            local order_value = tonumber(self.params.order_value)

            if not distance_km or distance_km <= 0 then
                return {
                    status = 400,
                    json = { error = "Valid distance_km is required" }
                }
            end

            if not order_value or order_value < 0 then
                return {
                    status = 400,
                    json = { error = "Valid order_value is required" }
                }
            end

            local estimate = DeliveryPricing.getEstimate(distance_km, order_value)

            return {
                json = {
                    success = true,
                    estimate = estimate,
                    note = "Estimated fee based on distance and order value. Actual fee may vary based on time of day and other factors."
                }
            }
        end,

        POST = function(self)
            -- Parse JSON body
            local body_success, body = pcall(function()
                return require("cjson").decode(self.req.read_body())
            end)

            if not body_success or not body then
                body = self.params
            end

            local distance_km = tonumber(body.distance_km)
            local order_value = tonumber(body.order_value)
            local delivery_partner_id = tonumber(body.delivery_partner_id)
            local store_id = tonumber(body.store_id)

            if not distance_km or distance_km <= 0 then
                return {
                    status = 400,
                    json = { error = "Valid distance_km is required" }
                }
            end

            if not order_value or order_value < 0 then
                return {
                    status = 400,
                    json = { error = "Valid order_value is required" }
                }
            end

            -- Calculate detailed breakdown
            local breakdown = DeliveryPricing.calculateDeliveryFee({
                distance_km = distance_km,
                order_value = order_value,
                delivery_partner_id = delivery_partner_id,
                store_id = store_id
            })

            return {
                json = {
                    success = true,
                    breakdown = breakdown,
                    formatted_fee = DeliveryPricing.formatFee(breakdown.total_fee)
                }
            }
        end
    }))

    -- Validate partner-proposed fee
    app:match("/api/v2/delivery/validate-fee", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local body_success, body = pcall(function()
                return require("cjson").decode(self.req.read_body())
            end)

            if not body_success or not body then
                body = self.params
            end

            local proposed_fee = tonumber(body.proposed_fee)
            local calculated_fee = tonumber(body.calculated_fee)

            if not proposed_fee then
                return {
                    status = 400,
                    json = { error = "proposed_fee is required" }
                }
            end

            if not calculated_fee then
                return {
                    status = 400,
                    json = { error = "calculated_fee is required" }
                }
            end

            local is_valid, message = DeliveryPricing.validatePartnerFee(proposed_fee, calculated_fee)

            return {
                json = {
                    success = is_valid,
                    valid = is_valid,
                    message = message,
                    proposed_fee = proposed_fee,
                    calculated_fee = calculated_fee,
                    deviation_percent = math.abs(((proposed_fee - calculated_fee) / calculated_fee) * 100)
                }
            }
        end)
    }))

    -- Get pricing configuration (Public)
    app:match("/api/v2/delivery/pricing-config", respond_to({
        GET = function(self)
            local config = DeliveryPricing.getConfig()

            -- Return public-safe config (exclude sensitive details)
            return {
                json = {
                    success = true,
                    config = {
                        base_fee = config.base_fee,
                        per_km_rate = config.per_km_rate,
                        free_delivery_radius_km = config.free_delivery_radius_km,
                        min_delivery_fee = config.min_delivery_fee,
                        max_delivery_fee = config.max_delivery_fee,
                        currency = config.currency,
                        distance_brackets = config.distance_brackets,
                        night_surcharge_percent = config.night_surcharge_percent,
                        peak_hour_surcharge = config.peak_hour_surcharge
                    }
                }
            }
        end
    }))

    -- Update pricing configuration (Admin only - requires special permission)
    app:match("/api/v2/delivery/pricing-config/update", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            -- TODO: Add admin role check here
            -- For now, any authenticated user can update (should be restricted to admin)

            local body_success, body = pcall(function()
                return require("cjson").decode(self.req.read_body())
            end)

            if not body_success or not body then
                return {
                    status = 400,
                    json = { error = "Invalid JSON body" }
                }
            end

            local updated_config = DeliveryPricing.updateConfig(body)

            ngx.log(ngx.INFO, "[DELIVERY PRICING] Configuration updated by user: " .. (self.current_user.uuid or "unknown"))

            return {
                json = {
                    success = true,
                    message = "Pricing configuration updated successfully",
                    config = updated_config
                }
            }
        end)
    }))
end
