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

    -- Non-prod bypass: accept TEST_OTP_CODE to skip email OTP outside production.
    -- Guards: (1) only fires when the deploy env is NOT prod/production. The
    --         label is taken from OPSAPI_DEPLOY_ENV (set by Helm to the env
    --         suffix: dev / test / int / acc / prod), falling back to
    --         LAPIS_ENVIRONMENT, then defaulting to "production" (fail-closed
    --         — matches routes/e2e-otp.lua's deploy_env() so an unconfigured
    --         pod can never accidentally enable the bypass).
    --         (2) code must be at least 6 characters to prevent trivial values.
    --         (3) still invalidates DB codes so the bypass is auditable.
    -- LAPIS_ENVIRONMENT alone can't gate this on K8s: it's hardcoded "production"
    -- there so the ESO-templated config.lua's single config("production") block
    -- is selected — without OPSAPI_DEPLOY_ENV, every cluster env (int/acc)
    -- would look like prod and the bypass would never fire.
    local deploy = os.getenv("OPSAPI_DEPLOY_ENV") or os.getenv("LAPIS_ENVIRONMENT") or "production"
    if deploy ~= "production" and deploy ~= "prod" then
        local test_code = os.getenv("TEST_OTP_CODE")
        if test_code and #test_code >= 6 and code == test_code then
            ngx.log(ngx.WARN, "[OTP] Test bypass used for user_id=", user_id,
                " deploy_env=", deploy, " ip=", ngx.var.remote_addr or "unknown")
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
    -- Mirrors the deploy-env guard in OTP.verify() above — OPSAPI_DEPLOY_ENV-first
    -- so cluster envs (int/acc with LAPIS_ENVIRONMENT="production") still log
    -- the bypass notice correctly. Fail-closed default "production".
    local deploy = os.getenv("OPSAPI_DEPLOY_ENV") or os.getenv("LAPIS_ENVIRONMENT") or "production"
    local test_code = os.getenv("TEST_OTP_CODE")
    if deploy ~= "production" and deploy ~= "prod" and test_code and #test_code >= 6 then
        ngx.log(ngx.NOTICE, "[OTP] Test bypass enabled — real OTP will also be created and emailed for ", user.email)
    end

    local code, err = OTP.create(user.id)
    if not code then
        return false, err
    end

    -- E2E test traffic suppression. CI runs the Playwright suite many times
    -- a day and each register/login dumps a real OTP into the shared test
    -- mailbox (diytaxreturnmail@gmail.com via Gmail plus-addressing). We
    -- still CREATE the OTP row above so OTP.verify works normally — only
    -- the SMTP send is skipped. Double-gated:
    --   1) LAPIS_ENVIRONMENT must not be "production"  (acc + prod = always send)
    --   2) Recipient must match OTP_SUPPRESS_FOR_EMAIL_REGEX
    -- If the env var is unset, behaviour is identical to before this change.
    local suppress_regex = os.getenv("OTP_SUPPRESS_FOR_EMAIL_REGEX")
    if env ~= "production" and suppress_regex and suppress_regex ~= "" then
        local matched, regex_err = ngx.re.match(user.email, suppress_regex, "jo")
        if regex_err then
            ngx.log(ngx.WARN, "[OTP] Bad OTP_SUPPRESS_FOR_EMAIL_REGEX (", suppress_regex,
                "): ", regex_err, " — falling back to sending the email")
        elseif matched then
            ngx.log(ngx.NOTICE, "[OTP] Suppressed email for E2E test recipient ", user.email,
                " (env=", env, ", code still in DB for OTP.verify)")
            return true
        end
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
        -- Non-prod debug context. Stripped by Mail.send before the
        -- SMTP payload is built; only used to populate the banner.
        triggered_by = {
            user_uuid = user.uuid,
            user_email = user.email,
            source = "otp.sendToEmail",
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
