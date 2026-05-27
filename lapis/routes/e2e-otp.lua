--[[
    E2E OTP Peek (TEST-ONLY) — routes/e2e-otp.lua
    =============================================

    Exposes POST /auth/e2e/peek-otp so the Playwright E2E suite can complete the
    REAL 2FA step in cluster envs (acc), where the fixed-code bypass is disabled
    (LAPIS_ENVIRONMENT="production") and the OTP email is suppressed — so the
    6-digit code only ever lands in `admin_otp_codes`. This returns that code,
    but ONLY behind five independent gates, so it is inert in real production and
    useless for real users.

    It is called EXCLUSIVELY by the server-side broker (devops/e2e-otp-broker),
    which holds E2E_OTP_PEEK_SECRET and forwards it as the X-E2E-OTP-Secret
    header. The Playwright test never sees the secret.

    Contract (matches the broker):
      POST /auth/e2e/peek-otp
      Headers: X-E2E-OTP-Secret: <secret>   Content-Type: application/json
      Body:    { "session_token": "<2fa session JWT>" }
      200 -> { "code": "123456" }
      404 -> { "error": "no_valid_otp" }     (login row not committed yet; retried)
      400/401/403/404 -> bad input / session / secret / non-test email / disabled

    Five gates (ALL must pass):
      1. E2E_OTP_PEEK_ENABLED == "true"      (also: app.lua only loads this route
                                              when the flag is set)
      2. X-E2E-OTP-Secret == E2E_OTP_PEEK_SECRET   (constant-time, >= 16 chars)
      3. a valid 2FA session_token resolves the user
      4. the user's email matches OTP_SUPPRESS_FOR_EMAIL_REGEX (test mailboxes
         only — a real account's OTP is never retrievable)
      5. OPSAPI_DEPLOY_ENV must NOT resolve to prod/production (hard refuse)

    READ-ONLY: it never consumes/expires the code or bumps attempts —
    /auth/2fa/verify still does that, so the genuine 2FA flow is exercised.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local bit = require("bit")
local OTP = require("helper.otp")

local function parse_json_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then return {} end
    local ok, data = pcall(cjson.decode, body)
    return (ok and type(data) == "table") and data or {}
end

-- Constant-time compare so the secret can't be recovered via response timing.
local function secure_equals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end

-- Deployment env label. Mirrors helper/mail.lua: prefer OPSAPI_DEPLOY_ENV (set
-- by helm to dev/test/int/acc/prod); fall back to LAPIS_ENVIRONMENT; fail closed
-- to "production".
local function deploy_env()
    return os.getenv("OPSAPI_DEPLOY_ENV") or os.getenv("LAPIS_ENVIRONMENT") or "production"
end

local function is_production_env(env)
    return env == "production" or env == "prod"
end

return function(app)
    app:post("/auth/e2e/peek-otp", function(self)
        -- Gate 1: feature flag (defence in depth; app.lua also only registers
        -- this route when the flag is set, so in prod it doesn't exist at all).
        if os.getenv("E2E_OTP_PEEK_ENABLED") ~= "true" then
            return { status = 404, json = { error = "not_found" } }
        end

        -- Gate 5 (checked early): never operate in real production, whatever
        -- else is configured.
        if is_production_env(deploy_env()) then
            return { status = 403, json = { error = "disabled_in_production" } }
        end

        -- Gate 2: shared secret, held only by the broker. Constant-time compare.
        local configured = os.getenv("E2E_OTP_PEEK_SECRET")
        if not configured or #configured < 16 then
            return { status = 403, json = { error = "peek_not_configured" } }
        end
        local provided = ngx.req.get_headers()["X-E2E-OTP-Secret"]
        if not secure_equals(provided or "", configured) then
            return { status = 403, json = { error = "forbidden" } }
        end

        -- Gate 3: a valid 2FA session token (proof the password step passed).
        local params = parse_json_body()
        local session_token = params.session_token or self.params.session_token
        if not session_token or session_token == "" then
            return { status = 400, json = { error = "session_token is required" } }
        end
        local session, serr = OTP.verifySessionToken(session_token)
        if not session or not session.user_id then
            return { status = 401, json = { error = serr or "invalid session" } }
        end
        local user_id = session.user_id

        -- Gate 4: only ever return a code for a test-mailbox email — the same
        -- allow-list that suppresses the OTP send. A real account's OTP can
        -- never be retrieved, even here.
        local pattern = os.getenv("OTP_SUPPRESS_FOR_EMAIL_REGEX")
        if not pattern or pattern == "" then
            return { status = 403, json = { error = "email_allowlist_not_configured" } }
        end
        local urow = db.query("SELECT email FROM users WHERE id = ? LIMIT 1", user_id)
        local email = urow and urow[1] and urow[1].email
        if not email then
            return { status = 404, json = { error = "user_not_found" } }
        end
        local matched, re_err = ngx.re.match(email, pattern, "jo")
        if re_err then
            ngx.log(ngx.ERR, "[e2e-peek] bad OTP_SUPPRESS_FOR_EMAIL_REGEX: ", re_err)
            return { status = 500, json = { error = "allowlist_regex_error" } }
        end
        if not matched then
            return { status = 403, json = { error = "email_not_allowed" } }
        end

        -- Fetch the latest valid OTP — READ-ONLY. Do not delete it, mark it
        -- verified, or bump attempts; /auth/2fa/verify owns that lifecycle.
        local rows = db.query([[
            SELECT code FROM admin_otp_codes
            WHERE user_id = ? AND verified = false AND expires_at > NOW()
            ORDER BY created_at DESC LIMIT 1
        ]], user_id)
        local code = rows and rows[1] and rows[1].code
        if not code then
            -- The login may not have committed the OTP row yet; the broker/test
            -- retries on 404.
            return { status = 404, json = { error = "no_valid_otp" } }
        end

        ngx.log(ngx.WARN, "[e2e-peek] returned an OTP for E2E user_id=", user_id,
            " env=", deploy_env(), " ip=", ngx.var.remote_addr or "?")
        return { status = 200, json = { code = code } }
    end)
end
