--[[
    UK Income Tax calculator (single source of truth)
    =================================================

    Pure, deterministic UK self-assessment tax maths, extracted so that BOTH the
    calculate screen (routes/tax-calculate) and the conversational tax agent
    (lib/agent/tax-tools: compute_estimate) call the SAME function — they can
    never disagree. No LLM ever produces these figures.

    `TaxCalc.compute(gross_income, total_expenses, rates)` is pure (no DB, no
    ngx) so it is trivially unit-testable — see lib/tax-calc_test.lua.
    `TaxCalc.load_rates(tax_year)` reads the per-year rates from `tax_rates`
    (lazy DB require, so loading this module needs no DB).
]]

local TaxCalc = {}

-- Lazy so requiring this module (e.g. in a unit test) needs no lapis.db.
local function get_db()
    return require("lapis.db")
end

--- The UK tax year ("2025-26") that the given time (default: now) falls in.
function TaxCalc.current_tax_year(now)
    now = now or os.date("*t")
    local year = now.year
    if now.month < 4 or (now.month == 4 and now.day < 6) then
        year = year - 1
    end
    return year .. "-" .. string.format("%02d", (year + 1) % 100)
end

-- The hardcoded fallback is 2025-26; any supported year SHOULD have a `tax_rates`
-- row (ponytail: fallback keeps estimates working if a year is unseeded, but it
-- will silently use 2025-26 figures — seed every year you support).
local FALLBACK_RATES = {
    personal_allowance = 12570, taper_threshold = 100000,
    basic_rate = 0.20, basic_rate_upper = 50270,
    higher_rate = 0.40, higher_rate_upper = 125140,
    additional_rate = 0.45,
    nic_main_rate = 0.06, nic_lower = 12570, nic_upper = 50270,
    nic_additional_rate = 0.02,
    class2_annual = 179.40, class2_threshold = 12570,
}

--- Load the rate table for a tax year from `tax_rates`, falling back to 2025-26.
function TaxCalc.load_rates(tax_year)
    local rows = get_db().query("SELECT * FROM tax_rates WHERE tax_year = ? LIMIT 1", tax_year)
    if rows and #rows > 0 then
        local r = rows[1]
        return {
            personal_allowance = tonumber(r.personal_allowance) or FALLBACK_RATES.personal_allowance,
            taper_threshold = tonumber(r.personal_allowance_taper_threshold) or FALLBACK_RATES.taper_threshold,
            basic_rate = tonumber(r.basic_rate) or FALLBACK_RATES.basic_rate,
            basic_rate_upper = tonumber(r.basic_rate_upper) or FALLBACK_RATES.basic_rate_upper,
            higher_rate = tonumber(r.higher_rate) or FALLBACK_RATES.higher_rate,
            higher_rate_upper = tonumber(r.higher_rate_upper) or FALLBACK_RATES.higher_rate_upper,
            additional_rate = tonumber(r.additional_rate) or FALLBACK_RATES.additional_rate,
            nic_main_rate = tonumber(r.nic_class4_main_rate) or FALLBACK_RATES.nic_main_rate,
            nic_lower = tonumber(r.nic_class4_lower_threshold) or FALLBACK_RATES.nic_lower,
            nic_upper = tonumber(r.nic_class4_upper_threshold) or FALLBACK_RATES.nic_upper,
            nic_additional_rate = tonumber(r.nic_class4_additional_rate) or FALLBACK_RATES.nic_additional_rate,
            class2_annual = tonumber(r.nic_class2_annual) or FALLBACK_RATES.class2_annual,
            class2_threshold = tonumber(r.nic_class2_threshold) or FALLBACK_RATES.class2_threshold,
        }
    end
    local copy = {}
    for k, v in pairs(FALLBACK_RATES) do copy[k] = v end
    return copy
end

