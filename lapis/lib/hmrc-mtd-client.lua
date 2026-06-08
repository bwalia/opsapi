-- HMRC MTD ITSA client (modern Self Assessment flow)
-- Implements the proven diy-tax-return-uk sequence in Lua:
--   list businesses (v2) → submit cumulative period (v5) → trigger calculation (v8)
--   → retrieve calculation (v8, polled). Plus sandbox test-support provisioning.
--
-- Reuses helper.hmrc for the mandatory fraud-prevention headers. NO final declaration
-- here — this client only powers the *preview* (in-year) calculation. Filing the return
-- (intent-to-finalise + final-declaration) is a deliberate later phase.

local cjson = require("cjson")
local HMRC = require("helper.hmrc")

local Client = {}

local BASE_URLS = {
    sandbox = "https://test-api.service.hmrc.gov.uk",
    production = "https://api.service.hmrc.gov.uk",
}

local function environment()
    return os.getenv("HMRC_ENVIRONMENT") or "sandbox"
end

function Client.is_sandbox()
    return environment() ~= "production"
end

local function base_url()
    return BASE_URLS[environment()] or BASE_URLS.sandbox
end

local function http_client()
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(40000)
    return httpc, nil
end

-- Build request headers: mandatory fraud headers + auth + the versioned Accept header.
-- `accept_version` is the MTD API version (e.g. "5.0"). `test_scenario` adds the
-- sandbox Gov-Test-Scenario header (ignored by production).
local function headers(token, accept_version, opts)
    opts = opts or {}
    local h = HMRC.build_fraud_headers()
    h["Authorization"] = "Bearer " .. token
    h["Accept"] = "application/vnd.hmrc." .. accept_version .. "+json"
    if opts.json_body then h["Content-Type"] = "application/json" end
    if opts.test_scenario and Client.is_sandbox() then
        h["Gov-Test-Scenario"] = opts.test_scenario
    end
    return h
end

-- Decode a JSON body defensively; returns {} on empty/garbage.
local function decode(body)
    if not body or body == "" then return {} end
    local ok, t = pcall(cjson.decode, body)
    if ok and type(t) == "table" then return t end
    return {}
end

-- ---------------------------------------------------------------------------
-- Business details (v2): list the taxpayer's businesses
-- ---------------------------------------------------------------------------
function Client.list_businesses(token, nino)
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local res, rerr = httpc:request_uri(
        base_url() .. "/individuals/business/details/" .. nino .. "/list",
        { method = "GET", headers = headers(token, "2.0"), ssl_verify = false })
    if not res then return nil, "list_businesses request failed: " .. tostring(rerr) end
    if res.status >= 400 then
        return nil, "HTTP " .. res.status, decode(res.body)
    end
    return decode(res.body), nil
end

-- Find the first self-employment business id from a list response.
function Client.first_self_employment(list_data)
    local list = list_data and (list_data.listOfBusinesses or list_data.businesses)
    if type(list) ~= "table" then return nil end
    for _, b in ipairs(list) do
        if b.typeOfBusiness == "self-employment" and b.businessId then
            return b.businessId
        end
    end
    -- Fall back to the first business with an id at all.
    if list[1] and list[1].businessId then return list[1].businessId end
    return nil
end

-- ---------------------------------------------------------------------------
-- Obligations (MTD) v3: which income-tax periods are open / due to file
-- ---------------------------------------------------------------------------
-- @param opts table { from, to (YYYY-MM-DD, required), status? ("Open"/"Fulfilled"),
--                     test_scenario? }
-- @return decoded body { obligations = { { businessId, typeOfBusiness,
--           obligationDetails = { { periodStartDate, periodEndDate, dueDate, status,
--           periodKey } } } } } or nil, err, hmrc_body
function Client.list_obligations(token, nino, opts)
    opts = opts or {}
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local q = {}
    if opts.from and opts.from ~= "" then table.insert(q, "from=" .. opts.from) end
    if opts.to and opts.to ~= "" then table.insert(q, "to=" .. opts.to) end
    if opts.status and opts.status ~= "" then table.insert(q, "status=" .. opts.status) end
    local url = string.format("%s/obligations/details/%s/income-and-expenditure", base_url(), nino)
    if #q > 0 then url = url .. "?" .. table.concat(q, "&") end
    local res, rerr = httpc:request_uri(url, {
        method = "GET",
        headers = headers(token, "3.0", { test_scenario = opts.test_scenario }),
        ssl_verify = false,
    })
    if not res then return nil, "list_obligations request failed: " .. tostring(rerr) end
    if res.status >= 400 then return nil, "HTTP " .. res.status, decode(res.body) end
    return decode(res.body), nil
end

-- ---------------------------------------------------------------------------
-- Self-employment cumulative period (v5): the SA103 income/expense submission
-- ---------------------------------------------------------------------------
-- @param body table { periodDates, periodIncome?, periodExpenses?, periodDisallowableExpenses? }
function Client.submit_cumulative(token, nino, business_id, tax_year, body)
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local url = string.format(
        "%s/individuals/business/self-employment/%s/%s/cumulative/%s",
        base_url(), nino, business_id, tax_year)
    local res, rerr = httpc:request_uri(url, {
        method = "PUT",
        body = cjson.encode(body),
        headers = headers(token, "5.0", { json_body = true, test_scenario = "STATEFUL" }),
        ssl_verify = false,
    })
    if not res then return nil, "submit_cumulative request failed: " .. tostring(rerr) end
    if res.status >= 400 then
        return nil, "HTTP " .. res.status, decode(res.body)
    end
    return { status = res.status }, nil  -- 204 No Content on success
