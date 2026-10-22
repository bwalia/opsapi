--[[
    Self-check for TaxCalc.compute_full — the full UK Self Assessment computation.
    Validated against the "Sample UK Tax Computation 2025/26 (Developer Reference)".
    Run from lapis/:  luajit lib/tax-calc-full_test.lua
    Pure (no DB). Uses the built-in 2025/26 England defaults (rates = {}).
]]

package.path = "./?.lua;" .. package.path
local TaxCalc = require("lib.tax-calc")

local passed, failed = 0, 0
local function approx(a, b) return math.abs((a or 0) - (b or 0)) < 0.01 end
local function check(label, got, want)
    if approx(got, want) then passed = passed + 1
    else failed = failed + 1; io.write(string.format("FAIL  %s: got %.4f want %.4f\n", label, got or -1, want or -1)) end
end

-- ===== Golden case: the PDF worked example (total payable £20,723.70) =====
local pdf = TaxCalc.compute_full({
    employment_income = 62000, paye_deducted = 12232,
    se_turnover = 28000, se_expenses = 5300, se_capital_allowances = 1200,   -- -> trading profit 21,500
    property_rents = 18000, property_expenses = 3200, property_finance_costs = 7500, -- -> profit 14,800
    savings_interest = 2400,
    gift_aid_net = 2000,
}, {})

check("trading_profit", pdf.schedules.trading_profit, 21500)
check("property_profit", pdf.schedules.property_profit, 14800)
check("non_savings", pdf.non_savings, 98300)
check("total_income", pdf.total_income, 100700)
check("gift_aid_gross", pdf.gift_aid_gross, 2500)
check("adjusted_net_income", pdf.adjusted_net_income, 98200)
check("personal_allowance", pdf.personal_allowance, 12570)
check("taxable_non_savings", pdf.taxable_non_savings, 85730)
check("taxable_savings", pdf.taxable_savings, 2400)
check("basic_limit (extended)", pdf.basic_limit, 40200)
check("personal_savings_allowance", pdf.personal_savings_allowance, 500)
check("tax_non_savings", pdf.tax_non_savings, 26252)
check("tax_savings", pdf.tax_savings, 760)
check("income_tax_before_reductions", pdf.income_tax_before_reductions, 27012)
check("finance_cost_reduction", pdf.finance_cost_reduction, 1500)
check("income_tax_due", pdf.income_tax_due, 25512)
check("class4_nic", pdf.class4_nic, 535.80)
check("class2_nic", pdf.class2_nic, 0)
check("total_liability", pdf.total_liability, 26047.80)
check("balancing_payment", pdf.balancing_payment, 13815.80)
check("payment_on_account_each", pdf.payment_on_account_each, 6907.90)
check("total_due_31_jan", pdf.total_due_31_jan, 20723.70)

-- ===== Sole trader only: profit 50,000 (Class 2 = 0 for 2025/26) =====
local st = TaxCalc.compute_full({ trading_profit = 50000 }, {})
check("st income_tax_due", st.income_tax_due, 7486)        -- 37,430 @ 20%
check("st class4", st.class4_nic, 2245.80)                 -- 37,430 @ 6%
check("st class2", st.class2_nic, 0)
check("st total_liability", st.total_liability, 9731.80)   -- NOT 9,911.20 (no Class 2)

-- ===== 60% zone: adjusted net income 110,000 tapers the PA by 5,000 =====
local z = TaxCalc.compute_full({ trading_profit = 110000 }, {})
check("taper PA = 7,570", z.personal_allowance, 7570)
check("taper income_tax_before_reductions", z.income_tax_before_reductions, 33432)

-- ===== Low earner: starting rate for savings covers modest savings =====
local low = TaxCalc.compute_full({ trading_profit = 3000, savings_interest = 10000 }, {})
check("low taxable_savings", low.taxable_savings, 430)                 -- 10,000 - (12,570-3,000)
check("low starting_rate_for_savings_used", low.starting_rate_for_savings_used, 430)
check("low income_tax_due", low.income_tax_due, 0)                     -- all within the 0% SRS band

io.write(string.format("\ntax-calc-full: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
