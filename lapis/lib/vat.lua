-- VAT records: the facts every VAT feature reads (codes, VAT numbers, net/VAT
-- splits, supplier rules). Pure functions, no database, so the 9-box engine,
-- the AI classifier and the screens all agree. Phase 1 of the VAT plan
-- (docs/plans/VAT_MTD.md).
--
-- The AI never does VAT arithmetic: it may suggest a code; the figures come from here.

local VAT = {}

-- Every VAT treatment a line can have. `rate` is the VAT rate in %; `reverse`
-- marks treatments where the business accounts for the VAT itself (it appears
-- as both output and input VAT on the return, so the net effect is nil for a
-- fully taxable business). `reclaimable` is the default share of input VAT that
-- can be reclaimed.
VAT.CODES = {
    { code = "STD20", label = "Standard rate (20%)", rate = 20, reclaimable = 100 },
    { code = "RED5", label = "Reduced rate (5%)", rate = 5, reclaimable = 100 },
    { code = "ZERO", label = "Zero-rated (0%)", rate = 0, reclaimable = 100 },
    { code = "EXEMPT", label = "Exempt", rate = 0, reclaimable = 0, no_vat = true },
    { code = "OUTSIDE", label = "Outside the scope of VAT", rate = 0, reclaimable = 0, no_vat = true,
      outside = true },
    { code = "RC_SERVICES", label = "Reverse charge: services from abroad", rate = 20, reclaimable = 100,
      reverse = true },
    { code = "RC_CIS", label = "Reverse charge: construction (CIS)", rate = 20, reclaimable = 100,
      reverse = true },
    { code = "PVA", label = "Postponed import VAT", rate = 20, reclaimable = 100, reverse = true },
    -- Goods moving between Northern Ireland and the EU: a sale (dispatch) is
    -- zero-rated; a purchase (acquisition) carries no supplier VAT and the buyer
    -- accounts for it (Boxes 2 and 4) — so it splits like a reverse charge.
    { code = "NI_EU_GOODS", label = "Northern Ireland: goods to/from the EU", rate = 20, reclaimable = 100,
      reverse = true },
    -- Second-hand goods under the margin scheme (Notice 718): no VAT on the invoice;
    -- the return charges 1/6 of the period's margin (global accounting).
    { code = "MARGIN", label = "Margin scheme (second-hand goods)", rate = 0, reclaimable = 0, no_vat = true,
      margin = true },
}

local BY_CODE = {}
for _, c in ipairs(VAT.CODES) do BY_CODE[c.code] = c end

--- The definition of a VAT code, or nil.
function VAT.code(code)
    return code and BY_CODE[tostring(code):upper()] or nil
end

-- VAT schemes a registration can be on.
VAT.SCHEMES = {
    standard = "Standard (accrual)",
    cash = "Cash accounting",
    flat_rate = "Flat Rate Scheme",
    annual = "Annual accounting",
}

--- Round to the penny, half away from zero (HMRC rounds VAT to the penny).
function VAT.round2(x)
    x = tonumber(x) or 0
    if x >= 0 then return math.floor(x * 100 + 0.5) / 100 end
    return -math.floor(-x * 100 + 0.5) / 100
end
local round2 = VAT.round2

--- Normalise a VAT registration number: drop a "GB" prefix, spaces and dashes.
function VAT.normalise_vrn(vrn)
    if vrn == nil then return nil end
    local s = tostring(vrn):upper():gsub("[%s%-%.]", "")
    s = s:gsub("^GB", "")
    return s
end

--- Is this a valid UK VAT registration number (9 digits, HMRC check digits)?
-- HMRC's modulus 97 check: weight the first 7 digits 8..2, add the last two
-- digits; valid when the total is divisible by 97 (old series) or when the total
-- + 55 is (the "9755" series issued since 2010).
-- @return normalised VRN, or nil + reason
function VAT.valid_vrn(vrn)
    local s = VAT.normalise_vrn(vrn)
    if not s or s == "" then return nil, "Enter the VAT registration number" end
    if not s:match("^%d%d%d%d%d%d%d%d%d$") then
        return nil, "A UK VAT number is 9 digits (with or without GB in front)"
    end
    local total = 0
    for i = 1, 7 do total = total + tonumber(s:sub(i, i)) * (9 - i) end
    total = total + tonumber(s:sub(8, 9))
    if total % 97 == 0 or (total + 55) % 97 == 0 then return s end
    return nil, "That VAT number doesn't pass HMRC's check — please check the digits"
end

