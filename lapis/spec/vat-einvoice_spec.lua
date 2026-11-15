--[[
    Spec: e-invoicing readiness (VAT plan phase 11) — our invoices as UBL 2.1 in the
    Peppol BIS Billing 3.0 profile (EN 16931), the business-rule checks, and reading a
    supplier's e-invoice back into UK VAT codes.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-einvoice_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function eq(a, b) return math.abs((tonumber(a) or -1e18) - b) < 0.005 end
local function rules(res)
    local t = {}
    for _, e in ipairs(res.errors) do t[#t + 1] = e.rule .. ": " .. e.message end
    return table.concat(t, "; ")
end

local E = require("lib.vat-einvoice")

local supplier = { name = "Acme Widgets Ltd", vrn = "899385734", address = "1 High Street, Leeds, LS1 4AB",
    email = "accounts@acme.example" }
local invoice = { invoice_number = "INV-1001", issue_date = "2026-11-02", due_date = "2026-12-02",
    currency = "GBP", customer_name = "Bob & Co <Trading>", customer_email = "bob@example.com",
    customer_address = { line1 = "2 Park Road", city = "York", postcode = "YO1 7HH", country = "GB" },
    customer_vat_number = "GB 123 4567 82", notes = "Thanks", po_number = "PO-77" }
local lines = {
    { description = "Widgets", quantity = 3, unit_price = 33.33, tax_rate = 20 },
    { description = "Delivery", quantity = 1, unit_price = 10, tax_rate = 20, discount_percent = 10 },
    { description = "Children's books", quantity = 2, unit_price = 7.5, tax_rate = 0 },
    { description = "Training (exempt)", quantity = 1, unit_price = 200, tax_rate = 0, vat_code = "EXEMPT" },
}

print("== addresses")
local a = E.address("1 High Street, Leeds, LS1 4AB")
check("free text: street, city, postcode",
    a.street == "1 High Street" and a.city == "Leeds" and a.postcode == "LS1 4AB",
    (a.street or "") .. "|" .. (a.city or "") .. "|" .. (a.postcode or ""))
a = E.address({ address_line1 = "Unit 4", town = "Hull", postal_code = "HU1 1AA", country = "United Kingdom" })
check("table with common key names", a.street == "Unit 4" and a.city == "Hull" and a.country == "GB")

print("== build (Peppol BIS Billing 3.0)")
local xml, problems = E.build(invoice, lines, supplier)
check("no problems for UK VAT rates", #problems == 0, #problems)
check("Peppol customization and profile", xml:find(E.CUSTOMIZATION_ID, 1, true) and xml:find(E.PROFILE_ID, 1, true))
check("special characters escaped", xml:find("Bob &amp; Co &lt;Trading&gt;", 1, true) ~= nil)
check("seller endpoint uses the UK VAT scheme 9932", xml:find('<cbc:EndpointID schemeID="9932">GB899385734', 1, true))
check("buyer VAT number normalised", xml:find("<cbc:CompanyID>GB123456782</cbc:CompanyID>", 1, true))
check("buyer reference is the PO", xml:find("<cbc:BuyerReference>PO-77</cbc:BuyerReference>", 1, true))
check("exempt line carries a reason", xml:find("<cbc:TaxExemptionReason>Exempt from VAT", 1, true))
check("discount as a line allowance (£1.00)", xml:find("<cbc:AllowanceChargeReason>Discount", 1, true)
    and xml:find('<cbc:Amount currencyID="GBP">1.00</cbc:Amount>', 1, true))
-- 3 x 33.33 = 99.99 + 9.00 = 108.99 at 20% -> 21.80; zero 15.00; exempt 200.00
check("standard-rated VAT per category: 108.99 x 20% = 21.80",
    xml:find('<cbc:TaxableAmount currencyID="GBP">108.99</cbc:TaxableAmount><cbc:TaxAmount currencyID="GBP">21.80',
        1, true))
check("payable = 323.99 + 21.80 = 345.79", xml:find('<cbc:PayableAmount currencyID="GBP">345.79', 1, true))

print("== check (EN 16931 / Peppol rules)")
local res = E.check(xml)
check("our invoice passes", res.valid, rules(res))
check("read back: 4 lines, 3 VAT groups", #res.data.lines == 4 and #res.data.breakdown == 3)
check("read back: categories map to our codes", res.data.breakdown[1].vat_code == "STD20"
    and res.data.lines[4].vat_code == "EXEMPT", res.data.breakdown[1].vat_code)

local paid = E.build({ invoice_number = "INV-2", issue_date = "2026-11-02", currency = "GBP", customer_name = "C",
    customer_email = "c@example.com", amount_paid = 50 }, { { description = "x", quantity = 1, unit_price = 100,
    tax_rate = 20 } }, supplier)
res = E.check(paid)
check("part-paid: prepaid shown and payable 70.00", res.valid and paid:find("<cbc:PrepaidAmount", 1, true)
    and eq(res.data.totals.payable, 70), rules(res))

local rc = E.build({ invoice_number = "INV-3", issue_date = "2026-11-02", currency = "GBP", customer_name = "Builder",
    customer_email = "b@example.com" }, { { description = "Labour", quantity = 1, unit_price = 1000, tax_rate = 0,
    vat_code = "RC_CIS" } }, supplier)
res = E.check(rc)
check("reverse charge without the buyer's VAT number fails BR-AE-02", not res.valid
    and rules(res):find("BR%-AE%-02"), rules(res))

local broken = xml:gsub('<cbc:PayableAmount currencyID="GBP">345.79', '<cbc:PayableAmount currencyID="GBP">300.00')
res = E.check(broken)
check("a wrong amount due fails BR-CO-16", not res.valid and rules(res):find("BR%-CO%-16"), rules(res))
broken = xml:gsub("<cbc:CustomizationID>[^<]+", "<cbc:CustomizationID>urn:other")
check("a non-Peppol customization fails R004", rules(E.check(broken)):find("R004"))
broken = xml:gsub('<cbc:EndpointID schemeID="9932">GB899385734</cbc:EndpointID>', "")
check("missing seller endpoint fails R020", rules(E.check(broken)):find("R020"))
broken = xml:gsub("21%.80</cbc:TaxAmount>%s*<cac:TaxCategory><cbc:ID>S",
    "25.00</cbc:TaxAmount>\n<cac:TaxCategory><cbc:ID>S")
check("wrong category VAT fails BR-CO-17", rules(E.check(broken)):find("BR%-CO%-17"), rules(E.check(broken)))

print("== safety")
res = E.check('<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><Invoice>&e;</Invoice>')
check("a DTD / external entity is refused", not res.valid and res.errors[1].message:find("DTD"), rules(res))
res = E.check("<Invoice>")
check("broken XML is refused", not res.valid, rules(res))
res = E.check('<CreditNote xmlns="urn:x"/>')
check("not an Invoice is refused", not res.valid and rules(res):find("UBL invoice"), rules(res))
local _, p2 = E.build(invoice, { { description = "x", quantity = 1, unit_price = 1, tax_rate = 17.5 } }, supplier)
check("a rate that isn't a UK rate is reported", #p2 == 1)

print("== a supplier's invoice -> purchases")
res = E.check(xml)
local pl = E.purchase_lines(res.data)
check("one purchase line per VAT group", #pl == 3)
check("standard group: net 108.99, VAT 21.80, gross 130.79", pl[1].vat_code == "STD20" and eq(pl[1].net, 108.99)
    and eq(pl[1].vat, 21.8) and eq(pl[1].gross, 130.79))
check("AE from a UK supplier reads as CIS reverse charge", E.code_for_category("AE", 0, nil, "GB") == "RC_CIS")
check("AE from abroad reads as reverse charge on services", E.code_for_category("AE", 0, nil, "DE") == "RC_SERVICES")
check("E with VATEX-EU-F reads as the margin scheme", E.code_for_category("E", 0, "VATEX-EU-F") == "MARGIN")
check("S at 17.5% has no UK code", E.code_for_category("S", 17.5) == nil)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
