local http = require("resty.http")
local cJson = require("cjson")
local db = require("lapis.db")
local UserQueries = require "queries.UserQueries"
local Global = require "helper.global"
local JWTHelper = require "helper.jwt-helper"
local NamespaceQueries = require "queries.NamespaceQueries"
local NamespaceMemberQueries = require "queries.NamespaceMemberQueries"
local DeviceTokenQueries = require "queries.DeviceTokenQueries"
local RateLimit = require("middleware.rate-limit")
local Errors = require("lib.errors")
local OTP = require("helper.otp")
local RefreshToken = require("helper.refresh-token")
local AuthCookies = require("helper.auth-cookies")
local PasswordReset = require("helper.password-reset")
local Mail = require("helper.mail")

-- Rate limit configs
local LOGIN_LIMIT    = { rate = 10,  window = 60,  prefix = "auth:login" }     -- 10/min per IP
local REFRESH_LIMIT  = { rate = 30,  window = 60,  prefix = "auth:refresh" }   -- 30/min per IP
local OAUTH_LIMIT    = { rate = 10,  window = 60,  prefix = "auth:oauth" }     -- 10/min per IP
local VALIDATE_LIMIT = { rate = 20,  window = 60,  prefix = "auth:validate" }  -- 20/min per IP
local OTP_LIMIT      = { rate = 5,   window = 60,  prefix = "auth:2fa" }       -- 5/min per IP

-- Password reset rate limits — strict, two layers
--   FORGOT_LIMIT: per-IP, capped at 5/hour. Stops drive-by enumeration sweeps
--   without inconveniencing a real user who might mistype their email a few times.
--   RESET_LIMIT:  per-IP, capped at 10/min. The reset endpoint is cheap and
--   self-rate-limited via single-use tokens, but stops a brute-force replay.
local FORGOT_LIMIT = { rate = 5,   window = 3600, prefix = "auth:forgot" }
local RESET_LIMIT  = { rate = 10,  window = 60,   prefix = "auth:reset"  }

-- Frontend domains allowed to receive a reset link. The ``redirect_url``
-- parameter on /auth/forgot-password is validated against this list
-- before being interpolated into the email — anything else is silently
-- replaced with the configured default. Prevents an attacker tricking
-- a user into clicking a link to a phishing domain wrapped in a real
-- email from us.
--
-- Set via env var ``PASSWORD_RESET_ALLOWED_ORIGINS`` (comma-separated).
-- Falls back to the single ``FRONTEND_URL`` env var, then to localhost
-- for local dev. SaaS deployments serving multiple frontends should
-- list each here.
local function get_allowed_reset_origins()
    local raw = os.getenv("PASSWORD_RESET_ALLOWED_ORIGINS")
    local origins = {}
    if raw and raw ~= "" then
        for origin in raw:gmatch("[^,]+") do
            local trimmed = origin:match("^%s*(.-)%s*$")
            if trimmed ~= "" then origins[trimmed] = true end
        end
    end
    local fallback = os.getenv("FRONTEND_URL")
    if fallback and fallback ~= "" then origins[fallback] = true end
    if not next(origins) then
        -- Local-dev safety net so engineers don't have to set env
        -- vars to test the flow on their laptop.
        origins["http://localhost:3000"] = true
        origins["http://localhost:3847"] = true
        origins["http://localhost"] = true
    end
    return origins
end

local function default_reset_origin()
    local explicit = os.getenv("FRONTEND_URL")
    if explicit and explicit ~= "" then return explicit end
    return "http://localhost"
end

-- Helper function to parse JSON body
local function parse_json_body()
    local ok, result = pcall(function()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then
            return {}
        end
        return cJson.decode(body)
    end)

    if ok and type(result) == "table" then
        return result
    end
    return {}
end

