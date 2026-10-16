-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-membership.lua (no nginx, no DB, no busted).
    Covers the brief's required cases: pricing, price lock, refund credit and
    the founding-member cap.

    Run from lapis/:
        luajit spec/shop-membership-test.lua
    or in the openresty image:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            luajit spec/shop-membership-test.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
local M = require("lib.shop-membership")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local s = M.settings(nil)

-- pricing ---------------------------------------------------------------------------
local f = M.prices(s, "founding")
check("pricing: founding monthly £75 + VAT", f.month.net_minor == 7500 and f.month.vat_minor == 1500 and f.month.gross_minor == 9000)
check("pricing: founding yearly = 10 months (2 free), £750 + VAT",
    f.year.net_minor == 75000 and f.year.gross_minor == 90000 and f.months_free_yearly == 2)
local st = M.prices(s, "standard")
check("pricing: standard monthly = launch + 33% (£99.75)", st.month.net_minor == 9975, st.month.net_minor)
check("pricing: standard monthly VAT rounds to the penny", st.month.vat_minor == 1995 and st.month.gross_minor == 11970)
check("pricing: standard yearly = 10 × standard monthly", st.year.net_minor == 99750 and st.year.gross_minor == 119700)
local custom = M.settings({ monthly_price_minor = 8000, yearly_months_charged = 12, uplift_pct = 25 })
check("pricing: settings drive the price", M.prices(custom, "standard").month.net_minor == 10000)
check("pricing: no free months when yearly charges 12", M.prices(custom, "founding").months_free_yearly == 0)

-- founding cap ------------------------------------------------------------------------
check("cap: 0 taken → 100 left, founding", M.spots_left(s, 0) == 100 and M.tier_for(s, 0) == "founding")
check("cap: 99 taken → 1 left, still founding", M.spots_left(s, 99) == 1 and M.tier_for(s, 99) == "founding")
check("cap: 100 taken → 0 left, price changes to standard", M.spots_left(s, 100) == 0 and M.tier_for(s, 100) == "standard")
check("cap: over-taken never shows negative spots", M.spots_left(s, 130) == 0)
check("cap: count is exact, never rounded", M.spots_left(s, 37) == 63)
check("cap: bad input counts as 0 taken", M.spots_left(s, nil) == 100)
local cap0 = M.settings({ founding_cap = 0 })
check("cap: cap 0 means everyone pays standard", M.tier_for(cap0, 0) == "standard")

-- price lock --------------------------------------------------------------------------
check("lock: members' quotes hold for 90 days", M.quote_valid_days(s, true) == 90)
check("lock: everyone else 30 days", M.quote_valid_days(s, false) == 30)
check("lock: 120 allowed", M.quote_valid_days(M.settings({ lock_days = 120 }), true) == 120)
check("lock: other values fall back to 90", M.quote_valid_days(M.settings({ lock_days = 45 }), true) == 90)

-- settings validation ------------------------------------------------------------------------
check("settings: lock_days 120 accepted", M.validate_update({ lock_days = 120 }).lock_days == 120)
local _, e1 = M.validate_update({ lock_days = 100 })
check("settings: lock_days 100 rejected", e1 ~= nil)
local _, e2 = M.validate_update({ monthly_price_minor = 75.5 })
check("settings: fractional pence rejected", e2 ~= nil)
check("settings: threshold editable", M.validate_update({ refund_threshold_minor = 5000000 }).refund_threshold_minor == 5000000)
local _, e3 = M.validate_update({ terms_version = "v1; DROP" })
check("settings: terms_version must be a plain label", e3 ~= nil)

-- refund credit ---------------------------------------------------------------------------
check("refund: order below £100k → no credit", M.refund_credit(s, 9999999, 30000, 0) == 0)
check("refund: order of exactly £100k qualifies", M.refund_credit(s, 10000000, 30000, 0) == 30000)
check("refund: credit = fees paid ex VAT", M.refund_credit(s, 25000000, 75000, 0) == 75000)
check("refund: fees already credited aren't credited twice", M.refund_credit(s, 25000000, 75000, 75000) == 0)
check("refund: only new fees since the last credit", M.refund_credit(s, 25000000, 90000, 75000) == 15000)
check("refund: threshold is a setting", M.refund_credit(M.settings({ refund_threshold_minor = 5000000 }), 6000000, 7500, 0) == 7500)
check("refund: threshold 0 disables refunds", M.refund_credit(M.settings({ refund_threshold_minor = 0 }), 100, 7500, 0) == 0)

-- applying credit ---------------------------------------------------------------------------
local a = M.apply_credits(10000000, 0.2, 0, { { id = 1, amount_minor = 75000, min_order_minor = 0 } })
check("credit: reduces subtotal ex VAT", a.subtotal_minor == 9925000 and a.credit_minor == 75000)
check("credit: VAT recomputed on the reduced subtotal", a.vat_minor == 1985000 and a.total_minor == 11910000)
local b = M.apply_credits(50000, 0.2, 2500, { { id = 1, amount_minor = 80000, min_order_minor = 0 } })
check("credit: bigger than the order → part used, order net 0", b.credit_minor == 50000 and b.subtotal_minor == 0)
check("credit: part used is recorded", b.applied[1].amount_minor == 50000 and b.applied[1].whole_minor == 80000)
check("credit: shipping never discounted", b.total_minor == 2500)
local c = M.apply_credits(400000, 0.2, 0, { { id = 1, amount_minor = 10000, min_order_minor = 500000 },
    { id = 2, amount_minor = 5000, min_order_minor = 0 } })
