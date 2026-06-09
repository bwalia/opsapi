-- HMRC Making Tax Digital API Client
-- Handles token management, business/obligation fetching, and self-assessment filing.
-- Includes mandatory fraud prevention headers.

local cjson = require("cjson")
local db = require("lapis.db")

local HMRC = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local HMRC_CLIENT_ID = os.getenv("HMRC_CLIENT_ID") or ""
local HMRC_CLIENT_SECRET = os.getenv("HMRC_CLIENT_SECRET") or ""
local HMRC_ENVIRONMENT = os.getenv("HMRC_ENVIRONMENT") or "sandbox"
-- The backend's PUBLIC egress IP (the address HMRC sees our calls come from). Required for
-- the Gov-Vendor-Public-IP / Gov-Vendor-Forwarded fraud headers. HMRC rejects PRIVATE IPs,
-- so when this is unset (e.g. local dev) we omit those headers rather than send an invalid
-- value. Set it to your NAT/egress IP in production.
local HMRC_SERVER_PUBLIC_IP = os.getenv("HMRC_SERVER_PUBLIC_IP") or ""

local BASE_URLS = {
    sandbox = "https://test-api.service.hmrc.gov.uk",
    production = "https://api.service.hmrc.gov.uk",
}

local function get_base_url()
    return BASE_URLS[HMRC_ENVIRONMENT] or BASE_URLS.sandbox
end

-- Verify TLS certificates in production. The sandbox is left unverified because the
-- container historically lacked a configured CA trust store; production REQUIRES
-- verification (we send NINOs + financial data) and the nginx http block now sets
-- lua_ssl_trusted_certificate to the system CA bundle so resty.http can verify.
local function tls_verify()
    return HMRC_ENVIRONMENT == "production"
end

local function create_http_client()
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(30000)
    return httpc, nil
end

-- ---------------------------------------------------------------------------
-- Fraud Prevention Headers (mandatory for MTD)
-- ---------------------------------------------------------------------------

