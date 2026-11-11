--[[
    Spec: back-office order pricing (lib/shop-pricing.lua): free-text lines and whole-order discounts.

    Standalone, from the repo root:
        luajit lapis/spec/order-authorisation-pricing_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path
local P = require("lib.shop-pricing")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

print("custom line: VIP membership, one month")
local l = P.custom_line({ name = "  Workstation VIP membership (founding member)  ", unit_price_minor = 7500,
    period_start = "2026-11-11", period_end = "2026-12-11" }, "u1")
check("name trimmed", l.product_name == "Workstation VIP membership (founding member)", l.product_name)
check("qty defaults to 1", l.qty == 1)
check("VAT 20%", l.line_vat_minor == 1500, l.line_vat_minor)
check("total £90", l.line_total_minor == 9000, l.line_total_minor)
check("period kept", l.period_start == "2026-11-11" and l.period_end == "2026-12-11")
check("custom, no product", l.custom == true and l.product_uuid == nil)
check("uuid kept", l.uuid == "u1")

print("custom line: bad input")
check("no name", select(2, P.custom_line({ name = "  ", unit_price_minor = 100 })) ~= nil)
check("no price", select(2, P.custom_line({ name = "x" })) ~= nil)
check("negative price", select(2, P.custom_line({ name = "x", unit_price_minor = -1 })) ~= nil)
check("qty 0", select(2, P.custom_line({ name = "x", unit_price_minor = 1, qty = 0 })) ~= nil)
check("bad date dropped", P.custom_line({ name = "x", unit_price_minor = 1, period_start = "11/11/2026" }).period_start == nil)
check("zero-rated", P.custom_line({ name = "x", unit_price_minor = 1000, vat_rate = 0 }).line_vat_minor == 0)

print("discounted totals: DGX Spark £5,599 ex VAT, £500 VIP discount")
local spark = P.custom_line({ name = "NVIDIA DGX Spark", unit_price_minor = 559900 })
local t = P.discounted_totals({ spark }, 0, 50000)
check("list subtotal", t.list_subtotal_minor == 559900)
check("subtotal £5,099", t.subtotal_minor == 509900, t.subtotal_minor)
check("VAT £1,019.80", t.vat_minor == 101980, t.vat_minor)
check("total £6,118.80", t.total_minor == 611880, t.total_minor)
check("discount applied", t.discount_minor == 50000)

print("discounted totals: edge cases")
local none = P.discounted_totals({ spark }, 1500, 0)
check("no discount = plain totals", none.total_minor == 559900 + 111980 + 1500, none.total_minor)
local over = P.discounted_totals({ l }, 0, 999999)
check("discount capped at subtotal", over.discount_minor == 7500 and over.total_minor == 0, over.total_minor)
local ship = P.discounted_totals({ l }, 2000, 1000)
check("shipping untouched", ship.total_minor == 6500 + 1300 + 2000, ship.total_minor)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
