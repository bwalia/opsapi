local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

-- Phone verification codes: one per user in delivery_partner_otps (shared by
-- every pod), stored as an HMAC bound to the user and the phone, 5 tries.
local OTP_TTL = 300
local MAX_ATTEMPTS = 5
local RESEND_SECONDS = 60

local function digits(s)
    return (tostring(s or ""):gsub("%D", ""))
end

-- No SMS provider is wired in, so production cannot deliver a code. Outside
-- production the code comes back in the response so the flow can be tested.
local function is_production()
    local env = os.getenv("OPSAPI_DEPLOY_ENV") or os.getenv("LAPIS_ENVIRONMENT") or "production"
    return env == "production" or env == "prod"
end

local function code_hash(user_id, phone, code)
    local secret = Global.getEnvVar("JWT_SECRET_KEY") or error("JWT_SECRET_KEY not configured")
    local h = assert(require("resty.openssl.hmac").new(secret, "sha256"))
    return ngx.encode_base64(h:final(user_id .. ":" .. phone .. ":" .. code))
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

                if not params or not params.phone_number then
                    params = self.params
                end

                local phone_number = params.phone_number

                if not phone_number or phone_number == "" then
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

                -- The code goes to the phone on the partner's profile, never to
                -- a number the caller picks.
                local phone = digits(delivery_partner.contact_person_phone)
                if phone == "" then
                    return { status = 400,
                        json = { error = "Add a phone number to your delivery partner profile first" } }
                end
                if digits(phone_number) ~= phone then
                    return { status = 400,
                        json = { error = "That is not the phone number on your delivery partner profile" } }
                end
                if is_production() then
                    return { status = 503, json = {
                        error = "Phone verification is not available yet: no SMS provider is configured" } }
                end
                if db.query([[SELECT 1 FROM delivery_partner_otps
                        WHERE user_id = ? AND created_at > NOW() - make_interval(secs => ?)]],
                        user_id, RESEND_SECONDS)[1] then
                    return { status = 429, json = { error = "Please wait a minute before requesting another code" } }
                end

                local otp = require("helper.uuid").random_string(6, "0123456789")
                db.query([[INSERT INTO delivery_partner_otps
                        (user_id, phone, code_hash, attempts, expires_at, created_at)
                    VALUES (?, ?, ?, 0, NOW() + make_interval(secs => ?), NOW())
                    ON CONFLICT (user_id) DO UPDATE SET phone = EXCLUDED.phone, code_hash = EXCLUDED.code_hash,
                        attempts = 0, expires_at = EXCLUDED.expires_at, created_at = EXCLUDED.created_at]],
                    user_id, phone, code_hash(user_id, phone, otp), OTP_TTL)

                return {
                    json = {
                        message = "OTP sent successfully",
                        phone_number = delivery_partner.contact_person_phone,
                        otp = otp, -- outside production only (see is_production): there is no SMS sender
                        expires_in = OTP_TTL
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

                local user_id = db.query([[
                    SELECT id FROM users WHERE uuid = ?
                ]], self.current_user.uuid)[1].id

                local row = db.query([[SELECT phone, code_hash, attempts FROM delivery_partner_otps
                    WHERE user_id = ? AND expires_at > NOW()]], user_id)[1]
                if not row or row.attempts >= MAX_ATTEMPTS then
                    db.query("DELETE FROM delivery_partner_otps WHERE user_id = ?", user_id)
                    return { status = 400, json = { error = "No valid OTP. Please request a new one." } }
                end
                db.query("UPDATE delivery_partner_otps SET attempts = attempts + 1 WHERE user_id = ?", user_id)
                local given = code_hash(user_id, row.phone, tostring(otp))
                if not require("lib.stripe")._secure_compare(given, row.code_hash) then
                    return { status = 400, json = { error = "Invalid OTP. Please try again." } }
                end
                db.query("DELETE FROM delivery_partner_otps WHERE user_id = ?", user_id)

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
