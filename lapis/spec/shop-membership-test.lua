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

-- fixed Trade discount -------------------------------------------------------------------------
check("fixed: default is £500 off orders of £5,000+", s.discount_fixed_minor == 50000 and s.discount_min_order_minor == 500000
    and M.fixed_discount(s))
local fx = M.apply_trade(s, "founding", 500000, 0.2, 2500)
check("fixed: £5,000 order → £500 off, VAT on £4,500, shipping kept",
    fx.discount_minor == 50000 and fx.subtotal_minor == 450000 and fx.vat_minor == 90000 and fx.total_minor == 542500
    and fx.pct == nil, fx.total_minor)
check("fixed: same for standard tier", M.apply_trade(s, "standard", 800000, 0.2, 0).discount_minor == 50000)
check("fixed: £4,999.99 order → the lower tier (£250) off", M.apply_trade(s, "founding", 499999, 0.2, 0).discount_minor == 25000)
check("fixed: £2,999.99 order → nothing off", M.apply_trade(s, "founding", 299999, 0.2, 0).discount_minor == 0)
local onetier = M.settings({ discount_tier2_minor = 0 })
check("fixed: tier 2 = 0 → £4,999.99 order gets nothing", M.apply_trade(onetier, "founding", 499999, 0.2, 0).discount_minor == 0)
local pctmode = M.settings({ discount_fixed_minor = 0 })
local pd = M.apply_trade(pctmode, "founding", 1000000, 0.2, 0)
check("fixed: 0 falls back to the tier %", not M.fixed_discount(pctmode) and pd.discount_minor == 50000 and pd.pct == 5)
check("fixed: admin update accepts amounts",
    M.validate_update({ discount_fixed_minor = 60000, discount_min_order_minor = 600000 }).discount_fixed_minor == 60000)
check("fixed: admin update rejects negative", M.validate_update({ discount_fixed_minor = -1 }) == nil)

-- tiers + yearly cap -----------------------------------------------------------------------------
check("tiers: defaults £500 at £5,000 then £250 at £3,000, cap £1,500", s.discount_tier2_minor == 25000
    and s.discount_tier2_min_order_minor == 300000 and s.discount_cap_minor == 150000)
local tl = M.tiers(s)
check("tiers: highest first", #tl == 2 and tl[1].min_order_minor == 500000 and tl[1].amount_minor == 50000
    and tl[2].min_order_minor == 300000 and tl[2].amount_minor == 25000)
