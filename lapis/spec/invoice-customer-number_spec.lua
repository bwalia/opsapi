-- luacheck: max line length 140
--[[
    Plain-Lua unit test for the customer invoice number rules in queries/InvoiceQueries.lua.

    Run from the repo root (as CI does) or from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/invoice-customer-number_spec.lua
]]

package.path = "./?.lua;./lapis/?.lua;" .. package.path

local taken = {}
package.loaded["lapis.db"] = {
    NULL = {}, raw = function(s) return s end,
    query = function(sql, ns, except_id, v)
        if sql:find("lower(customer_invoice_number) = lower(?)", 1, true) then
            local hit = taken[v:lower()]
            return (hit and hit ~= except_id) and { { ["?column?"] = 1 } } or {}
        end
        error("unexpected query: " .. sql)
    end,
}
for _, m in ipairs({ "models.InvoiceModel", "models.InvoiceLineItemModel", "models.InvoicePaymentModel",
                     "models.InvoiceSequenceModel", "models.InvoiceTaxRateModel", "helper.global", "helper.invoice-generator" }) do
    package.loaded[m] = {}
end

local I = require("queries.InvoiceQueries")
local cjson = require("cjson")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1 print("ok   - " .. name)
    else failed = failed + 1 print("FAIL - " .. name .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or "")) end
end

check("trims and collapses spaces", I.cleanCustomerNumber("  WS 2026   ACME-001 ") == "WS 2026 ACME-001")
check("blank means use the internal number", I.cleanCustomerNumber("   ") == "" and I.cleanCustomerNumber(nil) == "")
check("JSON null means use the internal number", I.cleanCustomerNumber(cjson.null) == "")
check("allows - _ / . #", I.cleanCustomerNumber("WS/2026.11#7_a-b") == "WS/2026.11#7_a-b")
local v, e = I.cleanCustomerNumber("ACME-ONE")
check("needs a digit", v == nil and e:find("digit", 1, true) ~= nil, e)
v, e = I.cleanCustomerNumber("<b>1</b>")
check("rejects markup characters", v == nil and e ~= nil)
v, e = I.cleanCustomerNumber("-123")
check("must start with a letter or number", v == nil and e ~= nil)
v, e = I.cleanCustomerNumber(string.rep("A1", 21))
check("at most 40 characters", v == nil and e:find("40", 1, true) ~= nil, e)
v, e = I.cleanCustomerNumber(123)
check("must be text", v == nil and e ~= nil)

check("customerNumber: custom wins", I.customerNumber({ invoice_number = "INV-0001", customer_invoice_number = "WS-2026-001" }) == "WS-2026-001")
check("customerNumber: falls back to internal", I.customerNumber({ invoice_number = "INV-0001" }) == "INV-0001")
check("customerNumber: blank falls back", I.customerNumber({ invoice_number = "INV-0001", customer_invoice_number = " " }) == "INV-0001")

taken["ws-2026-001"] = 7
check("taken by another invoice (case-insensitive)", I.customerNumberTaken(3, "WS-2026-001", 9) == true)
check("not taken by itself", I.customerNumberTaken(3, "ws-2026-001", 7) == false)
check("free number", I.customerNumberTaken(3, "WS-2026-002", 9) == false)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
