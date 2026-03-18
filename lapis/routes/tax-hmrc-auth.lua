--[[
    HMRC OAuth Routes (Tax Copilot feature)

    Implements the HMRC Making Tax Digital OAuth 2.0 flow.
    Mirrors the existing Google OAuth pattern in routes/auth.lua.

    Flow:
      1. GET /auth/hmrc/initiate?statement_id=<uuid>
             — Requires JWT auth. Returns {auth_url} for frontend to redirect to.
      2. HMRC redirects browser to:
         GET /auth/hmrc/callback?code=<code>&state=<state>
             — Public route. Validates state, exchanges code for token,
               stores in hmrc_tokens table, redirects to frontend /file page.

    State parameter: HMAC-signed JSON payload (no server-side storage needed).
      Format: base64(json({uuid, sid, ts})) + "." + base64(hmac_sha1(jwt_secret, prefix))
]]

local cjson   = require("cjson")
local http    = require("resty.http")
local Global  = require("helper.global")
local RateLimit = require("middleware.rate-limit")
local HMRCTokenQueries = require("queries.HMRCTokenQueries")

local HMRC_LIMIT = { rate = 10, window = 60, prefix = "auth:hmrc" }

-- ---------------------------------------------------------------------------
-- State helpers (HMAC-signed, no DB required)
-- ---------------------------------------------------------------------------

local function sign_state(data)
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
    if not secret then
        return nil, "JWT_SECRET_KEY not set"
    end
    local payload_b64 = ngx.encode_base64(cjson.encode(data))
    local sig_b64     = ngx.encode_base64(ngx.hmac_sha1(secret, payload_b64))
    return payload_b64 .. "." .. sig_b64
end

local function verify_state(state)
    if not state then return nil end
    -- Split on first literal "." (base64 chars are A-Za-z0-9+/= — no dots)
    local sep = state:find(".", 1, true)
    if not sep then return nil end

    local payload_b64 = state:sub(1, sep - 1)
    local sig_b64     = state:sub(sep + 1)

    -- Verify HMAC
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
    if not secret then return nil end
    local expected_sig = ngx.encode_base64(ngx.hmac_sha1(secret, payload_b64))
    if sig_b64 ~= expected_sig then
        ngx.log(ngx.WARN, "[HMRC] State HMAC mismatch — possible CSRF attempt")
        return nil
    end

    -- Decode payload
    local ok, data = pcall(cjson.decode, ngx.decode_base64(payload_b64))
    if not ok or type(data) ~= "table" then return nil end

    -- Check 10-minute TTL
    if ngx.time() - (data.ts or 0) > 600 then
        ngx.log(ngx.WARN, "[HMRC] OAuth state expired")
        return nil
    end

    return data
end

-- ---------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------