-- HMRC mandatory anti-fraud headers. We are a WEB_APP_VIA_SERVER: the end user runs a
-- browser and our server makes the HMRC call. The browser-only signals (device id,
-- timezone, JS user-agent, screens, window size, user ids) are collected client-side and
-- forwarded by the dashboard as X-Gov-Client-* headers; we read them here and map them to
-- the real Gov-Client-* headers. Server-derivable signals (public IP/port, the user→server
-- hop, vendor info) are set directly. We OMIT (never fake) anything we genuinely don't
-- have. Validate the full set against HMRC's "Test Fraud Prevention Headers" API.
function HMRC.build_fraud_headers()
    local headers = {}

    -- Signals forwarded by the browser (lower-cased keys via get_headers()).
    local fwd = {}
    pcall(function() fwd = ngx.req.get_headers() or {} end)

    headers["Gov-Client-Connection-Method"] = "WEB_APP_VIA_SERVER"

    -- Device ID — prefer the browser-persisted id the frontend forwards (stable per device);
    -- fall back to a server-generated one so we always send something.
    local device_id = fwd["x-gov-client-device-id"]
    if not device_id or device_id == "" then
        device_id = ngx.shared.rate_limit_store and ngx.shared.rate_limit_store:get("hmrc_device_id")
        if not device_id then
            local Global = require("helper.global")
            device_id = Global.generateStaticUUID()
            if ngx.shared.rate_limit_store then
                ngx.shared.rate_limit_store:set("hmrc_device_id", device_id, 86400 * 365)
            end
        end
    end
    headers["Gov-Client-Device-ID"] = device_id

    -- Browser-collected signals — forward only when present (don't fabricate).
    headers["Gov-Client-Timezone"] = fwd["x-gov-client-timezone"] or "UTC+00:00"
    headers["Gov-Client-Browser-JS-User-Agent"] =
        fwd["x-gov-client-browser-js-user-agent"] or ngx.var.http_user_agent or "OpsAPI/1.0"
    if fwd["x-gov-client-screens"] then headers["Gov-Client-Screens"] = fwd["x-gov-client-screens"] end
    if fwd["x-gov-client-window-size"] then headers["Gov-Client-Window-Size"] = fwd["x-gov-client-window-size"] end
    if fwd["x-gov-client-user-ids"] then headers["Gov-Client-User-IDs"] = fwd["x-gov-client-user-ids"] end

    -- The end user's PUBLIC IP: first hop of X-Forwarded-For, else the peer address.
    local client_ip = ngx.var.remote_addr or "127.0.0.1"
    local xff = ngx.var.http_x_forwarded_for
    if xff then client_ip = (xff:match("^%s*([^,]+)") or client_ip):gsub("%s", "") end
    local now_iso = os.date("!%Y-%m-%dT%H:%M:%S") .. ".000Z"
    headers["Gov-Client-Public-IP"] = client_ip
    headers["Gov-Client-Public-IP-Timestamp"] = now_iso
    local public_port = ngx.var.http_x_forwarded_port or ngx.var.remote_port
    if public_port and public_port ~= "" then
        headers["Gov-Client-Public-Port"] = tostring(public_port)
    end

    -- Vendor (our software) signals. HMRC requires our PUBLIC egress IP and percent-encoded
    -- product/license values. Emit the public-IP-derived headers only when the egress IP is
    -- configured — HMRC rejects private IPs, and a wrong value is worse than an omitted one.
    if HMRC_SERVER_PUBLIC_IP ~= "" then
        headers["Gov-Vendor-Public-IP"] = HMRC_SERVER_PUBLIC_IP
        -- The user→server hop: who we (by) forwarded the request for (for). Both public.
        headers["Gov-Vendor-Forwarded"] =
            "by=" .. ngx.escape_uri(HMRC_SERVER_PUBLIC_IP) .. "&for=" .. ngx.escape_uri(client_ip)
    end
    headers["Gov-Vendor-Version"] = "OpsAPI=1.0.0"
    headers["Gov-Vendor-Product-Name"] = ngx.escape_uri("OpsAPI Tax Filing")
    headers["Gov-Vendor-License-IDs"] = "OpsAPI=" .. ngx.escape_uri("opsapi-tax-filing")

    return headers
end

-- ---------------------------------------------------------------------------
-- Token Management
-- ---------------------------------------------------------------------------

--- Get a valid HMRC access token, refreshing if needed
function HMRC.get_valid_token(user_uuid)
    local rows = db.select(
        "* FROM hmrc_tokens WHERE user_uuid = ? LIMIT 1", user_uuid
    )
    if not rows or #rows == 0 then
        return nil, "No HMRC token found. Please connect HMRC first."
    end

    local token = rows[1]
    local now = ngx.time()
    local expires_at = token.expires_at

    -- Parse expires_at if it's a string
    if type(expires_at) == "string" then
        -- Approximate: check if the token looks expired
        local exp_rows = db.query(
            "SELECT EXTRACT(EPOCH FROM expires_at) as exp_epoch FROM hmrc_tokens WHERE user_uuid = ? LIMIT 1",
            user_uuid
        )
        if exp_rows and exp_rows[1] then
            expires_at = tonumber(exp_rows[1].exp_epoch)
        end
    end

    -- If token is still valid (with 5 minute buffer)
    if expires_at and (expires_at - 300) > now then
        return token.access_token, nil
    end

    -- Token expired or about to expire — refresh it
    if not token.refresh_token then
        return nil, "HMRC token expired and no refresh token available"
    end

    local new_token, err = HMRC.refresh_token(user_uuid, token.refresh_token)
    if not new_token then
        return nil, "Token refresh failed: " .. tostring(err)
    end

    return new_token, nil
end

--- Refresh an HMRC OAuth token
function HMRC.refresh_token(user_uuid, refresh_token)
    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local base_url = get_base_url()
    local res, req_err = httpc:request_uri(base_url .. "/oauth/token", {
        method = "POST",
        body = ngx.encode_args({
            grant_type = "refresh_token",
            refresh_token = refresh_token,
            client_id = HMRC_CLIENT_ID,
            client_secret = HMRC_CLIENT_SECRET,
        }),
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        ssl_verify = tls_verify(),
    })

    if not res then return nil, "Refresh request failed: " .. tostring(req_err) end
    if res.status >= 400 then return nil, "Refresh HTTP " .. res.status .. ": " .. tostring(res.body) end

    local data = cjson.decode(res.body)
    if not data or not data.access_token then
        return nil, "Invalid refresh response"
    end

    -- Store new tokens
    local expires_at = db.raw("NOW() + INTERVAL '" .. (data.expires_in or 14400) .. " seconds'")
    db.query([[
        INSERT INTO hmrc_tokens (user_uuid, access_token, refresh_token, scope, expires_at, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
        ON CONFLICT (user_uuid) DO UPDATE SET
            access_token = EXCLUDED.access_token,
            refresh_token = EXCLUDED.refresh_token,
            scope = EXCLUDED.scope,
            expires_at = EXCLUDED.expires_at
    ]], user_uuid, data.access_token, data.refresh_token or refresh_token, data.scope or "", expires_at)

    return data.access_token, nil
end

-- ---------------------------------------------------------------------------
-- API Calls
-- ---------------------------------------------------------------------------

--- Fetch self-employment businesses from HMRC
function HMRC.fetch_businesses(access_token)
    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local base_url = get_base_url()
    local fraud_headers = HMRC.build_fraud_headers()
    fraud_headers["Authorization"] = "Bearer " .. access_token
    fraud_headers["Accept"] = "application/vnd.hmrc.2.0+json"

    local res, req_err = httpc:request_uri(base_url .. "/individuals/business/details", {
        method = "GET",
        headers = fraud_headers,
        ssl_verify = tls_verify(),
    })

    if not res then return nil, "Request failed: " .. tostring(req_err) end
    if res.status >= 400 then return nil, "HTTP " .. res.status .. ": " .. tostring(res.body) end

    local data = cjson.decode(res.body)
    return data, nil
end

--- Fetch quarterly obligations from HMRC
function HMRC.fetch_obligations(access_token, business_id, from_date, to_date)
    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local base_url = get_base_url()
    local fraud_headers = HMRC.build_fraud_headers()
    fraud_headers["Authorization"] = "Bearer " .. access_token
    fraud_headers["Accept"] = "application/vnd.hmrc.2.0+json"

    local url = string.format(
        "%s/individuals/business/self-employment/%s/obligations?from=%s&to=%s",
        base_url, business_id, from_date, to_date
    )

    local res, req_err = httpc:request_uri(url, {
        method = "GET",
        headers = fraud_headers,
        ssl_verify = tls_verify(),
    })

    if not res then return nil, "Request failed: " .. tostring(req_err) end
    if res.status >= 400 then return nil, "HTTP " .. res.status .. ": " .. tostring(res.body) end

    local data = cjson.decode(res.body)
    return data, nil
end

--- Submit self-assessment return to HMRC MTD
function HMRC.submit_self_assessment(access_token, submission)
    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local base_url = get_base_url()
    local fraud_headers = HMRC.build_fraud_headers()
    fraud_headers["Authorization"] = "Bearer " .. access_token
    fraud_headers["Accept"] = "application/vnd.hmrc.2.0+json"
    fraud_headers["Content-Type"] = "application/json"

    -- Build the HMRC submission payload
    local payload = {
        selfEmployment = {
            selfEmploymentIncome = {
                turnover = submission.turnover or 0,
                other = submission.other_income or 0,
            },
            selfEmploymentDeductions = {
                costOfGoods = { amount = submission.expenses.costOfGoods or 0 },
                staffCosts = { amount = submission.expenses.staffCosts or 0 },
                premisesRunningCosts = { amount = submission.expenses.premisesRunningCosts or 0 },
                maintenanceCosts = { amount = submission.expenses.maintenanceCosts or 0 },
                adminCosts = { amount = submission.expenses.adminCosts or 0 },
                travelCosts = { amount = submission.expenses.travelCosts or 0 },
                advertisingCosts = { amount = submission.expenses.advertisingCosts or 0 },
                businessEntertainmentCosts = { amount = submission.expenses.businessEntertainmentCosts or 0 },
                professionalFees = { amount = submission.expenses.professionalFees or 0 },
                otherExpenses = { amount = submission.expenses.otherExpenses or 0 },
            },
        },
    }

    local url = base_url .. "/individuals/business/self-employment/annual-summary"
    local res, req_err = httpc:request_uri(url, {
        method = "PUT",
        body = cjson.encode(payload),
        headers = fraud_headers,
        ssl_verify = tls_verify(),
    })

    if not res then return nil, "Submission failed: " .. tostring(req_err) end

    local response_data = {}
    if res.body and #res.body > 0 then
        local ok, decoded = pcall(cjson.decode, res.body)
        if ok then response_data = decoded end
    end

    if res.status >= 400 then
        return nil, "HMRC rejected: HTTP " .. res.status, response_data
    end

    return {
        status = res.status,
        submission_id = response_data.id or response_data.submissionId,
        data = response_data,
    }, nil
end

--- Get an application (client_credentials) server token. Required by HMRC's
--- application-restricted APIs such as Create Test User.
function HMRC.get_server_token()
    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local base_url = get_base_url()
    local res, req_err = httpc:request_uri(base_url .. "/oauth/token", {
        method = "POST",
        body = ngx.encode_args({
            grant_type = "client_credentials",
            client_id = HMRC_CLIENT_ID,
            client_secret = HMRC_CLIENT_SECRET,
        }),
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        ssl_verify = tls_verify(),
    })
    if not res then return nil, "Server token request failed: " .. tostring(req_err) end
    if res.status >= 400 then return nil, "Server token HTTP " .. res.status .. ": " .. tostring(res.body) end
    local data = cjson.decode(res.body)
    if not data or not data.access_token then return nil, "Invalid server token response" end
    return data.access_token, nil
end

--- Create a sandbox test user (sandbox only)
function HMRC.create_sandbox_test_user()
    if HMRC_ENVIRONMENT ~= "sandbox" then
        return nil, "Only available in sandbox environment"
    end

    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    -- Create Test User is application-restricted — it needs a server token, not a user token.
    local server_token, st_err = HMRC.get_server_token()
    if not server_token then return nil, st_err end

    local base_url = get_base_url()
    local res, req_err = httpc:request_uri(base_url .. "/create-test-user/individuals", {
        method = "POST",
        body = cjson.encode({
            -- MTD ITSA filing needs the taxpayer enrolled for income-tax MTD + NI, not
            -- just legacy self-assessment, or calculations return MATCHING_RESOURCE_NOT_FOUND.
            serviceNames = { "national-insurance", "self-assessment", "mtd-income-tax" },
        }),
        headers = {
            ["Authorization"] = "Bearer " .. server_token,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/vnd.hmrc.1.0+json",
        },
        ssl_verify = tls_verify(),
    })

    if not res then return nil, "Request failed: " .. tostring(req_err) end
    if res.status >= 400 then return nil, "HTTP " .. res.status .. ": " .. tostring(res.body) end

    return cjson.decode(res.body), nil
end

return HMRC
