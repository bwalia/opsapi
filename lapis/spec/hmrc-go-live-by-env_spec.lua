--[[
    Spec: going live with HMRC is a settings change only. The code already does what live
    HMRC needs (the sandbox checks none of it):
    - a mid-year Income Tax update runs from the start of the year to the END OF THE
      QUARTER being filed, never past it (live: RULE_EARLY_DATA_SUBMISSION_NOT_ACCEPTED,
      "Cannot submit data more than 10 days before end of Period");
    - a binding final return isn't filed while the year has income File My Tax doesn't send;
    - TAX_DIRECT_FILING_ENABLED=false is refused by the server, not only hidden;
    - VAT files only the figures the person reviewed, under the HMRC period with the
      return's own dates, and VAT_FILING_ENABLED / VAT_REGISTRATION_THRESHOLD reach the
      workers (nginx drops any env var it doesn't declare).

    Run from the repo root: /usr/local/openresty/luajit/bin/luajit lapis/spec/hmrc-go-live-by-env_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end

package.loaded["lapis.db"] = { query = function() return {} end, escape_literal = function(v) return "'" .. v .. "'" end }
local A = require("lib.hmrc-aggregator")

print("== Income Tax: the period an update covers")
local s, e = A.period_bounds("2026-27")
check("no quarter: the whole tax year", s == "2026-04-06" and e == "2027-04-05", tostring(s) .. ".." .. tostring(e))
s, e = A.period_bounds("2026-27", "2026-10-05")
check("quarter 2: 6 April to 5 October", s == "2026-04-06" and e == "2026-10-05")
s, e = A.period_bounds("2026-27", "2026-09-30")
check("calendar quarters start on 1 April", s == "2026-04-01" and e == "2026-09-30")
local _, _, err = A.period_bounds("2026-27", "2027-07-05")
check("a quarter end outside the tax year is refused", err ~= nil)
_, _, err = A.period_bounds("2026-27", "5/10/2026")
check("a badly formed date is refused", err ~= nil)

print("== Income Tax: live HMRC takes an update from 10 days before its period ends")
check("quarter ending 5 Jan, sent 16 Nov: too early, from 26 Dec",
    A.too_early("2027-01-05", "2026-11-16") == "2026-12-26", A.too_early("2027-01-05", "2026-11-16"))
check("quarter ending 5 Oct, sent 16 Nov (late): fine", A.too_early("2026-10-05", "2026-11-16") == nil)
check("exactly 10 days before: fine", A.too_early("2027-01-05", "2026-12-26") == nil)
check("whole year in November: too early", A.too_early("2027-04-05", "2026-11-16") ~= nil)

print("== Income Tax: a final return must hold all the year's income")
check("self-employment only: nothing left out",
    #A.unfiled_income({ trading_profit = 30000, property_profit = 0, dividends = 0 }, "self-employment") == 0)
local left = A.unfiled_income({ property_profit = 12000, dividends = 5000, savings = 0 }, "uk-property")
check("landlord with dividends: dividends left out", #left == 1 and left[1] == "dividends", table.concat(left, ","))
left = A.unfiled_income({ trading_profit = 1000, employment = 25000, pension_income = 3000 }, "self-employment")
check("job and pension listed", #left == 2, table.concat(left, ","))
left = A.unfiled_income({ trading_profit = 1000, property_profit = 800 }, "uk-property")
check("landlord with trading income: self-employment left out", left[1] == "self-employment")

print("== Income Tax: the routes use these, and the off switch is enforced by the server")
local routes = read("lapis/routes/tax-hmrc-filing.lua")
local build = routes:match("local function buildAndSubmitCumulative.-\nend\n")
check("updates refuse when TAX_DIRECT_FILING_ENABLED=false", build and build:find("directFilingOff%(%)")
    and build:find("DIRECT_FILING_OFF"))
check("updates stop at the quarter end and check the 10-day rule on live HMRC",
    build and build:find("period_end = opts.period_end") and build:find("not Client.is_sandbox%(%)%) and Aggregator.too_early"))
local final = routes:match('app:post%("/api/v2/tax/hmrc/submit%-final%-declaration".-\n    %)\n')
check("final return: year must have ended on live HMRC", final and final:find("TAX_YEAR_NOT_ENDED"))
check("final return: other income goes via the accountant", final and final:find("OTHER_INCOME_NOT_FILED")
    and final:find("OTHER_INCOME_NOT_FILED") < final:find("buildAndSubmitCumulative"))
check("preview sends the selected quarter end", routes:find("{ period_end = self.params.period_end }", 1, true))

-- Live HMRC: RULE_START_DATE_NOT_ALIGNED_TO_COMMENCEMENT_DATE (self-employment-business-api
-- 5.0 and property-business-api 6.0 cumulative summaries). The commencement date is
-- Business Details v2 Retrieve Business Details' commencementDate (business-details-api 2.0).
print("== Income Tax: a business that started this year")
s, e = A.period_bounds("2026-27", nil, "2026-08-01")
check("whole year: starts on the commencement date", s == "2026-08-01" and e == "2027-04-05", s)
s = A.period_bounds("2026-27", "2026-10-05", "2026-08-01")
check("quarter: starts on the commencement date", s == "2026-08-01", s)
s = A.period_bounds("2026-27", "2026-09-30", "2026-04-03")
check("calendar quarter starting 3 April", s == "2026-04-03", s)
check("started before the year: unchanged", A.period_bounds("2026-27", nil, "2019-01-01") == "2026-04-06")
check("started after this quarter: unchanged", A.period_bounds("2026-27", "2026-07-05", "2026-08-01") == "2026-04-06")
check("a malformed date is ignored", A.period_bounds("2026-27", nil, "01/08/2026") == "2026-04-06")
local seen_sql = {}
package.loaded["lapis.db"].select = function() return {} end
package.loaded["lapis.db"].query = function(sql, ...)
    seen_sql[#seen_sql + 1] = { sql = sql, args = { ... } }
    return {}
end
local body = A.build_cumulative_body({ user_id = 7, tax_year = "2026-27", commencement_date = "2026-08-01" })
check("self-employment: counts transactions from that date", seen_sql[1] and seen_sql[1].args[2] == "2026-08-01"
    and body.tax_year_start == "2026-08-01")
seen_sql = {}
package.loaded["lib.agent.tax-tools"] = { _finance_split = function() return 0, 0, 0 end }
local pb = require("lib.hmrc-property-aggregator").build_cumulative_body({ user_id = 7, tax_year = "2026-27",
    commencement_date = "2026-08-01" })
check("UK property: fromDate and transactions from that date", pb.body.fromDate == "2026-08-01"
    and seen_sql[1] and seen_sql[1].sql:find("transaction_date >= '2026-08-01'", 1, true) ~= nil)
local called
package.loaded["helper.hmrc"] = { build_fraud_headers = function() return {} end }
package.loaded["resty.http"] = { new = function() return {
    set_timeout = function() end,
    request_uri = function(_, url, o)
        called = { url = url, accept = o.headers.Accept }
        return { status = 200, body = '{"businessId":"XBIS1","commencementDate":"2026-08-01"}' }
    end } end }
local Client = require("lib.hmrc-mtd-client")
local det = Client.get_business("tok", "AA123456A", "XBIS1")
check("reads Retrieve Business Details v2", called and called.url:find("/individuals/business/details/AA123456A/XBIS1$")
    and called.accept == "application/vnd.hmrc.2.0+json", called and called.url)
check("returns commencementDate", det and det.commencementDate == "2026-08-01")
check("filing asks HMRC for it and re-aggregates from it", build and build:find("Client.get_business(", 1, true)
    and build:find("Aggregator.starts_inside(commenced", 1, true)
    and build:find("agg, aerr = aggregate(commenced)", 1, true))

print("== VAT")
package.loaded["helper.hmrc"] = {}
package.loaded["lib.hmrc-vat-client"] = { is_sandbox = function() return true end }
package.loaded["lib.vat-return"] = {}
package.loaded["queries.VatReturnQueries"] = {}
local Q = require("queries.VatFilingQueries")
check("same boxes match", Q.same_boxes({ box1 = 100, box6 = 500 }, { box1 = 100.004, box6 = 500 }))
check("a changed box is caught", not Q.same_boxes({ box1 = 100, box4 = 20 }, { box1 = 100, box4 = 20.5 }))
local vf = read("lapis/queries/VatFilingQueries.lua")
check("submit refuses figures that changed since review", vf:find("FIGURES_CHANGED", 1, true)
    and vf:find("Q.same_boxes(boxes_of(draft), boxes)", 1, true))
check("live: the period key must have the return's own dates", vf:find('tostring(o["end"]) == tostring(draft.period_end)', 1, true))

print("== the settings reach the workers")
for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    local c = read(conf)
    for _, v in ipairs({ "HMRC_ENVIRONMENT", "HMRC_CLIENT_ID", "HMRC_CLIENT_SECRET", "HMRC_REDIRECT_URI",
        "HMRC_SERVER_PUBLIC_IP", "TAX_DIRECT_FILING_ENABLED", "VAT_FILING_ENABLED", "VAT_REGISTRATION_THRESHOLD" }) do
        if conf == "lapis/nginx.conf" or v:find("^VAT_") or v == "TAX_DIRECT_FILING_ENABLED" then
            check(conf:match("[^/]+$") .. " declares " .. v, c:find("\nenv " .. v .. ";", 1, true) ~= nil)
        end
    end
end

if failures > 0 then print(failures .. " FAILED") os.exit(1) end
print("all passed")
