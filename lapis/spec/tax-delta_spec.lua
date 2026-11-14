--[[
    Spec: our estimate vs HMRC's calculation (lib/tax-delta).

    Guards:
      * HMRC's v8 calculation fields are read from the right paths;
      * matching figures (within £1) are not flagged;
      * a real gap is flagged per line, with the reason, and the total delta is HMRC - ours;
      * lines neither side has are left out; the total always shows;
      * HMRC's income sources, extra charges and messages come through.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/tax-delta_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local Delta = require("lib.tax-delta")

-- Our estimate for the 100-property landlord (TaxTools.estimate shape).
local ours = {
    schedules = { property_profit = 1477310.30, trading_profit = 0, employment = 0 },
    total_income = 1477310.30, personal_allowance = 0, total_taxable = 1477310.30,
    income_tax_before_reductions = 650992.64, finance_cost_reduction = 79720,
    income_tax_due = 571272.64, class4_nic = 0, class2_nic = 0, total_liability = 571272.64,
}

-- HMRC's calculation, same person, figures agreeing to the penny but for rounding.
local function hmrc(over)
    local c = {
        metadata = { calculationId = "c1" },
        calculation = {
            incomeSummaryTotals = { totalUKPropertyProfit = 1477310 },
            allowancesAndDeductions = { personalAllowance = 12570, reducedPersonalAllowance = 0 },
            reliefs = { residentialFinanceCosts = { totalResidentialFinanceCostsRelief = 79720 } },
            businessProfitAndLoss = { { incomeSourceType = "uk-property", incomeSourceName = "UK property",
                totalIncome = 1698949.32, totalExpenses = 221639.02, taxableProfit = 1477310 } },
            taxCalculation = {
                incomeTax = { totalIncomeReceivedFromAllSources = 1477310, totalTaxableIncome = 1477310,
                    incomeTaxCharged = 650992.50, incomeTaxDueAfterReliefs = 571272.50 },
                nics = {},
                totalIncomeTaxAndNicsDue = 571272.50,
            },
        },
        messages = { info = { { id = "C22201", text = "Your Personal Allowance has been reduced" } } },
    }
    if over then over(c) end
    return c
end

print("== figures that agree")
local same = Delta.compare(ours, hmrc())
check("not flagged (under £1 is rounding)", same.differs == false)
check("total delta is HMRC minus ours", same.total_delta == -0.14, same.total_delta)
local keys = {}
for _, r in ipairs(same.rows) do keys[r.key] = r end
check("reduced personal allowance (0) is used, not the standard one", keys.personal_allowance
    and keys.personal_allowance.hmrc == nil or (keys.personal_allowance == nil),
    keys.personal_allowance and keys.personal_allowance.hmrc)
check("lines nobody has are left out", keys.employment == nil and keys.class4_nic == nil)
check("finance-cost credit read from reliefs", keys.finance_cost_reduction.hmrc == 79720)
check("property profit read from incomeSummaryTotals", keys.property_profit.hmrc == 1477310)
check("HMRC's income source listed", same.income_sources[1].type == "uk-property"
    and same.income_sources[1].taxable_profit == 1477310)
check("HMRC's messages come through", same.messages.info[1].text:find("Personal Allowance") ~= nil)

print("== HMRC holds a job we don't know about")
local diff = Delta.compare(ours, hmrc(function(c)
    local it = c.calculation.taxCalculation.incomeTax
    c.calculation.incomeSummaryTotals.totalEmploymentIncome = 30000
    it.totalIncomeReceivedFromAllSources = 1507310
    it.totalTaxableIncome = 1507310
    it.incomeTaxCharged = 664492.50
    it.incomeTaxDueAfterReliefs = 584772.50
    c.calculation.taxCalculation.totalIncomeTaxAndNicsDue = 584772.50
    c.calculation.taxCalculation.totalTaxDeducted = 4500
end))
keys = {}
for _, r in ipairs(diff.rows) do keys[r.key] = r end
check("flagged", diff.differs == true)
check("employment line appears, only on HMRC's side", keys.employment and keys.employment.ours == 0
    and keys.employment.hmrc == 30000 and keys.employment.differs)
check("income line explains HMRC may hold other income", keys.total_income.differs
    and keys.total_income.why:find("PAYE", 1, true) ~= nil)
check("matching lines carry no reason", keys.finance_cost_reduction.differs == false
    and keys.finance_cost_reduction.why == nil)
check("total delta", diff.total_delta == 13499.86, diff.total_delta)
check("tax already deducted listed as an extra", diff.extras[1] and diff.extras[1].amount == 4500,
    diff.extras[1] and diff.extras[1].label)

print("== sandbox flag passes through; empty HMRC response is safe")
local sb = Delta.compare(ours, {}, { sandbox = true })
check("sandbox", sb.sandbox == true)
check("total row still shown with no HMRC figure", sb.rows[#sb.rows].key == "total" and sb.rows[#sb.rows].hmrc == nil)
check("missing HMRC figure counts as a difference", sb.differs == true)

print("== HMRC test-service placeholders are not figures")
local ph = Delta.compare(ours, hmrc(function(c)
    c.calculation.taxCalculation.incomeTax.incomeTaxDueAfterReliefs = -99999999999.99
    c.calculation.taxCalculation.totalTaxDeducted = -99999999999.99
end), { sandbox = true })
local rk = {}
for _, r in ipairs(ph.rows) do rk[r.key] = r end
check("placeholder shown as missing", rk.income_tax_due.hmrc == nil)
check("placeholder extra is left out", #ph.extras == 0, #ph.extras)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
