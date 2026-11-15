--[[
    Spec: HMRC VAT (MTD) client (lib/hmrc-vat-client.lua) with the HTTP layer stubbed.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/hmrc-vat-client_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local cjson = require("cjson")
local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

_G.ngx = { escape_uri = function(s) return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte()) end)) end }
package.loaded["helper.hmrc"] = {
    build_fraud_headers = function() return { ["Gov-Client-Connection-Method"] = "WEB_APP_VIA_SERVER" } end,
}

local Client = require("lib.hmrc-vat-client")
local last
local reply = { status = 200, body = "{}", headers = {} }
Client._http = { request_uri = function(_, url, req) last = { url = url, req = req }; return reply end }

local VRN = "123456782"

print("== obligations")
reply = { status = 200, body = cjson.encode({ obligations = { { periodKey = "18A1", status = "O",
    start = "2026-01-01", ["end"] = "2026-03-31", due = "2026-05-07" } } }) }
local list = Client.obligations("tok", VRN, { from = "2026-01-01", to = "2026-12-31", status = "O",
    test_scenario = "QUARTERLY_ONE_MET" })
check("returns HMRC's periods", list and list[1].periodKey == "18A1")
check("GET with from/to/status", last.req.method == "GET"
    and last.url:find("/organisations/vat/123456782/obligations%?from=2026%-01%-01&to=2026%-12%-31&status=O") ~= nil,
    last.url)
check("Accept: VAT API 1.0", last.req.headers.Accept == "application/vnd.hmrc.1.0+json")
check("bearer token and fraud headers", last.req.headers.Authorization == "Bearer tok"
    and last.req.headers["Gov-Client-Connection-Method"] == "WEB_APP_VIA_SERVER")
check("sandbox: test scenario sent", last.req.headers["Gov-Test-Scenario"] == "QUARTERLY_ONE_MET")
check("bad VRN refused before any call", Client.obligations("tok", "12345") == nil)

print("== the return body")
local b = Client.return_body({ box1 = 2000, box2 = 0, box3 = 2000, box4 = 400, box5 = 1600, box6 = 14000.9,
    box7 = 2800, box8 = 0, box9 = 0 }, "18A1")
check("boxes mapped to HMRC's fields", b.vatDueSales == 2000 and b.totalVatDue == 2000
    and b.vatReclaimedCurrPeriod == 400 and b.netVatDue == 1600 and b.totalValuePurchasesExVAT == 2800)
check("Boxes 6–9 whole pounds", b.totalValueSalesExVAT == 14000)
check("period key and finalised", b.periodKey == "18A1" and b.finalised == true)

print("== submitting")
reply = { status = 201, body = cjson.encode({ processingDate = "2026-05-01T10:00:00.000Z", paymentIndicator = "BANK",
    formBundleNumber = "256660290587", chargeRefNumber = "aCxFaNx0FZsCvyWF" }),
    headers = { ["X-CorrelationId"] = "c-1" } }
local rec = Client.submit_return("tok", VRN, b)
check("POST to /returns with JSON", last.req.method == "POST" and last.url:find("/returns$") ~= nil
    and last.req.headers["Content-Type"] == "application/json")
check("body sent as given", cjson.decode(last.req.body).netVatDue == 1600)
check("HMRC's receipt returned with correlation id", rec.formBundleNumber == "256660290587"
    and rec.correlation_id == "c-1")
local nb = Client.return_body({}, "18A1"); nb.finalised = false
check("refuses to send without the declaration", Client.submit_return("tok", VRN, nb) == nil)
reply = { status = 403, body = cjson.encode({ code = "DUPLICATE_SUBMISSION", message = "dup" }) }
local r, err, body, status = Client.submit_return("tok", VRN, b)
check("HMRC errors come back with the body and status", r == nil and err == "HTTP 403" and body.code
    == "DUPLICATE_SUBMISSION" and status == 403)
check("explained in plain English", Client.explain(body) == "HMRC already has a return for this period.")
check("nested errors are explained", Client.explain({ code = "INVALID_REQUEST", errors = {
    { code = "TAX_PERIOD_NOT_ENDED", message = "x" } } }) == "HMRC rejected the figures as invalid.")
check("subscription problem explained", Client.explain({ code = "RESOURCE_FORBIDDEN" }):find("VAT %(MTD%)") ~= nil)

print("== production never sends a test scenario")
local real_getenv = os.getenv
os.getenv = function(k) -- luacheck: ignore 122
    if k == "HMRC_ENVIRONMENT" then return "production" end
    return real_getenv(k)
end
reply = { status = 200, body = cjson.encode({ liabilities = {} }) }
Client.liabilities("tok", VRN, { from = "2026-01-01", to = "2026-03-31", test_scenario = "SINGLE_LIABILITY" })
check("no Gov-Test-Scenario", last.req.headers["Gov-Test-Scenario"] == nil)
check("live host", last.url:find("^https://api%.service%.hmrc%.gov%.uk") ~= nil, last.url)
os.getenv = real_getenv -- luacheck: ignore 122

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
