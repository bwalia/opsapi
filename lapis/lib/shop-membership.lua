-- luacheck: max line length 140
--[[
    Trade membership (price lock + trade discount) — pure rules (no nginx, no DB)
    ========================================================
    Every number the shop shows or charges for membership comes from here, so
    the rules are unit tested in one place (spec/shop-membership-test.lua):

      prices       founding (launch) and standard (after the cap) prices,
                   monthly and yearly, ex VAT and inc VAT
      tier_for     founding while real taken spots < cap, else standard
      spots_left   cap − taken (never negative, never padded)
      lock_until   quote validity for a member's quote (lock_days)
      refund_credit  membership fees → order credit on a qualifying order
      discount_pct   trade discount % for a member's tier (founding / standard)
      apply_discount trade discount against an order subtotal, VAT recomputed
      apply_trade    the Trade discount in force: fixed £ off qualifying orders, or the tier's %
      apply_credits  credits against an order subtotal, VAT recomputed
      tiers / tier_amount / discount_for   fixed £ tiers (highest first) and the discount for a subtotal,
                   limited to what is left of the yearly cap (cap_remaining)
      clawback     discount taken back from a refund when a return drops the order below its tier
      year_bounds  membership year (anniversary of joined_at) containing a moment
      year_fees_net / gap   fees paid for a year (ex VAT) and the refund-the-gap amount

    Money is integer pence. Settings (per namespace, admin-editable) default to
    DEFAULTS below.
]]

local M = {}

M.DEFAULTS = {
    enabled = false,
    monthly_price_minor = 7500,         -- £75 + VAT, founding/launch price
    yearly_months_charged = 10,         -- yearly = 10 × monthly ("2 months free"), paid up front
    vat_rate = 0.20,
    founding_cap = 100,                 -- first N members keep the launch price
    uplift_pct = 33,                    -- standard price = launch × (1 + 33%)
    lock_days = 90,                     -- member quotes hold their price this long (90 or 120)
    refund_threshold_minor = 10000000,  -- order subtotal ex VAT ≥ £100,000 refunds fees as credit
    credit_expiry_days = 365,
    early_access_hours = 24,
    long_lead_days = 21,                -- advisor may mention membership at or above this lead time
    terms_version = "2026-10",
    founding_discount_pct = 5,          -- first founding_cap Trade members: % off catalogue orders (ex VAT)
    standard_discount_pct = 2.5,        -- every Trade member after them
    -- Fixed Trade discount: when discount_fixed_minor > 0 it replaces the % discount for every tier:
    -- that much off (ex VAT) any basket order whose subtotal ex VAT is at least discount_min_order_minor.
    discount_fixed_minor = 50000,       -- £500 ex VAT
    discount_min_order_minor = 500000,  -- on orders of £5,000 ex VAT or more
    -- Second, lower fixed tier (0 = none): £250 off orders of £3,000–£4,999.99 ex VAT by default.
    discount_tier2_minor = 25000,
    discount_tier2_min_order_minor = 300000,
    -- Most Trade discount (order discounts + join credits) one membership year can take; 0 = no cap.
    discount_cap_minor = 150000,
}

M.MAX_DISCOUNT_PCT = 50

M.LOCK_DAYS_ALLOWED = { [90] = true, [120] = true }
M.INTERVALS = { month = true, year = true }

local function round(x) return math.floor(x + 0.5) end