check("tiers: none in % mode", #M.tiers(pctmode) == 0)
check("tiers: tier 2 ignored when not below the top tier", #M.tiers(M.settings({ discount_tier2_min_order_minor = 600000 })) == 1)
check("tier_amount: boundaries", M.tier_amount(s, 500000) == 50000 and M.tier_amount(s, 300000) == 25000
    and M.tier_amount(s, 299999) == 0 and M.tier_amount(s, 2000000) == 50000)
check("cap: remaining = cap − used", M.cap_remaining(s, 50000) == 100000 and M.cap_remaining(s, 200000) == 0)
check("cap: 0 means no cap (nil)", M.cap_remaining(M.settings({ discount_cap_minor = 0 }), 999999) == nil)
check("discount_for: full tier when cap allows", M.discount_for(s, "founding", 600000, 150000) == 50000)
check("discount_for: limited by what is left of the cap", M.discount_for(s, "founding", 600000, 20000) == 20000)
check("discount_for: cap used up → nothing", M.discount_for(s, "founding", 600000, 0) == 0)
check("discount_for: no cap → full tier", M.discount_for(s, "founding", 350000, nil) == 25000)
check("discount_for: % mode capped too", M.discount_for(pctmode, "founding", 1000000, 30000) == 30000)
local capped = M.apply_trade(s, "standard", 600000, 0.2, 0, 10000)
check("apply_trade: remaining cap applied, VAT on the rest", capped.discount_minor == 10000 and capped.subtotal_minor == 590000
    and capped.vat_minor == 118000)
check("validate: tier and cap fields accepted", M.validate_update({ discount_tier2_minor = 20000,
    discount_tier2_min_order_minor = 250000, discount_cap_minor = 0 }).discount_cap_minor == 0)
check("validate: negative cap rejected", M.validate_update({ discount_cap_minor = -1 }) == nil)
check("validate_tiers: tier 2 min must be below the top min",
    M.validate_tiers(M.settings({ discount_tier2_min_order_minor = 500000 })) == nil)
check("validate_tiers: tier 2 amount must not beat the top tier", M.validate_tiers(M.settings({ discount_tier2_minor = 60000 })) == nil)
check("validate_tiers: defaults fine", M.validate_tiers(s) == true)

-- clawback on returns ----------------------------------------------------------------------------
check("clawback: £6,000 order (£500 off), £500 returned → still ≥ £5,000, nothing back",
    M.clawback(s, 600000, 50000, 50000, 0) == 0)
check("clawback: £6,000 order, £2,000 returned → £4,000 earns £250, £250 back", M.clawback(s, 600000, 50000, 200000, 0) == 25000)
check("clawback: £6,000 order, £3,500 returned → below £3,000, all £500 back", M.clawback(s, 600000, 50000, 350000, 0) == 50000)
check("clawback: second return counts only what wasn't taken before", M.clawback(s, 600000, 50000, 350000, 25000) == 25000)
check("clawback: full return → whole discount", M.clawback(s, 600000, 50000, 600000, 0) == 50000)
check("clawback: never more than the order got (capped discount)", M.clawback(s, 600000, 10000, 200000, 0) == 0
    and M.clawback(s, 600000, 10000, 600000, 0) == 10000)
check("clawback: no discount → nothing", M.clawback(s, 600000, 0, 600000, 0) == 0)
check("clawback: % mode keeps the share of what is left", M.clawback(pctmode, 1000000, 50000, 400000, 0) == 20000)

-- refund split -------------------------------------------------------------------------------------
-- £6,000 basket order with £500 off: subtotal £5,500, VAT £1,100, shipping £25 → £6,625 paid.
local ord = { subtotal_minor = 550000, member_discount_minor = 50000, credit_minor = 0, total_minor = 662500,
              refunded_minor = 0, returned_net_minor = 0, refund_clawback_minor = 0 }
local r1 = M.refund_split(s, ord, 200000, false, 0.2)
check("refund: £2,000 returned → £2,400 less £250 + VAT clawback = £2,100",
    r1 and r1.clawback_minor == 25000 and r1.clawback_gross_minor == 30000 and r1.refund_minor == 210000, r1 and r1.refund_minor)
local r0 = M.refund_split(s, ord, 50000, false, 0.2)
check("refund: small return keeps the tier → full £600 back, no clawback", r0.clawback_minor == 0 and r0.refund_minor == 60000)
local rf = M.refund_split(s, ord, nil, true, 0.2)
check("refund: full → everything paid back, whole discount reported as clawback",
    rf.refund_minor == 662500 and rf.clawback_minor == 50000 and rf.returned_net_minor == 600000)
local ord2 = { subtotal_minor = 550000, member_discount_minor = 50000, credit_minor = 0, total_minor = 662500,
               refunded_minor = 210000, returned_net_minor = 200000, refund_clawback_minor = 25000 }
local r2 = M.refund_split(s, ord2, 150000, false, 0.2)
check("refund: second return below £3,000 claws back the other £250",
    r2.clawback_minor == 25000 and r2.refund_minor == 180000 - 30000, r2.refund_minor)
local rf2 = M.refund_split(s, ord2, nil, true, 0.2)
check("refund: full after a partial refunds only what is left", rf2.refund_minor == 452500 and rf2.clawback_minor == 25000)
check("refund: more than the goods left rejected", M.refund_split(s, ord2, 500000, false, 0.2) == nil)
check("refund: amount required unless full", M.refund_split(s, ord, nil, false, 0.2) == nil
    and M.refund_split(s, ord, 10.5, false, 0.2) == nil)

-- membership year ----------------------------------------------------------------------------------
local J = 1792454400 -- 2026-10-20T00:00:00Z
local ys, ye, yi = M.year_bounds(J, J + 86400 * 10)
check("year: first year runs joined → first anniversary", ys == J and ye == 1823990400 and yi == 0, ye)
ys, ye, yi = M.year_bounds(J, 1823990400)
check("year: anniversary starts year 2", ys == 1823990400 and yi == 1 and ye == 1855612800, ye)
ys = M.year_bounds(J, 1823990399)
check("year: one second before the anniversary is still year 1", ys == J)
local leap = 1709164800 -- 2024-02-29T00:00:00Z
check("year: 29 Feb joiner renews on 28 Feb", M.add_years(leap, 1) == 1740700800)
check("year: back to 29 Feb in a leap year", M.add_years(leap, 4) == 1835395200)
check("year: keeps the time of day", M.add_years(J + 3661, 1) == 1823990400 + 3661)

-- year fees + refund-the-gap ------------------------------------------------------------------------
check("fees: annual year 0", M.year_fees_net("year", 75000, 75000, 0) == 75000)
check("fees: annual year 1 after renewal", M.year_fees_net("year", 75000, 150000, 1) == 75000)
check("fees: annual year 1 before renewal paid", M.year_fees_net("year", 75000, 75000, 1) == 0)
check("fees: monthly, 3 months into year 0", M.year_fees_net("month", 7500, 22500, 0) == 22500)
check("gap: fee − discounts − credits", M.gap(75000, 25000, 10000) == 40000)
check("gap: never negative", M.gap(75000, 50000, 50000) == 0)

-- email ----------------------------------------------------------------------------------------
check("email: normalised", M.email(" VIP@Lab.ac.uk ") == "vip@lab.ac.uk")
check("email: junk rejected", M.email("x@y") == nil)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