--- Build the full login response (user + token + namespaces + refresh_token).
-- Shared by both login and 2FA verify to avoid duplication.
-- @param self table Lapis request context (used by AuthCookies to
--             resolve the cookie's Domain attribute from the
--             calling tenant's Origin — see helper/auth-cookies.lua)
-- @param userWithRoles table User record from UserQueries.show()
-- @param user_id number Internal user ID
-- @param device_info string|nil Optional device description for refresh token
-- @return table JSON-ready response body
local function build_login_response(self, userWithRoles, user_id, device_info)
    local rolesArray = {}
    if userWithRoles.roles then
        for _, role in ipairs(userWithRoles.roles) do
            table.insert(rolesArray, {
                id = role.id,
                role_id = role.role_id,
                role_name = role.name or role.role_name,
                name = role.name or role.role_name
            })
        end
    end

    local namespaces = NamespaceQueries.getForUser(userWithRoles.uuid) or {}
    local default_namespace = nil
    local namespace_membership = nil

    if user_id then
        default_namespace = NamespaceQueries.getUserDefaultNamespace(user_id)
    end

    if not default_namespace then
        for _, ns in ipairs(namespaces) do
            if ns.status == "active" and ns.member_status == "active" then
                default_namespace = NamespaceQueries.show(ns.id)
                if user_id then
                    NamespaceQueries.updateLastActiveNamespace(user_id, ns.id)
                end
                break
            end
        end
    else
        if user_id then
            NamespaceQueries.updateLastActiveNamespace(user_id, default_namespace.id)
        end
    end

    if default_namespace then
        namespace_membership = NamespaceMemberQueries.findByUserAndNamespace(
            userWithRoles.uuid,
            default_namespace.id
        )
    end

    local token
    if default_namespace and namespace_membership then
        local namespace_permissions = NamespaceMemberQueries.getPermissions(namespace_membership.id)
        token = JWTHelper.generateNamespaceToken(userWithRoles, default_namespace, namespace_membership, {
            user_roles = rolesArray,
            namespace_permissions = namespace_permissions
        })
    else
        token = JWTHelper.generateToken(userWithRoles, {
            roles = rolesArray
        })
    end

    local namespacesArray = {}
    for _, ns in ipairs(namespaces) do
        table.insert(namespacesArray, {
            id = ns.id,
            uuid = ns.uuid,
            name = ns.name,
            slug = ns.slug,
            logo_url = ns.logo_url,
            is_owner = ns.is_owner,
            status = ns.status,
            member_status = ns.member_status
        })
    end

    -- Check if user has a PIN set (for mobile app lock)
    local has_pin = false
    if user_id then
        local pin_result = db.select("pin_hash FROM users WHERE id = ?", user_id)
        has_pin = pin_result and pin_result[1] and pin_result[1].pin_hash ~= nil and true or false
    end

    -- Issue an opaque refresh token (stored hashed in DB, revocable).
    -- Wrapped in pcall: if the refresh_tokens table doesn't exist yet (migration
    -- pending), login must still succeed — just without a refresh token.
    --
    -- The token is delivered to the client through TWO transports:
    --   1. JSON body (``refresh_token`` field below) — for mobile/CLI
    --      clients that don't speak cookies.
    --   2. HttpOnly Secure cookie via AuthCookies.set — the canonical
    --      web transport. JS-invisible so XSS can't read it; auto-sent
    --      by the browser on every refresh request, no localStorage
    --      handoff required. See helper/auth-cookies.lua for the full
    --      security rationale.
    -- Web clients should prefer the cookie and may treat the JSON
    -- ``refresh_token`` as optional.
    local refresh_token_raw
    if user_id then
        local ok, rt_or_err, rt_err = pcall(RefreshToken.create, user_id, device_info)
        if ok and rt_or_err then
            refresh_token_raw = rt_or_err
            pcall(AuthCookies.set, self, rt_or_err)
        else
            ngx.log(ngx.WARN, "[AUTH] Refresh token creation skipped: ",
                tostring(ok and rt_err or rt_or_err))
        end
    end

    return {
        user = {
            id = userWithRoles.internal_id,
            uuid = userWithRoles.uuid or userWithRoles.id,
            email = userWithRoles.email,
            username = userWithRoles.username,
            first_name = userWithRoles.first_name or "",
            last_name = userWithRoles.last_name or "",
            active = userWithRoles.active,
            created_at = userWithRoles.created_at,
            updated_at = userWithRoles.updated_at,
            roles = rolesArray
        },
        token = token,
        refresh_token = refresh_token_raw,
        has_pin = has_pin,
        namespaces = namespacesArray,
        current_namespace = default_namespace and {
            id = default_namespace.id,
            uuid = default_namespace.uuid,
            name = default_namespace.name,
            slug = default_namespace.slug,
            is_owner = default_namespace.is_owner
        } or nil
    }
end

