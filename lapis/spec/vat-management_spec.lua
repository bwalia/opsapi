--[[
    Spec: VAT management (lib/vat-management.lua) — the registration threshold watch,
    VAT periods and deadline reminders, the inspection export and VAT reports.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-management_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local M = require("lib.vat-management")

print("== registration threshold (rolling 12 months)")
check("threshold comes from configuration, default £90,000", M.threshold_amount() == 90000)
local monthly = {}
for i = 1, 12 do monthly[string.format("2026-%02d", i)] = 6000 end -- £72k a year
local r = M.threshold_check(monthly, "2026-12", 90000)
check("£72,000 → 80%, approaching", r.turnover == 72000 and r.status == "approaching" and r.pct == 80, r.status)
monthly["2026-11"] = 31000 -- Jan–Oct £60k + £31k = £91k by the end of November
r = M.threshold_check(monthly, "2026-12", 90000)
check("£90,000+ crossed at the end of November", r.status == "over" and r.crossed_month == "2026-11", r.crossed_month)
check("must register within 30 days of the end of that month", r.register_by == "2026-12-30", r.register_by)
r = M.threshold_check({ ["2026-06"] = 1000 }, "2026-12", 90000)
check("small turnover is fine", r.status == "ok")
check("residential rent isn't taxable turnover", M.is_taxable_sale({ category = "rental_income" }) == false)
check("sales are", M.is_taxable_sale({ category = "sales_income" }) == true)
check("a coded line follows its code", M.is_taxable_sale({ vat_code = "ZERO", category = "rental_income" }) == true
    and M.is_taxable_sale({ vat_code = "EXEMPT", category = "sales_income" }) == false)

print("== VAT periods and reminders")
local p = M.recent_periods("quarterly_mar", "standard", "2026-05-01", 2)
check("last quarter ended 31 March", p[1].start == "2026-01-01" and p[1]["end"] == "2026-03-31"
    and p[1].due == "2026-05-07", p[1]["end"])
check("the one before ended 31 December", p[2]["end"] == "2025-12-31")
p = M.recent_periods("quarterly_apr", "standard", "2026-05-01", 1)
check("April stagger: quarter to 30 April", p[1]["end"] == "2026-04-30" and p[1].start == "2026-02-01", p[1]["end"])
p = M.recent_periods("quarterly_may", "standard", "2026-07-15", 1)
check("May stagger: quarter to 31 May", p[1]["end"] == "2026-05-31", p[1]["end"])
p = M.recent_periods("monthly", "standard", "2026-05-20", 1)
check("monthly: April", p[1].start == "2026-04-01" and p[1]["end"] == "2026-04-30")
local reg = { stagger = "quarterly_mar", scheme = "standard" }
local due = M.reminders_due(reg, "2026-04-23", {})
check("14 days before 7 May", #due == 1 and due[1].kind == "14_days")
due = M.reminders_due(reg, "2026-05-04", {})
check("3 days before", #due == 1 and due[1].kind == "3_days")
due = M.reminders_due(reg, "2026-05-08", {})
check("the day after: overdue", #due == 1 and due[1].kind == "overdue")
check("filed → no reminder", #M.reminders_due(reg, "2026-04-23", { ["2026-03-31"] = true }) == 0)
check("other days → none", #M.reminders_due(reg, "2026-04-24", {}) == 0)

print("== inspection export")
local csv = M.export_csv({
    t1 = { date = "2026-01-05", description = 'ACME, "LTD"', amount = 120, vat_code = "STD20", net_amount = 100,
        vat_amount = 20, vat_notional = 0, vat_reclaimable_pct = 100, transaction_type = "CREDIT" },
    t2 = { date = "2026-01-09", description = "SCREWFIX", amount = 60, vat_code = "STD20", net_amount = 50,
        vat_amount = 10, vat_notional = 0, vat_reclaimable_pct = 100, transaction_type = "DEBIT" },
}, { box1 = { "t1" }, box6 = { "t1" }, box4 = { "t2" }, box7 = { "t2" } })
check("a header and one row per line", select(2, csv:gsub("\n", "")) == 3, csv)
check("lists the boxes each line went to", csv:find("t1,2026%-01%-05") ~= nil and csv:find(",1 6\n") ~= nil
    and csv:find(",4 7\n") ~= nil, csv)
check("commas and quotes are escaped", csv:find('"ACME, ""LTD"""', 1, true) ~= nil)

print("== VAT report")
local rep = M.report({
    { vat_code = "STD20", direction = "sale", net = 1000, vat = 200 },
    { vat_code = "STD20", direction = "purchase", net = 500, vat = 100, reclaimable_pct = 100, supplier = "SCREWFIX" },
    { vat_code = "STD20", direction = "purchase", net = 200, vat = 40, reclaimable_pct = 0, supplier = "THE IVY" },
    { vat_code = "RC_SERVICES", direction = "purchase", net = 300, vat = 0, notional_vat = 60, supplier = "SLACK" },
})
check("output VAT", rep.totals.output_vat == 200)
check("input VAT incl. reverse charge", rep.totals.input_vat == 200, rep.totals.input_vat)
check("reclaimable vs blocked (entertainment)", rep.totals.reclaimable == 160 and rep.totals.blocked == 40)
check("top supplier by spend", rep.top_suppliers[1].supplier == "SCREWFIX")

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
