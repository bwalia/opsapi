-- HMRC VAT (MTD) API v1.0 client (VAT plan phase 4, docs/plans/VAT_MTD.md).
--
--   obligations   GET  /organisations/vat/{vrn}/obligations?from&to&status
--   submit        POST /organisations/vat/{vrn}/returns        (BINDING: files the return)
--   view return   GET  /organisations/vat/{vrn}/returns/{periodKey}
--   liabilities   GET  /organisations/vat/{vrn}/liabilities?from&to
--   payments      GET  /organisations/vat/{vrn}/payments?from&to
--   penalties     GET  /organisations/vat/{vrn}/penalties
--
-- Needs the HMRC application subscribed to "VAT (MTD)" and a user token with the
-- read:vat / write:vat scopes (connect with /auth/hmrc/initiate?purpose=vat).
-- Fraud-prevention headers are mandatory and come from helper/hmrc.lua.
-- Gov-Test-Scenario is sent only in the sandbox.

local cjson = require("cjson")
local HMRC = require("helper.hmrc")

local Client = {}

local BASE_URLS = {
    sandbox = "https://test-api.service.hmrc.gov.uk",
    production = "https://api.service.hmrc.gov.uk",
}

local function environment() return os.getenv("HMRC_ENVIRONMENT") or "sandbox" end
function Client.is_sandbox() return environment() ~= "production" end
local function base_url() return BASE_URLS[environment()] or BASE_URLS.sandbox end

-- For specs: replace the HTTP layer.
Client._http = nil

local function http_client()
    if Client._http then return Client._http end
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local c = http.new()
    c:set_timeout(40000)
    return c
end

local function headers(token, opts)
    opts = opts or {}
    local h = HMRC.build_fraud_headers()
    h["Authorization"] = "Bearer " .. token
    h["Accept"] = "application/vnd.hmrc.1.0+json"
    if opts.json_body then h["Content-Type"] = "application/json" end
    if opts.test_scenario and opts.test_scenario ~= "" and Client.is_sandbox() then
        h["Gov-Test-Scenario"] = opts.test_scenario
    end
    return h
end

local function decode(body)
    if not body or body == "" then return {} end
    local ok, t = pcall(cjson.decode, body)
    return (ok and type(t) == "table") and t or {}
end

local function valid_vrn(vrn) return type(vrn) == "string" and vrn:match("^%d%d%d%d%d%d%d%d%d$") ~= nil end

