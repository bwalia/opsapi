-- luacheck: max line length 160
--[[
    Spec: supplier portal rules (lib/supplier-portal.lua) and its wiring.

    Standalone (no busted). From the repo root:
        luajit lapis/spec/supplier-portal_spec.lua
    or from lapis/ in the OpenResty image:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine sh -c \
          'LUA_PATH="/usr/local/openresty/lualib/?.lua;;" luajit spec/supplier-portal_spec.lua'
    The database paths (supplier A vs B on every id-taking route, downloads, uploads to MinIO, the whole PO-to-close
    flow, nothing in the mail catcher) are driven for real by spec/supplier-portal-e2e/run.sh.

    Covers: stage transitions (valid / invalid, staff vs supplier), the effective stage, payment balance maths,
    closing rules, what staff and suppliers type (proforma, payment, dispatch, delivery), upload checks (type by
    content, 20 MB, scripts in PDFs, file names), what a supplier sees of a PO (no customer, drop-ship rules), the
    supplier's history, who may be emailed (never when off, never a customer), signed download links, and that the
    routes / guard / migrations / login are wired the way the rules assume.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, INFO = 7, NOTICE = 6, ctx = {}, var = {} } -- luacheck: ignore 111

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end

package.loaded["lapis.db"] = setmetatable({ NULL = {} }, {
    __index = function() return function() error("database must not be used by pure rules") end end,
})

local R = require("lib.supplier-portal")

-- ---------------------------------------------------------------------------
print("Stages:")
check("staff: draft -> sent", R.canTransition("draft", "sent", "staff"))
check("supplier acknowledges a sent PO", R.canTransition("sent", "acknowledged", "supplier"))
check("supplier: acknowledged -> proforma_received", R.canTransition("acknowledged", "proforma_received", "supplier"))
check("supplier: paid -> dispatched", R.canTransition("paid", "dispatched", "supplier"))
check("supplier: dispatched -> delivered", R.canTransition("dispatched", "delivered", "supplier"))
check("supplier: delivered -> invoiced", R.canTransition("delivered", "invoiced", "supplier"))
check("staff: invoiced -> closed", R.canTransition("invoiced", "closed", "staff"))
check("supplier can't close", not R.canTransition("invoiced", "closed", "supplier"))
check("supplier can't cancel", not R.canTransition("sent", "cancelled", "supplier"))
check("supplier can't send a draft", not R.canTransition("draft", "sent", "supplier"))
check("nobody marks paid by hand", not R.canTransition("proforma_received", "paid", "staff")
    and not R.canTransition("proforma_received", "part_paid", "supplier"))
check("can't skip dispatch", not R.canTransition("paid", "delivered", "staff"))
check("can't go back", not R.canTransition("delivered", "dispatched", "staff") and not R.canTransition("closed", "invoiced", "staff"))
check("closed and cancelled are final", next(R.TRANSITIONS.closed) == nil and next(R.TRANSITIONS.cancelled) == nil)
check("can't cancel once dispatched", not R.canTransition("dispatched", "cancelled", "staff"))
check("unknown actor can't move", not R.canTransition("sent", "acknowledged", "customer"))
check("unknown stage", not R.canTransition("nope", "sent", "staff") and not R.isStage("paid_twice"))
local all_known = true
for from, tos in pairs(R.TRANSITIONS) do
    for to in pairs(tos) do if not R.TRANSITIONS[to] then all_known = false end end
    if not R.LABELS[from] then all_known = false end
end
check("every stage has a label and every target is a stage", all_known)

print("Effective stage (portal stage vs the PO's goods/bill status):")
check("no portal stage: from the status", R.effectiveStage({ status = "sent" }) == "sent")
check("portal ahead of status", R.effectiveStage({ status = "acknowledged", portal_stage = "paid" }) == "paid")
check("status ahead (goods received on the PO page)", R.effectiveStage({ status = "received", portal_stage = "paid" }) == "delivered")
check("billed = invoiced", R.effectiveStage({ status = "billed" }) == "invoiced")
check("cancelled wins", R.effectiveStage({ status = "cancelled", portal_stage = "paid" }) == "cancelled"
    and R.effectiveStage({ status = "acknowledged", portal_stage = "cancelled" }) == "cancelled")
check("closed stays closed", R.effectiveStage({ status = "billed", portal_stage = "closed" }) == "closed")

print("Stage after payments:")
check("full payment before dispatch -> paid", R.stageAfterPayment("proforma_received", "paid", true) == "paid")
check("part payment -> part_paid", R.stageAfterPayment("proforma_received", "part_paid", true) == "part_paid")
check("then the rest -> paid", R.stageAfterPayment("part_paid", "paid", true) == "paid")
check("overpaid counts as paid", R.stageAfterPayment("acknowledged", "overpaid", false) == "paid")
check("payment voided -> back to proforma received", R.stageAfterPayment("paid", "unpaid", true) == "proforma_received")
check("voided, no proforma -> acknowledged", R.stageAfterPayment("part_paid", "unpaid", false) == "acknowledged")
check("after dispatch the stage follows the goods", R.stageAfterPayment("dispatched", "paid", true) == "dispatched"
    and R.stageAfterPayment("invoiced", "part_paid", true) == "invoiced")
check("never touches sent / closed", R.stageAfterPayment("sent", "paid", false) == "sent"
    and R.stageAfterPayment("closed", "unpaid", true) == "closed")

-- ---------------------------------------------------------------------------
print("Money:")
check("pennies of text", R.pennies("5256.65") == 525665 and R.pennies("1051.33") == 105133)
check("pennies of numbers", R.pennies(6307.98) == 630798 and R.pennies(0.1 + 0.2) == 30)
check("thousands separators and £", R.pennies("£6,307.98") == 630798)
check("whole and one-decimal", R.pennies("10") == 1000 and R.pennies("10.5") == 1050 and R.pennies(".5") == 50)
check("refuses 3 decimals, negatives, junk", R.pennies("1.005") == nil and R.pennies("-1") == nil
    and R.pennies("1e5") == nil and R.pennies("12,34") == nil and R.pennies({}) == nil and R.pennies(0 / 0) == nil)
check("money", R.money(630798) == "6307.98" and R.money(5) == "0.05" and R.money(-1250) == "-12.50")
check("net + VAT = total, exactly", R.pennies("5256.65") + R.pennies("1051.33") == R.pennies("6307.98"))

print("Balance:")
local b = R.balance("6307.98", {}, {})
check("PO total due, nothing paid", b.due == 630798 and b.paid == 0 and b.state == "unpaid" and b.basis == "purchase_order")
b = R.balance("6307.98", { { kind = "proforma", total = "6307.98" } }, { { amount = "6307.98" } })
check("Boston example: proforma paid in full", b.state == "paid" and b.balance == 0 and b.basis == "proforma"
    and b.balance_text == "0.00")
b = R.balance("6307.98", { { kind = "proforma", total = "6307.98" } }, { { amount = "3000.00" }, { amount = "1307.98" } })
check("part payments add up", b.state == "part_paid" and b.paid == 430798 and b.balance_text == "2000.00")
b = R.balance("6307.98", { { kind = "proforma", total = "6000.00" }, { kind = "proforma", total = "6307.98" } }, {})
check("the latest proforma counts", b.due == 630798)
b = R.balance("6307.98", { { kind = "proforma", total = "6307.98" }, { kind = "invoice", total = "6300.00" } },
    { { amount = "6307.98" } })
check("the final invoice replaces the proforma -> overpaid", b.basis == "invoice" and b.state == "overpaid"
    and b.balance_text == "-7.98")
b = R.balance("100.00", { { kind = "invoice", total = "60.00" }, { kind = "invoice", total = "40.00" },
    { kind = "credit_note", total = "10.00" } }, { { amount = "90.00" } })
check("several invoices less a credit note", b.due == 9000 and b.state == "paid")
b = R.balance("0", {}, {})
check("nothing due", b.state == "nothing_due")

print("Closing:")
local paid = R.balance("10", { { kind = "invoice", total = "10" } }, { { amount = "10" } })
check("delivered + final invoice + paid -> can close", R.canClose("invoiced", paid, true) == true)
local ok, msg = R.canClose("dispatched", paid, true)
check("not delivered yet -> no", not ok and msg:find("delivered", 1, true) ~= nil)
local owing = R.balance("10", { { kind = "invoice", total = "10" } }, { { amount = "4" } })
ok, msg = R.canClose("invoiced", owing, true)
check("money still owed -> no, says how much", not ok and msg:find("6.00", 1, true) ~= nil)
ok, msg = R.canClose("delivered", paid, false)
check("no final invoice -> no", not ok and msg:find("final VAT invoice", 1, true) ~= nil)
check("forced with a reason -> yes", R.canClose("delivered", owing, false, true, "Written off: agreed with supplier") == true)
check("forced without a reason -> no", not R.canClose("delivered", owing, false, true, "  "))

-- ---------------------------------------------------------------------------
print("Proforma / invoice fields:")
local inv, e = R.invoiceFields({ kind = "proforma", number = "PRF-BUK012611-012", invoice_date = "2026-11-17",
    supplier_order_ref = "SO-BUK012611-063", net = "5256.65", vat = "1051.33", total = "6307.98",
    payment_terms = "100% pre-payment", incoterm = "ddp" }, "GBP")
check("the example proforma", inv and inv.number == "PRF-BUK012611-012" and inv.total == "6307.98" and inv.net == "5256.65"
    and inv.incoterm == "DDP" and inv.currency == "GBP", e)
check("number required", select(2, R.invoiceFields({ kind = "proforma", invoice_date = "2026-11-17", total = "1" })) ~= nil)
check("real date required", R.invoiceFields({ kind = "invoice", number = "1", invoice_date = "2026-02-30", total = "1" }) == nil
    and R.invoiceFields({ kind = "invoice", number = "1", invoice_date = "17/11/2026", total = "1" }) == nil)
check("kind must be known", R.invoiceFields({ kind = "receipt", number = "1", invoice_date = "2026-11-17", total = "1" }) == nil)
local derived = R.invoiceFields({ kind = "invoice", number = "1", invoice_date = "2026-11-17", total = "120", vat = "20" })
check("net worked out from total - VAT", derived and derived.net == "100.00")
check("VAT over the total refused", R.invoiceFields({ kind = "invoice", number = "1", invoice_date = "2026-11-17", total = "10",
    vat = "20" }) == nil)

local po = { subtotal = "5256.65", tax_total = "1051.33", total = "6307.98", currency = "GBP" }
local flags = R.invoiceFlags(inv, po, {})
check("matching proforma: no flags", #flags == 0, #flags > 0 and flags[1].code or nil)
local function has(fl, code) for _, f in ipairs(fl) do if f.code == code then return true end end return false end
local off = R.invoiceFields({ kind = "proforma", number = "X", invoice_date = "2026-11-17", net = "5300.00", vat = "1060.00",
    total = "6360.00" }, "GBP")
flags = R.invoiceFlags(off, po, { sale_net = 520000 })
check("flags a total that differs from the PO", has(flags, "total_differs") and has(flags, "net_differs") and has(flags, "vat_differs"))
check("flags a cost above our sale price (below cost)", has(flags, "cost_above_sale"))
local bad_sum = { kind = "invoice", net = "100.00", vat = "20.00", total = "125.00", currency = "EUR" }
flags = R.invoiceFlags(bad_sum, { total = "125.00", currency = "GBP" })
check("flags net + VAT not adding up, and another currency", has(flags, "does_not_add_up") and has(flags, "currency_differs"))
flags = R.invoiceFlags({ kind = "proforma", net = "1", vat = "0", total = "1", bank_details = "Sort 20-00-00 Acc 12345678" }, nil,
    { previous_bank_details = "Sort 40-11-22 Acc 87654321" })
check("flags changed bank details", has(flags, "bank_details_changed"))
flags = R.invoiceFlags({ kind = "proforma", net = "1", vat = "0", total = "1", bank_details = "sort 200000 acc 12345678" }, nil,
    { previous_bank_details = "Sort 20-00-00  Acc 12345678" })
check("same bank details written differently: no flag", not has(flags, "bank_details_changed"))
check("credit notes aren't compared with the PO total", not has(R.invoiceFlags({ kind = "credit_note", net = "10", vat = "2",
    total = "12", currency = "GBP" }, po), "total_differs"))

print("Payment fields:")
local pay, perr = R.paymentFields({ amount = "6307.98", method = "faster_payment", sent_on = "2026-11-17", cleared_on = "2026-11-17",
    bank_transaction_id = "FP-TEST-0001", payment_reference = "PRF-BUK012611-012" }, "GBP")
check("the example payment", pay and pay.amount == "6307.98" and pay.method == "faster_payment" and pay.cleared_on == "2026-11-17", perr)
check("amount > 0", R.paymentFields({ amount = "0", sent_on = "2026-11-17" }, "GBP") == nil)
check("method must be known", R.paymentFields({ amount = "1", method = "crypto", sent_on = "2026-11-17" }, "GBP") == nil)
check("cleared before sent refused", R.paymentFields({ amount = "1", sent_on = "2026-11-17", cleared_on = "2026-11-16" }, "GBP") == nil)
check("other currency refused", R.paymentFields({ amount = "1", sent_on = "2026-11-17", currency = "EUR" }, "GBP") == nil)
check("sent date required", R.paymentFields({ amount = "1" }, "GBP") == nil)

print("Dispatch / delivery / messages / invites:")
local sh = R.shipmentFields({ carrier = "DPD", tracking_number = "1550 1234 5678", tracking_url = "https://track.dpd.co.uk/x?p=1",
    expected_on = "2026-11-20" }, "2026-11-18")
check("dispatch with defaults", sh and sh.dispatched_on == "2026-11-18" and sh.expected_on == "2026-11-20")
check("carrier required", R.shipmentFields({}, "2026-11-18") == nil)
check("tracking link must be https", R.shipmentFields({ carrier = "DPD", tracking_url = "javascript:alert(1)" }, "2026-11-18") == nil
    and R.shipmentFields({ carrier = "DPD", tracking_url = "http://x.example" }, "2026-11-18") == nil)
check("expected before dispatch refused", R.shipmentFields({ carrier = "DPD", dispatched_on = "2026-11-18",
    expected_on = "2026-11-17" }, "2026-11-18") == nil)
check("delivered in the future refused", R.deliveryFields({ delivered_on = "2026-12-01" }, "2026-11-20") == nil)
check("delivered defaults to today", (R.deliveryFields({}, "2026-11-20") or {}).delivered_on == "2026-11-20")
check("message required and capped", R.messageBody("  ") == nil and R.messageBody(("x"):rep(4001)) == nil
    and R.messageBody(" Hello ") == "Hello")
check("invite needs an email", R.inviteFields({ email = "not-an-email" }) == nil
    and (R.inviteFields({ email = "Ops+Supplier@Example.co.uk", name = "Test Contact" }) or {}).email == "ops+supplier@example.co.uk")

-- ---------------------------------------------------------------------------
print("Uploads:")
local PDF = "%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer\n%%EOF\n"
local PNG = "\137PNG\r\n\26\n" .. ("x"):rep(20)
local JPG = "\255\216\255\224" .. ("x"):rep(20)
local f = R.checkFile({ filename = "Proforma PRF-012.pdf", content = PDF, content_type = "application/pdf" })
check("PDF accepted", f and f.content_type == "application/pdf" and f.filename == "Proforma PRF-012.pdf")
check("PNG and JPG accepted", (R.checkFile({ filename = "pod.png", content = PNG }) or {}).ext == "png"
    and (R.checkFile({ filename = "pod.jpeg", content = JPG, content_type = "image/jpeg" }) or {}).ext == "jpg")
check("type comes from the bytes, not the name", select(2, R.checkFile({ filename = "invoice.pdf", content = "MZ\144\0evil" }))
    == "Only PDF, PNG or JPG files can be uploaded")
check("GIF / HTML / zip refused", R.checkFile({ filename = "a.gif", content = "GIF89a....." }) == nil
    and R.checkFile({ filename = "a.html", content = "<html><script>" }) == nil
    and R.checkFile({ filename = "a.zip", content = "PK\3\4...." }) == nil)
check("declared type must match", R.checkFile({ filename = "x.pdf", content = PNG, content_type = "application/pdf" }) == nil)
check("extension must match", R.checkFile({ filename = "x.png", content = PDF }) == nil)
check("octet-stream is fine (we sniff)", R.checkFile({ filename = "x", content = PDF, content_type = "application/octet-stream" }) ~= nil)
check("other declared types refused", R.checkFile({ filename = "x.pdf", content = PDF, content_type = "text/html" }) == nil)
check("empty refused", select(2, R.checkFile({ filename = "x.pdf", content = "" })) == "The file is empty")
local big = R.checkFile({ filename = "x.pdf", content = "%PDF-" .. ("0"):rep(R.MAX_FILE_BYTES) })
check("over 20 MB refused", big == nil)
check("exactly 20 MB accepted", R.checkFile({ filename = "x.pdf", content = "%PDF-" .. ("0"):rep(R.MAX_FILE_BYTES - 5) }) ~= nil)
check("PDF with JavaScript refused", R.checkFile({ filename = "x.pdf", content = PDF .. "/OpenAction << /S /JavaScript /JS (app.alert(1)) >>" }) == nil)
check("PDF with /Launch refused", R.checkFile({ filename = "x.pdf", content = PDF .. "<< /S /Launch /F (cmd.exe) >>" }) == nil)
check("no file", R.checkFile(nil) == nil and R.checkFile({ filename = "x" }) == nil)
check("file names: folders dropped", R.safeFilename("../../etc/passwd.pdf", "pdf") == "passwd.pdf"
    and R.safeFilename("C:\\Users\\me\\proforma.pdf", "pdf") == "proforma.pdf")
check("file names: odd characters replaced", R.safeFilename("in<voice>\"; rm -rf.pdf", "pdf") == "in_voice_ rm -rf.pdf")
check("file names: control characters and header injection", not R.safeFilename("a\r\nContent-Type: x.pdf", "pdf"):find("[\r\n]"))
check("file names: extension follows the real type", R.safeFilename("photo.pdf", "png") == "photo.png")
check("file names: capped and never empty", #R.safeFilename(("a"):rep(500) .. ".pdf", "pdf") == 104
    and R.safeFilename("...", "jpg") == "document.jpg" and R.safeFilename(nil, "pdf") == "document.pdf")
check("who may upload what", R.mayUpload("proforma", "supplier") and not R.mayUpload("payment_proof", "supplier")
    and not R.mayUpload("purchase_order", "supplier") and R.mayUpload("payment_proof", "staff") and not R.mayUpload("virus", "staff")
    and not R.mayUpload("proforma", "customer"))

-- ---------------------------------------------------------------------------
print("What a supplier sees of a PO:")
local Codes = require("lib.deal-codes")
local markers = Codes.markers({ name = "Jane Buyer", email = "jane@e2e-buyer.co.uk", company = "Buyer Analytics Ltd",
    phone = "07700 900123" }, { "WSQ-000123" })
local base_po = {
    uuid = "po-1", po_number = "PO-000001", status = "sent", issue_date = "2026-11-17", currency = "GBP",
    subtotal = "5256.65", tax_total = "1051.33", total = "6307.98", reference = "WS-DT5Z-994X",
    notes = "Deal code: WS-DT5Z-994X (please quote it on your delivery note and invoice)", created_by_uuid = "staff-1",
    supplier_email = "orders@supplier.example", delivery_address = "Workstation Ltd, 1 Our Street, London",
    metadata = { deal_code = "WS-DT5Z-994X", shop_order_uuid = "order-uuid-777", shop_order_number = "WS-ORD-77",
                 shop_supplier_uuid = "sup-A", drop_ship = false, bill_to = { company = "Workstation Ltd", line1 = "1 Our Street" },
                 deliver_to = { company = "Workstation Ltd" }, receipts = { { x = 1 } }, bills = { { y = 2 } } },
    items = { { description = "NVIDIA DGX Spark", quantity = "1", unit_price = "5256.65", tax_rate = "20", tax_amount = "1051.33",
                line_total = "6307.98", received_quantity = "0", billed_quantity = "0" } },
}
local function encode(t)
    local parts = {}
    local function walk(x)
        if type(x) == "table" then for k, y in pairs(x) do walk(k); walk(y) end
        elseif x ~= nil then parts[#parts + 1] = tostring(x) end
    end
    walk(t)
    return table.concat(parts, " | ")
end
local view = R.supplierPo(base_po, { company_name = "Workstation", markers = markers })
local blob = encode(view)
check("shows the deal code and the spec", view.deal_code == "WS-DT5Z-994X" and view.items[1].description == "NVIDIA DGX Spark")
check("delivers to us: our address shown", view.delivery_address == "Workstation Ltd, 1 Our Street, London" and view.drop_ship == false)
check("no customer name / email / phone / company / WSQ", #Codes.leaks(view, markers) == 0, blob)
check("no staff-only fields", view.created_by_uuid == nil and view.metadata == nil and not blob:find("WS-ORD-77", 1, true)
    and not blob:find("order-uuid-777", 1, true) and view.items[1].received_quantity == nil and not blob:find("staff-1", 1, true))
check("no end-customer PO unless confirmed", view.end_customer_po == nil)

local leaky = {}
for k, x in pairs(base_po) do leaky[k] = x end
leaky.notes = "Deliver to Jane Buyer, call 07700 900 123"
leaky.items = { { description = "Laptop for Buyer Analytics Ltd", quantity = "1" } }
view = R.supplierPo(leaky, { markers = markers })
check("anything naming the customer is hidden", view.notes == R.HIDDEN and view.items[1].description == R.HIDDEN and view.redacted == true
    and #Codes.leaks(view, markers) == 0)

local legacy = {}
for k, x in pairs(base_po) do legacy[k] = x end
legacy.metadata = { deal_code = "WS-AAAA-BBBB", shop_order_uuid = "o-2", drop_ship = true, shop_supplier_uuid = "sup-A" }
legacy.delivery_address = "Jane Buyer, Buyer Analytics Ltd, 9 Customer Road, Leeds"
check("legacy drop-ship recognised", select(2, R.dropShipVisible(legacy)) == "legacy")
view = R.supplierPo(legacy, { markers = markers })
check("legacy drop-ship: the customer's delivery address is shown (the supplier has that PO)",
    view.delivery_address == legacy.delivery_address and view.drop_ship == true and view.drop_ship_kind == "legacy")
local legacy_nil = { delivery_address = "Somewhere", metadata = { shop_order_uuid = "o-3" } }
check("old shop PO without the drop_ship key but with an address = legacy", select(2, R.dropShipVisible(legacy_nil)) == "legacy")

local confirmed = {}
for k, x in pairs(base_po) do confirmed[k] = x end
confirmed.metadata = { deal_code = "WS-CCCC-DDDD", shop_order_uuid = "o-4", drop_ship = true, drop_ship_confirmed = true,
                       end_customer_po = "CUST-PO-9" }
confirmed.delivery_address = "Jane Buyer, 9 Customer Road, Leeds"
view = R.supplierPo(confirmed, { markers = markers })
check("confirmed drop-ship: address and end-customer PO shown", view.delivery_address == confirmed.delivery_address
    and view.end_customer_po == "CUST-PO-9" and view.drop_ship_kind == "confirmed")

local unconfirmed = { delivery_address = "Jane Buyer, Leeds", metadata = { shop_order_uuid = "o-5", drop_ship = false } }
check("shop PO to us is not a drop-ship", R.dropShipVisible(unconfirmed) == false)
local to_us_customer = {}
for k, x in pairs(base_po) do to_us_customer[k] = x end
to_us_customer.delivery_address = "Jane Buyer, 9 Customer Road, Leeds"
view = R.supplierPo(to_us_customer, { markers = markers })
check("not a drop-ship but the address names the customer: hidden", view.delivery_address == R.HIDDEN)
local manual = { uuid = "m", po_number = "PO-9", status = "sent", delivery_address = "Site office, 2 Builder Lane", metadata = {} }
check("PO raised by hand: its delivery address is shown", R.supplierPo(manual, {}).delivery_address == "Site office, 2 Builder Lane")

print("Supplier history:")
local tl = R.supplierTimeline({
    { action = "po.stage_changed", detail = { from = "sent", to = "acknowledged" }, at = "1", actor_kind = "supplier", actor_name = "Sam (Supplier)" },
    { action = "payment.recorded", detail = { amount = "6307.98", currency = "GBP", note = "internal note", bank_transaction_id = "TX1",
      by_name = "Jo Staff" }, at = "2", actor_kind = "staff", actor_name = "Jo Staff" },
    { action = "po.viewed", detail = {}, at = "3", actor_kind = "supplier" },
    { action = "document.removed", detail = { reason = "wrong file" }, at = "4", actor_kind = "staff", actor_name = "Jo Staff" },
    { action = "notification.suppressed", detail = { event = "payment_recorded" }, at = "5" },
}, "Workstation")
check("only what the supplier should see", #tl == 2)
check("our staff shown as the company", tl[2].by == "Workstation" and not encode(tl):find("Jo Staff", 1, true))
check("supplier contact shown by name", tl[1].by == "Sam (Supplier)")
check("no internal notes or our bank transaction id", tl[2].detail.note == nil and tl[2].detail.bank_transaction_id == nil
    and tl[2].detail.amount == "6307.98")

-- ---------------------------------------------------------------------------
print("Who may be emailed:")
local allowed = { ["sam@supplier.example"] = true, ["jane@e2e-buyer.co.uk"] = true }
local customers = { ["jane@e2e-buyer.co.uk"] = true }
local to, why = R.safeRecipients(false, { "sam@supplier.example" }, allowed, customers)
check("supplier emails off (the default): nobody", #to == 0 and why == "disabled")
to = R.safeRecipients(nil, { "sam@supplier.example" }, allowed, customers)
check("unset counts as off", #to == 0)
to = R.safeRecipients(true, { "Sam@Supplier.example", "sam@supplier.example", "jane@e2e-buyer.co.uk", "boss@other.example" },
    allowed, customers)
check("on: only the supplier's own portal users, once each, never a customer", #to == 1 and to[1] == "sam@supplier.example")
to, why = R.safeRecipients(true, { "jane@e2e-buyer.co.uk" }, allowed, customers)
check("a customer who is somehow a portal user is still never emailed", #to == 0 and why == "no_recipients")

print("Download links:")
local function fake_hmac(key, m) -- stand-in for HMAC-SHA256 (the real one is resty.openssl.hmac, driven by the e2e)
    local h = 0
    local s = key .. "\0" .. m
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h) .. key:sub(1, 4)
end
local tok = R.signToken("doc-uuid-1", "user-uuid-1", 1000, 120, "k1", fake_hmac)
local t = R.verifyToken(tok, 1100, "k1", fake_hmac)
check("valid within 2 minutes", t and t.doc_uuid == "doc-uuid-1" and t.user_uuid == "user-uuid-1" and t.exp == 1120)
check("expired after", select(2, R.verifyToken(tok, 1121, "k1", fake_hmac)) == "expired")
check("another key refused", select(2, R.verifyToken(tok, 1100, "k2", fake_hmac)) == "invalid")
local p64 = tok:match("^([^.]+)")
local forged = R.b64url("v1|doc-uuid-2|user-uuid-1|9999999999") .. "." .. tok:match("%.(.+)$")
check("changed document / expiry refused", select(2, R.verifyToken(forged, 1100, "k1", fake_hmac)) == "invalid")
check("garbage refused", R.verifyToken("x", 1, "k1", fake_hmac) == nil and R.verifyToken(p64, 1, "k1", fake_hmac) == nil
    and R.verifyToken(nil, 1, "k1", fake_hmac) == nil and R.verifyToken(("a"):rep(700) .. ".b", 1, "k1", fake_hmac) == nil)
local rt = true
for _, s in ipairs({ "", "a", "ab", "abc", "abcd", "v1|x|y|123", "\0\255\128binary" }) do
    if R.unb64url(R.b64url(s)) ~= s then rt = false end
end
check("base64url round trip", rt and not R.b64url("\255\255\255"):find("[+/=]"))

-- ---------------------------------------------------------------------------
print("Wiring:")
local routes = read("lapis/routes/supplier-portal.lua")
local queries = read("lapis/queries/SupplierPortalQueries.lua")
local app = read("lapis/app.lua")
local migrations = read("lapis/migrations.lua")
local auth = read("lapis/routes/auth.lua")
local guard_src = read("lapis/helper/supplier-portal-guard.lua")
local notify = read("lapis/lib/supplier-portal-notify.lua")

local sp_routes, staff_routes, bad = 0, 0, {}
for line in routes:gmatch("[^\n]+") do
    local path, wrap = line:match('app:%a+%((%u+ %.%. "[^"]*"),%s*(%a+)%(')
    if not path then path, wrap = line:match('app:%a+%((%u+),%s*(%a+)%(') end
    if path then
        if path:match("^SP") then
            sp_routes = sp_routes + 1
            if wrap ~= "supplier" then bad[#bad + 1] = path end
        elseif path:match("^PO") or path:match("^SUP") then
            staff_routes = staff_routes + 1
            if wrap ~= "staff" then bad[#bad + 1] = path end
        end
    end
end
check("every supplier route resolves the supplier (and is rate limited)", sp_routes >= 11 and #bad == 0, table.concat(bad, ", "))
check("every staff route checks RBAC and refuses supplier logins", staff_routes >= 18 and #bad == 0)
check("staff wrapper refuses supplier logins", routes:find("Guard.isSupplier(self.current_user", 1, true) ~= nil)
check("supplier wrapper is rate limited", routes:find("RateLimit.wrap(limit", 1, true) ~= nil)
check("the download is public only through its signed token",
    routes:find('app:get("/api/v2/public/supplier-portal/files/:token", RateLimit.wrap(DOWNLOAD_LIMIT', 1, true) ~= nil
    and queries:find("Files.verifyLink(token)", 1, true) ~= nil)
check("app.lua loads the routes with the shop feature", app:find('load_if("shop", "routes.supplier-portal")', 1, true) ~= nil)
check("app.lua runs the guard on every authenticated request", app:find('require("helper.supplier-portal-guard").check', 1, true) ~= nil)
check("login always asks a supplier login for a sign-in code",
    auth:find('require("helper.supplier-portal-guard").isSupplier(userWithRoles.uuid)', 1, true) ~= nil)
check("migrations zzs60/zzs61, gated by SHOP", migrations:find("['zzs60_supplier_portal_tables'] = conditional_array(ProjectConfig.FEATURES.SHOP", 1, true)
    and migrations:find("['zzs61_supplier_portal_settings'] = conditional_array(ProjectConfig.FEATURES.SHOP", 1, true)
    and migrations:find('load_if_enabled(ProjectConfig.FEATURES.SHOP, "migrations.supplier-portal")', 1, true))
local mig = read("lapis/migrations/supplier-portal.lua")
local _, creates = mig:gsub("CREATE ", "")
local _, guarded = mig:gsub("CREATE [%u ]-IF NOT EXISTS", "")
local idempotent = creates > 0 and creates == guarded
check("migration is idempotent (IF NOT EXISTS everywhere)", idempotent and not mig:find("DROP ", 1, true)
    and mig:find("supplier_portal_enabled BOOLEAN NOT NULL DEFAULT false", 1, true)
    and mig:find("supplier_portal_emails_enabled BOOLEAN NOT NULL DEFAULT false", 1, true))

-- Every SQL statement on the PO tables is scoped to the workspace.
local unscoped = {}
local body_src = queries:gsub("^%-%-.-%]%]", "", 1) -- the header comment
for sql in body_src:gmatch("%[%[(.-)%]%]") do
    local touches = sql:find("purchase_order") or sql:find("supplier_portal_users")
    -- user-level lookups (who is this login?) are by the user, not the workspace
    local user_lookup = sql:find("WHERE u.uuid = ?", 1, true) or sql:find("WHERE spu.user_id = ?", 1, true)
        or sql:find("^%s*SELECT 1 AS x FROM supplier_portal_users WHERE user_id")
    if touches and not user_lookup and not sql:find("namespace_id") and not sql:find("information_schema") then
        unscoped[#unscoped + 1] = (sql:gsub("%s+", " ")):sub(1, 90)
    end
end
check("every query on the PO tables filters namespace_id", #unscoped == 0, table.concat(unscoped, " || "))
check("supplier queries always filter by their supplier", select(2, queries:gsub("metadata%->>'shop_supplier_uuid' = %?", "")) >= 6)
check("supplier PO loads exclude drafts", queries:find("AND metadata->>'shop_supplier_uuid' = ? AND status <> 'draft'", 1, true) ~= nil)
check("supplier never gets mismatch flags, bank transaction id or notes",
    queries:find("if not for_supplier then\n        out.note", 1, true) ~= nil
    and queries:find("if not for_supplier then\n        out.bank_transaction_id", 1, true) ~= nil)
check("supplier emails only through safeRecipients, gated by the setting",
    notify:find("Rules.safeRecipients(enabled, candidates, allowed", 1, true) ~= nil
    and notify:find("supplier_portal_emails_enabled", 1, true) ~= nil and select(2, notify:gsub("Mail%.send%(", "")) == 1)
check("staff alerts are in-app only (no email)", not notify:match("function N%.toStaff.-Mail%.send.-\nend"))

local saved = package.loaded["lapis.db"]
package.loaded["lapis.db"] = { query = function() return {} end }
package.loaded["resty.lrucache"] = { new = function() local c = {} return { get = function(_, k) return c[k] end,
    set = function(_, k, x) c[k] = x end } end }
local G = require("helper.supplier-portal-guard")
check("guard lets a supplier reach the portal and its own session only",
    G.allowed("/api/v2/supplier-portal/purchase-orders") and G.allowed("/auth/me") and G.allowed("/auth/logout")
    and not G.allowed("/api/v2/purchase-orders") and not G.allowed("/api/v2/shop/admin/orders")
    and not G.allowed("/api/v2/supplier-portalx/evil") and not G.allowed("/auth/delete-account")
    and not G.allowed("/api/v2/users") and not G.allowed("/api/v2/namespace/members"))
check("guard source: supplier logins blocked everywhere else", guard_src:find("SUPPLIER_PORTAL_ONLY", 1, true) ~= nil)
package.loaded["lapis.db"] = saved

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
