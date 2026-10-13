-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-supplier.lua (no nginx, no DB, no busted).

    Run from lapis/ in the openresty image (needs cjson):
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            luajit spec/shop-supplier-test.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
-- cjson ships with OpenResty, not plain LuaJIT
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
local S = require("lib.shop-supplier")

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

-- CSV ----------------------------------------------------------------------------------------
local csv = '\239\187\191Part No,Description,Manufacturer,Trade Price,Stock,Lead Time\r\n'
    .. 'VCNRTXPRO6000-PB,"NVIDIA RTX PRO 6000 Blackwell, 96GB",PNY,"£7,450.00",12,2-3 days\r\n'
    .. 'ABC-1,"Cable ""HDMI"" 2m",Generic,4.99,In stock,\n'
    .. '\n'
    .. 'WS-1,"Workstation with\nRTX 5000 Ada",Lenovo,5120.5,0,2 weeks'
local recs = S.records(csv, "csv")
check("csv: header row becomes keys, BOM stripped", recs and recs[1]["Part No"] == "VCNRTXPRO6000-PB", recs and recs[1]["Part No"])
check("csv: quoted comma kept", recs[1]["Description"] == "NVIDIA RTX PRO 6000 Blackwell, 96GB")
check("csv: escaped quotes", recs[2]["Description"] == 'Cable "HDMI" 2m')
check("csv: newline inside quotes", recs[3]["Description"] == "Workstation with\nRTX 5000 Ada")
check("csv: blank line skipped, 3 records", #recs == 3, #recs)
check("csv: semicolon delimiter", S.records("a;b\n1;2", "csv", { delimiter = ";" })[1].b == "2")

-- JSON / XML ----------------------------------------------------------------------------------
local js = S.records('{"data":{"items":[{"sku":"A1","price":12.5,"meta":{"x":1}},{"sku":"B2","price":"9"}]}}', "json",
    { records_path = "data.items" })
check("json: records at a path", js and #js == 2 and js[1].sku == "A1" and js[1].price == "12.5")
check("json: nested values ignored", js[1].meta == nil)
local _, jerr = S.records('{"data":{}}', "json", { records_path = "data.items" })
check("json: missing path explained", jerr ~= nil)
local _, jerr2 = S.records("not json", "json", {})
check("json: invalid JSON explained", jerr2 == "the file is not valid JSON")
local xml = [==[<?xml version="1.0"?><catalogue><product id="1"><sku>X-1</sku><name><![CDATA[RTX A6000 & cooler]]></name>
<price>1&#44;000.00</price><brand>NVIDIA</brand><empty/></product><product><sku>X-2</sku><name>Mouse &amp; pad</name><price>5</price></product></catalogue>]==]
local xr = S.records(xml, "xml", { record_tag = "product" })
check("xml: one record per product element", xr and #xr == 2, xr and #xr)
check("xml: CDATA and fields", xr[1].sku == "X-1" and xr[1].name == "RTX A6000 & cooler")
check("xml: entities decoded", xr[2].name == "Mouse & pad" and xr[1].price == "1,000.00")
local _, xerr = S.records(xml, "xml", {})
check("xml: record_tag required", xerr ~= nil)
check("format: unknown refused", select(2, S.records("x", "pdf")) ~= nil)
check("format: empty file refused", select(2, S.records("", "csv")) == "the file is empty")

-- values -----------------------------------------------------------------------------------------
check("money: £ and thousands", S.money("£7,450.00") == 745000)
check("money: plain decimal", S.money("5120.5") == 512050)
check("money: European format", S.money("1.234,56 €") == 123456)
check("money: currency code", S.money("GBP 99") == 9900)
check("money: zero/blank/words → nil", S.money("0") == nil and S.money("") == nil and S.money("POA") == nil)
local q, ins = S.stock("12")
check("stock: number", q == 12 and ins == true)
q, ins = S.stock("0")
check("stock: zero is out of stock", q == 0 and ins == false)
q, ins = S.stock("In stock")
check("stock: words without a number", q == nil and ins == true)
q, ins = S.stock("Out of stock")
check("stock: out of stock words", q == 0 and ins == false)
q = S.stock("10+")
check("stock: 10+", q == 10)
check("lead: range takes the upper end", S.lead_days("2-3 days") == 3)
check("lead: weeks", S.lead_days("2 weeks") == 14)
check("lead: none", S.lead_days("") == nil and S.lead_days("Call") == nil)

-- normalise ----------------------------------------------------------------------------------------
local map = { supplier_sku = "Part No", name = "Description", brand = "Manufacturer", cost = "Trade Price", stock = "Stock",
    lead_time_days = "Lead Time" }
local it = S.normalise(recs[1], map, {})
check("normalise: core fields", it.supplier_sku == "VCNRTXPRO6000-PB" and it.cost_minor == 745000 and it.stock_qty == 12
    and it.lead_time_days == 3 and it.brand == "PNY")
local inc = S.normalise({ ["Part No"] = "Z", Description = "RTX", ["Trade Price"] = "120" }, map, { prices_include_vat = true, vat_rate = 0.2 })
check("normalise: VAT-inclusive file stored ex VAT", inc.cost_minor == 10000)
check("normalise: missing cost rejected", select(2, S.normalise({ ["Part No"] = "Z", Description = "x" }, map, {})) == "no cost price")
check("normalise: missing SKU rejected", select(2, S.normalise({ Description = "x", ["Trade Price"] = "1" }, map, {})) == "no supplier SKU")

-- filter -------------------------------------------------------------------------------------------
check("filter: NVIDIA GPU kept", S.matches(it))
check("filter: workstation with RTX kept", S.matches(S.normalise(recs[3], map, {})))
check("filter: unrelated item dropped", not S.matches(S.normalise(recs[2], map, {})))
check("filter: custom keywords", S.matches({ name = "Supermicro SYS-421GE" }, { keywords = { "supermicro" } }))
check("filter: empty keywords keep everything", S.matches({ name = "Mouse" }, { keywords = {} }))

-- pricing ------------------------------------------------------------------------------------------
check("margin: product beats category beats supplier", S.margin(8, 12, 15) == 8 and S.margin(nil, 12, 15) == 12
    and S.margin(nil, nil, 15) == 15)
check("margin: 0% is a real margin", S.margin(0, 12, 15) == 0)
check("sell price: cost + 15%", S.sell_price(745000, 15) == 856750)
check("sell price: rounds to the penny", S.sell_price(999, 12.5) == 1124)
check("sell price: no cost → nil", S.sell_price(0, 15) == nil)
check("decide: same price → none", S.decide(856750, 856750, 10) == "none")
check("decide: +5% applies", S.decide(100000, 105000, 10) == "apply")
check("decide: −10% exactly applies", S.decide(100000, 90000, 10) == "apply")
check("decide: +10.01% needs review", S.decide(100000, 110010, 10) == "review")
check("decide: −30% needs review", S.decide(100000, 70000, 10) == "review")
check("decide: first price needs review", S.decide(0, 50000, 10) == "review")
check("change pct", math.abs(S.change_pct(100000, 112500) - 12.5) < 1e-9)

-- mapping -----------------------------------------------------------------------------------------
check("mapping: valid", S.validate_mapping(map) ~= nil)
check("mapping: cost required", select(2, S.validate_mapping({ supplier_sku = "a", name = "b" })) == "mapping.cost is required")
check("mapping: unknown field", select(2, S.validate_mapping({ supplier_sku = "a", name = "b", cost = "c", colour = "d" })) ~= nil)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