--- Settings row (or nil) merged over DEFAULTS, with sane bounds.
function M.settings(row)
    local s = {}
    for k, v in pairs(M.DEFAULTS) do s[k] = v end
    if type(row) == "table" then
        for k in pairs(M.DEFAULTS) do
            if row[k] ~= nil then s[k] = row[k] end
        end
    end
    s.enabled = s.enabled == true or s.enabled == "t"
    for _, k in ipairs({ "monthly_price_minor", "yearly_months_charged", "founding_cap", "refund_threshold_minor",
                         "credit_expiry_days", "early_access_hours", "long_lead_days", "lock_days",
                         "discount_fixed_minor", "discount_min_order_minor", "discount_tier2_minor",
                         "discount_tier2_min_order_minor", "discount_cap_minor" }) do
        s[k] = math.floor(tonumber(s[k]) or M.DEFAULTS[k])
    end
    s.vat_rate = tonumber(s.vat_rate) or M.DEFAULTS.vat_rate
    s.uplift_pct = tonumber(s.uplift_pct) or M.DEFAULTS.uplift_pct
    for _, k in ipairs({ "founding_discount_pct", "standard_discount_pct" }) do
        local n = tonumber(s[k]) or M.DEFAULTS[k]
        if n < 0 or n > M.MAX_DISCOUNT_PCT then n = M.DEFAULTS[k] end
        s[k] = n
    end
    if not M.LOCK_DAYS_ALLOWED[s.lock_days] then s.lock_days = M.DEFAULTS.lock_days end
    return s
end

--- Cross-field check on the merged (current + update) settings: the lower tier must sit below the top one.
-- Returns true or (nil, message).
function M.validate_tiers(s)
    local t2 = math.floor(tonumber(s.discount_tier2_minor) or 0)
    if t2 <= 0 or (tonumber(s.discount_fixed_minor) or 0) <= 0 then return true end
    if (tonumber(s.discount_tier2_min_order_minor) or 0) >= (tonumber(s.discount_min_order_minor) or 0) then
        return nil, "discount_tier2_min_order_minor must be below discount_min_order_minor"
    end
    if t2 > (tonumber(s.discount_fixed_minor) or 0) then
        return nil, "discount_tier2_minor must not be more than discount_fixed_minor"
    end
    return true
end

--- Validate an admin settings update. Returns (clean_fields) or (nil, message).
function M.validate_update(body)
    if type(body) ~= "table" then return nil, "body must be an object" end
    local out = {}
    local function pos_int(k, min, max)
        if body[k] == nil then return true end
        local n = tonumber(body[k])
        if not n or n ~= math.floor(n) or n < min or n > max then
            return nil, k .. " must be a whole number between " .. min .. " and " .. max
        end
        out[k] = n
        return true
    end
    local checks = {
        { "monthly_price_minor", 100, 10000000 }, { "yearly_months_charged", 1, 12 }, { "founding_cap", 0, 100000 },
        { "refund_threshold_minor", 0, 10000000000 }, { "credit_expiry_days", 1, 3650 },
        { "early_access_hours", 0, 720 }, { "long_lead_days", 1, 365 },
        { "discount_fixed_minor", 0, 10000000 }, { "discount_min_order_minor", 0, 1000000000 },
        { "discount_tier2_minor", 0, 10000000 }, { "discount_tier2_min_order_minor", 0, 1000000000 },
        { "discount_cap_minor", 0, 100000000 },
    }
    for _, c in ipairs(checks) do
        local ok, err = pos_int(c[1], c[2], c[3])
        if not ok then return nil, err end
    end
    if body.lock_days ~= nil then
        local n = tonumber(body.lock_days)
        if not n or not M.LOCK_DAYS_ALLOWED[n] then return nil, "lock_days must be 90 or 120" end
        out.lock_days = n
    end
    if body.uplift_pct ~= nil then
        local n = tonumber(body.uplift_pct)
        if not n or n < 0 or n > 500 then return nil, "uplift_pct must be between 0 and 500" end
        out.uplift_pct = n
    end
    for _, k in ipairs({ "founding_discount_pct", "standard_discount_pct" }) do
        if body[k] ~= nil then
            local n = tonumber(body[k])
            if not n or n < 0 or n > M.MAX_DISCOUNT_PCT then
                return nil, k .. " must be a number between 0 and " .. M.MAX_DISCOUNT_PCT
            end
            out[k] = n
        end
    end
    if body.vat_rate ~= nil then
        local n = tonumber(body.vat_rate)
        if not n or n < 0 or n > 1 then return nil, "vat_rate must be between 0 and 1 (e.g. 0.20)" end
        out.vat_rate = n
    end
    if body.enabled ~= nil then out.enabled = body.enabled == true end
    if body.terms_version ~= nil then
        if type(body.terms_version) ~= "string" or not body.terms_version:match("^[%w%.%-]+$") or #body.terms_version > 32 then
            return nil, "terms_version must be a short version label, e.g. 2026-10"
        end
        out.terms_version = body.terms_version
    end
    return out
