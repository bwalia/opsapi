local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")

-- In-memory OTP storage (in production, use Redis or database with expiry)
local otp_storage = {}

-- Generate a random 6-digit OTP
local function generateOtp()
    return tostring(math.random(100000, 999999))
end

-- Store OTP with expiry (5 minutes)
local function storeOtp(phone_number, otp)
    otp_storage[phone_number] = {
        otp = otp,
        created_at = os.time(),
        expires_at = os.time() + 300 -- 5 minutes
    }
end

-- Verify OTP
local function verifyOtp(phone_number, otp)
    local stored = otp_storage[phone_number]

    if not stored then
        return false, "OTP not found. Please request a new OTP."
    end

    if os.time() > stored.expires_at then
        otp_storage[phone_number] = nil
        return false, "OTP expired. Please request a new OTP."
    end

    if stored.otp ~= otp then
        return false, "Invalid OTP. Please try again."
    end

    -- OTP is valid, remove it
    otp_storage[phone_number] = nil
    return true, "OTP verified successfully"
end

-- Clean up expired OTPs (call this periodically)
local function cleanupExpiredOtps()
    local current_time = os.time()
    for phone, data in pairs(otp_storage) do
        if current_time > data.expires_at then
            otp_storage[phone] = nil
        end
    end
end

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

    app:match("send_verification_otp", "/api/v2/delivery-partners/verification/send-otp", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                -- Parse JSON body first, fallback to form params
                local params = parse_json_body()

                -- Debug logging
                ngx.log(ngx.INFO, "Parsed JSON params: ", cjson.encode(params))
                ngx.log(ngx.INFO, "Form params: ", cjson.encode(self.params))

                if not params or not params.phone_number then
                    params = self.params
                end

                local phone_number = params.phone_number

                if not phone_number or phone_number == "" then
                    ngx.log(ngx.ERR, "Phone number missing. Params: ", cjson.encode(params))
                    return { status = 400, json = { error = "Phone number is required" } }
                end

                -- Validate user is a delivery partner
                local user_id = db.query([[
                    SELECT id FROM users WHERE uuid = ?
                ]], self.current_user.uuid)[1].id

                local delivery_partner = db.query([[
                    SELECT id, contact_person_phone, is_verified
                    FROM delivery_partners
                    WHERE user_id = ?
                ]], user_id)[1]

                if not delivery_partner then
                    return { status = 404, json = { error = "Delivery partner profile not found" } }
                end

                -- Check if already verified
                if delivery_partner.is_verified then
                    return { status = 400, json = { error = "Account is already verified" } }
                end

                -- Generate OTP
                local otp = generateOtp()

                -- Store OTP
                storeOtp(phone_number, otp)

                -- Clean up expired OTPs
                cleanupExpiredOtps()

                -- In production, send SMS here using Twilio, AWS SNS, or other SMS service
                -- For now, return OTP in response for testing
                ngx.log(ngx.INFO, "OTP for " .. phone_number .. ": " .. otp)

                return {
                    json = {
                        message = "OTP sent successfully",
                        phone_number = phone_number,
                        -- REMOVE THIS IN PRODUCTION - only for testing
                        otp = otp,
                        expires_in = 300 -- seconds
                    },
                    status = 200
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error sending OTP: " .. tostring(result))
                return { json = { error = "Failed to send OTP" }, status = 500 }
            end

            return result
        end)
    }))

    app:match("verify_delivery_partner_otp", "/api/v2/delivery-partners/verification/verify-otp", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                -- Parse JSON body first, fallback to form params
                local params = parse_json_body()
                if not params or not params.phone_number then
                    params = self.params
                end

                local phone_number = params.phone_number
                local otp = params.otp

                if not phone_number or phone_number == "" then
                    return { status = 400, json = { error = "Phone number is required" } }
                end

                if not otp or otp == "" then
                    return { status = 400, json = { error = "OTP is required" } }
                end

                -- Verify OTP
                local is_valid, message = verifyOtp(phone_number, otp)

                if not is_valid then
                    return { status = 400, json = { error = message } }
                end

                -- Get user and delivery partner
                local user_id = db.query([[
                    SELECT id FROM users WHERE uuid = ?
                ]], self.current_user.uuid)[1].id

                local delivery_partner = db.query([[
                    SELECT id, contact_person_phone, is_verified
                    FROM delivery_partners
                    WHERE user_id = ?
                ]], user_id)[1]

                if not delivery_partner then
                    return { status = 404, json = { error = "Delivery partner profile not found" } }
                end

                -- Check if already verified
                if delivery_partner.is_verified then
                    return { status = 200, json = {
                        verified = true,
                        message = "Account is already verified"
                    } }
                end

                -- Update delivery partner as verified
                db.update("delivery_partners", {
                    is_verified = true,
                    updated_at = db.format_date()
                }, {
                    id = delivery_partner.id
                })

                return {
                    json = {
                        verified = true,
                        message = "Phone number verified successfully! Your account is now active."
                    },
                    status = 200
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error verifying OTP: " .. tostring(result))
                return { json = { error = "Failed to verify OTP" }, status = 500 }
            end

            return result
        end)
    }))

    -- Get verification status
    app:match("get_verification_status", "/api/v2/delivery-partners/verification/status", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                -- Get user and delivery partner
                local user_id = db.query([[
                    SELECT id FROM users WHERE uuid = ?
                ]], self.current_user.uuid)[1].id

                local delivery_partner = db.query([[
                    SELECT id, contact_person_phone, is_verified
                    FROM delivery_partners
                    WHERE user_id = ?
                ]], user_id)[1]

                if not delivery_partner then
                    return { status = 404, json = { error = "Delivery partner profile not found" } }
                end

                local verification_status = "not_verified"
                if delivery_partner.is_verified then
                    verification_status = "verified"
                end

                return {
                    json = {
                        verification_status = verification_status,
                        is_verified = delivery_partner.is_verified or false,
                        phone_number = delivery_partner.contact_person_phone,
                        message = delivery_partner.is_verified
                            and "Your account is verified"
                            or "Phone verification required to accept orders"
                    },
                    status = 200
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error getting verification status: " .. tostring(result))
                return { json = { error = "Failed to get verification status" }, status = 500 }
            end

            return result
        end)
    }))
end
