--[[
    Spec: the 9-box VAT return engine (lib/vat-return.lua), with worked examples from
    HMRC's VAT notices as the expected figures.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-return_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function eq(a, b) return math.abs((tonumber(a) or -1e18) - b) < 0.005 end

local VAT = require("lib.vat")
local R = require("lib.vat-return")

-- A line from an amount and code, the way the database holds it.
local n = 0
local function line(direction, amount, code, extra)
    n = n + 1
    local s = assert(VAT.split(amount, code, extra and { vat_amount = extra.vat_amount } or nil))
    local l = { id = n, direction = direction, vat_code = code, net = s.net, vat = s.vat,
        notional_vat = s.notional_vat, gross = amount }
    for k, v in pairs(extra or {}) do if k ~= "vat_amount" then l[k] = v end end
    return l
end

print("== standard scheme: sales, purchases, exempt, zero, outside")
local lines = {
    line("sale", 12000, "STD20"),          -- £10,000 + £2,000
    line("sale", 3000, "ZERO"),            -- zero-rated sales: Box 6 only
    line("sale", 1000, "EXEMPT"),          -- exempt: Box 6 only
    line("purchase", 2400, "STD20"),       -- £2,000 + £400
    line("purchase", 600, "STD20", { reclaimable_pct = 0 }), -- entertainment: £500 + £100, none back
    line("purchase", 300, "EXEMPT"),       -- insurance: Box 7 only
    line("purchase", 15000, "OUTSIDE"),    -- wages: nowhere
    line("sale", 5000, "OUTSIDE"),         -- transfer in: nowhere
}
local r = R.build(lines, { scheme = "standard" })
check("Box 1 = output VAT", eq(r.boxes.box1, 2000), r.boxes.box1)
check("Box 4 = reclaimable input VAT only", eq(r.boxes.box4, 400), r.boxes.box4)
check("Box 3 = Box 1 + Box 2", eq(r.boxes.box3, 2000))
check("Box 5 = Box 3 − Box 4", eq(r.boxes.box5, 1600) and r.direction == "pay", r.boxes.box5)
check("Box 6 = all sales ex VAT, not outside-scope", r.boxes.box6 == 14000, r.boxes.box6)
check("Box 7 = all purchases ex VAT, not wages", r.boxes.box7 == 2800, r.boxes.box7)
check("Boxes 8 and 9 empty", r.boxes.box8 == 0 and r.boxes.box9 == 0)
check("audit trail: Box 1 lists the standard-rated sale", #r.audit.box1 == 1 and r.audit.box1[1] == 1)
check("audit trail: Box 7 lists 3 purchases", #r.audit.box7 == 3, #r.audit.box7)
check("valid for HMRC", R.validate(r.boxes) == true)

print("== repayment")
r = R.build({ line("sale", 1200, "STD20"), line("purchase", 6000, "STD20") }, { scheme = "standard" })
check("refund due: Box 5 is positive, direction repay", eq(r.boxes.box5, 800) and r.direction == "repay")

print("== Boxes 6–9 are whole pounds (rounded down)")
r = R.build({ line("sale", 1199.99, "STD20") }, { scheme = "standard" })
check("Box 6 £999.99 → 999", r.boxes.box6 == 999, r.boxes.box6)
check("Box 1 keeps pence", eq(r.boxes.box1, 200), r.boxes.box1)

print("== reverse charge on services from abroad (Notice 741A)")
r = R.build({ line("purchase", 1000, "RC_SERVICES") }, { scheme = "standard" })
check("Box 1 £200 and Box 4 £200: no net cost", eq(r.boxes.box1, 200) and eq(r.boxes.box4, 200)
    and eq(r.boxes.box5, 0) and r.direction == "nil")
check("value in Box 6 and Box 7", r.boxes.box6 == 1000 and r.boxes.box7 == 1000)

print("== construction reverse charge (CIS)")
r = R.build({ line("purchase", 5000, "RC_CIS") }, { scheme = "standard" })
check("customer: Box 1 and 4 £1,000, value in Box 7 only", eq(r.boxes.box1, 1000) and eq(r.boxes.box4, 1000)
    and r.boxes.box6 == 0 and r.boxes.box7 == 5000)
r = R.build({ line("sale", 5000, "RC_CIS") }, { scheme = "standard" })
check("supplier: value in Box 6, no VAT", r.boxes.box6 == 5000 and eq(r.boxes.box1, 0))

print("== postponed import VAT (Notice 702)")
r = R.build({ line("purchase", 8000, "PVA") }, { scheme = "standard" })
check("Box 1 and 4 £1,600, value in Box 7", eq(r.boxes.box1, 1600) and eq(r.boxes.box4, 1600)
    and r.boxes.box7 == 8000)

print("== Northern Ireland goods with the EU")
r = R.build({ line("purchase", 4000, "NI_EU_GOODS"), line("sale", 2500, "NI_EU_GOODS") }, { scheme = "standard" })
check("acquisition: Box 2 £800, Box 4 £800, Box 7 and 9 £4,000", eq(r.boxes.box2, 800) and eq(r.boxes.box4, 800)
    and r.boxes.box7 == 4000 and r.boxes.box9 == 4000, r.boxes.box2)
check("dispatch: Box 6 and 8 £2,500, no Box 1 VAT", r.boxes.box6 == 2500 and r.boxes.box8 == 2500
    and eq(r.boxes.box1, 0))
check("Box 3 includes Box 2", eq(r.boxes.box3, 800))

print("== Flat Rate Scheme (Notice 733)")
r = R.build({ line("sale", 100000, "STD20"), line("purchase", 1200, "STD20") },
    { scheme = "flat_rate", flat_rate_pct = 14.5 })
check("Box 1 = 14.5% × £100,000 VAT-inclusive turnover = £14,500", eq(r.boxes.box1, 14500), r.boxes.box1)
check("Box 6 is VAT-inclusive turnover", r.boxes.box6 == 100000, r.boxes.box6)
check("ordinary purchases claim nothing", eq(r.boxes.box4, 0) and r.boxes.box7 == 0)
r = R.build({ line("sale", 100000, "STD20") },
    { scheme = "flat_rate", flat_rate_pct = 14.5, flat_rate_first_year = true })
check("first year: 1% off → 13.5% = £13,500", eq(r.boxes.box1, 13500), r.boxes.box1)
r = R.build({ line("sale", 100000, "STD20") },
    { scheme = "flat_rate", flat_rate_pct = 14.5, limited_cost_trader = true })
check("limited-cost trader: 16.5% = £16,500", eq(r.boxes.box1, 16500), r.boxes.box1)
r = R.build({ line("sale", 60000, "STD20"), line("purchase", 3600, "STD20", { capital_asset = true }),
    line("purchase", 1800, "STD20", { capital_asset = true }) }, { scheme = "flat_rate", flat_rate_pct = 12 })
check("capital asset £3,600 inc VAT is claimed (£600), £1,800 one is not", eq(r.boxes.box4, 600)
    and r.boxes.box7 == 3000, r.boxes.box4)
check("limited-cost test: £400 of goods on £60k turnover a quarter passes",
    R.limited_cost_test(60000, 400, 3) == true)
check("limited-cost test: £5,000 of goods does not", R.limited_cost_test(60000, 5000, 3) == false)
r = R.build({ line("sale", 60000, "STD20") }, { scheme = "flat_rate", flat_rate_pct = 12 },
    { relevant_goods_gross = 100 })
check("warns when the business looks like a limited-cost trader", #r.warnings == 1, #r.warnings)

print("== partial exemption (Notice 706)")
local pl = { line("sale", 60000, "STD20"), line("sale", 40000, "EXEMPT"), line("purchase", 30000, "STD20") }
r = R.build(pl, { scheme = "standard", partially_exempt = true, recovery_pct = 60 })
check("over de minimis: 60% of £5,000 input VAT = £3,000", eq(r.boxes.box4, 3000)
    and r.partial_exemption.de_minimis == false, r.boxes.box4)
r = R.build({ line("sale", 60000, "STD20"), line("sale", 10000, "EXEMPT"), line("purchase", 6000, "STD20") },
    { scheme = "standard", partially_exempt = true, recovery_pct = 60 })
check("de minimis (£1,000 input VAT ≤ £1,875, exempt ≤ 50%): all recovered", eq(r.boxes.box4, 1000)
    and r.partial_exemption.de_minimis == true, r.boxes.box4)

print("== adjustments")
r = R.build({ line("sale", 1200, "STD20") }, { scheme = "standard" }, {
    period_end = "2026-03-31",
    adjustments = {
        { id = "f1", type = "fuel_scale", vat = 50.83, net = 254.17 },
        { id = "b1", type = "bad_debt_relief", vat = 100, due_date = "2025-08-31", written_off = true },
        { id = "b2", type = "bad_debt_relief", vat = 99, due_date = "2026-01-31", written_off = true },
        { id = "b3", type = "bad_debt_relief", vat = 98, due_date = "2025-01-31", written_off = false },
    } })
check("fuel scale charge adds to Box 1 and Box 6", eq(r.boxes.box1, 250.83) and r.boxes.box6 == 1254, r.boxes.box1)
check("bad debt 7 months overdue and written off: claimed", eq(r.boxes.box4, 100), r.boxes.box4)
check("too recent / not written off: refused with a reason each", #r.warnings == 2, #r.warnings)
check("adjustments are in the audit trail", r.audit.box1[#r.audit.box1] == "adj:f1")

print("== earlier errors (Notice 700/45)")
check("threshold: £10,000 floor", R.correction_threshold(600000) == 10000)
check("threshold: 1% of Box 6", R.correction_threshold(3000000) == 30000)
check("threshold: capped at £50,000", R.correction_threshold(8000000) == 50000)
r = R.build({ line("sale", 120000, "STD20") }, { scheme = "standard" },
    { adjustments = { { id = "c1", type = "correction", box1 = 4000, box4 = 0 } } })
check("small error goes on this return", eq(r.boxes.box1, 24000) and #r.corrections.applied == 1, r.boxes.box1)
r = R.build({ line("sale", 120000, "STD20") }, { scheme = "standard" },
    { adjustments = { { id = "c2", type = "correction", box1 = 25000, box4 = 0 } } })
check("large error is not added; told to disclose", eq(r.boxes.box1, 20000) and #r.corrections.too_large == 1
    and r.warnings[1]:find("VAT652") ~= nil, r.boxes.box1)

print("== annual accounting interim payments (Notice 732)")
local ia = R.annual_interim(12000)
check("9 monthly payments of 10%", ia.count == 9 and eq(ia.each, 1200))
ia = R.annual_interim(12000, "quarterly")
check("3 quarterly payments of 25%", ia.count == 3 and eq(ia.each, 3000))

print("== HMRC's submission checks")
local ok, errs = R.validate({ box1 = 100, box2 = 0, box3 = 90, box4 = 20, box5 = 80, box6 = 500, box7 = 100,
    box8 = 0, box9 = 0 })
check("Box 3 ≠ 1 + 2 is caught", ok == false and errs[1].box == "box3")
ok, errs = R.validate({ box1 = 100, box2 = 0, box3 = 100, box4 = 20, box5 = 80, box6 = 500.5, box7 = 100,
    box8 = 0, box9 = 0 })
check("pence in Box 6 is caught", ok == false and errs[1].box == "box6")
ok, errs = R.validate({ box1 = 100, box2 = 0, box3 = 100, box4 = 20, box5 = 70, box6 = 500, box7 = 100,
    box8 = 0, box9 = 0 })
check("wrong Box 5 is caught", ok == false and errs[1].box == "box5")

print("== uncoded lines")
r = R.build({ { id = 99, direction = "purchase", vat_code = nil, net = 10, vat = 2 } }, { scheme = "standard" })
check("left out with a warning", eq(r.boxes.box4, 0) and #r.warnings == 1)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
