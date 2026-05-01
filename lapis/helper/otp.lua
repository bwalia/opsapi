--[[
    OTP Helper (helper/otp.lua)

    Generates, stores, and verifies one-time passwords for admin 2FA.
    OTPs are stored in the admin_otp_codes DB table (not in-memory).

    Security:
    - 6-digit numeric codes
    - 5-minute expiry
    - Max 5 verification attempts per code
    - Old codes invalidated on new code generation
    - Expired codes cleaned up automatically
    - 2FA session tokens: short-lived JWTs that prove password was verified
      (required by /auth/2fa/verify and /auth/2fa/resend to prevent abuse)
]]

local db = require("lapis.db")
local Mail = require("helper.mail")
local Global = require("helper.global")

local OTP = {}

local CODE_LENGTH = 6
local EXPIRY_SECONDS = 300  -- 5 minutes
local MAX_ATTEMPTS = 5
local SESSION_TOKEN_EXPIRY = 300  -- 5 minutes (matches OTP expiry)

--- Validate a hex color string (e.g. "#dc2626"). Returns sanitized value or default.
local function sanitize_hex_color(color, default)
    default = default or "#dc2626"
    if type(color) ~= "string" then return default end
    if color:match("^#%x%x%x%x%x%x$") then return color end
    if color:match("^#%x%x%x$") then return color end
    return default
end

--- Validate a URL for use in img src. Only allows https:// URLs with safe characters.
local function sanitize_url(url)
    if type(url) ~= "string" then return nil end
    if url:match("^https://[%w%.%-/_%?&=%%~:@!%$%+,;]+$") then return url end
    return nil
end

-- ============================================================================
-- 2FA Session Token (signed proof that password was verified)
-- ============================================================================

--- Generate a short-lived 2FA session token.
-- This token is returned after successful password verification and must be
-- presented to /auth/2fa/verify and /auth/2fa/resend. It proves the caller
-- already passed the password check, preventing unauthenticated brute-force.
-- @param user_uuid string The user's UUID
-- @param user_id number The user's internal ID
-- @return string The signed session token
function OTP.generateSessionToken(user_uuid, user_id)
    local jwt = require("resty.jwt")
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
    if not secret then
        error("JWT_SECRET_KEY not configured")
    end

    local now = ngx.time()
    local token = jwt:sign(secret, {
        header = { typ = "JWT", alg = "HS256" },
        payload = {
            sub = user_uuid,
            uid = user_id,
            purpose = "2fa_session",
            iat = now,
            exp = now + SESSION_TOKEN_EXPIRY,
        }
    })

    return token
end

--- Verify a 2FA session token and extract the user info.
-- @param token string The session token to verify
-- @return table|nil { user_uuid, user_id } if valid
-- @return string|nil Error message if invalid
function OTP.verifySessionToken(token)
    if not token or token == "" then
        return nil, "2FA session token is required"
    end

    local jwt = require("resty.jwt")
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
    if not secret then
        return nil, "Server configuration error"
    end

    local result = jwt:verify(secret, token)
    if not result or not result.verified then
        return nil, "Invalid or expired 2FA session. Please login again."
    end

    local payload = result.payload
    if not payload or payload.purpose ~= "2fa_session" then
        return nil, "Invalid 2FA session token"
    end

    if not payload.sub or not payload.uid then
        return nil, "Malformed 2FA session token"
    end

    return {
        user_uuid = payload.sub,
        user_id = payload.uid,
    }
end

-- ============================================================================
-- OTP Code Generation & Verification
-- ============================================================================

--- Generate a cryptographically random 6-digit OTP
-- @return string 6-digit code
local function generate_code()
    local resty_random = require("resty.random")
    local bytes = resty_random.bytes(4)
    if not bytes then
        math.randomseed(ngx.now() * 1000 + ngx.worker.pid())
        return string.format("%0" .. CODE_LENGTH .. "d", math.random(0, 10 ^ CODE_LENGTH - 1))
    end

    local num = 0
    for i = 1, #bytes do
        num = num * 256 + string.byte(bytes, i)
    end
    return string.format("%0" .. CODE_LENGTH .. "d", num % (10 ^ CODE_LENGTH))
end

--- Invalidate all pending OTP codes for a user
-- @param user_id number
local function invalidate_existing(user_id)
    db.query([[
        DELETE FROM admin_otp_codes WHERE user_id = ?
    ]], user_id)
end

--- Clean up expired OTP codes (housekeeping)
local function cleanup_expired()
    db.query([[
        DELETE FROM admin_otp_codes WHERE expires_at < NOW()
    ]])
end

--- Create and store a new OTP for a user. Invalidates any existing codes.
-- @param user_id number The user's internal ID
-- @return string The generated OTP code
-- @return string|nil Error message
function OTP.create(user_id)
    if not user_id then
        return nil, "user_id is required"
    end

    -- Invalidate previous codes
    invalidate_existing(user_id)

    -- Clean up old expired codes (opportunistic)
    pcall(cleanup_expired)

    local code = generate_code()
    local expires_at = db.raw("NOW() + INTERVAL '" .. EXPIRY_SECONDS .. " seconds'")

    db.insert("admin_otp_codes", {
        user_id = user_id,
        code = code,
        expires_at = expires_at,
        verified = false,
        attempts = 0,
        created_at = db.raw("NOW()"),
    })

    return code
