--[[
    Spec: VAT on our own invoices (lib/vat-invoice.lua).

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-invoice_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local M = require("lib.vat-invoice")
local R = require("lib.vat-return")

print("== line VAT")
check("20% rate -> STD20", M.code_for_line({ tax_rate = 20 }) == "STD20")
check("5% -> RED5, 0% -> ZERO", M.code_for_line({ tax_rate = 5 }) == "RED5"
    and M.code_for_line({ tax_rate = 0 }) == "ZERO")
check("explicit code wins (exempt at 0%)", M.code_for_line({ tax_rate = 0, vat_code = "EXEMPT" }) == "EXEMPT")
check("17.5% isn't a UK rate", M.code_for_line({ tax_rate = 17.5 }) == nil)
local net, vat = M.line_amounts({ quantity = 3, unit_price = 100, discount_percent = 10, tax_rate = 20 })
check("3 x £100 less 10% = £270 + £54 VAT", net == 270 and vat == 54, net .. "/" .. vat)
net, vat = M.line_amounts({ quantity = 1, unit_price = 5000, vat_code = "RC_CIS", tax_rate = 0 })
check("CIS reverse charge: no VAT charged", net == 5000 and vat == 0)

print("== is it a valid VAT invoice? (Notice 700/21)")
local supplier = { name = "Acme Ltd", address = "1 High St, Leeds", vrn = "980780684" }
local inv = { invoice_number = "INV-0001", issue_date = "2026-02-10", customer_name = "Beta Ltd",
    customer_address = "2 Low Rd", currency = "GBP" }
local lines = { { description = "Consulting", quantity = 10, unit_price = 100, tax_rate = 20 } }
local c = M.check(inv, lines, supplier)
check("complete invoice passes", c.ok and c.vat == 200 and c.gross == 1200, table.concat(c.missing, "; "))
c = M.check(inv, lines, { name = "Acme Ltd", address = "1 High St" })
check("no VAT number -> listed", not c.ok and c.missing[1]:find("VAT registration") ~= nil)
c = M.check({ invoice_number = "S1", issue_date = "2026-02-10", currency = "GBP" },
    { { description = "Coffee", quantity = 1, unit_price = 100, tax_rate = 20 } }, supplier)
check("£120: simplified invoice, no customer details needed", c.ok and c.simplified_allowed)
c = M.check({ invoice_number = "S2", issue_date = "2026-02-10", currency = "GBP" }, lines, supplier)
check("£1,200 without the customer -> customer name and address listed", not c.ok and #c.missing == 2)
c = M.check(inv, { { description = "Groundworks", quantity = 1, unit_price = 5000, vat_code = "RC_CIS" } }, supplier)
check("CIS reverse charge wording supplied",
    c.reverse_charge_text and c.reverse_charge_text:find("customer to pay") ~= nil)
inv.currency = "USD"
c = M.check(inv, lines, supplier)
check("a USD invoice must show VAT in sterling", not c.ok and c.missing[#c.missing]:find("sterling") ~= nil)
inv.currency = "GBP"

print("== invoices on the VAT return")
local invoices = {
    { id = 1, status = "paid", issue_date = "2026-02-10", currency = "GBP", lines = lines,
      payments = { { amount = 1200, payment_date = "2026-04-02" } } },
    { id = 2, status = "draft", issue_date = "2026-02-11", currency = "GBP", lines = lines },
    { id = 3, status = "sent", issue_date = "2026-03-30", currency = "USD", lines = lines },
    { id = 4, status = "partially_paid", issue_date = "2026-03-01", currency = "GBP",
      lines = { { description = "Design", quantity = 1, unit_price = 2000, tax_rate = 20 } },
      payments = { { amount = 1200, payment_date = "2026-03-15" } } },
}
local el, skipped = M.engine_lines(invoices,
    { period_start = "2026-01-01", period_end = "2026-03-31", scheme = "standard" })
check("standard: issued invoices dated in the quarter (not drafts)", #el == 2, #el)
check("foreign-currency invoice skipped and counted", skipped.foreign_currency == 1)
local r = R.build(el, { scheme = "standard" })
check("Box 1 = £200 + £400 VAT, Box 6 = £3,000", r.boxes.box1 == 600 and r.boxes.box6 == 3000, r.boxes.box1)
el = M.engine_lines(invoices, { period_start = "2026-01-01", period_end = "2026-03-31", scheme = "cash" })
r = R.build(el, { scheme = "cash" })
check("cash accounting: only what was paid in the quarter (half of invoice 4)", r.boxes.box1 == 200
    and r.boxes.box6 == 1000, r.boxes.box1 .. "/" .. r.boxes.box6)
el = M.engine_lines(invoices, { period_start = "2026-04-01", period_end = "2026-06-30", scheme = "cash" })
r = R.build(el, { scheme = "cash" })
check("cash: invoice 1 counts when paid in April", r.boxes.box1 == 200, r.boxes.box1)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