end

--- One price point: { net_minor, vat_minor, gross_minor }.
local function point(net, vat_rate)
    local vat = round(net * vat_rate)
    return { net_minor = net, vat_minor = vat, gross_minor = net + vat }
end

--- Monthly + yearly prices for a tier ("founding" | "standard").
function M.prices(s, tier)
    local monthly = s.monthly_price_minor
    if tier == "standard" then monthly = round(monthly * (1 + s.uplift_pct / 100)) end
    return {
        tier = tier,
        month = point(monthly, s.vat_rate),
        year = point(monthly * s.yearly_months_charged, s.vat_rate),
        months_free_yearly = math.max(0, 12 - s.yearly_months_charged),
    }
end

--- Spots left in the founding tier. taken = paid founding members + live reservations.
function M.spots_left(s, taken)
    return math.max(0, s.founding_cap - math.max(0, math.floor(tonumber(taken) or 0)))
end

--- Tier a NEW joiner gets right now.
function M.tier_for(s, taken)
    if M.spots_left(s, taken) > 0 then return "founding" end
    return "standard"
end

--- Quote validity in days: members get lock_days, everyone else the normal 30.
function M.quote_valid_days(s, is_member)
    if is_member then return s.lock_days end
    return 30
end

--- Fee refund on a paid order.
-- fees_paid_net: membership fees paid so far (ex VAT); already_credited: fees already turned into credit.
-- Returns the credit to issue (pence, ex VAT), or 0.
function M.refund_credit(s, order_subtotal_net, fees_paid_net, already_credited)
    order_subtotal_net = math.floor(tonumber(order_subtotal_net) or 0)
    if order_subtotal_net < s.refund_threshold_minor then return 0 end
    -- The threshold must be real: an order "over £100k" means strictly the setting or more, and 0 disables refunds.
    if s.refund_threshold_minor <= 0 then return 0 end
    local due = math.floor(tonumber(fees_paid_net) or 0) - math.floor(tonumber(already_credited) or 0)
    return math.max(0, due)
end

--- Trade discount % for a tier ("founding" | "standard").
function M.discount_pct(s, tier)
    if tier == "founding" then return s.founding_discount_pct end
    return s.standard_discount_pct
end

--- Trade discount on an order subtotal (ex VAT), in pence.
-- Returns { discount_minor, subtotal_minor, vat_minor, shipping_minor, total_minor }.
-- VAT is recomputed on the reduced subtotal; shipping is never discounted.
local function apply_amount(subtotal_net, vat_rate, shipping_minor, amount)
    local discount = math.max(0, math.min(subtotal_net, math.floor(tonumber(amount) or 0)))
    local net = subtotal_net - discount
    local vat = round(net * (tonumber(vat_rate) or 0))
    return {
        discount_minor = discount, subtotal_minor = net, vat_minor = vat,
        shipping_minor = shipping_minor, total_minor = net + vat + shipping_minor,
    }
end

function M.apply_discount(subtotal_net, vat_rate, shipping_minor, pct)
    subtotal_net = math.floor(tonumber(subtotal_net) or 0)
    shipping_minor = math.floor(tonumber(shipping_minor) or 0)
    pct = tonumber(pct) or 0
    if pct < 0 then pct = 0 end
    if pct > M.MAX_DISCOUNT_PCT then pct = M.MAX_DISCOUNT_PCT end
    return apply_amount(subtotal_net, vat_rate, shipping_minor, round(subtotal_net * pct / 100))
end

--- True when the fixed Trade discount (discount_fixed_minor) is in force instead of the %.
function M.fixed_discount(s)
    return (tonumber(s.discount_fixed_minor) or 0) > 0
end