return function(app)

    -- Ensure DB table exists on first load
    local ok, err = pcall(HMRCTokenQueries.ensureTable)
    if not ok then
        ngx.log(ngx.ERR, "[HMRC] Failed to ensure hmrc_tokens table: ", tostring(err))
    end

    -- -----------------------------------------------------------------------
    -- GET /auth/hmrc/initiate?statement_id=<uuid>
    -- Requires: JWT auth (handled by before_filter)
    -- Returns:  JSON { auth_url: "https://test-www.tax.service.gov.uk/oauth/..." }
    -- -----------------------------------------------------------------------
    app:get("/auth/hmrc/initiate", RateLimit.wrap(HMRC_LIMIT, function(self)
        local client_id    = Global.getEnvVar("HMRC_CLIENT_ID")
        local redirect_uri = Global.getEnvVar("HMRC_REDIRECT_URI")
        local environment  = Global.getEnvVar("HMRC_ENVIRONMENT") or "sandbox"

        if not client_id or not redirect_uri then
            return {
                status = 503,
                json   = { error = "HMRC OAuth not configured (HMRC_CLIENT_ID / HMRC_REDIRECT_URI missing)" }
            }
        end

        -- statement_id is optional — when connecting from settings/profile page
        -- it won't be provided. The callback uses it to redirect back appropriately.
        local statement_id = self.params.statement_id
        local source = self.params.source or "file"  -- "file" or "settings"

        -- current_user is set by the before_filter auth middleware
        local user_uuid = self.current_user and (self.current_user.uuid or self.current_user.id)
        if not user_uuid then
            return { status = 401, json = { error = "Not authenticated" } }
        end

        -- Build HMAC-signed state
        local state, state_err = sign_state({
            uuid = user_uuid,
            sid  = statement_id or "",
            src  = source,
            ts   = ngx.time(),
        })
        if not state then
            ngx.log(ngx.ERR, "[HMRC] Failed to sign state: ", tostring(state_err))
            return { status = 500, json = { error = "Failed to generate auth state" } }
        end

        -- Choose auth URL based on environment
        local auth_base
        if environment == "production" then
            auth_base = "https://www.tax.service.gov.uk/oauth/authorize"
        else
            auth_base = "https://test-www.tax.service.gov.uk/oauth/authorize"
        end

        local auth_url = string.format(
            "%s?client_id=%s&redirect_uri=%s&response_type=code&scope=%s&state=%s",
            auth_base,
            ngx.escape_uri(client_id),
            ngx.escape_uri(redirect_uri),
            ngx.escape_uri("read:self-assessment write:self-assessment"),
            ngx.escape_uri(state)
        )

        ngx.log(ngx.NOTICE, "[HMRC] Initiated OAuth for user=", user_uuid, " statement=", statement_id)

        return {
            status = 200,
            json   = { auth_url = auth_url }
        }
    end))

    -- -----------------------------------------------------------------------
    -- GET /auth/hmrc/callback?code=<code>&state=<state>[&error=<err>]
    -- Public route (registered in before_filter whitelist in app.lua).
    -- Called by HMRC after user authenticates.
    -- -----------------------------------------------------------------------
    app:get("/auth/hmrc/callback", RateLimit.wrap(HMRC_LIMIT, function(self)
        local frontend_url = Global.getEnvVar("APP_BASE_URL") or "http://localhost"
        local environment  = Global.getEnvVar("HMRC_ENVIRONMENT") or "sandbox"

        -- ── OAuth error from HMRC ──
        local oauth_error = self.params.error
        if oauth_error then
            ngx.log(ngx.WARN, "[HMRC] OAuth error from HMRC: ", oauth_error)
            return { redirect_to = frontend_url .. "/file?hmrc_error=" .. ngx.escape_uri(oauth_error) }
        end

        local code  = self.params.code
        local state = self.params.state

        if not code or not state then
            ngx.log(ngx.WARN, "[HMRC] Callback missing code or state")
            return { redirect_to = frontend_url .. "/file?hmrc_error=missing_params" }
        end

        -- ── Validate HMAC state ──
        local state_data = verify_state(state)
        if not state_data then
            return { redirect_to = frontend_url .. "/file?hmrc_error=invalid_state" }
        end

        local user_uuid    = state_data.uuid
        local statement_id = state_data.sid
        local source       = state_data.src or "file"

        -- Build redirect base depending on where the user started
        local function error_redirect(err_code)
            if source == "settings" then
                return { redirect_to = frontend_url .. "/settings?hmrc_error=" .. ngx.escape_uri(err_code) }
            end
            return {
                redirect_to = frontend_url .. "/file?statement=" .. (statement_id or "") ..
                              "&hmrc_error=" .. ngx.escape_uri(err_code)
            }
        end

        -- ── Exchange code for token ──
        local client_id     = Global.getEnvVar("HMRC_CLIENT_ID")
        local client_secret = Global.getEnvVar("HMRC_CLIENT_SECRET")
        local redirect_uri  = Global.getEnvVar("HMRC_REDIRECT_URI")

        local token_url
        if environment == "production" then
            token_url = "https://api.service.hmrc.gov.uk/oauth/token"
        else
            token_url = "https://test-api.service.hmrc.gov.uk/oauth/token"
        end

        local httpc = http.new()
        httpc:set_timeout(30000)

        local token_res, token_err = httpc:request_uri(token_url, {
            method = "POST",
            body   = ngx.encode_args({
                grant_type    = "authorization_code",
                code          = code,
                client_id     = client_id,
                client_secret = client_secret,
                redirect_uri  = redirect_uri,
            }),
            headers    = { ["Content-Type"] = "application/x-www-form-urlencoded" },
            ssl_verify = false,  -- required for sandbox; production uses valid cert
        })

        if not token_res then
            ngx.log(ngx.ERR, "[HMRC] Token exchange HTTP error: ", tostring(token_err))
            return error_redirect("token_exchange_failed")
        end

        if token_res.status ~= 200 then
            ngx.log(ngx.ERR, "[HMRC] Token exchange failed HTTP ", token_res.status, ": ", token_res.body)
            return error_redirect("token_exchange_failed")
        end

        local ok, token_data = pcall(cjson.decode, token_res.body)
        if not ok or not token_data or not token_data.access_token then
            ngx.log(ngx.ERR, "[HMRC] Token response missing access_token")
            return error_redirect("token_exchange_failed")
        end

        -- ── Store token in DB ──
        local expires_in = tonumber(token_data.expires_in) or 14400  -- default 4h
        local store_ok, store_err = pcall(
            HMRCTokenQueries.upsert,
            user_uuid,
            token_data.access_token,
            token_data.refresh_token,
            token_data.scope,
            expires_in
        )

        if not store_ok then
            ngx.log(ngx.ERR, "[HMRC] Failed to store token: ", tostring(store_err))
            return error_redirect("token_store_failed")
        end

        ngx.log(ngx.NOTICE, "[HMRC] OAuth successful for user=", user_uuid,
                             " statement=", statement_id, " source=", source, " expires_in=", expires_in)

        -- ── Redirect to frontend — no token in URL ──
        if source == "settings" then
            return {
                redirect_to = frontend_url .. "/settings?hmrc_connected=true"
            }
        end
        return {
            redirect_to = frontend_url .. "/file?statement=" .. (statement_id or "") ..
                          "&hmrc_connected=true"
        }
    end))

    -- -----------------------------------------------------------------------
    -- DELETE /auth/hmrc/disconnect
    -- Requires: JWT auth. Removes stored HMRC token for the current user.
    -- -----------------------------------------------------------------------
    app:delete("/auth/hmrc/disconnect", function(self)
        local user_uuid = self.current_user and (self.current_user.uuid or self.current_user.id)
        if not user_uuid then
            return { status = 401, json = { error = "Not authenticated" } }
        end

        local ok, err = pcall(HMRCTokenQueries.delete, user_uuid)
        if not ok then
            ngx.log(ngx.ERR, "[HMRC] Failed to delete token: ", tostring(err))
            return { status = 500, json = { error = "Failed to disconnect" } }
        end

        ngx.log(ngx.NOTICE, "[HMRC] Disconnected HMRC for user=", user_uuid)
        return { status = 200, json = { message = "HMRC disconnected successfully" } }
    end)

end
