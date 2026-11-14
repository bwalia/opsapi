-- The 9-box VAT return engine (VAT plan phase 2, docs/plans/VAT_MTD.md).
--
-- Deterministic: the same lines, registration and adjustments always give the same
-- boxes. The AI never computes a figure; it may only suggest the VAT code of a line
-- (phase 3). Every box keeps the list of lines (and adjustments) behind it.
--
-- Input lines (from tax_transactions / accounting tables, already VAT-coded):
--   { id, date, direction = "sale"|"purchase", vat_code, net, vat, notional_vat,
--     reclaimable_pct, gross, capital_asset?, relevant_goods? }
-- Registration: { scheme = standard|cash|flat_rate|annual, flat_rate_pct,
--   flat_rate_first_year, limited_cost_trader, partially_exempt, recovery_pct }
-- Adjustments: { type = "fuel_scale"|"bad_debt_relief"|"correction", ... } (see below)
--
-- Sources: VAT Notice 700/12 (filling in the return), 733 (Flat Rate Scheme),
-- 731 (cash accounting), 732 (annual accounting), 700/45 (correcting errors),
-- 700/18 (bad debt relief), 706 (partial exemption), 741A / 735 (reverse charges),
-- 702 (postponed import VAT).

local VAT = require("lib.vat")

local Return = {}

local round2 = VAT.round2

-- Boxes 6–9 are whole pounds; HMRC allows rounding down, which we do (towards zero).
local function whole(x)
    x = tonumber(x) or 0
    if x >= 0 then return math.floor(x) end
    return -math.floor(-x)
end

Return.LIMITED_COST_RATE = 16.5
Return.FRS_CAPITAL_THRESHOLD = 2000       -- VAT-inclusive, single purchase (Notice 733)
Return.CORRECTION_FLOOR = 10000           -- Notice 700/45
Return.CORRECTION_CAP = 50000
Return.BAD_DEBT_MONTHS = 6                -- Notice 700/18
Return.DE_MINIMIS_MONTHLY = 625           -- Notice 706, test 1

local function num(x) return tonumber(x) or 0 end

local function months_between(from_date, to_date)
    local y1, m1, d1 = tostring(from_date or ""):match("^(%d+)%-(%d+)%-(%d+)")
    local y2, m2, d2 = tostring(to_date or ""):match("^(%d+)%-(%d+)%-(%d+)")
    if not y1 or not y2 then return nil end
    local m = (tonumber(y2) - tonumber(y1)) * 12 + (tonumber(m2) - tonumber(m1))
    if tonumber(d2) < tonumber(d1) then m = m - 1 end
    return m
end
Return._months_between = months_between

--- Does the business pass the limited-cost trader test (Notice 733 §4.5)?
-- Relevant goods cost less than 2% of VAT-inclusive turnover, or less than
-- £1,000 a year (£250 a quarter, pro rata).
function Return.limited_cost_test(turnover_gross, relevant_goods_gross, period_months)
    local months = tonumber(period_months) or 3
    local goods = num(relevant_goods_gross)
    return goods < 0.02 * num(turnover_gross) or goods < 1000 * months / 12
end

--- The error-correction threshold for a return (Notice 700/45): £10,000, or 1% of
-- Box 6 up to £50,000 — whichever is greater.
function Return.correction_threshold(box6)
    return math.max(Return.CORRECTION_FLOOR, math.min(0.01 * math.abs(num(box6)), Return.CORRECTION_CAP))
end

--- Partial exemption de minimis, simplified test 1 (Notice 706 §11): total input
-- tax no more than £625 a month on average, and exempt supplies no more than half
-- of all supplies. Passing means all input VAT can be recovered.
function Return.de_minimis_test(total_input_vat, exempt_supplies, all_supplies, period_months)
    local months = tonumber(period_months) or 3
    return num(total_input_vat) <= Return.DE_MINIMIS_MONTHLY * months
        and num(exempt_supplies) <= 0.5 * num(all_supplies)
end

