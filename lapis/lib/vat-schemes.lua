-- Less common VAT schemes (VAT plan phase 10, docs/plans/VAT_MTD.md).
--
--   * partial exemption annual adjustment (Notice 706 §10): at the end of the
--     partial exemption year, recover on the whole year's figures and put the
--     difference from what the returns recovered on the next return;
--   * the capital goods scheme (Notice 706/2): input VAT on big-ticket land,
--     buildings, ships and aircraft is adjusted over 5 or 10 intervals as their
--     taxable use changes, and on sale;
--   * EC Sales List lines for Northern Ireland goods sold to EU VAT-registered
--     customers.
-- (Margin scheme global accounting and VAT groups live in lib/vat-return.)
-- Pure: no database. Figures are deterministic; the AI never computes them.

local VAT = require("lib.vat")
local Return = require("lib.vat-return")

local S = {}

local round2 = VAT.round2
local function num(x) return tonumber(x) or 0 end

-- ---------------------------------------------------------------------------
-- Partial exemption: the annual adjustment
-- ---------------------------------------------------------------------------

--- The annual adjustment for a partial exemption year.
-- @param year_lines every coded line of the year (as for Return.build)
-- @param reg the registration (partially_exempt)
-- @param claimed input VAT the year's returns recovered (sum of their Box 4 from lines)
-- @return { annual_pct, de_minimis, tests, should_recover, claimed, adjustment, direction }
function S.annual_adjustment(year_lines, reg, claimed)
    local r = {}
    for k, v in pairs(reg or {}) do r[k] = v end
    r.partially_exempt = true
    r.scheme = (r.scheme == "flat_rate") and "standard" or r.scheme
    -- First the year's own recovery %, then recover the whole year on it.
    local probe = Return.build(year_lines, r, { period_months = 12, recovery_pct = 100 })
    local pe = probe.partial_exemption
    local pct = Return.recovery_pct(pe.taxable_supplies, pe.exempt_supplies)
    local res = Return.build(year_lines, r, { period_months = 12, recovery_pct = pct })
    local should = res.partial_exemption.input_vat_recovered
    local adj = round2(should - num(claimed))
    return {
        annual_pct = pct, de_minimis = res.partial_exemption.de_minimis, tests = res.partial_exemption.tests,
        taxable_supplies = pe.taxable_supplies, exempt_supplies = pe.exempt_supplies,
        should_recover = should, claimed = round2(num(claimed)), adjustment = adj,
        direction = adj > 0.004 and "claim" or (adj < -0.004 and "repay" or "none"),
        note = "Put the adjustment in Box 4 of the first return after the year ends (or the last return of "
            .. "the year). Next year's provisional recovery % is this year's: " .. pct .. "%.",
    }
end

-- ---------------------------------------------------------------------------
-- Capital goods scheme (Notice 706/2)
-- ---------------------------------------------------------------------------

S.CGS_KINDS = {
    land = { label = "Land", threshold = 250000, intervals = 10 },
    building = { label = "Building (or part)", threshold = 250000, intervals = 10 },
    civil_engineering = { label = "Civil engineering work", threshold = 250000, intervals = 10 },
    refurbishment = { label = "Building refurbishment or fitting out", threshold = 250000, intervals = 10 },
    ship = { label = "Ship or boat", threshold = 50000, intervals = 5 },
    aircraft = { label = "Aircraft", threshold = 50000, intervals = 5 },
}

--- Is the item in the scheme? (VAT-exclusive cost at or over the threshold.)
function S.cgs_applies(kind, cost_ex_vat)
    local k = S.CGS_KINDS[kind or ""]
    return k ~= nil and num(cost_ex_vat) >= k.threshold
end

--- Number of intervals: 10 for land and buildings (5 when the interest has less
-- than 10 years to run), 5 for ships, boats and aircraft.
function S.cgs_intervals(kind, short_lease)
    local k = S.CGS_KINDS[kind or ""]
    if not k then return nil end
    if k.intervals == 10 and short_lease then return 5 end
    return k.intervals
end

--- Validate a capital item. @return clean table or nil, message
function S.validate_item(f)
    f = f or {}
    local k = S.CGS_KINDS[f.kind or ""]
    if not k then return nil, "kind must be one of land, building, civil_engineering, refurbishment, ship, aircraft" end
    local cost, input = tonumber(f.cost_ex_vat), tonumber(f.input_vat)
    if not cost or cost <= 0 then return nil, "cost_ex_vat must be a positive amount" end
    if not input or input < 0 then return nil, "input_vat must be zero or more" end
    if not S.cgs_applies(f.kind, cost) then
        return nil, string.format("%s under £%s isn't in the capital goods scheme", k.label,
            tostring(k.threshold))
    end
    local orig = tonumber(f.original_use_pct)
    if not orig or orig < 0 or orig > 100 then return nil, "original_use_pct must be 0–100" end
    local short = f.short_lease == true or f.short_lease == "true"
    return { kind = f.kind, cost_ex_vat = round2(cost), input_vat = round2(input), original_use_pct = orig,
        intervals = S.cgs_intervals(f.kind, short) }