return function(app)
    ----------------- Auth Routes --------------------

    app:post("/auth/login", RateLimit.wrap(LOGIN_LIMIT, function(self)
        local identifier = self.params.username or self.params.identifier
        local password = self.params.password

        if not identifier or not password then
            return Errors.response(self, "VALIDATION_400", {
                context = {
                    field = not identifier and "identifier" or "password",
                    reason = "required",
                },
            })
        end

        local user = UserQueries.verify(identifier, password)

        if not user then
            return Errors.response(self, "AUTH_INVALID_CREDENTIALS")
        end

        -- Get user with roles
        local userWithRoles = UserQueries.show(user.uuid)
        if not userWithRoles then
            return Errors.response(self, "SYSTEM_500", {
                cause = "UserQueries.show returned nil after successful verify for uuid=" .. tostring(user.uuid),
            })
        end

        -- Resolve user's internal ID for DB lookups
        local db = require("lapis.db")
        local user_record = db.select("id FROM users WHERE uuid = ?", userWithRoles.uuid)
        local user_id = user_record and user_record[1] and user_record[1].id

        -- All users require 2FA — send OTP and return partial response (no JWT)
        -- Accept optional branding from the frontend (SaaS: each frontend sends its own brand)
        local brand = {
            app_name = self.params.app_name or self.params.brand_name,
            brand_color = self.params.brand_color,
            header_title = self.params.header_title,
            brand_logo_url = self.params.brand_logo_url,
            support_email = self.params.support_email,
        }

        local otp_ok, otp_err = OTP.sendToEmail({
            id = user_id,
            email = userWithRoles.email,
            first_name = userWithRoles.first_name,
        }, brand)

        if not otp_ok then
            ngx.log(ngx.ERR, "[2FA] OTP send failed for ", userWithRoles.email, ": ", tostring(otp_err))
            -- Still require 2FA, just warn that email may not arrive
        end

        -- Generate a short-lived session token proving password was verified.
        -- The frontend must send this back with /auth/2fa/verify and /auth/2fa/resend.
        local session_token = OTP.generateSessionToken(userWithRoles.uuid, user_id)

        return {
            status = 200,
            json = {
                requires_2fa = true,
                session_token = session_token,
                email = userWithRoles.email,
                message = "Verification code sent to your email"
            }
        }
    end))

    -- =========================================================================
    -- 2FA OTP Verification — completes admin login after password was verified
    -- =========================================================================

    -- POST /auth/2fa/verify — Verify OTP and issue full JWT
    -- Body: { "session_token": "...", "code": "123456" }
    -- The session_token proves the user already passed password verification.
    app:post("/auth/2fa/verify", RateLimit.wrap(OTP_LIMIT, function(self)
        local params = parse_json_body()
        local session_token = params.session_token or self.params.session_token
        local code = params.code or self.params.code

        if not session_token or not code then
            return {
                status = 400,
                json = { error = "session_token and code are required" }
            }
        end

        -- Verify the 2FA session token (signed proof of password verification)
        local session, session_err = OTP.verifySessionToken(session_token)
        if not session then
            return { status = 401, json = { error = session_err } }
        end

        local user_uuid = session.user_uuid
        local user_id = session.user_id

        -- Look up user
        local userWithRoles = UserQueries.show(user_uuid)
        if not userWithRoles then
            return { status = 401, json = { error = "Invalid session" } }
        end

        -- Verify OTP
        local verified, otp_err = OTP.verify(user_id, code)
        if not verified then
            return { status = 401, json = { error = otp_err or "Invalid code" } }
        end

        -- OTP verified — issue the full JWT
        ngx.log(ngx.NOTICE, "[2FA] Admin login completed for: ", userWithRoles.email)

        -- Extract device info from User-Agent for refresh token tracking
        local device_info = ngx.req.get_headers()["user-agent"]
        if device_info and #device_info > 255 then
            device_info = device_info:sub(1, 255)
        end

        return {
            status = 200,
            json = build_login_response(self, userWithRoles, user_id, device_info)
        }
    end))

    -- POST /auth/2fa/resend — Resend OTP code
    -- Body: { "session_token": "..." }
    -- Requires the same session_token from login to prevent abuse.
    app:post("/auth/2fa/resend", RateLimit.wrap(OTP_LIMIT, function(self)
        local params = parse_json_body()
        local session_token = params.session_token or self.params.session_token

        if not session_token then
            return { status = 400, json = { error = "session_token is required" } }
        end

        -- Verify the 2FA session token
        local session, session_err = OTP.verifySessionToken(session_token)
        if not session then
            return { status = 401, json = { error = session_err } }
        end

        local db = require("lapis.db")
        local user_record = db.query([[
            SELECT id, email, first_name FROM users WHERE uuid = ? AND active = true
        ]], session.user_uuid)

        if not user_record or #user_record == 0 then
            return { status = 200, json = { message = "If the account exists, a new code has been sent" } }
        end

        local user = user_record[1]

        -- Accept optional branding for resend (same as login)
        local brand = {
            app_name = params.app_name or params.brand_name,
            brand_color = params.brand_color,
            header_title = params.header_title,
            brand_logo_url = params.brand_logo_url,
            support_email = params.support_email,
        }

        local ok, err = OTP.sendToEmail(user, brand)
        if not ok then
            ngx.log(ngx.ERR, "[2FA] Resend OTP failed for ", user.email, ": ", tostring(err))
        end

        return { status = 200, json = { message = "If the account exists, a new code has been sent" } }
    end))

    -- =====================================================================
    -- Password Reset
    -- =====================================================================
    --
    -- Two-step flow:
    --   1. POST /auth/forgot-password { email, redirect_url? }
    --      → always returns 200 (prevents email enumeration). If the
    --        email exists, sends a one-time link to user's email.
    --   2. POST /auth/reset-password  { token, new_password }
    --      → validates the token, updates password, revokes all
    --        refresh tokens (forces re-login on every device), returns
    --        a generic success.
    --
    -- Security properties:
    --   - Tokens are 256 bits of CSPRNG entropy, hashed with SHA-256
    --     in the DB (plaintext only in the email link). See
    --     helper/password-reset.lua.
    --   - Single-use enforced atomically via UPDATE ... RETURNING.
    --   - 30-minute TTL.
    --   - Rate-limited per IP (5 forgot-requests/hour, 10 reset
    --     attempts/min). The token itself is the strong gate; the
    --     rate limit just stops resource abuse.
    --   - Constant 200 on /forgot — no enumeration via timing or
    --     status codes.
    --   - On successful reset, ALL refresh tokens for the user are
    --     revoked. An attacker holding a stolen session is kicked
    --     out the moment the user resets.
    --   - Email link points at the **namespace primary** — the first
    --     entry in ``namespaces.allowed_redirect_origins``, set via the
    --     admin UI. ``redirect_url`` from the client is ignored;
    --     destination is admin-controlled, not caller-controlled.
    -- =====================================================================
    app:post("/auth/forgot-password", RateLimit.wrap(FORGOT_LIMIT, function(self)
        local body = parse_json_body()
        local email = body.email or self.params.email
        -- ``redirect_url`` was previously honoured via an "echo back"
        -- policy. We now always use the namespace primary so admins
        -- control reset destinations from the UI without code changes;
        -- any redirect_url supplied by the client is silently ignored.

        -- Basic shape validation. Beyond this we deliberately give
        -- back the same 200-OK response regardless of what the email
        -- contains — see the enumeration note below.
        if type(email) ~= "string" or #email < 3 or not email:find("@", 1, true) then
            return Errors.response(self, "VALIDATION_400", {
                context = { field = "email", reason = "invalid_format" },
            })
        end
        email = email:lower():match("^%s*(.-)%s*$")

        -- Generic success response — same shape whether the email
        -- exists or not. Prevents an attacker from enumerating
        -- registered emails by submitting a list and watching for
        -- response differences.
        local generic_ok = {
            status = 200,
            json = {
                message = "If an account with that email exists, we've sent a reset link.",
            },
        }

        -- Look up the user. Wrapped in pcall so a DB hiccup doesn't
        -- leak through the enumeration mask via a 500 status.
        local lookup_ok, user_or_err = pcall(UserQueries.findByEmail, email)
        if not lookup_ok then
            ngx.log(ngx.ERR, "[forgot-password] findByEmail failed: ",
                tostring(user_or_err))
            return generic_ok
        end
        local user = user_or_err
        if not user or not user.id then
            -- Email not registered. Return the same 200-OK as the
            -- success path so the response is timing-stable.
            return generic_ok
        end

        -- ────────────────────────────────────────────────────────────
        -- Resolve which frontend origin to use in the email link.
        --
        -- Pick the origin to use in the email link.
        --
        -- Policy: **primary always wins.** The first entry in the
        -- namespace allow-list (``namespaces.allowed_redirect_origins[1]``)
        -- is the canonical destination for reset emails. Admins set it
        -- via the admin UI — no code changes, no env-var updates, no
        -- restart needed. Caller-supplied ``redirect_url`` is ignored;
        -- destination is admin-controlled, not caller-controlled.
        --
        -- Fallback chain (only reached if the prior level is empty):
        --   1. Namespace primary — first row of the namespace's
        --      ``allowed_redirect_origins`` array.
        --   2. Env-var primary — legacy ``FRONTEND_URL`` /
        --      ``PASSWORD_RESET_ALLOWED_ORIGINS``. Inert once migration
        --      489 has bootstrapped the namespace column.
        --   3. ``default_reset_origin()`` — last-resort dev default
        --      pointing at localhost. Only reachable when the namespace
        --      column AND env vars are empty.
        -- ────────────────────────────────────────────────────────────
        local function canonicalise(url)
            if type(url) ~= "string" or url == "" then return nil end
            return url:match("^(https?://[^/]+)") or url
        end

        local origin
        local user_ns = NamespaceQueries.getUserDefaultNamespace(user.id)
        if user_ns and user_ns.id then
            local ns_origins = NamespaceQueries.getAllowedRedirectOrigins(user_ns.id)
            for _, o in ipairs(ns_origins or {}) do
                local canon = canonicalise(o)
                if canon then origin = canon; break end
            end
        end

        if not origin then
            for legacy_origin, _ in pairs(get_allowed_reset_origins()) do
                origin = canonicalise(legacy_origin)
                if origin then break end
            end
        end

        if not origin then
            origin = default_reset_origin()
            ngx.log(ngx.WARN,
                "[forgot-password] no allow-list configured for namespace; ",
                "using env default. user_id=", user.id,
                " namespace_id=", user_ns and user_ns.id or "nil",
                " origin=", origin)
        end

        local ip = ngx.var.remote_addr
        local raw_token, token_err = PasswordReset.create(user.id, ip)
        if not raw_token then
            ngx.log(ngx.ERR, "[forgot-password] token create failed for user=",
                user.id, " err=", tostring(token_err))
            -- Don't surface the error to the client — would let an
            -- attacker probe for "user exists" via timing/error
            -- differential. Log loud, return generic.
            return generic_ok
        end

        -- Build the email and send via the existing async Mail helper.
        -- The email template ``password_reset.etlua`` already exists —
        -- we just need to provide the data.
        local reset_url = origin .. "/reset-password?token=" .. raw_token
        local app_name = os.getenv("APP_NAME") or "OpsAPI"

        local send_ok, send_err = pcall(Mail.send, {
            to = user.email,
            subject = "Reset your " .. app_name .. " password",
            template = "password_reset",
            data = {
                app_name = app_name,
                email = user.email,
                reset_url = reset_url,
                expires_in = "30 minutes",
            },
        })
        if not send_ok then
            ngx.log(ngx.ERR, "[forgot-password] Mail.send failed for user=",
                user.id, " err=", tostring(send_err))
            -- Token is already stored; the user just won't get the
            -- email. We still return generic 200 so we don't
            -- distinguish "email infrastructure broken" from "email
            -- not registered". An admin notice on Mail.send failures
            -- is a separate concern.
        end

        return generic_ok
    end))


    app:post("/auth/reset-password", RateLimit.wrap(RESET_LIMIT, function(self)
        local body = parse_json_body()
        local token = body.token or self.params.token
        local new_password = body.new_password or self.params.new_password
            or body.password or self.params.password

        if type(token) ~= "string" or #token < 16 then
            return Errors.response(self, "VALIDATION_400", {
                context = { field = "token", reason = "invalid_format" },
            })
        end
        if type(new_password) ~= "string" or #new_password < 8 then
            return Errors.response(self, "VALIDATION_400", {
                context = {
                    field = "new_password",
                    reason = "too_short",
                    min_length = 8,
                },
            })
        end
        if #new_password > 256 then
            -- bcrypt silently truncates above 72 bytes; reject loudly
            -- so users don't think their giant password is being
            -- stored as typed.
            return Errors.response(self, "VALIDATION_400", {
                context = {
                    field = "new_password",
                    reason = "too_long",
                    max_length = 256,
                },
            })
        end

        local user_id, err_code = PasswordReset.validateAndConsume(token)
        if not user_id then
            -- Map our internal error code to a clean envelope so the
            -- frontend can show a precise message ("link expired" vs
            -- "already used").
            local reason = err_code or "invalid_token"
            return Errors.response(self, "VALIDATION_400", {
                status = 400,
                context = {
                    field = "token",
                    reason = reason,
                    action = "request_new_link",
                    action_url = "/forgot-password",
                },
            })
        end

        -- Find the user the consumed token belongs to. Wrapped in
        -- pcall so a missing user (race: account deleted between
        -- token issue and consume) doesn't 500 the response.
        local user_lookup_ok, user_row = pcall(function()
            return db.query("SELECT id, uuid FROM users WHERE id = ? LIMIT 1",
                user_id)
        end)
        if not user_lookup_ok or not user_row or #user_row == 0 then
            return Errors.response(self, "VALIDATION_400", {
                context = { field = "token", reason = "user_not_found" },
            })
        end

        -- Hash the new password and update. UserQueries.update takes
        -- a uuid (not numeric id) per its contract — see queries
        -- file. We hash here so a logging mishap can't accidentally
        -- log the plaintext.
        local hashed = Global.hashPassword(new_password)
        local update_ok, update_err = pcall(UserQueries.update, user_row[1].uuid, {
            password = hashed,
        })
        if not update_ok then
            ngx.log(ngx.ERR, "[reset-password] password update failed for user=",
                user_id, " err=", tostring(update_err))
            return Errors.response(self, "SYSTEM_500")
        end

        -- Defence in depth — kick the user out of every device. If
        -- the reset was triggered by an attacker stealing a session
        -- (and the legitimate user noticed), we want their stolen
        -- token revoked the moment the password changes.
        pcall(RefreshToken.revokeAllForUser, user_id)

        -- Also revoke any *other* outstanding reset tokens for this
        -- user — defence in depth against an attacker holding a
        -- second link from an earlier request.
        pcall(PasswordReset.revokeAllForUser, user_id)

        return {
            status = 200,
            json = {
                message = "Your password has been reset. Please sign in.",
            },
        }
    end))

    -- Google OAuth Routes
    app:get("/auth/google", RateLimit.wrap(OAUTH_LIMIT, function(self)
        local google_client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local google_redirect_uri = Global.getEnvVar("GOOGLE_REDIRECT_URI")

        if not google_client_id or not google_redirect_uri then
            return {
                status = 500,
                json = {
                    error = "Google OAuth not configured"
                }
            }
        end

        local redirect_from = self.params.from or "/"
        local frontend_url = self.params.frontend_url

        -- Encode state as JSON if frontend_url is provided, otherwise plain string for backward compatibility
        local state
        if frontend_url then
            state = cJson.encode({ from = redirect_from, frontend_url = frontend_url })
        else
            state = redirect_from
        end

        local auth_url = string.format(
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=%s&redirect_uri=%s" ..
            "&response_type=code&scope=openid+profile+email&prompt=select_account&state=%s",
            google_client_id, ngx.escape_uri(google_redirect_uri), ngx.escape_uri(state)
        )

        return {
            redirect_to = auth_url
        }
    end))

    app:get("/auth/google/callback", RateLimit.wrap(OAUTH_LIMIT, function(self)
        local code = self.params.code
        local raw_state = self.params.state or "/"

        -- Decode state: may be JSON (new format) or plain string (legacy)
        local redirect_from = "/"
        local state_frontend_url = nil
        local ok_state, state_data = pcall(cJson.decode, raw_state)
        if ok_state and type(state_data) == "table" then
            redirect_from = state_data.from or "/"
            state_frontend_url = state_data.frontend_url
        else
            redirect_from = raw_state
        end

        if not code then
            return {
                status = 400,
                json = {
                    error = "Authorization code not provided"
                }
            }
        end

        local google_client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local google_client_secret = Global.getEnvVar("GOOGLE_CLIENT_SECRET")
        local google_redirect_uri = Global.getEnvVar("GOOGLE_REDIRECT_URI")

        -- Exchange code for access token
        local httpc = http.new()
        httpc:set_timeout(30000)

        local token_res, token_err = httpc:request_uri("https://oauth2.googleapis.com/token", {
            method = "POST",
            body = ngx.encode_args({
                client_id = google_client_id,
                client_secret = google_client_secret,
                code = code,
                grant_type = "authorization_code",
                redirect_uri = google_redirect_uri
            }),
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
            },
            ssl_verify = false,
        })

        if not token_res then
            return {
                status = 500,
                json = {
                    error = "Failed to exchange code for token: " .. (token_err or "unknown")
                }
            }
        end

        local token_data = cJson.decode(token_res.body)
        if not token_data.access_token then
            return {
                status = 500,
                json = {
                    error = "No access token received"
                }
            }
        end

        -- Get user info from Google
        local httpc2 = http.new()
        httpc2:set_timeout(30000)

        local user_res, user_err = httpc2:request_uri("https://www.googleapis.com/oauth2/v2/userinfo", {
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token_data.access_token,
            },
            ssl_verify = false,
        })

        if not user_res then
            return {
                status = 500,
                json = {
                    error = "Failed to get user info: " .. (user_err or "unknown")
                }
            }
        end

        local user_body = user_res.body

        local google_user = cJson.decode(user_body)
        if not google_user.email then
            return {
                status = 500,
                json = {
                    error = "No email received from Google"
                }
            }
        end

        -- Find or create user
        local user = UserQueries.findByEmail(google_user.email)
        if not user then
            local names = {}
            if google_user.name then
                names = Global.splitName(google_user.name)
            end

            user = UserQueries.createOAuthUser({
                uuid = Global.generateUUID(),
                email = google_user.email,
                username = google_user.email,
                first_name = names.first_name or google_user.given_name or "",
                last_name = names.last_name or google_user.family_name or "",
                password = Global.generateRandomPassword(),
                role = "buyer",
                oauth_provider = "google",
                oauth_id = google_user.id,
                active = true
            })
        end

        -- Get user with roles
        local userWithRoles = UserQueries.show(user.uuid)
        if not userWithRoles then
            return {
                status = 500,
                json = {
                    error = "Failed to load user data"
                }
            }
        end

        -- Build roles array
        local rolesArray = {}
        if userWithRoles.roles then
            for _, role in ipairs(userWithRoles.roles) do
                table.insert(rolesArray, {
                    id = role.id,
                    role_id = role.role_id,
                    role_name = role.name or role.role_name,
                    name = role.name or role.role_name
                })
            end
        end

        -- Get user's namespaces
        local namespaces = NamespaceQueries.getForUser(userWithRoles.uuid) or {}
        local default_namespace = nil
        local namespace_membership = nil

        -- Find first active namespace
        for _, ns in ipairs(namespaces) do
            if ns.status == "active" and ns.member_status == "active" then
                default_namespace = ns
                break
            end
        end

        -- Get namespace membership if available
        if default_namespace then
            namespace_membership = NamespaceMemberQueries.findByUserAndNamespace(
                userWithRoles.uuid,
                default_namespace.id
            )
        end

        -- Generate JWT token with namespace context
        local token
        if default_namespace and namespace_membership then
            local namespace_permissions = NamespaceMemberQueries.getPermissions(namespace_membership.id)
            token = JWTHelper.generateNamespaceToken(userWithRoles, default_namespace, namespace_membership, {
                user_roles = rolesArray,
                namespace_permissions = namespace_permissions
            })
        else
            token = JWTHelper.generateToken(userWithRoles, {
                roles = rolesArray
            })
        end

        -- Issue an opaque refresh token alongside the JWT, mirroring
        -- /auth/login. Delivered ONLY via HttpOnly Secure cookie — never
        -- in the redirect URL, because URL params leak through server
        -- access logs, browser history, Referer headers, and browser
        -- extensions. See helper/auth-cookies.lua for the full
        -- rationale.
        --
        -- Without this, OAuth-signed-up users had no refresh_token at
        -- all and the frontend fell through to the legacy JWT-only
        -- refresh path, which 401s under certain proxy/JWT
        -- configurations and forced an unnecessary re-login.
        --
        -- pcall mirrors /auth/login: if the refresh_tokens migration
        -- hasn't run yet, OAuth login still succeeds — the user just
        -- won't get refresh-on-401 until the migration lands.
        local device_info = ngx.req.get_headers()["user-agent"]
        if device_info and #device_info > 255 then
            device_info = device_info:sub(1, 255)
        end
        if user.id then
            local ok_rt, rt_or_err, rt_err = pcall(RefreshToken.create, user.id, device_info)
            if ok_rt and rt_or_err then
                pcall(AuthCookies.set, self, rt_or_err)
            else
                ngx.log(ngx.WARN, "[AUTH] OAuth refresh token creation skipped: ",
                    tostring(ok_rt and rt_err or rt_or_err))
            end
        end

        -- Determine redirect URL based on client type
        -- If redirect_from contains 'desktop' or 'electron', use custom protocol
        -- Otherwise, use web frontend URL
        local is_desktop = redirect_from:find("desktop") or redirect_from:find("electron") or
        redirect_from:find("wsl%-chat")
        local final_url

        if is_desktop then
            -- Desktop app: use custom protocol. Desktop doesn't share
            -- the browser's cookie jar so this leaves desktop OAuth
            -- without a refresh token — the desktop client will need
            -- a separate exchange step (out of scope for this fix).
            final_url = string.format("wsl-chat://auth/callback?token=%s", ngx.escape_uri(token))
        else
            -- Web app: use frontend_url from state (passed by frontend), fall back to env var
            local frontend_url = state_frontend_url or Global.getEnvVar("FRONTEND_URL") or "http://127.0.0.1:3033"
            final_url = string.format("%s/auth/callback?token=%s&redirect=%s",
                frontend_url, ngx.escape_uri(token), ngx.escape_uri(redirect_from))
        end

        return {
            redirect_to = final_url
        }
    end))

    -- Logout endpoint
    app:post("/auth/logout", function(self)
        -- Clear any session data
        if self.session then
            for k, _ in pairs(self.session) do
                self.session[k] = nil
            end
        end

        -- Clear the refresh-token cookie. Browser keeps the cookie
        -- around indefinitely otherwise — even after the user logs
        -- out — and would auto-include it on subsequent /auth/refresh
        -- attempts, which would then succeed if the underlying DB
        -- token wasn't also revoked. Belt-and-braces: zero out both.
        pcall(AuthCookies.clear, self)

        -- Clear user's cart and deactivate device tokens
        local user_uuid = ngx.var.http_x_user_id
        if user_uuid and user_uuid ~= "guest" then
            local db = require("lapis.db")
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if user_result and #user_result > 0 then
                db.delete("cart_items", "user_id = ?", user_result[1].id)
            end

            -- Device token cleanup is handled by the iOS app calling
            -- DELETE /api/v2/device-tokens with the specific fcm_token
            -- before this endpoint. We don't delete all tokens here
            -- because the user may be logged in on other devices.
        end

        return {
            json = {
                message = "Logged out successfully"
            },
            status = 200
        }
    end)

    -- Helper function to check if token is a Google ID token
    local function is_google_id_token(token)
        -- Google ID tokens are JWTs with specific issuers
        local parts = {}
        for part in string.gmatch(token, "[^%.]+") do
            table.insert(parts, part)
        end
        if #parts ~= 3 then return false end

        -- Decode payload (second part) - add padding if needed
        local payload_b64 = parts[2]
        local padding = 4 - (#payload_b64 % 4)
        if padding ~= 4 then
            payload_b64 = payload_b64 .. string.rep("=", padding)
        end
        -- Replace URL-safe characters
        payload_b64 = payload_b64:gsub("-", "+"):gsub("_", "/")

        local ok, payload_json = pcall(ngx.decode_base64, payload_b64)
        if not ok or not payload_json then return false end

        local ok2, payload = pcall(cJson.decode, payload_json)
        if not ok2 or not payload then return false end

        -- Check if issuer is Google
        local iss = payload.iss
        return iss == "accounts.google.com" or iss == "https://accounts.google.com"
    end

    -- Helper function to validate Google ID token
    local function validate_google_token(token)
        local google_client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local google_client_ios_id = Global.getEnvVar("GOOGLE_CLIENT_IOS_ID")

        if not google_client_id and not google_client_ios_id then
            return nil, "Google OAuth not configured"
        end

        local httpc = http.new()
        httpc:set_timeout(30000)

        -- Validate token with Google's tokeninfo endpoint
        local res, err = httpc:request_uri("https://oauth2.googleapis.com/tokeninfo?id_token=" .. token, {
            method = "GET",
            ssl_verify = false
        })

        if not res then
            return nil, "Failed to validate token: " .. (err or "unknown")
        end

        if res.status ~= 200 then
            return nil, "Invalid Google token"
        end

        local ok, token_info = pcall(cJson.decode, res.body)
        if not ok or not token_info then
            return nil, "Failed to parse Google response"
        end

        -- Verify audience matches our web or iOS client ID
        local valid_audience = (google_client_id and token_info.aud == google_client_id) or
            (google_client_ios_id and token_info.aud == google_client_ios_id)

        if not valid_audience then
            return nil, "Token not issued for this app"
        end

        return token_info, nil
    end

    -- OAuth token validation endpoint (handles both Google ID tokens and app JWTs)
    app:post("/auth/oauth/validate", RateLimit.wrap(VALIDATE_LIMIT, function(self)
        local token = self.params.token
        if not token then
            return {
                status = 400,
                json = {
                    error = "Token is required"
                }
            }
        end

        -- Check if this is a Google ID token
        if is_google_id_token(token) then
            -- Validate Google token
            local google_user, err = validate_google_token(token)
            if not google_user then
                return {
                    status = 401,
                    json = { error = err or "Invalid Google token" }
                }
            end

            -- Find or create user by email
            local user = UserQueries.findByEmail(google_user.email)
            if not user then
                -- Create new user (signup)
                local names = {}
                if google_user.name then
                    names = Global.splitName(google_user.name)
                end

                user = UserQueries.createOAuthUser({
                    uuid = Global.generateUUID(),
                    email = google_user.email,
                    username = google_user.email,
                    first_name = names.first_name or google_user.given_name or "",
                    last_name = names.last_name or google_user.family_name or "",
                    password = Global.generateRandomPassword(),
                    role = "buyer",
                    oauth_provider = "google",
                    oauth_id = google_user.sub,
                    active = true
                })

                if not user then
                    return {
                        status = 500,
                        json = { error = "Failed to create user" }
                    }
                end
            end

            -- Get user with roles
            local userWithRoles = UserQueries.show(user.uuid)
            if not userWithRoles then
                return {
                    status = 500,
                    json = { error = "Failed to load user data" }
                }
            end

            -- Build roles array
            local rolesArray = {}
            if userWithRoles.roles then
                for _, role in ipairs(userWithRoles.roles) do
                    table.insert(rolesArray, {
                        id = role.id,
                        role_id = role.role_id,
                        role_name = role.name or role.role_name,
                        name = role.name or role.role_name
                    })
                end
            end

            -- Get user's namespaces
            local namespaces = NamespaceQueries.getForUser(userWithRoles.uuid) or {}
            local default_namespace = nil
            local namespace_membership = nil

            -- Find first active namespace
            for _, ns in ipairs(namespaces) do
                if ns.status == "active" and ns.member_status == "active" then
                    default_namespace = ns
                    break
                end
            end

            -- Get namespace membership if available
            if default_namespace then
                namespace_membership = NamespaceMemberQueries.findByUserAndNamespace(
                    userWithRoles.uuid,
                    default_namespace.id
                )
            end

            -- Generate JWT token
            local app_token
            if default_namespace and namespace_membership then
                local namespace_permissions = NamespaceMemberQueries.getPermissions(namespace_membership.id)
                app_token = JWTHelper.generateNamespaceToken(userWithRoles, default_namespace, namespace_membership, {
                    user_roles = rolesArray,
                    namespace_permissions = namespace_permissions
                })
            else
                app_token = JWTHelper.generateToken(userWithRoles, {
                    roles = rolesArray
                })
            end

            -- Return user data and token (matching login response format)
            return {
                status = 200,
                json = {
                    user = {
                        id = userWithRoles.internal_id,
                        uuid = userWithRoles.uuid,
                        email = userWithRoles.email,
                        username = userWithRoles.username,
                        name = (userWithRoles.first_name or "") .. " " .. (userWithRoles.last_name or ""),
                        first_name = userWithRoles.first_name or "",
                        last_name = userWithRoles.last_name or "",
                        active = userWithRoles.active,
                        roles = rolesArray
                    },
                    token = app_token
                }
            }
        end

        -- Existing app JWT validation (unchanged)
        local result = JWTHelper.verifyToken(token)

        if not result.valid then
            return {
                status = 401,
                json = {
                    error = "Invalid token"
                }
            }
        end

        local userinfo = result.payload.userinfo
        return {
            status = 200,
            json = {
                user = {
                    id = userinfo.uuid,
                    email = userinfo.email,
                    name = userinfo.name,
                    role = userinfo.roles,
                    namespace = userinfo.namespace
                },
                token = token
            }
        }
    end))

    -- Token refresh endpoint with opaque refresh token + backward compat
    --
    -- Token sources, in priority order:
    --   1. JSON body / form ``refresh_token`` field (mobile, CLI, and
    --      existing localStorage-based web sessions)
    --   2. ``refresh_token`` HttpOnly cookie (modern web — set by
    --      /auth/login + /auth/google/callback via AuthCookies)
    --   3. ``Authorization: Bearer <jwt>`` legacy fallback
    --
    -- The cookie path is the canonical web transport because it's
    -- XSS-safe (HttpOnly), CSRF-safe (SameSite=Strict), and never
    -- traverses URL/log/history/Referer channels. See
    -- helper/auth-cookies.lua for the full rationale.
    app:post("/auth/refresh", RateLimit.wrap(REFRESH_LIMIT, function(self)
        local params = parse_json_body()
        local refresh_token_raw = params.refresh_token or self.params.refresh_token

        -- Cookie fallback when the body / form didn't carry one. We
        -- check this BEFORE the legacy Authorization-header path so
        -- modern web sessions (no localStorage refresh_token) hit the
        -- well-tested opaque-rotation path instead of the brittle
        -- JWT-resign fallback.
        if (not refresh_token_raw or refresh_token_raw == "") then
            local cookie_token = AuthCookies.read(self)
            if cookie_token and cookie_token ~= "" then
                refresh_token_raw = cookie_token
            end
        end

        -- ── New flow: opaque refresh token ──
        if refresh_token_raw and refresh_token_raw ~= "" then
            -- pcall protects against missing table (migration not yet run).
            -- If pcall fails, fall through to legacy JWT-based refresh.
            local ok_validate, rt_data, rt_err = pcall(RefreshToken.validate, refresh_token_raw)
            if not ok_validate then
                ngx.log(ngx.WARN, "[AUTH] Refresh token validation error (falling back to legacy): ", tostring(rt_data))
                -- Fall through to legacy flow below
            elseif not rt_data then
                return { status = 401, json = { error = rt_err or "Invalid refresh token" } }
            else
                -- Re-validate user from DB
                local user_record = db.select("* FROM users WHERE id = ? AND active = true", rt_data.user_id)
                if not user_record or #user_record == 0 then
                    pcall(RefreshToken.revokeAllForUser, rt_data.user_id)
                    return { status = 401, json = { error = "Account is deactivated" } }
                end
                local db_user = user_record[1]

                -- Build a fresh JWT via the same logic as login
                local userWithRoles = UserQueries.show(db_user.uuid)
                if not userWithRoles then
                    return { status = 401, json = { error = "User not found" } }
                end

                local rolesArray = {}
                if userWithRoles.roles then
                    for _, role in ipairs(userWithRoles.roles) do
                        table.insert(rolesArray, {
                            id = role.id,
                            role_id = role.role_id,
                            role_name = role.name or role.role_name,
                            name = role.name or role.role_name
                        })
                    end
                end

                -- Rebuild namespace context from DB
                local token_options = { roles = rolesArray }
                local default_ns = NamespaceQueries.getUserDefaultNamespace(db_user.id)
                local ns_membership
                if default_ns then
                    token_options.namespace = default_ns
                    ns_membership = NamespaceMemberQueries.findByUserAndNamespace(db_user.uuid, default_ns.id)
                    if ns_membership then
                        token_options.namespace_permissions = NamespaceMemberQueries.getPermissions(ns_membership.id)
                        local raw_is_owner = ns_membership.is_owner
                        token_options.is_namespace_owner = raw_is_owner == true or raw_is_owner == 't' or raw_is_owner == 1

                        local member_details = NamespaceMemberQueries.getWithDetails(ns_membership.id)
                        if member_details and member_details.roles then
                            local roles = member_details.roles
                            if type(roles) == "string" then
                                local ok_parse, parsed = pcall(cJson.decode, roles)
                                if ok_parse then roles = parsed end
                            end
                            if type(roles) == "table" and #roles > 0 then
                                token_options.namespace_role = roles[1].role_name
                            end
                        end
                    end
                end

                local new_jwt
                if token_options.namespace and ns_membership then
                    new_jwt = JWTHelper.generateNamespaceToken(userWithRoles, token_options.namespace, ns_membership, {
                        user_roles = rolesArray,
                        namespace_permissions = token_options.namespace_permissions
                    })
                else
                    new_jwt = JWTHelper.generateToken(userWithRoles, token_options)
                end

                -- Rotate the refresh token (revoke old, issue new in same family)
                local device_info = ngx.req.get_headers()["user-agent"]
                if device_info and #device_info > 255 then
                    device_info = device_info:sub(1, 255)
                end
                local ok_rotate, new_refresh = pcall(RefreshToken.rotate,
                    rt_data.id, rt_data.user_id, rt_data.family_id, device_info)

                -- Persist the rotated token on the same two transports
                -- as login: HttpOnly cookie for web, JSON body for
                -- mobile/CLI. Browser auto-replaces the old cookie
                -- (same name/path/domain) so the next refresh round
                -- carries the new value with no client work required.
                if ok_rotate and new_refresh then
                    pcall(AuthCookies.set, self, new_refresh)
                end

                return {
                    status = 200,
                    json = {
                        token = new_jwt,
                        refresh_token = ok_rotate and new_refresh or nil,
                        message = "Token refreshed successfully"
                    }
                }
            end
        end

        -- ── Legacy flow: JWT-based refresh (backward compatibility) ──
        local auth_header = self.req.headers["authorization"]
        if not auth_header then
            return {
                status = 401,
                json = { error = "Authorization header or refresh_token required" }
            }
        end

        local token = auth_header:match("Bearer%s+(.+)")
        if not token then
            return {
                status = 401,
                json = { error = "Invalid Authorization format" }
            }
        end

        local new_token = JWTHelper.refreshToken(token)
        if not new_token then
            return {
                status = 401,
                json = { error = "Invalid or expired token" }
            }
        end

        return {
            status = 200,
            json = {
                token = new_token,
                message = "Token refreshed successfully"
            }
        }
    end))

    -- =========================================================================
    -- Logout — revoke refresh token
    -- =========================================================================
    app:post("/auth/logout", function(self)
        local params = parse_json_body()
        local refresh_token_raw = params.refresh_token or self.params.refresh_token

        -- Cookie-based clients send the refresh token via HttpOnly
        -- cookie, not body. Read both so revocation works for every
        -- transport. Always clear the cookie regardless — browsers
        -- otherwise hold on to it forever and would silently
        -- "re-login" the user on the next refresh.
        if (not refresh_token_raw or refresh_token_raw == "") then
            refresh_token_raw = AuthCookies.read(self)
        end

        if refresh_token_raw and refresh_token_raw ~= "" then
            pcall(RefreshToken.revoke, refresh_token_raw)
        end

        pcall(AuthCookies.clear, self)

        return {
            status = 200,
            json = { message = "Logged out successfully" }
        }
    end)

    -- Get current user info (includes namespace)
    app:get("/auth/me", function(self)
        if not self.current_user then
            return {
                status = 401,
                json = { error = "Not authenticated" }
            }
        end

        -- Get full user data
        local user = UserQueries.show(self.current_user.uuid)
        if not user then
            return {
                status = 404,
                json = { error = "User not found" }
            }
        end

        -- Build roles array
        local rolesArray = {}
        if user.roles then
            for _, role in ipairs(user.roles) do
                table.insert(rolesArray, {
                    id = role.id,
                    role_id = role.role_id,
                    role_name = role.name or role.role_name,
                    name = role.name or role.role_name
                })
            end
        end

        -- Get user's namespaces
        local namespaces = NamespaceQueries.getForUser(user.uuid) or {}
        local namespacesArray = {}
        for _, ns in ipairs(namespaces) do
            table.insert(namespacesArray, {
                id = ns.id,
                uuid = ns.uuid,
                name = ns.name,
                slug = ns.slug,
                logo_url = ns.logo_url,
                is_owner = ns.is_owner,
                status = ns.status,
                member_status = ns.member_status
            })
        end

        -- Get current namespace from token
        local current_namespace = self.current_user.namespace

        return {
            status = 200,
            json = {
                user = {
                    id = user.internal_id,
                    uuid = user.uuid,
                    email = user.email,
                    username = user.username,
                    first_name = user.first_name or "",
                    last_name = user.last_name or "",
                    active = user.active,
                    created_at = user.created_at,
                    updated_at = user.updated_at,
                    roles = rolesArray
                },
                namespaces = namespacesArray,
                current_namespace = current_namespace
            }
        }
    end)
end
