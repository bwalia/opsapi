-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-insights.lua (no nginx, no DB, no busted).
    Real data only: counts are exact, below-threshold signals are withheld.

    Run from lapis/:
        luajit spec/shop-insights-test.lua
    or in the openresty image:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            luajit spec/shop-insights-test.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
local I = require("lib.shop-insights")

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

-- settings ---------------------------------------------------------------------
check("setting: unset → default", I.setting(nil, 5) == 5)
check("setting: valid integer", I.setting("12", 5) == 12)
check("setting: zero/negative/fraction/junk → default",
    I.setting("0", 5) == 5 and I.setting("-3", 5) == 5 and I.setting("2.5", 5) == 5 and I.setting("lots", 5) == 5)

-- popular ------------------------------------------------------------------------
check("popular: below minimum is withheld", I.popular(4, 5) == nil)
check("popular: exactly the minimum is shown", I.popular(5, 5) == 5)
check("popular: shown count is exact, never rounded up", I.popular(7, 5) == 7)
check("popular: zero never shown even with min 1", I.popular(0, 1) == nil)
check("popular: missing count is withheld", I.popular(nil, 5) == nil)

-- history ------------------------------------------------------------------------
local function rows(prices)
    local out = {}
    for i, p in ipairs(prices) do
        out[i] = { day = string.format("2026-10-%02d", i), from_price_minor = p, base_price_minor = p, price_verified = true }
    end
    return out
end

check("history: too few snapshots → hidden", I.history(rows({ 100, 100, 100 }), 7) == nil)
check("history: empty → hidden", I.history({}, 1) == nil)
check("history: not a table → hidden", I.history(nil, 1) == nil)

local h = I.history(rows({ 250000, 260000, 255000, 240000, 270000, 265000, 262500 }), 7)
check("history: enough snapshots → shown", h ~= nil)
check("history: every stored day is a point", h and #h.points == 7)
check("history: first/last day", h and h.first_day == "2026-10-01" and h.last_day == "2026-10-07")
check("history: low/high from real points", h and h.low_price_minor == 240000 and h.high_price_minor == 270000)
check("history: change = last - first", h and h.change_minor == 12500, h and h.change_minor)
check("history: verified flag carried", h and h.points[1].verified == true)

local unverified = rows({ 100, 100 })
unverified[2].price_verified = false
local hu = I.history(unverified, 2)
check("history: unverified day flagged", hu and hu.points[2].verified == false)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