--- The Trade discount for a member of `tier` on a basket order: the fixed amount when the order
-- qualifies (else nothing), or the tier's %. Same shape as apply_discount, plus pct (nil when fixed).
-- remaining_cap: what is left of the member's yearly cap (nil = no cap); the discount never exceeds it.
function M.apply_trade(s, tier, subtotal_net, vat_rate, shipping_minor, remaining_cap)
    subtotal_net = math.floor(tonumber(subtotal_net) or 0)
    shipping_minor = math.floor(tonumber(shipping_minor) or 0)
    local d = apply_amount(subtotal_net, vat_rate, shipping_minor, M.discount_for(s, tier, subtotal_net, remaining_cap))
    if not M.fixed_discount(s) then d.pct = M.discount_pct(s, tier) end
    return d
end

--- Fixed tiers, highest first: { {min_order_minor, amount_minor}, … }. Empty in % mode.
function M.tiers(s)
    if not M.fixed_discount(s) then return {} end
    local out = { { min_order_minor = s.discount_min_order_minor, amount_minor = s.discount_fixed_minor } }
    local t2, t2min = tonumber(s.discount_tier2_minor) or 0, tonumber(s.discount_tier2_min_order_minor) or 0
    if t2 > 0 and t2min < s.discount_min_order_minor then
        out[2] = { min_order_minor = t2min, amount_minor = t2 }
    end
    return out
end

--- Tier amount for an order subtotal ex VAT (fixed mode): the highest tier it reaches, else 0.
function M.tier_amount(s, subtotal_net)
    subtotal_net = math.floor(tonumber(subtotal_net) or 0)
    for _, t in ipairs(M.tiers(s)) do
        if subtotal_net >= t.min_order_minor then return t.amount_minor end
    end
    return 0
end

--- What is left of the yearly cap after `used` (nil when there is no cap).
function M.cap_remaining(s, used)
    local cap = tonumber(s.discount_cap_minor) or 0
    if cap <= 0 then return nil end
    return math.max(0, cap - math.max(0, math.floor(tonumber(used) or 0)))
end