check("credit: minimum-order rule respected", #c.applied == 1 and c.applied[1].id == 2 and c.credit_minor == 5000)
check("credit: none → unchanged totals", M.apply_credits(1000, 0.2, 0, {}).total_minor == 1200)

-- loyalty credit (admin) -----------------------------------------------------------------------
local good = M.validate_credit({ email = " Head@School.org.uk ", amount_minor = 25000, min_order_minor = 500000,
    reason = "Thanks for the lab order" }, s)
check("credit grant: valid request cleaned", good and good.email == "head@school.org.uk" and good.amount_minor == 25000
    and good.min_order_minor == 500000)
check("credit grant: expiry defaults to the setting", good and good.expires_in_days == 365)
check("credit grant: notify only when asked", good and good.notify == false)
check("credit grant: min order defaults to 0", M.validate_credit({ email = "a@b.co", amount_minor = 100, reason = "abc" }, s).min_order_minor == 0)
local function bad(b) local r, e = M.validate_credit(b, s) return r == nil and e ~= nil end
check("credit grant: amount must be positive whole pence", bad({ email = "a@b.co", amount_minor = 0, reason = "abc" })
    and bad({ email = "a@b.co", amount_minor = 12.5, reason = "abc" }) and bad({ email = "a@b.co", amount_minor = -100, reason = "abc" }))
check("credit grant: typo guard on huge amounts", bad({ email = "a@b.co", amount_minor = M.MAX_CREDIT_MINOR + 1, reason = "abc" }))
check("credit grant: reason required", bad({ email = "a@b.co", amount_minor = 100 }) and bad({ email = "a@b.co", amount_minor = 100, reason = "  " }))
check("credit grant: email required", bad({ email = "nope", amount_minor = 100, reason = "abc" }))
check("credit grant: negative min order rejected", bad({ email = "a@b.co", amount_minor = 100, min_order_minor = -1, reason = "abc" }))
check("credit grant: expiry bounds", bad({ email = "a@b.co", amount_minor = 100, reason = "abc", expires_in_days = 0 }))
local fmt = function(m) return string.format("£%.2f", m / 100) end
check("credit label: with minimum order", M.credit_label(25000, 500000, fmt) == "£250.00 off your next order over £5000.00 (before VAT)")
check("credit label: no minimum", M.credit_label(25000, 0, fmt) == "£250.00 off your next order (before VAT)")
-- the min-order rule is enforced when credit is applied
local under = M.apply_credits(499999, 0.2, 0, { { id = 9, amount_minor = 25000, min_order_minor = 500000 } })
local over = M.apply_credits(500000, 0.2, 0, { { id = 9, amount_minor = 25000, min_order_minor = 500000 } })
check("credit redeem: not applied below the minimum order", under.credit_minor == 0)
check("credit redeem: applied at the minimum order", over.credit_minor == 25000 and over.subtotal_minor == 475000)

-- trade discount ------------------------------------------------------------------------------
check("trade: defaults 5% founding, 2.5% standard", s.founding_discount_pct == 5 and s.standard_discount_pct == 2.5)
check("trade: pct by tier", M.discount_pct(s, "founding") == 5 and M.discount_pct(s, "standard") == 2.5)
local tset = M.settings({ founding_discount_pct = "7.5", standard_discount_pct = 99 })
check("trade: settings row read (numeric string), out-of-range falls back",
    tset.founding_discount_pct == 7.5 and tset.standard_discount_pct == 2.5)
local d5 = M.apply_discount(1000000, 0.2, 2500, 5)
check("trade: 5% off £10,000 ex VAT = £500, VAT recomputed, shipping kept",
    d5.discount_minor == 50000 and d5.subtotal_minor == 950000 and d5.vat_minor == 190000
    and d5.shipping_minor == 2500 and d5.total_minor == 1142500)
local d25 = M.apply_discount(12345, 0.2, 0, 2.5)
check("trade: 2.5% rounds to the penny", d25.discount_minor == 309 and d25.subtotal_minor == 12036 and d25.vat_minor == 2407,
    d25.discount_minor)
check("trade: 0% → unchanged", M.apply_discount(1000, 0.2, 0, 0).total_minor == 1200)
check("trade: pct clamped to max", M.apply_discount(1000, 0.2, 0, 90).discount_minor == 500)
-- discount first, then credit on the discounted subtotal
local after = M.apply_credits(d5.subtotal_minor, 0.2, d5.shipping_minor, { { id = 1, amount_minor = 10000, min_order_minor = 0 } })
check("trade + credit: credit applies to the discounted subtotal", after.subtotal_minor == 940000 and after.total_minor == 1130500)
local okv, errv = M.validate_update({ founding_discount_pct = 5, standard_discount_pct = 2.5 })
check("trade: admin update accepts decimals", okv and okv.standard_discount_pct == 2.5, errv)
check("trade: admin update rejects > 50", M.validate_update({ founding_discount_pct = 60 }) == nil)
check("trade: admin update rejects negative", M.validate_update({ standard_discount_pct = -1 }) == nil)

-- email ----------------------------------------------------------------------------------------
check("email: normalised", M.email(" VIP@Lab.ac.uk ") == "vip@lab.ac.uk")
check("email: junk rejected", M.email("x@y") == nil)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
