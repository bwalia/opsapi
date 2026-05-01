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

local BASE_URLS = {
    sandbox = "https://test-api.service.hmrc.gov.uk",
    production = "https://api.service.hmrc.gov.uk",
}

local function get_base_url()
    return BASE_URLS[HMRC_ENVIRONMENT] or BASE_URLS.sandbox
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

function HMRC.build_fraud_headers()
    local headers = {}

    headers["Gov-Client-Connection-Method"] = "WEB_APP_VIA_SERVER"

    -- Device ID — generate and reuse per server instance
    local device_id = ngx.shared.rate_limit_store and ngx.shared.rate_limit_store:get("hmrc_device_id")
    if not device_id then
        local Global = require("helper.global")
        device_id = Global.generateStaticUUID()
        if ngx.shared.rate_limit_store then
            ngx.shared.rate_limit_store:set("hmrc_device_id", device_id, 86400 * 365)
        end
    end
    headers["Gov-Client-Device-ID"] = device_id

    -- Client timezone
    headers["Gov-Client-Timezone"] = "UTC+" .. string.format("%+03d:00", 0)

    -- Client IP (from request)
    local client_ip = ngx.var.remote_addr or "127.0.0.1"
    local xff = ngx.var.http_x_forwarded_for
    if xff then
        client_ip = xff:match("^([^,]+)")
    end
    headers["Gov-Client-Local-IPs"] = client_ip

    -- User agent
    headers["Gov-Client-User-Agent"] = ngx.var.http_user_agent or "OpsAPI/1.0"

    -- Vendor info
    headers["Gov-Vendor-Version"] = "OpsAPI=1.0.0"
    headers["Gov-Vendor-Product-Name"] = "OpsAPI Tax Filing"

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
        ssl_verify = false,
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
        ssl_verify = false,
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
        ssl_verify = false,
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
        ssl_verify = false,
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

--- Create a sandbox test user (sandbox only)
function HMRC.create_sandbox_test_user()
    if HMRC_ENVIRONMENT ~= "sandbox" then
        return nil, "Only available in sandbox environment"
    end

    local httpc, err = create_http_client()
    if not httpc then return nil, err end

    local base_url = get_base_url()
    local res, req_err = httpc:request_uri(base_url .. "/create-test-user/individuals", {
        method = "POST",
        body = cjson.encode({
            serviceNames = { "self-assessment" },
        }),
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/vnd.hmrc.1.0+json",
        },
        ssl_verify = false,
    })

    if not res then return nil, "Request failed: " .. tostring(req_err) end
    if res.status >= 400 then return nil, "HTTP " .. res.status .. ": " .. tostring(res.body) end

    return cjson.decode(res.body), nil
end

return HMRC