--- Full UK tax breakdown from gross income + allowable expenses for one year.
-- Pure: identical inputs always give identical output. The ONLY place tax is
-- computed — do not duplicate this maths anywhere.
-- @param opts table? { apply_nic = boolean } — Class 2/4 NIC apply to trading
--   (self-employment) profit but NOT to property income; a pure landlord passes
--   apply_nic = false. Defaults to true (self-employment) for backward compat.
function TaxCalc.compute(gross_income, total_expenses, rates, opts)
    opts = opts or {}
    local apply_nic = opts.apply_nic ~= false
    gross_income = tonumber(gross_income) or 0
    total_expenses = tonumber(total_expenses) or 0
    local trading_profit = math.max(0, gross_income - total_expenses)

    -- Personal allowance (tapered £1 for every £2 of profit over the threshold).
    local pa = rates.personal_allowance
    if trading_profit > rates.taper_threshold then
        local excess = trading_profit - rates.taper_threshold
        pa = math.max(0, pa - math.floor(excess / 2))
    end

    local taxable_income = math.max(0, trading_profit - pa)

    -- Income tax bands.
    local basic_tax, higher_tax, additional_tax = 0, 0, 0
    local remaining = taxable_income

    local basic_band = rates.basic_rate_upper - pa
    if basic_band > 0 then
        local basic_amount = math.min(remaining, basic_band)
        basic_tax = basic_amount * rates.basic_rate
        remaining = remaining - basic_amount
    end

    if remaining > 0 then
        local higher_band = rates.higher_rate_upper - rates.basic_rate_upper
        local higher_amount = math.min(remaining, higher_band)
        higher_tax = higher_amount * rates.higher_rate
        remaining = remaining - higher_amount
    end

    if remaining > 0 then
        additional_tax = remaining * rates.additional_rate
    end

    local income_tax = basic_tax + higher_tax + additional_tax

    -- National Insurance (Class 2 + 4) — self-employment only. Property income is
    -- not subject to these, so a pure landlord (apply_nic = false) pays neither.
    local nic4, nic2 = 0, 0
    if apply_nic then
        if trading_profit > rates.nic_lower then
            local main_band = math.min(trading_profit, rates.nic_upper) - rates.nic_lower
            nic4 = main_band * rates.nic_main_rate
            if trading_profit > rates.nic_upper then
                nic4 = nic4 + (trading_profit - rates.nic_upper) * rates.nic_additional_rate
            end
        end
        -- Class 2 NIC: from 2024/25, profits above the Small Profits Threshold are
        -- credited a qualifying year WITHOUT payment (nic2 stays 0); below the SPT it
        -- is voluntary and not auto-charged. Historic years can re-enable via rates.
        if rates.class2_charge_above_spt and trading_profit >= rates.class2_threshold then
            nic2 = rates.class2_annual
        end
    end

    local total_tax = income_tax + nic4 + nic2
    local effective_rate = trading_profit > 0 and (total_tax / trading_profit * 100) or 0

    return {
        gross_income = gross_income,
        total_expenses = total_expenses,
        trading_profit = trading_profit,
        personal_allowance = pa,
        taxable_income = taxable_income,
        income_tax = {
            basic = { amount = basic_tax, rate = rates.basic_rate },
            higher = { amount = higher_tax, rate = rates.higher_rate },
            additional = { amount = additional_tax, rate = rates.additional_rate },
            total = income_tax,
        },
        national_insurance = {
            class4 = nic4,
            class2 = nic2,
            total = nic4 + nic2,
        },
        total_tax_due = math.floor(total_tax * 100 + 0.5) / 100,
        effective_rate = math.floor(effective_rate * 100) / 100,
    }
end

