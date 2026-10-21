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
        if trading_profit >= rates.class2_threshold then
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

return TaxCalc
