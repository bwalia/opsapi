--[[
    Self-check for lib/tax-calc (the single source of truth for UK tax maths).
    Pure function, no DB. Run from the lapis/ directory:

        luajit lib/tax-calc_test.lua
        # or in the container:
        docker exec opsapi /usr/local/openresty/luajit/bin/luajit \
            -e "package.path='/app/?.lua;'..package.path" /app/lib/tax-calc_test.lua

    These golden cases are the consistency guarantee: if the maths ever changes,
    this fails. Figures are 2025-26.
]]

package.path = "./?.lua;" .. package.path
local TaxCalc = require("lib.tax-calc")

-- 2025-26 rates (matches lib/tax-calc's fallback + the seeded tax_rates row).
local RATES = {
    personal_allowance = 12570, taper_threshold = 100000,
    basic_rate = 0.20, basic_rate_upper = 50270,
    higher_rate = 0.40, higher_rate_upper = 125140,
    additional_rate = 0.45,
    nic_main_rate = 0.06, nic_lower = 12570, nic_upper = 50270,
    nic_additional_rate = 0.02,
    class2_annual = 179.40, class2_threshold = 12570,
}

local passed, failed = 0, 0
local function approx(a, b) return math.abs((a or 0) - (b or 0)) < 0.01 end
local function check(label, got, want)
    if approx(got, want) then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("FAIL  %s: got %.4f want %.4f\n", label, got or -1, want or -1))
    end
end

-- Case 1: basic-rate sole trader. profit 50,000.
local c1 = TaxCalc.compute(60000, 10000, RATES)
check("c1 trading_profit", c1.trading_profit, 50000)
check("c1 personal_allowance", c1.personal_allowance, 12570)
check("c1 taxable_income", c1.taxable_income, 37430)
check("c1 income_tax", c1.income_tax.total, 7486)       -- 37430 * 20%
check("c1 class4", c1.national_insurance.class4, 2245.8) -- 37430 * 6%
check("c1 class2", c1.national_insurance.class2, 179.40)
check("c1 total_tax_due", c1.total_tax_due, 9911.2)

-- Case 2: additional-rate, personal allowance fully tapered away. profit 130,000.
local c2 = TaxCalc.compute(130000, 0, RATES)
check("c2 personal_allowance", c2.personal_allowance, 0)   -- tapered to 0 above 125,140
check("c2 taxable_income", c2.taxable_income, 130000)
check("c2 income_tax", c2.income_tax.total, 42189)         -- 10054 + 29948 + 2187
check("c2 class4", c2.national_insurance.class4, 3856.6)    -- 2262 + 1594.6
check("c2 total_tax_due", c2.total_tax_due, 46225.0)

-- Case 3: profit below the personal allowance AND the Class 2 threshold → no tax.
local c3 = TaxCalc.compute(10000, 0, RATES)
check("c3 taxable_income", c3.taxable_income, 0)
check("c3 income_tax", c3.income_tax.total, 0)
check("c3 class4", c3.national_insurance.class4, 0)
check("c3 class2", c3.national_insurance.class2, 0)
check("c3 total_tax_due", c3.total_tax_due, 0)

-- Case 4: expenses exceed income → profit floored at 0, nothing due.
local c4 = TaxCalc.compute(5000, 8000, RATES)
check("c4 trading_profit", c4.trading_profit, 0)
check("c4 total_tax_due", c4.total_tax_due, 0)

io.write(string.format("\ntax-calc: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
