--[[
    Spec: VAT records (lib/vat.lua) — codes, VAT numbers, net/VAT splits, rules, due dates.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-records_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local VAT = require("lib.vat")

print("== VAT registration numbers")
check("HMRC's own VRN (old series) is valid", VAT.valid_vrn("980780684") == "980780684")
check("GB prefix and spaces are accepted", VAT.valid_vrn("GB 980 7806 84") == "980780684")
check("9755 series is valid", VAT.valid_vrn("123456727") == "123456727")
check("old series is valid", VAT.valid_vrn("123456782") == "123456782")
local ok, err = VAT.valid_vrn("123456789")
check("wrong check digits are refused with a reason", ok == nil and err:find("check") ~= nil, err)
ok, err = VAT.valid_vrn("12345")
check("wrong length is refused", ok == nil and err:find("9 digits") ~= nil, err)
check("empty is refused", VAT.valid_vrn("") == nil and VAT.valid_vrn(nil) == nil)

print("== net / VAT splits")
local s = VAT.split(120, "STD20")
check("£120 at 20% = £100 net + £20 VAT", s.net == 100 and s.vat == 20 and s.notional_vat == 0)
s = VAT.split(105, "RED5")
check("£105 at 5% = £100 + £5", s.net == 100 and s.vat == 5)
s = VAT.split(-120, "STD20")
check("a refund keeps its sign", s.net == -100 and s.vat == -20)
s = VAT.split(10.99, "STD20")
check("pennies round half-up and add back to the gross", s.vat == 1.83 and s.net == 9.16
    and VAT.split_ok(10.99, s.net, s.vat), s.net .. " + " .. s.vat)
s = VAT.split(130, "STD20", { vat_amount = 20 })
check("the receipt's VAT wins over 20/120", s.vat == 20 and s.net == 110)
check("receipt VAT larger than the total is refused", VAT.split(10, "STD20", { vat_amount = 11 }) == nil)
s = VAT.split(500, "ZERO")
check("zero-rated: all net, no VAT", s.net == 500 and s.vat == 0)
s = VAT.split(300, "EXEMPT")
check("exempt: all net, no VAT", s.net == 300 and s.vat == 0)
s = VAT.split(15000, "OUTSIDE")
check("outside the scope (e.g. a transfer): no VAT", s.vat == 0 and s.notional_vat == 0)
s = VAT.split(1000, "RC_SERVICES")
check("reverse charge: amount is net, £200 notional VAT, nothing charged", s.net == 1000 and s.vat == 0
    and s.notional_vat == 200)
s = VAT.split(2500, "PVA")
check("postponed import VAT: notional VAT on the import value", s.notional_vat == 500)
check("unknown code is refused", VAT.split(10, "NOPE") == nil)
check("code lookup is case-insensitive", VAT.code("std20").rate == 20)

print("== reclaimable VAT")
check("full reclaim", VAT.reclaimable(20, 0, 100) == 20)
check("car with private use: 50%", VAT.reclaimable(20, 0, 50) == 10)
check("business entertainment: nothing", VAT.reclaimable(20, 0, 0) == 0)
check("reverse charge: the notional VAT is reclaimable", VAT.reclaimable(0, 200, 100) == 200)
check("default share is 100%", VAT.reclaimable(20, 0, nil) == 20)

print("== supplier rules")
local rules = {
    { match_type = "contains", match_value = "insurance", vat_code = "EXEMPT" },
    { match_type = "contains", match_value = "HMRC", vat_code = "OUTSIDE" },
    { match_type = "category", match_value = "software_subscriptions", vat_code = "STD20" },
    { match_type = "merchant", match_value = "PROPDESK", vat_code = "ZERO", registration_id = 7 },
    { match_type = "contains", match_value = "PROPDESK", vat_code = "STD20" },
    { match_type = "contains", match_value = "old supplier", vat_code = "STD20", is_active = false },
}
local r = VAT.match_rule(rules, { description = "LANDLORD INSURANCE DIRECT DEBIT" })
check("contains match (case-insensitive)", r and r.vat_code == "EXEMPT")
r = VAT.match_rule(rules, { description = "PROPDESK SOFTWARE SUBSCRIPTION", merchant = "Propdesk",
    category = "software_subscriptions" })
check("the business's own merchant rule beats global rules", r and r.vat_code == "ZERO" and r.registration_id == 7)
r = VAT.match_rule(rules, { description = "Something", category = "software_subscriptions" })
check("category rule when nothing more specific", r and r.vat_code == "STD20")
check("inactive rules are ignored", VAT.match_rule(rules, { description = "OLD SUPPLIER LTD" }) == nil)
check("no match → nil", VAT.match_rule(rules, { description = "TESCO" }) == nil)

print("== due dates")
check("quarter to 31 March is due 7 May", VAT.due_date("2026-03-31") == "2026-05-07", VAT.due_date("2026-03-31"))
check("quarter to 30 June is due 7 August", VAT.due_date("2026-06-30") == "2026-08-07", VAT.due_date("2026-06-30"))
check("quarter to 31 January is due 7 March (short February)", VAT.due_date("2026-01-31") == "2026-03-07",
    VAT.due_date("2026-01-31"))
check("annual accounting: two months", VAT.due_date("2026-03-31", "annual") == "2026-05-31",
    VAT.due_date("2026-03-31", "annual"))
check("bad date → nil", VAT.due_date("31/03/2026") == nil)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
