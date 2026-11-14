--[[
    Spec: landlord (UK property) filing figures.

    Guards:
      * rents → ukProperty.income.periodAmount; other business income → otherIncome;
        bank interest is not property income;
      * deductible expenses land in the right UK property field by HMRC box;
      * non-deductible lines (mortgage payments, HMRC tax payments, transfers) and
        capital items never reach the body;
      * residential interest → residentialFinancialCost (never an expense), and taken
        back out of financialCosts if older data had claimed interest;
      * commercial interest the landlord stated → financialCosts, without double
        counting interest already classified as an expense;
      * the estimate adds stated commercial interest to property expenses the same way.

    Standalone (no DB): run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/hmrc-property-filing_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function near(a, b) return math.abs((tonumber(a) or -1e9) - b) < 0.01 end

local year_row = { gross_income = 0, total_expenses = 0, finance_interest = 0, unreviewed = 0 }
package.loaded["lapis.db"] = {
    query = function(sql)
        if sql:find("FROM tax_rates") then return {} end
        if sql:find("AS gross_income") then return { year_row } end
        return {}
    end,
    select = function() return {} end,
}
package.loaded["resty.http"] = { new = function() error("no http in spec") end }
package.loaded["helper.hmrc"] = { build_fraud_headers = function() return {} end }

local TaxTools = require("lib.agent.tax-tools")
local Property = require("lib.hmrc-property-aggregator")
local ci = TaxTools._commercial_interest

local function row(tt, cat, box, deductible, amount, income)
    return { transaction_type = tt, category = cat, hmrc_category = box, deductible = deductible,
        amount = amount, is_income = income or false }
end

-- The 100-property landlord, as classified after the fix.
local rows = {
    row("CREDIT", "rental_income", "other_income", false, 1698949.32, true),
    row("CREDIT", "interest_income", "other_income", false, 120.50, true),
    row("CREDIT", "income_other", "other_income", false, 500, true),
    row("DEBIT", "loan_repayments", nil, false, 684120),
    row("DEBIT", "tax_payments", nil, false, 264650),
    row("DEBIT", "transfer", nil, false, 180000),
    row("DEBIT", "repairs_property", "repairs_maintenance", true, 46335.18),
    row("DEBIT", "premises_insurance", "rent_rates", true, 25680),
    row("DEBIT", "business_rates", "rent_rates", true, 3841.90),
    row("DEBIT", "utilities", "rent_rates", true, 1633.90),
    row("DEBIT", "accountancy_fees", "accountancy_legal", true, 7400),
    row("DEBIT", "legal_fees", "accountancy_legal", true, 2680),
    row("DEBIT", "professional_fees", "accountancy_legal", true, 3074.05),
    row("DEBIT", "general_admin_expenses", "telephone_office", true, 14400),
    row("DEBIT", "software_subscriptions", "telephone_office", true, 2268),
    row("DEBIT", "equipment_purchase", "capital_allowances", true, 5000),
    row("CREDIT", "repairs_property", "repairs_maintenance", true, 335.18), -- a refund
}
local profile = { property_finance_costs = 398600, commercial_finance_costs = 113800 }

print("== UK property body")
local out = Property.fold(rows, profile, ci)
check("rents → periodAmount", near(out.income.periodAmount, 1698949.32), out.income.periodAmount)
check("other business income → otherIncome", near(out.income.otherIncome, 500), out.income.otherIncome)
check("repairs net of the refund", near(out.expenses.repairsAndMaintenance, 46000), out.expenses.repairsAndMaintenance)
check("insurance + rates + utilities → premisesRunningCosts",
    near(out.expenses.premisesRunningCosts, 25680 + 3841.90 + 1633.90), out.expenses.premisesRunningCosts)
check("accountancy/legal/professional → professionalFees",
    near(out.expenses.professionalFees, 7400 + 2680 + 3074.05), out.expenses.professionalFees)
check("admin + software → other", near(out.expenses.other, 14400 + 2268), out.expenses.other)
check("commercial interest → financialCosts", near(out.expenses.financialCosts, 113800), out.expenses.financialCosts)
check("residential interest → residentialFinancialCost",
    near(out.expenses.residentialFinancialCost, 398600), out.expenses.residentialFinancialCost)
local total = 0
for k, v in pairs(out.expenses) do if k ~= "residentialFinancialCost" then total = total + v end end
check("mortgage payments, tax payments, transfers and capital items are not expenses",
    near(total, 46000 + 31155.80 + 13154.05 + 16668 + 113800), total)

print("== older data that claimed the mortgage payments as interest")
local legacy = {
    row("CREDIT", "rental_income", "other_income", false, 100000, true),
    row("DEBIT", "loan_interest", "interest_finance", true, 30000),
}
local o2 = Property.fold(legacy, { property_finance_costs = 20000, commercial_finance_costs = 8000 }, ci)
-- 30,000 classified: 20,000 is residential (moved out), the remaining 10,000 already
-- covers the 8,000 commercial, so nothing is added.
check("residential taken back out, commercial not double counted",
    near(o2.expenses.financialCosts, 10000), o2.expenses.financialCosts)
check("residential still claimed as the credit", near(o2.expenses.residentialFinancialCost, 20000))

print("== no stated interest")
local o3 = Property.fold({ row("CREDIT", "rental_income", "other_income", false, 12000, true) }, {}, ci)
check("no finance fields when none given",
    o3.expenses.financialCosts == nil and o3.expenses.residentialFinancialCost == nil)

print("== negative rents are flagged")
local o4 = Property.fold({ row("DEBIT", "rental_income", "other_income", false, 500, true) }, {}, ci)
check("rent refunded beyond rent received is reported", near(o4.negative_income.periodAmount, -500))

print("== estimate adds stated commercial interest")
local est = TaxTools.estimate(1698949.32, 107839, "2025-26",
    { income_types = { "uk_property" }, property_finance_costs = 398600, commercial_finance_costs = 113800 },
    { finance_interest = 0 })
check("property profit = rents - expenses - commercial interest",
    near(est.schedules.property_profit, 1698949.32 - 107839 - 113800), est.schedules.property_profit)
check("allowable expenses include the commercial interest", near(est.total_expenses, 107839 + 113800),
    est.total_expenses)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
