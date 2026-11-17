-- luacheck: max line length 140
--[[
    Plain-Lua unit test for the membership offer v2 rules in lib/shop-membership.lua
    (Trade Account + Pro; v1 members keep their v1 benefits until their membership year ends).

    Run from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine sh -c \
          'LUA_PATH="/usr/local/openresty/lualib/?.lua;;" LUA_CPATH="/usr/local/openresty/lualib/?.so;;" \
           luajit spec/shop-membership-offer-v2-test.lua'
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

local DAY = 86400
local J = 1792454400                    -- joined 2026-10-20T00:00:00Z
local J1 = M.add_years(J, 1)            -- first anniversary 2027-10-20
local J2 = M.add_years(J, 2)

-- settings -----------------------------------------------------------------------------------------
local v1 = M.settings(nil)
check("settings: offer v1 by default (nothing changes until an admin switches)", M.offer_version(v1) == "v1")
check("settings: no Pro members' discount by default", v1.pro_discount_pct == 0)
local v2 = M.settings({ offer_version = "v2", pro_discount_pct = "1.5" })
check("settings: v2 read from the row", M.offer_version(v2) == "v2" and v2.pro_discount_pct == 1.5)
check("settings: unknown offer version falls back to v1", M.offer_version(M.settings({ offer_version = "v9" })) == "v1")
check("settings: Pro % out of range falls back to 0", M.settings({ pro_discount_pct = 80 }).pro_discount_pct == 0)
check("validate: offer_version v1|v2 only", M.validate_update({ offer_version = "v3" }) == nil
    and M.validate_update({ offer_version = "v2" }).offer_version == "v2")
check("validate: pro_discount_pct 0–50", M.validate_update({ pro_discount_pct = 51 }) == nil
    and M.validate_update({ pro_discount_pct = 2 }).pro_discount_pct == 2)

-- intervals --------------------------------------------------------------------------------------
check("join: v1 offers monthly and annual", M.join_intervals(v1).month and M.join_intervals(v1).year)
check("join: Pro (v2) is annual only", M.join_intervals(v2).year and not M.join_intervals(v2).month)
local list = M.join_interval_list(v1)
check("join: interval list month first", list[1] == "month" and list[2] == "year")
check("join: v2 list is just year", #M.join_interval_list(v2) == 1 and M.join_interval_list(v2)[1] == "year")

-- legacy_until ----------------------------------------------------------------------------------------
check("legacy: no end while v2 is off", M.legacy_until(J, nil) == nil)
local since = J + 100 * DAY                       -- v2 goes live 100 days into their first year
check("legacy: v1 ends at the end of the membership year v2 went live in", M.legacy_until(J, since) == J1)
local late = J1 - 10 * DAY                        -- v2 goes live 10 days before their renewal
check("legacy: at least 30 days' notice when the year ends sooner", M.legacy_until(J, late) == late + 30 * DAY)
local second = J1 + 5 * DAY                       -- v2 goes live early in their second year
check("legacy: a renewed member keeps v1 to the end of the year in progress", M.legacy_until(J, second) == J2)
check("legacy: someone who finished a v1 checkout after v2 went live keeps their first year",
    M.legacy_until(since + DAY, since) == M.add_years(since + DAY, 1))

-- benefits ----------------------------------------------------------------------------------------
v2.v2_since_unix = since
check("benefits: everyone on v1 while the offer is v1", M.benefits(v1, "v1", J, J2, nil) == "v1")
check("benefits: v1 member keeps v1 during the year v2 went live", M.benefits(v2, "v1", J, J1 - 1, since) == "v1")
check("benefits: v1 member moves to v2 at renewal", M.benefits(v2, "v1", J, J1, since) == "v2")
check("benefits: a v2 member is always v2", M.benefits(v2, "v2", J, J, since) == "v2" and M.benefits(v1, "v2", J, J, nil) == "v2")
check("benefits: switching back to v1 restores v1 members", M.benefits(v1, "v1", J, J2 + DAY, since) == "v1")

-- effective pricing ---------------------------------------------------------------------------------
local tiers = M.settings(nil)                     -- £500 off £5k+, £250 off £3k+, cap £1,500
check("v1 member: £500 off a £6,000 order (unchanged)", M.discount_for(M.effective(tiers, "v1"), "founding", 600000, nil) == 50000)
local e0 = M.effective(M.settings({ offer_version = "v2" }), "v2")
check("v2, no members' %: no discount on any order", M.discount_for(e0, "founding", 600000, nil) == 0
    and M.discount_for(e0, "standard", 12000000, nil) == 0)
check("v2: no tiers and no yearly cap", #M.tiers(e0) == 0 and M.cap_remaining(e0, 0) == nil)
local e15 = M.effective(M.settings({ offer_version = "v2", pro_discount_pct = 1.5 }), "v2")
check("v2, 1.5%: £180 off £12,000", M.discount_for(e15, "founding", 1200000, nil) == 18000)
check("v2, 1.5%: same % for founding and standard", M.discount_for(e15, "standard", 1200000, nil) == 18000)
local d = M.apply_trade(e15, "standard", 1200000, 0.2, 0, nil)
check("v2, 1.5%: VAT recomputed on the lower price", d.subtotal_minor == 1182000 and d.vat_minor == 236400 and d.pct == 1.5)
check("v2 effective leaves the stored settings alone", tiers.discount_fixed_minor == 50000 and M.effective(tiers, "v1") == tiers)
check("v1 perks (join credit, fees back, gap) only for v1 benefits", M.v1_perks("v1") and not M.v1_perks("v2"))

-- labels ----------------------------------------------------------------------------------------------
check("fee label: Pro", M.fee_label("v2", "founding") == "Workstation Pro (12 months)")
check("fee label: v1 unchanged", M.fee_label("v1", "founding") == "Workstation VIP membership (founding member)"
    and M.fee_label(nil, "standard") == "Workstation VIP membership")

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