--- Split a line into net and VAT.
-- @param gross number  the amount on the bank line / invoice total (VAT inclusive
--                      for normal codes; for reverse-charge and postponed import
--                      VAT the amount paid IS the net — no VAT was charged)
-- @param code  string  VAT code
-- @param opts  table?  { vat_amount = n } — the VAT shown on the receipt/invoice
--                      wins over a calculated figure
-- @return { net, vat, notional_vat, code } or nil, err
--   vat           VAT actually charged by the supplier (in the gross)
--   notional_vat  VAT the business accounts for itself (reverse charge / PVA):
--                 goes to Box 1 and, if reclaimable, Box 4
function VAT.split(gross, code, opts)
    opts = opts or {}
    local c = VAT.code(code)
    if not c then return nil, "Unknown VAT code " .. tostring(code) end
    local g = tonumber(gross)
    if not g then return nil, "Amount is not a number" end
    local sign = g < 0 and -1 or 1
    local a = math.abs(g)

    if c.reverse then
        return { code = c.code, net = round2(g), vat = 0, notional_vat = round2(sign * a * c.rate / 100) }
    end
    if c.no_vat or c.rate == 0 then
        return { code = c.code, net = round2(g), vat = 0, notional_vat = 0 }
    end

    local vat
    if opts.vat_amount ~= nil then
        vat = tonumber(opts.vat_amount)
        if not vat or vat < 0 or vat > a then
            return nil, "The VAT on the receipt must be between £0 and the total"
        end
        vat = sign * vat
    else
        vat = sign * a * c.rate / (100 + c.rate)
    end
    vat = round2(vat)
    return { code = c.code, net = round2(g - vat), vat = vat, notional_vat = 0 }
end

--- Do net + VAT make the gross (to the penny, allowing 1p for imported figures)?
function VAT.split_ok(gross, net, vat)
    return math.abs(round2((tonumber(net) or 0) + (tonumber(vat) or 0)) - round2(tonumber(gross) or 0)) <= 0.01
end

--- The VAT a business can reclaim on a line: VAT (charged or notional) × share.
function VAT.reclaimable(vat, notional_vat, pct)
    local p = tonumber(pct)
    if p == nil then p = 100 end
    p = math.max(0, math.min(100, p))
    return round2(((tonumber(vat) or 0) + (tonumber(notional_vat) or 0)) * p / 100)
end

--- Normalise text for rule matching: upper case, single spaces, no punctuation noise.
function VAT.norm(text)
    local s = tostring(text or ""):upper()
    s = s:gsub("[^%w%s&]", " "):gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A database NULL arrives as ngx.null, not nil.
local function is_null(v)
    return v == nil or (ngx ~= nil and v == ngx.null)
end

-- How specific a match type is (higher wins when several rules match).
local SPECIFICITY = { merchant = 3, contains = 2, category = 1 }

--- Pick the rule for a line. A business's own rules beat global ones; among
-- those, merchant > contains > category, then the longest match text.
-- @param rules table list of { match_type, match_value, vat_code, reclaimable_pct,
--                              registration_id (nil = global), is_active }
-- @param line  table { description, merchant, category }
-- @return the winning rule or nil
function VAT.match_rule(rules, line)
    line = line or {}
    local desc, merchant = VAT.norm(line.description), VAT.norm(line.merchant)
    local best, best_score
    for _, r in ipairs(rules or {}) do
        if r.is_active ~= false and r.is_active ~= "f" then
            -- Category keys (software_subscriptions) are compared as they are.
            local v = r.match_type == "category" and tostring(r.match_value or ""):lower()
                or VAT.norm(r.match_value)
            local hit = false
            if v ~= "" then
                if r.match_type == "merchant" then
                    hit = merchant ~= "" and merchant == v
                elseif r.match_type == "contains" then
                    hit = desc:find(v, 1, true) ~= nil or (merchant ~= "" and merchant:find(v, 1, true) ~= nil)
                elseif r.match_type == "category" then
                    hit = line.category ~= nil and tostring(line.category):lower() == v
                end
            end
            if hit then
                local own = is_null(r.registration_id) and 0 or 1
                local score = own * 1000 + (SPECIFICITY[r.match_type] or 0) * 100 + math.min(#v, 99)
                if not best_score or score > best_score then best, best_score = r, score end
            end
        end
    end
    return best
end

--- When is a VAT return for a period due? One calendar month and seven days
-- after the period ends (31 March -> 7 May); annual accounting: two months.
-- @param period_end "YYYY-MM-DD"
function VAT.due_date(period_end, scheme)
    local y, m, d = tostring(period_end or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local months = scheme == "annual" and 2 or 1
    local function last_day(yy, mm) -- day 0 of the next month = last day of mm
        return tonumber(os.date("*t", os.time({ year = yy, month = mm + 1, day = 0, hour = 12 })).day)
    end
    local t
    if d == last_day(y, m) then
        -- Period ends on a month end (the usual case): the due month's last day.
        t = os.time({ year = y, month = m + months + 1, day = 0, hour = 12 })
    else
        t = os.time({ year = y, month = m + months, day = d, hour = 12 })
    end
    if scheme ~= "annual" then t = t + 7 * 86400 end
    return os.date("%Y-%m-%d", t)
end

return VAT
