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

-- email ----------------------------------------------------------------------------------------
check("email: normalised", M.email(" VIP@Lab.ac.uk ") == "vip@lab.ac.uk")
check("email: junk rejected", M.email("x@y") == nil)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
