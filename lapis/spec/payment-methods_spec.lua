--[[
    Spec: payment methods ("Getting paid") and bank transfer for Order Authorisations
    (lib/payment-methods.lua): validation, normalisation, document ordering, bank-transfer rules,
    invoice lines from a shop order.

    Standalone, from the repo root:
        luajit lapis/spec/payment-methods_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path
local PM = require("lib.payment-methods")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

print("sort code / account number / IBAN / BIC")
check("sort code digits", PM.formatSortCode("123456") == "12-34-56")
check("sort code spaced", PM.formatSortCode(" 12 34 56 ") == "12-34-56")
check("sort code dashed", PM.formatSortCode("12-34-56") == "12-34-56")
check("sort code too short", PM.formatSortCode("12345") == nil)
check("sort code letters", PM.formatSortCode("12ab56") == nil)
check("account number", PM.cleanAccountNumber("3141 5926") == "31415926")
check("account number too short", PM.cleanAccountNumber("123") == nil)
check("IBAN valid (spaces, lower case)", PM.normaliseIban("gb29 nwbk 6016 1331 9268 19") == "GB29NWBK60161331926819")
check("IBAN bad check digits", PM.normaliseIban("GB28NWBK60161331926819") == nil)
check("IBAN garbage", PM.normaliseIban("hello") == nil)
check("IBAN DE valid", PM.normaliseIban("DE89 3704 0044 0532 0130 00") == "DE89370400440532013000")
check("BIC 8", PM.cleanBic("nwbkgb2l") == "NWBKGB2L")
check("BIC 11", PM.cleanBic("NWBKGB2LXXX") == "NWBKGB2LXXX")
check("BIC 9 rejected", PM.cleanBic("NWBKGB2LX") == nil)

print("clean: bank transfer rules")
local f, err = PM.clean({ kind = "bank_transfer", account_name = "Workstation Ltd", bank_name = "Barclays",
    sort_code = "200000", account_number = "55779911" })
check("UK account ok", f ~= nil, err)
check("sort code stored formatted", f and f.sort_code == "20-00-00")
check("default label", f and f.label == "Barclays GBP account", f and f.label)
check("currency GBP default", f and f.currency == "GBP")
check("show_on_documents default true", f and f.show_on_documents == true)
check("active by default", f and f.is_active == true)
check("not default unless asked", f and f.is_default == false)

f, err = PM.clean({ kind = "bank_transfer", sort_code = "200000", account_number = "55779911" })
check("account_name required", f == nil and err:find("account_name"), err)
f, err = PM.clean({ kind = "bank_transfer", account_name = "X" })
check("needs sort code+account or IBAN", f == nil and err:find("IBAN"), err)
f, err = PM.clean({ kind = "bank_transfer", account_name = "X", sort_code = "200000" })
check("sort code without account number", f == nil and err:find("both"), err)
f, err = PM.clean({ kind = "bank_transfer", account_name = "X", iban = "GB29NWBK60161331926819", currency = "eur" })
check("IBAN only ok", f ~= nil and f.iban == "GB29NWBK60161331926819", err)
check("currency upper-cased", f and f.currency == "EUR")
f, err = PM.clean({ kind = "bank_transfer", account_name = "X", iban = "GB00BAD" })
check("bad IBAN rejected", f == nil and err:find("IBAN"), err)
f, err = PM.clean({ kind = "bank_transfer", account_name = "X", sort_code = "1", account_number = "55779911" })
check("bad sort code rejected", f == nil and err:find("sort_code"), err)
f, err = PM.clean({ kind = "bank_transfer", account_name = "X", iban = "GB29NWBK60161331926819", currency = "pounds" })
check("bad currency rejected", f == nil and err:find("currency"), err)
f, err = PM.clean({ kind = "bitcoin" })
check("unknown kind rejected", f == nil and err:find("kind"), err)

print("clean: other kinds, flags, partial update")
f = PM.clean({ kind = "cheque", instructions = "Payable to Workstation Ltd", sort_code = "200000" })
check("cheque ok, bank fields dropped", f and f.sort_code == nil and f.label == "Cheque")
f = PM.clean({ kind = "card", is_default = true, is_active = false })
check("inactive can't be default", f and f.is_default == false and f.is_active == false)
local existing = { kind = "bank_transfer", label = "Main", account_name = "Workstation Ltd", sort_code = "20-00-00",
    account_number = "55779911", currency = "GBP", is_default = true, show_on_documents = true, is_active = true,
    sort_order = 2 }
f, err = PM.clean({ instructions = "Use the order number as the reference" }, existing)
check("partial update keeps stored fields", f and f.sort_code == "20-00-00" and f.label == "Main"
    and f.is_default == true and f.sort_order == 2, err)
check("partial update sets new field", f and f.instructions == "Use the order number as the reference")
f = PM.clean({ show_on_documents = "false" }, existing)
check("string false flag", f and f.show_on_documents == false)

print("documents: filter and order")
local rows = {
    { id = 1, kind = "card", is_active = true, show_on_documents = true, sort_order = 0 },
    { id = 2, kind = "bank_transfer", is_active = true, show_on_documents = true, is_default = true, sort_order = 5 },
    { id = 3, kind = "bank_transfer", is_active = false, show_on_documents = true },
    { id = 4, kind = "cheque", is_active = true, show_on_documents = false },
    { id = 5, kind = "other", is_active = true, show_on_documents = true, sort_order = -1 },
}
local docs = PM.forDocuments(rows)
check("inactive and hidden removed", #docs == 3, #docs)
check("default first", docs[1].id == 2)
check("then sort_order", docs[2].id == 5 and docs[3].id == 1)
local NULL = {}
local pub = PM.publicShape({ kind = "bank_transfer", label = "L", account_name = "A", sort_code = "20-00-00",
    account_number = "1", iban = "", id = 9, uuid = "secret" }, NULL)
check("public shape has no id/uuid", pub.id == nil and pub.uuid == nil)
check("public shape null for empty", pub.iban == NULL and pub.swift_bic == NULL)
check("public shape keeps bank fields", pub.sort_code == "20-00-00")

print("bank transfer allowed")
local bank = { { kind = "bank_transfer" } }
local oa = { kind = "order", status = "accepted", total_minor = 100, is_past_validity = false, unpriced = 0 }
check("authorised OA with bank account", PM.bankTransferAllowed(oa, bank) == true)
local function reason(q, m) return select(2, PM.bankTransferAllowed(q, m)) end
local function with(k, v) local c = {} for a, b in pairs(oa) do c[a] = b end c[k] = v return c end
check("quote kind refused", reason(with("kind", "quote"), bank) == "NOT_AN_ORDER_AUTHORISATION")
check("sent (not authorised) refused", reason(with("status", "sent"), bank) == "NOT_AUTHORISED")
check("converted refused", reason(with("status", "converted"), bank) == "NOT_AUTHORISED")
check("expired refused", reason(with("is_past_validity", true), bank) == "QUOTE_EXPIRED")
check("unpriced refused", reason(with("unpriced", 1), bank) == "QUOTE_PRICING_PENDING")
check("zero total refused", reason(with("total_minor", 0), bank) == "NOTHING_TO_PAY")
check("no bank account refused", reason(oa, { { kind = "card" } }) == "NO_BANK_ACCOUNT")

print("invoice lines from an order")
local order = {
    lines = {
        { product_name = "DGX Spark", label = "DGX Spark", sku = "DGX-1", qty = 2, unit_price_minor = 559900,
          line_subtotal_minor = 1119800, line_vat_minor = 223960, vat_rate = 0.2 },
        { product_name = "Setup", qty = 1, unit_price_minor = 10000, line_subtotal_minor = 10000,
          line_vat_minor = 0, vat_rate = 0 },
    },
    subtotal_minor = 1079800, vat_minor = 0, shipping_minor = 1500,
}
local items = PM.invoiceLinesFromOrder(order)
check("lines + discount + delivery", #items == 4, #items)
check("unit price in pounds", items[1].unit_price == 5599 and items[1].quantity == 2)
check("tax rate in percent", items[1].tax_rate == 20 and items[2].tax_rate == 0)
check("SKU in description", items[1].description:find("SKU DGX-1", 1, true) ~= nil, items[1].description)
check("discount negative £500", items[3].unit_price == -500, items[3].unit_price)
check("discount at effective VAT rate", math.abs(items[3].tax_rate - 19.823) < 0.01, items[3].tax_rate)
check("delivery zero-rated", items[4].description == "Delivery" and items[4].unit_price == 15 and items[4].tax_rate == 0)
local plain = PM.invoiceLinesFromOrder({ lines = { order.lines[2] }, subtotal_minor = 10000, shipping_minor = 0 })
check("no discount, no delivery lines", #plain == 1)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
