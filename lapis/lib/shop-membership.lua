-- luacheck: max line length 140
--[[
    VIP price-lock membership — pure rules (no nginx, no DB)
    ========================================================
    Every number the shop shows or charges for membership comes from here, so
    the rules are unit tested in one place (spec/shop-membership-test.lua):

      prices       founding (launch) and standard (after the cap) prices,
                   monthly and yearly, ex VAT and inc VAT
      tier_for     founding while real taken spots < cap, else standard
      spots_left   cap − taken (never negative, never padded)
      lock_until   quote validity for a member's quote (lock_days)
      refund_credit  membership fees → order credit on a qualifying order
      apply_credits  credits against an order subtotal, VAT recomputed

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
}

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
                         "credit_expiry_days", "early_access_hours", "long_lead_days", "lock_days" }) do
        s[k] = math.floor(tonumber(s[k]) or M.DEFAULTS[k])
    end
    s.vat_rate = tonumber(s.vat_rate) or M.DEFAULTS.vat_rate
    s.uplift_pct = tonumber(s.uplift_pct) or M.DEFAULTS.uplift_pct
    if not M.LOCK_DAYS_ALLOWED[s.lock_days] then s.lock_days = M.DEFAULTS.lock_days end
    return s
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