end

--- Verify an OTP code for a user.
-- @param user_id number
-- @param code string The code to verify
-- @return boolean success
-- @return string|nil Error message
function OTP.verify(user_id, code)
    if not user_id or not code then
        return false, "user_id and code are required"
    end

    -- Normalize: strip whitespace
    code = code:gsub("%s+", "")

    -- Dev-only bypass: accept TEST_OTP_CODE to skip email OTP during development.
    -- Guards: (1) only works when LAPIS_ENVIRONMENT is NOT "production",
    --         (2) code must be at least 6 characters to prevent trivial values,
    --         (3) still invalidates DB codes so the bypass is auditable.
    local env = os.getenv("LAPIS_ENVIRONMENT") or "development"
    if env ~= "production" then
        local test_code = os.getenv("TEST_OTP_CODE")
        if test_code and #test_code >= 6 and code == test_code then
            ngx.log(ngx.WARN, "[OTP] Dev bypass used for user_id=", user_id,
                " env=", env, " ip=", ngx.var.remote_addr or "unknown")
            invalidate_existing(user_id)
            return true
        end
    end

    -- Find the latest non-expired, non-verified code for this user
    local rows = db.query([[
        SELECT id, code, attempts FROM admin_otp_codes
        WHERE user_id = ? AND verified = false AND expires_at > NOW()
        ORDER BY created_at DESC LIMIT 1
    ]], user_id)

    if not rows or #rows == 0 then
        return false, "No valid OTP found. Please request a new code."
    end

    local otp_row = rows[1]

    -- Check max attempts
    if otp_row.attempts >= MAX_ATTEMPTS then
        db.query("DELETE FROM admin_otp_codes WHERE id = ?", otp_row.id)
        return false, "Too many failed attempts. Please request a new code."
    end

    -- Increment attempt counter
    db.query([[
        UPDATE admin_otp_codes SET attempts = attempts + 1 WHERE id = ?
    ]], otp_row.id)

    -- Compare codes
    if otp_row.code ~= code then
        local remaining = MAX_ATTEMPTS - otp_row.attempts - 1
        if remaining <= 0 then
            db.query("DELETE FROM admin_otp_codes WHERE id = ?", otp_row.id)
            return false, "Invalid code. No attempts remaining. Please request a new code."
        end
        return false, "Invalid code. " .. remaining .. " attempt(s) remaining."
    end

    -- Verified — delete the code
    db.query("DELETE FROM admin_otp_codes WHERE id = ?", otp_row.id)

    return true
end

--- Send an OTP to a user's email using the mail service.
-- @param user table User object with .id, .email, .first_name
-- @param brand table|nil Optional branding { app_name, brand_color, header_title, brand_logo_url, support_email }
-- @return boolean success
-- @return string|nil Error message
function OTP.sendToEmail(user, brand)
    if not user or not user.id or not user.email then
        return false, "Valid user with id and email is required"
    end

    -- When TEST_OTP_CODE is set, the bypass code is accepted by OTP.verify()
    -- but we still create a real OTP and send the email so users receive the code.
    -- This allows developers to bypass with the test code while real users get emails.
    local env = os.getenv("LAPIS_ENVIRONMENT") or "development"
    local test_code = os.getenv("TEST_OTP_CODE")
    if env ~= "production" and test_code and #test_code >= 6 then
        ngx.log(ngx.NOTICE, "[OTP] Test bypass enabled — real OTP will also be created and emailed for ", user.email)
    end

    local code, err = OTP.create(user.id)
    if not code then
        return false, err
    end

    brand = brand or {}
    local app_name = type(brand.app_name) == "string" and brand.app_name ~= "" and brand.app_name or "DIY Tax Return"
    local safe_color = sanitize_hex_color(brand.brand_color)
    local safe_logo = sanitize_url(brand.brand_logo_url)

    local ok, mail_err = Mail.send({
        to = user.email,
        subject = "Your " .. app_name .. " Verification Code",
        template = "otp",
        data = {
            otp_code = code,
            user_name = user.first_name or "Admin",
            expires_in = "5 minutes",
            app_name = app_name,
            brand_color = safe_color,
            header_title = type(brand.header_title) == "string" and brand.header_title ~= "" and brand.header_title or app_name,
            brand_logo_url = safe_logo,
            support_email = brand.support_email,
        },
    })

    if not ok then
        ngx.log(ngx.ERR, "[OTP] Failed to send email to ", user.email, ": ", tostring(mail_err))
        return false, "Failed to send verification code. Please try again."
    end

    ngx.log(ngx.NOTICE, "[OTP] Code sent to ", user.email)
    return true
end

return OTP
