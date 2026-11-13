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

-- ===== Band breakdown (reports screens) adds up to the income tax =====
local function band_sum(r)
    local s = 0
    for _, b in ipairs(r.income_tax_bands) do s = s + b.tax end
    return s
end
check("pdf bands sum = income tax before reductions", band_sum(pdf), pdf.income_tax_before_reductions)
check("taper bands sum = income tax", band_sum(z), z.income_tax_before_reductions)
-- Tapered PA: the basic band stays 37,700 wide (the old simple compute() widened it).
local basic_z
for _, b in ipairs(z.income_tax_bands) do if b.name == "Basic Rate" then basic_z = b end end
check("taper basic band taxable_amount", basic_z and basic_z.taxable_amount, 37700)
local top = TaxCalc.compute_full({ trading_profit = 160000 }, {})
check("160k PA fully withdrawn", top.personal_allowance, 0)
check("160k bands sum", band_sum(top), top.income_tax_due)
check("160k additional-rate slice", top.income_tax_bands[#top.income_tax_bands].taxable_amount, 34860)
local c4 = 0
for _, b in ipairs(top.class4_bands) do c4 = c4 + b.nic end
check("160k class4 bands sum", c4, top.class4_nic)

-- ===== Low earner: starting rate for savings covers modest savings =====
local low = TaxCalc.compute_full({ trading_profit = 3000, savings_interest = 10000 }, {})
check("low taxable_savings", low.taxable_savings, 430)                 -- 10,000 - (12,570-3,000)
check("low starting_rate_for_savings_used", low.starting_rate_for_savings_used, 430)
check("low income_tax_due", low.income_tax_due, 0)                     -- all within the 0% SRS band

-- ===== Section 24: residential finance costs -> 20% basic-rate tax reduction =====
-- Reduction = 20% x lowest of (finance costs, property profit, adjusted total income
-- above the PA — non-savings, non-dividend). Costs are NOT deducted from profit.
-- Large landlord (the case that was ~£100k overstated before the agent could record it):
local big = TaxCalc.compute_full({ property_rents = 1698949, property_expenses = 250000,
    property_finance_costs = 512400 }, {})
check("s24 big property_profit (interest not deducted)", big.schedules.property_profit, 1448949)
check("s24 big PA fully withdrawn", big.personal_allowance, 0)
check("s24 big tax before reductions", big.income_tax_before_reductions, 638230.05)
check("s24 big reduction = 20% of finance costs", big.finance_cost_reduction, 102480)
check("s24 big income_tax_due", big.income_tax_due, 535750.05)
check("s24 big no class4 on property", big.class4_nic, 0)
local big_none = TaxCalc.compute_full({ property_rents = 1698949, property_expenses = 250000 }, {})
check("s24 big without finance costs", big_none.income_tax_due, 638230.05)

-- Capped by adjusted total income above the PA (small landlord, big mortgage):
local small = TaxCalc.compute_full({ property_rents = 20000, property_expenses = 5000,
    property_finance_costs = 30000 }, {})
check("s24 small reduction capped at ATI above PA", small.finance_cost_reduction, 486)   -- 20% x 2,430
check("s24 small tax never negative", small.income_tax_due, 0)
check("s24 small carried forward", small.finance_costs_carried_forward, 27570)

-- Capped by property profit (employee + landlord):
local mixed = TaxCalc.compute_full({ employment_income = 60000, property_rents = 10000,
    property_expenses = 2000, property_finance_costs = 12000 }, {})
check("s24 mixed reduction capped at property profit", mixed.finance_cost_reduction, 1600) -- 20% x 8,000

-- Savings/dividends are excluded from adjusted total income for the cap:
local sav = TaxCalc.compute_full({ property_profit = 14000, savings_interest = 20000,
    property_finance_costs = 14000 }, {})
check("s24 savings excluded from ATI cap", sav.finance_cost_reduction, 286)              -- 20% x 1,430

-- Self-employed landlord with the rental figures split out: credit applies.
local sel = TaxCalc.compute_full({ se_turnover = 60000, se_expenses = 10000, property_rents = 30000,
    property_expenses = 5000, property_finance_costs = 9000 }, {})
check("s24 SE+property reduction", sel.finance_cost_reduction, 1800)
check("s24 SE+property class4 on trading only", sel.class4_nic, 2245.80)

io.write(string.format("\ntax-calc-full: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
