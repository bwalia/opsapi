--[[
    Spec: customer PO numbers, quote revisions and quote locks (lib/shop-quote-rules.lua).

    Standalone, from the repo root:
        luajit lapis/spec/shop-quote-revisions_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path
local R = require("lib.shop-quote-rules")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

print("customer PO number")
check("trimmed", R.clean_po_number("  PO-12345  ") == "PO-12345")
check("inner whitespace collapsed", R.clean_po_number("PO  12\t345") == "PO 12 345", R.clean_po_number("PO  12\t345"))
check("control characters removed", R.clean_po_number("PO\n123\r") == "PO 123", R.clean_po_number("PO\n123\r"))
check("number accepted", R.clean_po_number(45001234) == "45001234")
local none, nerr = R.clean_po_number("   ")
check("blank = none, no error", none == nil and nerr == nil)
check("nil = none", R.clean_po_number(nil) == nil)
check("64 characters allowed", R.clean_po_number(string.rep("A", 64)) == string.rep("A", 64))
local long, lerr = R.clean_po_number(string.rep("A", 65))
check("65 characters refused", long == nil and lerr ~= nil, lerr)
check("65 after trimming is fine if ≤ 64", R.clean_po_number("  " .. string.rep("B", 64) .. "  ") == string.rep("B", 64))
local tbl, terr = R.clean_po_number({ "x" })
check("a table is refused", tbl == nil and terr ~= nil)

print("revision numbering")
check("root of an original", R.root_number("WSQ-2026-00012") == "WSQ-2026-00012")
check("root of a revision", R.root_number("WSQ-2026-00012-R3") == "WSQ-2026-00012")
check("first revision", R.revision_number("WSQ-2026-00012", 1) == "WSQ-2026-00012-R1")
check("revision of a revision uses the root", R.revision_number("WSQ-2026-00012-R1", 2) == "WSQ-2026-00012-R2")
check("next after the original", R.next_revision_no({ 0 }) == 1)
check("next after R1, R2", R.next_revision_no({ 0, 1, 2 }) == 3)
check("gaps: highest + 1", R.next_revision_no({ 0, 4, 2 }) == 5)
check("strings from the database", R.next_revision_no({ "0", "1" }) == 2)
check("empty chain", R.next_revision_no({}) == 1)
check("fits shop_quotes.quote_number varchar(32)", #R.revision_number("WSQ-2026-00012", 99) <= 32)

print("can revise")
check("draft", R.can_revise({ status = "draft" }) == true)
check("sent", R.can_revise({ status = "sent" }) == true)
check("expired", R.can_revise({ status = "expired" }) == true)
check("accepted without an order", R.can_revise({ status = "accepted", authorised_at = "2026-11-13" }) == true)
local ok1, c1 = R.can_revise({ status = "accepted", order_id = 7 })
check("accepted with an order (bank transfer) refused", ok1 == false and c1 == "QUOTE_HAS_ORDER", c1)
local ok2, c2 = R.can_revise({ status = "converted" })
check("converted refused", ok2 == false and c2 == "QUOTE_HAS_ORDER", c2)
local ok3, c3 = R.can_revise({ status = "cancelled" })
check("cancelled refused", ok3 == false and c3 == "QUOTE_CANCELLED", c3)
local ok4, c4 = R.can_revise({ status = "cancelled", superseded_by_id = 9 })
check("superseded refused", ok4 == false and c4 == "QUOTE_SUPERSEDED", c4)

print("staff edits and the customer lock")
check("draft editable", R.can_edit_content({ status = "draft" }) == true)
check("accepted, no order: editable", R.can_edit_content({ status = "accepted" }) == true)
check("order: not editable", R.can_edit_content({ status = "accepted", order_uuid = "u" }) == false)
check("superseded: not editable", R.can_edit_content({ status = "cancelled", superseded_by_id = 2 }) == false)
check("PO number editable on a sent quote", R.can_edit_po_number({ status = "sent" }) == true)
check("PO number not on a quote with an order", R.can_edit_po_number({ status = "accepted", order_id = 1 }) == false)
check("PO number not on a cancelled quote", R.can_edit_po_number({ status = "cancelled" }) == false)
check("sent: open to the customer", R.locked_for_customer({ status = "sent" }) == false)
check("draft: open to the customer", R.locked_for_customer({ status = "draft" }) == false)
check("accepted: locked", R.locked_for_customer({ status = "accepted" }) == true)
check("has an order: locked", R.locked_for_customer({ status = "sent", order_id = 3 }) == true)
check("converted: locked", R.locked_for_customer({ status = "converted" }) == true)
check("superseded: locked", R.locked_for_customer({ status = "cancelled", superseded_by_id = 4 }) == true)

print("order fields and supplier PO notes")
check("PO carried to the order", R.order_fields({ customer_po_number = " PO-9 " }).customer_po_number == "PO-9")
check("no PO: nil", R.order_fields({}).customer_po_number == nil)
local notes = R.supplier_po_notes({ customer_po_number = "PO-9", account_number = "WS001", delivery_method = "Courier",
    supplier_notes = "Email orders to sales@", notes = "" })
check("end customer PO first", notes:sub(1, 20) == "End customer PO: PO-", notes)
check("our account number", notes:find("Our account number: WS001", 1, true) ~= nil)
check("delivery method", notes:find("Delivery method: Courier", 1, true) ~= nil)
check("supplier's PO notes", notes:find("Email orders to sales@", 1, true) ~= nil)
check("no PO line without a PO", not R.supplier_po_notes({ delivery_method = "x" }):find("End customer", 1, true))
check("nothing = empty", R.supplier_po_notes({}) == "")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
