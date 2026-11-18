--[[
    Spec: stock enquiries to suppliers (queries/ShopStockEnquiryQueries.lua).

    Standalone (no busted). From the repo root:
        luajit lapis/spec/stock-enquiry_spec.lua

    Covers:
      - the message: greeting (contact, else the supplier's name), qty x product, the questions, sender and company
      - their code only when the product is linked to THIS supplier's price file; the part number always
      - staff notes become bullet lines; the subject names the product
      - the brand is not repeated when the name already starts with it
      - never our prices: the product's price is not in the message
      - deal screens can't reach a stock enquiry (deal_code IS NOT NULL guards) and the migration allows a
        NULL deal code only for kind = 'stock'
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, INFO = 7, ctx = {}, var = {} } -- luacheck: ignore 111
package.loaded["lapis.db"] = package.loaded["lapis.db"] or { query = function() return {} end, NULL = {} }
package.loaded["helper.global"] = package.loaded["helper.global"] or { generateUUID = function() return "u-1" end }

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and (": " .. tostring(detail)) or ""))
    end
end

local E = require("queries.ShopStockEnquiryQueries")

print("stock enquiry message")
local product = { name = "Juno Neptune 18\"", brand = "Juno Computers", base_price_minor = 310417,
                  item_supplier_id = 7, supplier_sku = "NEP18-5080", mpn = "JN18-U9-5080" }
local sam = { id = 7, name = "Juno Computers", contact_name = "Sam" }
local m = E.message(product, sam, { qty = 3, note = "RTX 5080, 64 GB\n- Kubuntu", company = "Workstation", sender = "Bal Walia" })

check("subject names the product", m.subject == "Stock enquiry: Juno Neptune 18\"", m.subject)
check("greets the contact", m.body:find("^Hello Sam,\n") ~= nil, m.body)
check("asks about stock", m.body:find("Do you have the following in stock?", 1, true) ~= nil)
check("qty x product", m.body:find("3 x Juno Neptune 18\"", 1, true) ~= nil)
check("their own code when linked to this supplier", m.body:find("Your code: NEP18-5080", 1, true) ~= nil)
check("the part number", m.body:find("Part number: JN18-U9-5080", 1, true) ~= nil)
check("note lines become bullets", m.body:find("   - RTX 5080, 64 GB\n   - Kubuntu", 1, true) ~= nil, m.body)
check("asks stock or lead time, price ex VAT, delivery, validity",
    m.body:find("how many you have in stock (or the lead time), your trade price ex VAT, when you could deliver, "
        .. "and how long the price is valid.", 1, true) ~= nil)
check("signed by the sender and company", m.body:find("Thank you,\nBal Walia\nWorkstation$") ~= nil, m.body)
check("never our price", not m.body:find("3104", 1, true) and not m.body:find("3,104", 1, true) and not m.body:find("£", 1, true))

local other = { id = 9, name = "Overclockers UK" }
local m2 = E.message(product, other, { qty = 1 })
check("greets the supplier by name without a contact", m2.body:find("^Hello Overclockers UK,\n") ~= nil, m2.body)
check("no 'Your code' for a different supplier", not m2.body:find("Your code", 1, true))
check("part number still shown for another supplier", m2.body:find("Part number: JN18-U9-5080", 1, true) ~= nil)
check("no sender lines when unknown", m2.body:find("Thank you,$") ~= nil, m2.body)
check("bad qty falls back to 1", E.message(product, other, { qty = "abc" }).body:find("\n1 x Juno", 1, true) ~= nil)

print("product title")
check("brand not repeated", E.title({ name = "Juno Neptune 18\"", brand = "Juno Computers" }) == "Juno Neptune 18\"")
check("brand added when missing", E.title({ name = "ThinkPad P16 Gen 3", brand = "Lenovo" }) == "Lenovo ThinkPad P16 Gen 3")
check("no brand", E.title({ name = "RTX PRO 6000" }) == "RTX PRO 6000")

print("deal screens never reach stock enquiries")
local function read(p)
    local f = io.open(p) or io.open("lapis/" .. p)
    local s = f:read("*a"); f:close(); return s
end
local deal = read("queries/ShopDealQueries.lua")
check("deal request lookup skips rows without a deal",
    deal:find("WHERE r.namespace_id = ? AND r.uuid = ? AND r.deal_code IS NOT NULL", 1, true) ~= nil)
check("deal search skips rows without a deal",
    deal:find("FROM shop_supplier_requests\n           WHERE namespace_id = ? AND deal_code IS NOT NULL AND supplier_quote_ref ILIKE ?", 1, true) ~= nil)
local mig = read("migrations/shop-deal-codes.lua")
check("a NULL deal code only for a stock enquiry", mig:find("CHECK (deal_code IS NOT NULL OR kind = 'stock')", 1, true) ~= nil)
check("zzs66 registered", read("migrations.lua"):find("['zzs66_supplier_stock_enquiries'] = conditional_array(ProjectConfig.FEATURES.SHOP, shop_deal_code_migrations, 5)", 1, true) ~= nil)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