--- Build the return.
-- @param lines table, @param reg table, @param opts { period_start, period_end,
--   adjustments = {...}, period_months }
-- @return { boxes = {box1..box9}, direction = "pay"|"repay"|"nil", audit = { box = {ids} },
--           warnings = {...}, notes = {...}, flat_rate = {...}?, partial_exemption = {...}?,
--           corrections = {...} }
function Return.build(lines, reg, opts)
    reg, opts = reg or {}, opts or {}
    local scheme = reg.scheme or "standard"
    local months = opts.period_months or (scheme == "annual" and 12 or 3)
    local b = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    local audit = {}
    for i = 1, 9 do audit["box" .. i] = {} end
    local warnings, notes = {}, {}
    local function add(box, amount, ref)
        if amount == 0 then return end
        b[box] = b[box] + amount
        if ref ~= nil then
            local list = audit["box" .. box]
            list[#list + 1] = ref
        end
    end

    local flat = scheme == "flat_rate"
    local turnover_gross, exempt_sales, all_sales = 0, 0, 0
    local input_vat_total = 0
    local input_refs = {}

    for _, l in ipairs(lines or {}) do
        local c = VAT.code(l.vat_code)
        local id = l.id
        if not c then
            warnings[#warnings + 1] = "Line " .. tostring(id) .. " has no VAT code and is left out."
        elseif not c.outside then
            local net, vat, notional = num(l.net), num(l.vat), num(l.notional_vat)
            local pct = l.reclaimable_pct
            if pct == nil then pct = c.reclaimable end
            pct = math.max(0, math.min(100, num(pct)))

            if l.direction == "sale" then
                if flat then
                    -- FRS: the flat % applies to VAT-inclusive turnover of all supplies.
                    local gross = l.gross ~= nil and num(l.gross) or (net + vat)
                    turnover_gross = turnover_gross + gross
                    add(6, gross, id)
                else
                    if c.code == "RC_CIS" then
                        -- Supplier under the CIS reverse charge: value in Box 6, no VAT.
                        add(6, net, id)
                    elseif c.code == "NI_EU_GOODS" then
                        add(6, net, id); add(8, net, id) -- dispatch to the EU, zero-rated
                    else
                        add(1, vat, id); add(6, net, id)
                    end
                end
                all_sales = all_sales + net
                if c.code == "EXEMPT" then exempt_sales = exempt_sales + net end
            elseif l.direction == "purchase" then
                if flat then
                    -- FRS: only capital assets costing £2,000+ including VAT are claimed.
                    local gross = l.gross ~= nil and num(l.gross) or (net + vat)
                    if l.capital_asset and gross >= Return.FRS_CAPITAL_THRESHOLD then
                        add(4, round2(vat * pct / 100), id); add(7, net, id)
                    end
                else
                    if c.code == "RC_SERVICES" then
                        -- Reverse charge on services: output and input VAT, value in 6 and 7.
                        add(1, notional, id); add(6, net, id)
                        add(4, round2(notional * pct / 100), id); add(7, net, id)
                        input_vat_total = input_vat_total + notional
                    elseif c.code == "RC_CIS" or c.code == "PVA" then
                        -- CIS customer / postponed import VAT: VAT in Box 1 and 4, value in 7.
                        add(1, notional, id)
                        add(4, round2(notional * pct / 100), id); add(7, net, id)
                        input_vat_total = input_vat_total + notional
                    elseif c.code == "NI_EU_GOODS" then
                        -- NI acquisition from the EU: Box 2 and 4, value in 7 and 9.
                        add(2, notional, id)
                        add(4, round2(notional * pct / 100), id); add(7, net, id); add(9, net, id)
                        input_vat_total = input_vat_total + notional
                    else
                        add(4, round2(vat * pct / 100), id); add(7, net, id)
                        input_vat_total = input_vat_total + vat
                    end
                    if vat > 0 or notional > 0 then input_refs[#input_refs + 1] = id end
                end
            end
        end
    end

    -- Flat Rate Scheme: Box 1 = flat % x VAT-inclusive turnover.
    local flat_info
    if flat then
        local pct = num(reg.flat_rate_pct)
        local lct = reg.limited_cost_trader == true or reg.limited_cost_trader == "t"
        if lct then pct = Return.LIMITED_COST_RATE end
        if reg.flat_rate_first_year == true or reg.flat_rate_first_year == "t" then pct = pct - 1 end
        local box1 = round2(turnover_gross * pct / 100)
        b[1] = b[1] + box1
        audit.box1 = audit.box6
        flat_info = { rate_used = pct, turnover_gross = round2(turnover_gross), limited_cost_trader = lct }
        if opts.relevant_goods_gross ~= nil then
            local passes = Return.limited_cost_test(turnover_gross, opts.relevant_goods_gross, months)
            flat_info.limited_cost_test = passes
            if passes and not lct then
                warnings[#warnings + 1] = "Your spending on goods looks low enough to make you a limited-cost "
                    .. "trader: the flat rate would be 16.5%. Check with your accountant and update your VAT details."
            end
        end
    end

    -- Partial exemption: recover only the recovery % of input VAT unless de minimis.
    local pe_info
    if not flat and (reg.partially_exempt == true or reg.partially_exempt == "t") then
        local dm = Return.de_minimis_test(input_vat_total, exempt_sales, all_sales, months)
        local pct = dm and 100 or math.max(0, math.min(100, num(reg.recovery_pct)))
        local before = b[4]
        b[4] = round2(before * pct / 100)
        pe_info = { de_minimis = dm, recovery_pct = pct, input_vat_before = round2(before),
            input_vat_recovered = b[4] }
        notes[#notes + 1] = dm
            and "Partial exemption: under the de minimis limits, so all input VAT is recovered."
            or string.format("Partial exemption: %.2f%% of input VAT recovered.", pct)
    end

    -- Adjustments.
    local corrections = { applied = {}, too_large = {} }
    local correction_net = 0
    for _, a in ipairs(opts.adjustments or {}) do
        local ref = "adj:" .. tostring(a.id or a.type)
        if a.type == "fuel_scale" then
            -- Fuel scale charge (Notice 700/64): VAT to Box 1, VAT-exclusive value to Box 6.
            add(1, num(a.vat), ref); add(6, num(a.net), ref)
        elseif a.type == "bad_debt_relief" then
            local m = months_between(a.due_date, opts.period_end)
            if not (a.written_off == true or a.written_off == "t") then
                warnings[#warnings + 1] = "Bad debt relief needs the debt written off in your accounts first."
            elseif not m or m < Return.BAD_DEBT_MONTHS then
                warnings[#warnings + 1] = "Bad debt relief can only be claimed once the debt is 6 months overdue."
            else
                add(4, num(a.vat), ref)
            end
        elseif a.type == "correction" then
            corrections[#corrections + 1] = a
            correction_net = correction_net + num(a.box1) - num(a.box4)
        end
    end
    -- Earlier-period errors (Notice 700/45): within the threshold they go on this
    -- return; above it they must be disclosed to HMRC separately — never added.
    if #corrections > 0 then
        local threshold = Return.correction_threshold(b[6])
        if math.abs(correction_net) <= threshold then
            for _, a in ipairs(corrections) do
                local ref = "adj:" .. tostring(a.id or "correction")
                add(1, num(a.box1), ref); add(4, num(a.box4), ref)
                corrections.applied[#corrections.applied + 1] = a.id or true
            end
        else
            for _, a in ipairs(corrections) do corrections.too_large[#corrections.too_large + 1] = a.id or true end
            warnings[#warnings + 1] = string.format("Earlier errors totalling £%.2f are over the £%.2f limit for "
                .. "correcting on a return: tell HMRC separately (form VAT652). They were not added.",
                math.abs(correction_net), threshold)
        end
        corrections.threshold = threshold
    end

    local boxes = {
        box1 = round2(b[1]), box2 = round2(b[2]),
        box6 = whole(b[6]), box7 = whole(b[7]), box8 = whole(b[8]), box9 = whole(b[9]),
        box4 = round2(b[4]),
    }
    boxes.box3 = round2(boxes.box1 + boxes.box2)
    boxes.box5 = round2(math.abs(boxes.box3 - boxes.box4))
    local diff = boxes.box3 - boxes.box4
    local direction = diff > 0.004 and "pay" or (diff < -0.004 and "repay" or "nil")

    if #input_refs > 0 and not flat then
        notes[#notes + 1] = #input_refs .. " purchase line(s) with VAT reclaimed."
    end
    return {
        boxes = boxes, direction = direction, audit = audit, warnings = warnings, notes = notes,
        flat_rate = flat_info, partial_exemption = pe_info,
        corrections = (#corrections > 0) and corrections or nil, scheme = scheme,
    }
end

--- Check boxes against HMRC's submission rules before sending anything.
-- @return true, or false + list of { box, message }
function Return.validate(boxes)
    local errs = {}
    local function e(box, msg) errs[#errs + 1] = { box = box, message = msg } end
    for _, k in ipairs({ "box1", "box2", "box3", "box4" }) do
        local v = tonumber(boxes[k])
        if v == nil then e(k, "missing")
        elseif math.abs(v) > 9999999999999.99 then e(k, "out of range")
        elseif round2(v) ~= v then e(k, "must be to the penny") end
    end
    local b5 = tonumber(boxes.box5)
    if b5 == nil or b5 < 0 or b5 > 99999999999.99 then e("box5", "must be between 0 and 99,999,999,999.99") end
    for _, k in ipairs({ "box6", "box7", "box8", "box9" }) do
        local v = tonumber(boxes[k])
        if v == nil then e(k, "missing")
        elseif v ~= math.floor(v) then e(k, "must be whole pounds")
        elseif math.abs(v) > 9999999999999 then e(k, "out of range") end
    end
    if #errs == 0 then
        if round2(boxes.box1 + boxes.box2) ~= round2(boxes.box3) then e("box3", "must equal Box 1 + Box 2") end
        if round2(math.abs(boxes.box3 - boxes.box4)) ~= round2(boxes.box5) then
            e("box5", "must equal the difference between Box 3 and Box 4")
        end
    end
    if #errs > 0 then return false, errs end
    return true
end

--- Interim payments under annual accounting (Notice 732): 9 monthly payments of
-- 10%, or 3 quarterly payments of 25%, of last year's liability (or an estimate).
function Return.annual_interim(previous_liability, frequency)
    local base = math.max(0, num(previous_liability))
    if frequency == "quarterly" then
        return { count = 3, each = round2(base * 0.25) }
    end
    return { count = 9, each = round2(base * 0.10) }
end

return Return