end

--- The adjustment for one later interval: (input VAT / intervals) × (use % now −
-- original use %). Positive: claim more; negative: pay some back.
function S.cgs_interval_adjustment(item, use_pct)
    local n = math.max(1, num(item.intervals))
    return round2(num(item.input_vat) / n * (num(use_pct) - num(item.original_use_pct)) / 100)
end

--- On sale: the remaining complete intervals after the one in which the item is
-- sold count as 100% taxable use if the sale is taxable, 0% if exempt. The
-- interval of sale itself is adjusted as normal (cgs_interval_adjustment).
-- @param intervals_used intervals up to and including the one of sale
-- @param sale_output_vat optional: a claim can't exceed the output VAT on the sale
function S.cgs_disposal(item, intervals_used, sale_taxable, sale_output_vat)
    local n = math.max(1, num(item.intervals))
    local remaining = math.max(0, n - math.floor(num(intervals_used)))
    local use = sale_taxable and 100 or 0
    local each = num(item.input_vat) / n * (use - num(item.original_use_pct)) / 100
    local total = round2(each * remaining)
    local capped = false
    if total > 0 and sale_output_vat ~= nil and total > num(sale_output_vat) then
        total, capped = round2(num(sale_output_vat)), true
    end
    return { remaining_intervals = remaining, adjustment = total, capped = capped }
end

-- ---------------------------------------------------------------------------
-- EC Sales List (Northern Ireland goods to EU VAT-registered customers)
-- ---------------------------------------------------------------------------

S.EU_PREFIXES = { AT = 1, BE = 1, BG = 1, CY = 1, CZ = 1, DE = 1, DK = 1, EE = 1, EL = 1, ES = 1, FI = 1,
    FR = 1, HR = 1, HU = 1, IE = 1, IT = 1, LT = 1, LU = 1, LV = 1, MT = 1, NL = 1, PL = 1, PT = 1, RO = 1,
    SE = 1, SI = 1, SK = 1 }
S.ESL_QUARTERLY_LIMIT = 35000

--- Normalise an EU VAT number: "de 123 456 789" -> "DE", "123456789"; nil if not EU.
function S.eu_vat_number(s)
    local v = tostring(s or ""):upper():gsub("[%s%.%-]", "")
    local cc, rest = v:match("^(%u%u)(%w+)$")
    if not cc or not S.EU_PREFIXES[cc] or #rest < 2 or #rest > 12 then return nil end
    return cc, rest
end

--- The EC Sales List for a period.
-- @param lines { { customer_vat_number, customer_name, net, triangulation? } } — NI goods sales to the EU
-- @return { rows = { {country, vat_number, value, indicator} }, total, missing = { {customer_name, net} },
--   frequency_hint }
function S.ec_sales_list(lines)
    local by, order, missing, total = {}, {}, {}, 0
    for _, l in ipairs(lines or {}) do
        local cc, no = S.eu_vat_number(l.customer_vat_number)
        local net = num(l.net)
        if not cc then
            missing[#missing + 1] = { customer_name = l.customer_name, net = round2(net), invoice = l.invoice }
        else
            local ind = l.triangulation and 2 or 0
            local key = cc .. no .. ":" .. ind
            if not by[key] then
                by[key] = { country = cc, vat_number = no, value = 0, indicator = ind }
                order[#order + 1] = key
            end
            by[key].value = by[key].value + net
            total = total + net
        end
    end
    local rows = {}
    for _, k in ipairs(order) do
        local r = by[k]
        r.value = math.floor(r.value + 0.5) -- whole pounds sterling
        rows[#rows + 1] = r
    end
    table.sort(rows, function(a, b)
        if a.country ~= b.country then return a.country < b.country end
        return a.vat_number < b.vat_number
    end)
    return { rows = rows, total = round2(total), missing = missing,
        frequency_hint = total > S.ESL_QUARTERLY_LIMIT and "monthly" or "quarterly" }
end

--- CSV of the list (to key into HMRC's online EC Sales List, or keep as a record).
function S.ec_sales_csv(esl)
    local out = { "country_code,customer_vat_number,total_value_gbp,indicator" }
    for _, r in ipairs(esl.rows or {}) do
        out[#out + 1] = string.format("%s,%s,%d,%d", r.country, r.vat_number, r.value, r.indicator)
    end
    return table.concat(out, "\n") .. "\n"
end

return S