--- Full UK Self Assessment computation (England/rUK), following the HMRC order:
--  1 net income per source  2 total income  3 adjusted net income (Gift Aid/pension)
--  4 taper PA  5 allocate PA (non-savings, savings, dividends)  6 extend bands by Gift Aid
--  7 tax non-savings, savings (SRS, PSA, bands), dividends  8 tax reductions (finance costs)
--  9 Class 4/2 NIC  10 deduct tax at source, compute payments on account.
-- Every intermediate figure is returned. See lib/tax-calc-full_test.lua (validated
-- against the "Sample UK Tax Computation 2025/26" developer reference, total £20,723.70).
-- Inputs (all optional, £): employment_income, employment_expenses, paye_deducted;
--   se_turnover, se_expenses, se_capital_allowances (or trading_profit directly);
--   property_rents, property_expenses (or property_profit), property_finance_costs,
--   finance_costs_brought_forward; savings_interest; dividends; gift_aid_net, pension_ras;
--   payments_on_account_made. `rates` overrides any 2025/26 default below.
function TaxCalc.compute_full(inp, rates)
    inp = inp or {}
    rates = rates or {}
    local function num(x) return tonumber(x) or 0 end
    local function pos(x, d) local n = tonumber(x); return (n and n > 0) and n or d end
    local function r2(x) return math.floor(num(x) * 100 + 0.5) / 100 end

    local p = {
        pa = pos(rates.personal_allowance, 12570),
        taper = pos(rates.taper_threshold, 100000),
        basic_band = pos(rates.basic_rate_band, 37700),
        add_threshold = pos(rates.additional_rate_threshold, 125140),
        basic_rate = pos(rates.basic_rate, 0.20),
        higher_rate = pos(rates.higher_rate, 0.40),
        add_rate = pos(rates.additional_rate, 0.45),
        srs = rates.starting_rate_for_savings or 5000,
        psa_basic = rates.psa_basic or 1000,
        psa_higher = rates.psa_higher or 500,
        psa_add = rates.psa_additional or 0,
        div_allowance = rates.dividend_allowance or 500,
        div_basic = rates.dividend_basic_rate or 0.0875,
        div_higher = rates.dividend_higher_rate or 0.3375,
        div_add = rates.dividend_additional_rate or 0.3935,
        fin_reduction = rates.finance_cost_reduction_rate or 0.20,
        nic4_lower = pos(rates.nic_lower, 12570),
        nic4_upper = pos(rates.nic_upper, 50270),
        nic4_main = pos(rates.nic_main_rate, 0.06),
        nic4_add = pos(rates.nic_additional_rate, 0.02),
        class2_spt = pos(rates.class2_threshold, 6845),
        trading_allowance = rates.trading_allowance or 1000,
        property_allowance = rates.property_allowance or 1000,
    }

    -- Step 1: net income per source (trading/property allowance = lower resulting profit).
    local employment = math.max(0, num(inp.employment_income) - num(inp.employment_expenses))
    local se_turnover = num(inp.se_turnover)
    local trading_profit = inp.trading_profit and num(inp.trading_profit) or math.min(
        math.max(0, se_turnover - num(inp.se_expenses) - num(inp.se_capital_allowances)),
        math.max(0, se_turnover - math.min(p.trading_allowance, se_turnover)))
    local prop_rents = num(inp.property_rents)
    local property_profit = inp.property_profit and num(inp.property_profit) or math.min(
        math.max(0, prop_rents - num(inp.property_expenses)),
        math.max(0, prop_rents - math.min(p.property_allowance, prop_rents)))
    local finance_costs = num(inp.property_finance_costs) + num(inp.finance_costs_brought_forward)
    local savings = num(inp.savings_interest)
    local dividends = num(inp.dividends)

    -- Step 2 + 3: total and adjusted net income.
    local non_savings = employment + trading_profit + property_profit
    local total_income = non_savings + savings + dividends
    local gift_aid_gross = r2(num(inp.gift_aid_net) * 100 / 80)
    local pension_gross = r2(num(inp.pension_ras) * 100 / 80)
    local adjusted_net_income = total_income - gift_aid_gross - pension_gross

    -- Step 4: taper the personal allowance.
    local pa = p.pa
    if adjusted_net_income > p.taper then
        pa = math.max(0, pa - math.floor((adjusted_net_income - p.taper) / 2))
    end

    -- Step 5: allocate PA — non-savings first, then savings, then dividends.
    local pa_left = pa
    local taxable_non_savings = math.max(0, non_savings - pa_left); pa_left = math.max(0, pa_left - non_savings)
    local taxable_savings = math.max(0, savings - pa_left); pa_left = math.max(0, pa_left - savings)
    local taxable_dividends = math.max(0, dividends - pa_left)

    -- Step 6: extend bands by gross Gift Aid + pension.
    local basic_limit = p.basic_band + gift_aid_gross + pension_gross
    local higher_limit = p.add_threshold + gift_aid_gross + pension_gross

    local total_taxable = taxable_non_savings + taxable_savings + taxable_dividends
    local psa = p.psa_basic
    if total_taxable > higher_limit then psa = p.psa_add
    elseif total_taxable > basic_limit then psa = p.psa_higher end

    -- Step 7: tax by band. A slice sits on top of `floor` (band space already used).
    local function tax_bands(amount, floor, rb, rh, ra)
        local tax, rem = 0, amount
        local inb = math.min(rem, math.max(0, basic_limit - floor)); tax = tax + inb * rb; rem = rem - inb; floor = floor + inb
        local inh = math.min(rem, math.max(0, higher_limit - floor)); tax = tax + inh * rh; rem = rem - inh; floor = floor + inh
        tax = tax + rem * ra; floor = floor + rem
        return tax, floor
    end

    local floor = 0
    local tax_non_savings; tax_non_savings, floor = tax_bands(taxable_non_savings, floor, p.basic_rate, p.higher_rate, p.add_rate)

    -- Savings: starting-rate-for-savings (0%) and PSA (0%) consume band space; rest at main rates.
    local srs_band = math.max(0, p.srs - taxable_non_savings)
    local srs_used = math.min(taxable_savings, srs_band); floor = floor + srs_used
    local after_srs = taxable_savings - srs_used
    local psa_used = math.min(after_srs, psa); floor = floor + psa_used
    local tax_savings; tax_savings, floor = tax_bands(after_srs - psa_used, floor, p.basic_rate, p.higher_rate, p.add_rate)

    -- Dividends: allowance (0%) consumes band space; rest at dividend rates.
    local div_used = math.min(taxable_dividends, p.div_allowance); floor = floor + div_used
    local tax_dividends; tax_dividends, floor = tax_bands(taxable_dividends - div_used, floor, p.div_basic, p.div_higher, p.div_add)

    local income_tax_before_reductions = tax_non_savings + tax_savings + tax_dividends

    -- Step 8: residential finance cost reduction = 20% of the lowest of
    -- (finance costs) / (property profit) / (adjusted income above PA).
    local adj_income_above_pa = math.max(0, non_savings - pa)
    local fc_lowest = math.min(finance_costs, property_profit, adj_income_above_pa)
    local finance_cost_reduction = r2(fc_lowest * p.fin_reduction)
    local income_tax_due = math.max(0, income_tax_before_reductions - finance_cost_reduction)

    -- Step 9: NIC. Class 4 on trading profit only; Class 2 credited free above the SPT.
    local class4 = 0
    if trading_profit > p.nic4_lower then
        class4 = (math.min(trading_profit, p.nic4_upper) - p.nic4_lower) * p.nic4_main
        if trading_profit > p.nic4_upper then class4 = class4 + (trading_profit - p.nic4_upper) * p.nic4_add end
    end
    class4 = r2(class4)
    local class2 = 0

    -- Step 10: total, tax at source, payments on account.
    local total_liability = r2(income_tax_due + class4 + class2)
    local paye = num(inp.paye_deducted)
    local balancing = r2(total_liability - paye - num(inp.payments_on_account_made))
    local relevant_for_poa = r2(total_liability - paye) -- income tax + Class 4 not collected at source
    local collected_pct = total_liability > 0 and (paye / total_liability) or 0
    local poa_each = (relevant_for_poa > 1000 and collected_pct < 0.80) and r2(relevant_for_poa / 2) or 0

    return {
        schedules = {
            employment = employment, trading_profit = trading_profit, property_profit = property_profit,
            savings = savings, dividends = dividends, finance_costs = finance_costs,
        },
        non_savings = non_savings, savings_income = savings, dividend_income = dividends,
        total_income = total_income,
        gift_aid_gross = gift_aid_gross, pension_gross = pension_gross,
        adjusted_net_income = adjusted_net_income,
        personal_allowance = pa,
        taxable_non_savings = taxable_non_savings, taxable_savings = taxable_savings,
        taxable_dividends = taxable_dividends, total_taxable = total_taxable,
        basic_limit = basic_limit, higher_limit = higher_limit,
        starting_rate_for_savings_used = srs_used, personal_savings_allowance = psa, psa_used = psa_used,
        dividend_allowance_used = div_used,
        tax_non_savings = r2(tax_non_savings), tax_savings = r2(tax_savings), tax_dividends = r2(tax_dividends),
        income_tax_before_reductions = r2(income_tax_before_reductions),
        finance_cost_reduction = finance_cost_reduction,
        finance_costs_carried_forward = math.max(0, finance_costs - fc_lowest),
        income_tax_due = r2(income_tax_due),
        class4_nic = class4, class2_nic = class2,
        total_liability = total_liability,
        paye_deducted = paye,
        balancing_payment = balancing,
        payment_on_account_each = poa_each,
        total_due_31_jan = r2(balancing + poa_each),
        is_estimate = true,
    }
end

return TaxCalc