--- Trade discount (pence, ex VAT) for a subtotal: the tier amount (or the tier's %), limited to
-- remaining_cap (nil = no cap) and to the subtotal itself.
function M.discount_for(s, tier, subtotal_net, remaining_cap)
    subtotal_net = math.max(0, math.floor(tonumber(subtotal_net) or 0))
    local amount
    if M.fixed_discount(s) then
        amount = M.tier_amount(s, subtotal_net)
    else
        local pct = math.max(0, math.min(M.MAX_DISCOUNT_PCT, tonumber(M.discount_pct(s, tier)) or 0))
        amount = round(subtotal_net * pct / 100)
    end
    if remaining_cap ~= nil then amount = math.min(amount, math.max(0, math.floor(tonumber(remaining_cap) or 0))) end
    return math.min(amount, subtotal_net)
end

--- Returns clawback (pence, ex VAT) for a refund.
-- original_net: the order's goods value ex VAT before any discount or credit; got: the Trade discount it was given;
-- returned_net: goods ex VAT returned so far INCLUDING this refund; already: clawback already taken on earlier refunds.
-- The order keeps the discount its remaining value still earns (never more than it got); the rest comes back.
-- In % mode the % of the remaining value is kept.
function M.clawback(s, original_net, got, returned_net, already)
    got = math.max(0, math.floor(tonumber(got) or 0))
    if got == 0 then return 0 end
    original_net = math.max(0, math.floor(tonumber(original_net) or 0))
    local remaining = math.max(0, original_net - math.max(0, math.floor(tonumber(returned_net) or 0)))
    local keep
    if remaining == 0 then
        keep = 0
    elseif M.fixed_discount(s) then
        keep = math.min(got, M.tier_amount(s, remaining))
    else
        keep = math.min(got, original_net > 0 and round(got * remaining / original_net) or 0)
    end
    return math.max(0, got - keep - math.max(0, math.floor(tonumber(already) or 0)))
end

--- A refund on an order. o: { subtotal_minor (after discount + credit), member_discount_minor, credit_minor,
-- total_minor, refunded_minor, returned_net_minor, refund_clawback_minor }; amount_net: goods ex VAT returned now
-- (ignored when full). Returns { returned_net_minor, clawback_minor (ex VAT), clawback_gross_minor, refund_minor }
-- or (nil, message). refund = returned goods + VAT − clawback incl. VAT, never more than is left to refund;
-- a full refund returns everything still unrefunded (what the customer actually paid, shipping included).
function M.refund_split(s, o, amount_net, full, vat_rate)
    local function n(v) return math.max(0, math.floor(tonumber(v) or 0)) end
    vat_rate = tonumber(vat_rate) or 0
    local got = n(o.member_discount_minor)
    local original = n(o.subtotal_minor) + got + n(o.credit_minor)
    local returned_before = n(o.returned_net_minor)
    local left_goods = math.max(0, original - returned_before)
    local left_money = math.max(0, n(o.total_minor) - n(o.refunded_minor))
    local now
    if full then
        now = left_goods
    else
        now = tonumber(amount_net)
        if not now or now ~= math.floor(now) or now < 1 then
            return nil, "amount_net_minor must be a whole number of pence, 1 or more (or send full: true)"
        end
        if now > left_goods then
            return nil, "amount_net_minor is more than the goods left on this order (" .. left_goods .. ")"
        end
    end
    local claw = M.clawback(s, original, got, returned_before + now, o.refund_clawback_minor)
    local claw_gross = claw + round(claw * vat_rate)
    local refund
    if full then
        refund = left_money
    else
        refund = math.max(0, math.min(left_money, now + round(now * vat_rate) - claw_gross))
    end
    return { returned_net_minor = now, clawback_minor = claw, clawback_gross_minor = claw_gross, refund_minor = refund }
end

-- Civil-date helpers (UTC, no os.time/local time zone involved).
local function days_from_civil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civil_from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return m <= 2 and y + 1 or y, m, d
end

local function is_leap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end

--- unix + n calendar years (29 Feb → 28 Feb in a non-leap year).
function M.add_years(unix, n)
    unix = math.floor(tonumber(unix) or 0)
    local days = math.floor(unix / 86400)
    local secs = unix - days * 86400
    local y, m, d = civil_from_days(days)
    y = y + n
    if m == 2 and d == 29 and not is_leap(y) then d = 28 end
    return days_from_civil(y, m, d) * 86400 + secs
end

--- Membership year containing `now`: returns start, end (unix, end exclusive) and its index (0 = first year).
function M.year_bounds(joined_unix, now_unix)
    joined_unix = math.floor(tonumber(joined_unix) or 0)
    now_unix = math.floor(tonumber(now_unix) or 0)
    if now_unix < joined_unix then return joined_unix, M.add_years(joined_unix, 1), 0 end
    local y0 = civil_from_days(math.floor(joined_unix / 86400))
    local y1 = civil_from_days(math.floor(now_unix / 86400))
    local k = math.max(0, y1 - y0)
    while k > 0 and M.add_years(joined_unix, k) > now_unix do k = k - 1 end
    while M.add_years(joined_unix, k + 1) <= now_unix do k = k + 1 end
    return M.add_years(joined_unix, k), M.add_years(joined_unix, k + 1), k
end

--- Fees paid (ex VAT) for membership year `index`, from the running total fees_paid_net (no per-invoice history):
-- the fee is net_minor a year (annual) or a month (monthly); earlier years are assumed paid in full first.
function M.year_fees_net(interval, net_minor, fees_paid_net, index)
    net_minor = math.max(0, math.floor(tonumber(net_minor) or 0))
    local per_year = interval == "month" and net_minor * 12 or net_minor
    local before = per_year * math.max(0, math.floor(tonumber(index) or 0))
    return math.max(0, math.min(per_year, math.floor(tonumber(fees_paid_net) or 0) - before))
end

--- Refund-the-gap: fee paid for the year minus the discounts and credits it gave (never negative).
function M.gap(fees_net, discounts_minor, credits_minor)
    return math.max(0, math.floor(tonumber(fees_net) or 0) - math.floor(tonumber(discounts_minor) or 0)
        - math.floor(tonumber(credits_minor) or 0))
end

M.GAP_CLAIM_DAYS = 30
M.JOIN_CREDIT_HOURS = 48

--- Apply available credits (oldest first) to an order subtotal (ex VAT).
-- credits: { {id, amount_minor, min_order_minor}, … }
-- Returns { applied = {{id, amount_minor}, …}, credit_minor, subtotal_minor, vat_minor, total_minor }.
-- VAT is recomputed on the reduced subtotal; shipping is never discounted.
function M.apply_credits(subtotal_net, vat_rate, shipping_minor, credits)
    subtotal_net = math.floor(tonumber(subtotal_net) or 0)
    shipping_minor = math.floor(tonumber(shipping_minor) or 0)
    local remaining, applied, total_credit = subtotal_net, {}, 0
    for _, c in ipairs(credits or {}) do
        local amt = math.floor(tonumber(c.amount_minor) or 0)
        local min_order = math.floor(tonumber(c.min_order_minor) or 0)
        if remaining > 0 and amt > 0 and subtotal_net >= min_order then
            -- Use what fits; any unused part of the credit stays available for a later order.
            local use = math.min(amt, remaining)
            applied[#applied + 1] = { id = c.id, amount_minor = use, whole_minor = amt }
            remaining = remaining - use
            total_credit = total_credit + use
        end
    end
    local vat = round(remaining * vat_rate)
    return {
        applied = applied, credit_minor = total_credit, subtotal_minor = remaining, vat_minor = vat,
        shipping_minor = shipping_minor, total_minor = remaining + vat + shipping_minor,
    }
end

M.MAX_CREDIT_MINOR = 100000000   -- £1,000,000: a typo guard, not a business limit

--- Validate an admin "give credit" request. s = settings (for the default expiry).
-- body: { email, amount_minor, min_order_minor?, reason, expires_in_days?, notify? }
-- Returns (clean) or (nil, message).
function M.validate_credit(body, s)
    if type(body) ~= "table" then return nil, "body must be an object" end
    local email = M.email(body.email)
    if not email then return nil, "email must be a valid email address" end
    local amount = tonumber(body.amount_minor)
    if not amount or amount ~= math.floor(amount) or amount < 1 or amount > M.MAX_CREDIT_MINOR then
        return nil, "amount_minor must be a whole number of pence between 1 and " .. M.MAX_CREDIT_MINOR
    end
    local min_order = body.min_order_minor == nil and 0 or tonumber(body.min_order_minor)
    if not min_order or min_order ~= math.floor(min_order) or min_order < 0 or min_order > 10000000000 then
        return nil, "min_order_minor must be a whole number of pence, 0 or more"
    end
    local reason = type(body.reason) == "string" and body.reason:gsub("%c", " "):match("^%s*(.-)%s*$") or ""
    if #reason < 3 or #reason > 500 then return nil, "reason is required (3–500 characters)" end
    local days = body.expires_in_days == nil and (s and s.credit_expiry_days or M.DEFAULTS.credit_expiry_days)
        or tonumber(body.expires_in_days)
    if not days or days ~= math.floor(days) or days < 1 or days > 3650 then
        return nil, "expires_in_days must be a whole number between 1 and 3650"
    end
    return {
        email = email, amount_minor = amount, min_order_minor = min_order, reason = reason,
        expires_in_days = days, notify = body.notify == true,
    }
end

--- Plain description used in emails, CRM notes and the member page: "£250.00 off your next order over £5,000.00".
function M.credit_label(amount_minor, min_order_minor, money)
    local label = money(amount_minor) .. " off your next order"
    if (tonumber(min_order_minor) or 0) > 0 then label = label .. " over " .. money(min_order_minor) end
    return label .. " (before VAT)"
end

--- Normalised email or nil.
function M.email(v)
    if type(v) ~= "string" then return nil end
    v = v:match("^%s*(.-)%s*$"):lower()
    if #v > 254 or not v:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then return nil end
    return v
end

return M