end

-- ---------------------------------------------------------------------------
-- Individual Calculations (v8): trigger + retrieve
-- ---------------------------------------------------------------------------
-- calc_type ∈ {"in-year", "intent-to-finalise", "intent-to-amend"}. Preview uses in-year.
function Client.trigger_calculation(token, nino, tax_year, calc_type)
    calc_type = calc_type or "in-year"
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local url = string.format(
        "%s/individuals/calculations/%s/self-assessment/%s/trigger/%s",
        base_url(), nino, tax_year, calc_type)
    local res, rerr = httpc:request_uri(url, {
        method = "POST",
        headers = headers(token, "8.0"),
        ssl_verify = false,
    })
    if not res then return nil, "trigger_calculation request failed: " .. tostring(rerr) end
    if res.status >= 400 then
        return nil, "HTTP " .. res.status, decode(res.body)
    end
    local data = decode(res.body)
    return data.calculationId, nil
end

-- Retrieve a calculation once. Returns ready=true with data, ready=false if still
-- calculating (HMRC returns 404 while in progress — that is NOT an error).
function Client.get_calculation(token, nino, tax_year, calc_id)
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local url = string.format(
        "%s/individuals/calculations/%s/self-assessment/%s/%s",
        base_url(), nino, tax_year, calc_id)
    local res, rerr = httpc:request_uri(url, {
        method = "GET",
        headers = headers(token, "8.0", { test_scenario = "DYNAMIC" }),
        ssl_verify = false,
    })
    if not res then return nil, "get_calculation request failed: " .. tostring(rerr) end
    if res.status == 404 then
        return { ready = false }, nil  -- still calculating
    end
    if res.status >= 400 then
        return nil, "HTTP " .. res.status, decode(res.body)
    end
    return { ready = true, data = decode(res.body),
             correlation_id = res.headers and res.headers["X-CorrelationId"] }, nil
end

-- Poll until the calculation is ready, with backoff (5,8,13,21,34s ≈ 80s worst case).
function Client.poll_calculation(token, nino, tax_year, calc_id)
    local delays = { 5, 8, 13, 21, 34 }
    local attempts = 0
    -- One immediate try, then backoff.
    local result, err, hmrc_body = Client.get_calculation(token, nino, tax_year, calc_id)
    attempts = attempts + 1
    if not result then return nil, err, hmrc_body, attempts end
    if result.ready then result.attempts = attempts; return result, nil, nil, attempts end

    for _, d in ipairs(delays) do
        ngx.sleep(d)
        result, err, hmrc_body = Client.get_calculation(token, nino, tax_year, calc_id)
        attempts = attempts + 1
        if not result then return nil, err, hmrc_body, attempts end
        if result.ready then result.attempts = attempts; return result, nil, nil, attempts end
    end
    return nil, "calculation_timeout", nil, attempts
end

-- Pull the headline figures out of a retrieved calculation. Sandbox returns the fixed
-- placeholder -99999999999.99 for the total — flag that so the UI can disclaim it.
function Client.parse_figures(calc_data)
    local tc = (calc_data and calc_data.taxCalculation) or {}
    local nics = tc.nics or {}
    local total = tonumber(tc.totalIncomeTaxAndNicsDue)
    return {
        total_income_tax_and_nics_due = total,
        total_taxable_income = tonumber(tc.totalTaxableIncome),
        income_tax_charged = tonumber(tc.incomeTaxCharged),
        personal_allowance = tonumber(tc.personalAllowance),
        class2_nics = nics.class2Nics and tonumber(nics.class2Nics.amount) or nil,
        class4_nics = nics.class4Nics and tonumber(nics.class4Nics.totalAmount) or nil,
        is_sandbox_placeholder = (total ~= nil and total <= -99999999999),
    }
end

-- ---------------------------------------------------------------------------
-- Sandbox test-support: provision a stateful test business + MTD ITSA status so
-- cumulative submissions and calculations work for the current tax year. Sandbox only.
-- ---------------------------------------------------------------------------
function Client.create_test_business(token, nino, params)
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local res, rerr = httpc:request_uri(
        base_url() .. "/individuals/self-assessment-test-support/business/" .. nino, {
            method = "POST",
            body = cjson.encode(params),
            headers = headers(token, "1.0", { json_body = true }),
            ssl_verify = false,
        })
    if not res then return nil, "create_test_business request failed: " .. tostring(rerr) end
    if res.status >= 400 then return nil, "HTTP " .. res.status, decode(res.body) end
    local data = decode(res.body)
    return data.businessId, nil
end

function Client.set_itsa_status(token, nino, tax_year, details)
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local res, rerr = httpc:request_uri(
        base_url() .. "/individuals/self-assessment-test-support/itsa-status/" .. nino .. "/" .. tax_year, {
            method = "POST",
            body = cjson.encode({ itsaStatusDetails = details }),
            headers = headers(token, "1.0", { json_body = true }),
            ssl_verify = false,
        })
    if not res then return nil, "set_itsa_status request failed: " .. tostring(rerr) end
    if res.status >= 400 then return nil, "HTTP " .. res.status, decode(res.body) end
    return true, nil
end

return Client
