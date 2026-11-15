--[[
    Spec: less common VAT schemes (VAT plan phase 10) — partial exemption standard
    method with attribution and all three de minimis tests (Notice 706), the annual
    adjustment, the capital goods scheme (Notice 706/2), margin scheme global
    accounting (Notice 718), VAT group supplies (Notice 700/2) and the Northern
    Ireland EC Sales List.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-schemes_spec.lua
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
local S = require("lib.vat-schemes")

local n = 0
local function line(direction, amount, code, extra)
    n = n + 1
    local s = assert(VAT.split(amount, code))
    local l = { id = n, direction = direction, vat_code = code, net = s.net, vat = s.vat,
        notional_vat = s.notional_vat, gross = amount }
    for k, v in pairs(extra or {}) do l[k] = v end
    return l
end
local PE = { scheme = "standard", partially_exempt = true }

print("== recovery % (Notice 706 §6.4)")
check("80k taxable / 100k total = 80%", R.recovery_pct(80000, 20000) == 80)
check("66.667% rounds UP to 67%", R.recovery_pct(66667, 33333) == 67, R.recovery_pct(66667, 33333))
check("exactly 60% stays 60%", R.recovery_pct(60000, 40000) == 60)
check("no supplies: 100%", R.recovery_pct(0, 0) == 100)

print("== partial exemption: attribution")
local sales = { line("sale", 72000, "STD20"), line("sale", 40000, "EXEMPT") } -- 60k taxable net, 40k exempt
local lines = { sales[1], sales[2],
    line("purchase", 12000, "STD20", { attribution = "taxable" }),  -- £2,000 VAT
    line("purchase", 6000, "STD20", { attribution = "exempt" }),    -- £1,000 VAT
    line("purchase", 30000, "STD20") }                               -- £5,000 VAT, residual
local r = R.build(lines, PE)
local pe = r.partial_exemption
check("this period's recovery % is 60 (no provisional rate)", pe.recovery_pct == 60 and pe.basis == "this_period",
    pe.recovery_pct)
check("taxable £2,000 + 60% of residual £5,000 = £5,000 recovered; exempt £1,000 not",
    eq(r.boxes.box4, 5000) and pe.de_minimis == false, r.boxes.box4)
check("residual split shown", eq(pe.residual_input, 5000) and eq(pe.residual_recovered, 3000))
r = R.build(lines, { scheme = "standard", partially_exempt = true, recovery_pct = 50 })
check("a provisional 50% is used when set", eq(r.boxes.box4, 4500) and r.partial_exemption.basis == "provisional",
    r.boxes.box4)

print("== de minimis tests (Notice 706 §11)")
r = R.build({ sales[1], sales[2],
    line("purchase", 30000, "STD20", { attribution = "taxable" }), -- £5,000
    line("purchase", 1800, "STD20", { attribution = "exempt" }),   -- £300
    line("purchase", 6000, "STD20") }, PE)                          -- £1,000 residual
check("test 2 passes (input tax less taxable-only £1,300 ≤ £1,875): all £6,300 recovered",
    eq(r.boxes.box4, 6300) and r.partial_exemption.tests.test2 and not r.partial_exemption.tests.test1,
    r.boxes.box4)
r = R.build({ line("sale", 36000, "STD20"), line("sale", 70000, "EXEMPT"),
    line("purchase", 18000, "STD20", { attribution = "taxable" }), -- £3,000
    line("purchase", 3600, "STD20") }, PE)                          -- £600 residual, 30% recovered
check("original test passes (exempt input tax £420 ≤ £1,875 and ≤ half): all £3,600 recovered",
    eq(r.boxes.box4, 3600) and r.partial_exemption.tests.original and not r.partial_exemption.tests.test2,
    r.boxes.box4)
check("exempt input tax reported", eq(r.partial_exemption.tests.exempt_input_tax, 420))

print("== annual adjustment")
local year = { line("sale", 84000, "STD20"), line("sale", 30000, "EXEMPT"),
    line("purchase", 180000, "STD20") } -- £30,000 residual VAT
local a = S.annual_adjustment(year, { scheme = "standard", partially_exempt = true, recovery_pct = 50 }, 15000)
check("annual % from the year's supplies is 70", a.annual_pct == 70, a.annual_pct)
check("should recover £21,000; returns recovered £15,000; claim £6,000",
    eq(a.should_recover, 21000) and eq(a.adjustment, 6000) and a.direction == "claim", a.adjustment)
a = S.annual_adjustment(year, { scheme = "standard", partially_exempt = true }, 24000)
check("over-recovered in year: repay £3,000", eq(a.adjustment, -3000) and a.direction == "repay", a.adjustment)

print("== capital goods scheme (Notice 706/2)")
check("a £1m building is in the scheme", S.cgs_applies("building", 1000000))
check("a £240k building is not", not S.cgs_applies("building", 240000))
check("a £60k boat is (threshold £50k)", S.cgs_applies("ship", 60000))
check("land: 10 intervals, 5 on a short lease", S.cgs_intervals("land") == 10 and S.cgs_intervals("land", true) == 5)
check("aircraft: 5 intervals", S.cgs_intervals("aircraft") == 5)
local item = { kind = "building", input_vat = 200000, original_use_pct = 100, intervals = 10 }
check("use falls to 60%: £200,000/10 × −40% = −£8,000",
    eq(S.cgs_interval_adjustment(item, 60), -8000), S.cgs_interval_adjustment(item, 60))
check("no change in use: nothing", eq(S.cgs_interval_adjustment(item, 100), 0))
local d = S.cgs_disposal(item, 4, false)
check("exempt sale after 4 intervals: 6 left at 0% = −£120,000", eq(d.adjustment, -120000)
    and d.remaining_intervals == 6, d.adjustment)
d = S.cgs_disposal({ kind = "building", input_vat = 200000, original_use_pct = 50, intervals = 10 }, 4, true, 50000)
check("taxable sale: 6 × £20,000 × 50% = £60,000, capped at the £50,000 output VAT",
    eq(d.adjustment, 50000) and d.capped, d.adjustment)
local v, verr = S.validate_item({ kind = "building", cost_ex_vat = 100000, input_vat = 20000, original_use_pct = 100 })
check("validation refuses an item under the threshold", v == nil and verr:find("isn't in the capital goods"), verr)
r = R.build({ line("sale", 1200, "STD20") }, { scheme = "standard" },
    { adjustments = { { id = "c1", type = "cgs", vat = -8000 } } })
check("a CGS adjustment goes to Box 4", eq(r.boxes.box4, -8000), r.boxes.box4)

print("== margin scheme, global accounting (Notice 718)")
r = R.build({ line("purchase", 5000, "MARGIN"), line("sale", 6200, "MARGIN") }, { scheme = "standard" })
check("£1,200 margin: VAT £200 (1/6) in Box 1", eq(r.boxes.box1, 200) and eq(r.margin.vat, 200), r.boxes.box1)
check("Box 6 = sales less VAT (£6,000); Box 7 = margin purchases (£5,000)",
    r.boxes.box6 == 6000 and r.boxes.box7 == 5000, r.boxes.box6 .. "/" .. r.boxes.box7)
check("no input VAT on margin stock", eq(r.boxes.box4, 0))
r = R.build({ line("purchase", 5000, "MARGIN"), line("sale", 4000, "MARGIN") }, { scheme = "standard" })
check("negative margin: no VAT, £1,000 carried forward", eq(r.boxes.box1, 0) and eq(r.margin.carried_forward, 1000))
r = R.build({ line("purchase", 2000, "MARGIN"), line("sale", 6000, "MARGIN") }, { scheme = "standard" },
    { margin_brought_forward = 1000 })
check("brought forward reduces next margin: (6,000 − 2,000 − 1,000)/6 = £500", eq(r.boxes.box1, 500), r.boxes.box1)
do
    local msgs = require("lib.vat-classifier").messages({ { i = 1, description = "x", amount = 1 } }, {})
    local text = ""
    for _, m in ipairs(msgs) do text = text .. tostring(m.content) end
    check("MARGIN isn't offered to the AI", not text:find("MARGIN"))
end

print("== VAT groups (Notice 700/2)")
r = R.build({ line("sale", 1200, "STD20"), line("sale", 6000, "STD20", { intra_group = true }) },
    { scheme = "standard" })
check("a supply to another group member is left off", eq(r.boxes.box1, 200) and r.boxes.box6 == 1000, r.boxes.box1)

print("== EC Sales List (Northern Ireland)")
local esl = S.ec_sales_list({
    { customer_vat_number = "DE123456789", net = 1000.40 },
    { customer_vat_number = "de 123 456 789", net = 500 },
    { customer_vat_number = "FR12345678901", net = 2000, triangulation = true },
    { customer_vat_number = "", customer_name = "No Number GmbH", net = 300 },
    { customer_vat_number = "GB123456789", customer_name = "UK Ltd", net = 50 },
})
check("one row per customer and indicator", #esl.rows == 2, #esl.rows)
check("DE customer totalled, whole pounds", esl.rows[1].country == "DE" and esl.rows[1].value == 1500
    and esl.rows[1].indicator == 0, esl.rows[1].value)
check("triangulation indicator 2", esl.rows[2].country == "FR" and esl.rows[2].indicator == 2)
check("lines without an EU VAT number are listed to fix", #esl.missing == 2, #esl.missing)
check("quarterly under £35,000", esl.frequency_hint == "quarterly")
check("Greece uses EL", S.eu_vat_number("EL123456789") == "EL")
local csv = S.ec_sales_csv(esl)
check("CSV has a header and the rows", csv:find("^country_code,") and csv:find("DE,123456789,1500,0"), csv)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