local function query(params)
    local q = {}
    for _, k in ipairs({ "from", "to", "status" }) do
        if params[k] and params[k] ~= "" then q[#q + 1] = k .. "=" .. ngx.escape_uri(tostring(params[k])) end
    end
    return #q > 0 and ("?" .. table.concat(q, "&")) or ""
end

local function call(method, path, token, opts)
    opts = opts or {}
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local res, rerr = httpc:request_uri(base_url() .. path, {
        method = method,
        body = opts.body and cjson.encode(opts.body) or nil,
        headers = headers(token, { json_body = opts.body ~= nil, test_scenario = opts.test_scenario }),
        ssl_verify = true,
    })
    if not res then return nil, method .. " " .. path .. " failed: " .. tostring(rerr) end
    local data = decode(res.body)
    if res.status >= 400 then return nil, "HTTP " .. res.status, data, res.status end
    return data, nil, nil, res.status, res.headers
end

--- Open / fulfilled VAT periods. opts: { from, to, status = "O"|"F", test_scenario }
function Client.obligations(token, vrn, opts)
    opts = opts or {}
    if not valid_vrn(vrn) then return nil, "Invalid VRN" end
    local data, err, body, status = call("GET", "/organisations/vat/" .. vrn .. "/obligations" .. query(opts),
        token, { test_scenario = opts.test_scenario })
    if not data then return nil, err, body, status end
    return data.obligations or {}, nil
end

--- The JSON body HMRC wants for a return from our boxes (lib/vat-return).
-- `finalised` must be true: the person has confirmed the declaration.
function Client.return_body(boxes, period_key)
    local function n(x) return tonumber(x) or 0 end
    return {
        periodKey = period_key,
        vatDueSales = n(boxes.box1),
        vatDueAcquisitions = n(boxes.box2),
        totalVatDue = n(boxes.box3),
        vatReclaimedCurrPeriod = n(boxes.box4),
        netVatDue = n(boxes.box5),
        totalValueSalesExVAT = math.floor(n(boxes.box6)),
        totalValuePurchasesExVAT = math.floor(n(boxes.box7)),
        totalValueGoodsSuppliedExVAT = math.floor(n(boxes.box8)),
        totalAcquisitionsExVAT = math.floor(n(boxes.box9)),
        finalised = true,
    }
end

--- File a VAT return. BINDING. @return receipt { processingDate, paymentIndicator,
-- formBundleNumber, chargeRefNumber, correlation_id } or nil, err, hmrc_body, status
function Client.submit_return(token, vrn, body, opts)
    opts = opts or {}
    if not valid_vrn(vrn) then return nil, "Invalid VRN" end
    if type(body) ~= "table" or body.finalised ~= true then
        return nil, "The declaration must be confirmed (finalised = true)"
    end
    local data, err, hbody, status, hdrs = call("POST", "/organisations/vat/" .. vrn .. "/returns", token,
        { body = body, test_scenario = opts.test_scenario })
    if not data then return nil, err, hbody, status end
    data.correlation_id = hdrs and (hdrs["X-CorrelationId"] or hdrs["x-correlationid"]) or nil
    return data
end

function Client.view_return(token, vrn, period_key, opts)
    opts = opts or {}
    if not valid_vrn(vrn) then return nil, "Invalid VRN" end
    return call("GET", "/organisations/vat/" .. vrn .. "/returns/" .. ngx.escape_uri(period_key), token,
        { test_scenario = opts.test_scenario })
end

function Client.liabilities(token, vrn, opts)
    opts = opts or {}
    if not valid_vrn(vrn) then return nil, "Invalid VRN" end
    local data, err, body, status = call("GET", "/organisations/vat/" .. vrn .. "/liabilities" .. query(opts), token,
        { test_scenario = opts.test_scenario })
    if not data then return nil, err, body, status end
    return data.liabilities or {}, nil
end

function Client.payments(token, vrn, opts)
    opts = opts or {}
    if not valid_vrn(vrn) then return nil, "Invalid VRN" end
    local data, err, body, status = call("GET", "/organisations/vat/" .. vrn .. "/payments" .. query(opts), token,
        { test_scenario = opts.test_scenario })
    if not data then return nil, err, body, status end
    return data.payments or {}, nil
end

function Client.penalties(token, vrn, opts)
    opts = opts or {}
    if not valid_vrn(vrn) then return nil, "Invalid VRN" end
    return call("GET", "/organisations/vat/" .. vrn .. "/penalties", token, { test_scenario = opts.test_scenario })
end

--- Plain-English message for HMRC's VAT error codes (what the person can do).
Client.ERRORS = {
    DUPLICATE_SUBMISSION = "HMRC already has a return for this period.",
    TAX_PERIOD_NOT_ENDED = "This VAT period hasn't ended yet, so it can't be filed.",
    INVALID_VRN = "HMRC doesn't recognise the VAT number.",
    VRN_INVALID = "HMRC doesn't recognise the VAT number.",
    INVALID_PERIODKEY = "HMRC doesn't recognise this VAT period.",
    PERIOD_KEY_INVALID = "HMRC doesn't recognise this VAT period.",
    INVALID_REQUEST = "HMRC rejected the figures as invalid.",
    INVALID_PAYLOAD = "HMRC rejected the figures as invalid.",
    NOT_FINALISED = "The declaration must be confirmed before filing.",
    INSOLVENT_TRADER = "HMRC can't accept a return for an insolvent business through this service.",
    CLIENT_OR_AGENT_NOT_AUTHORISED = "This HMRC sign-in isn't authorised for that VAT number.",
    RESOURCE_FORBIDDEN = "The HMRC application isn't subscribed to the VAT (MTD) API.",
    MATCHING_RESOURCE_NOT_FOUND = "HMRC has nothing for that VAT number and period.",
}

function Client.explain(hmrc_body)
    local code = type(hmrc_body) == "table" and hmrc_body.code or nil
    if code and Client.ERRORS[code] then return Client.ERRORS[code], code end
    if type(hmrc_body) == "table" and type(hmrc_body.errors) == "table" and hmrc_body.errors[1] then
        local c = hmrc_body.errors[1].code
        return Client.ERRORS[c] or hmrc_body.errors[1].message or c, c
    end
    return (type(hmrc_body) == "table" and hmrc_body.message) or "HMRC rejected the request.", code
end

return Client
