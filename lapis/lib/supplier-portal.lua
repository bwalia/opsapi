-- luacheck: max line length 140
--[[
    Supplier portal: pure rules (no database, no ngx)
    ==================================================
    Purchase orders, proforma/VAT invoices, payments and deliveries managed online with the supplier,
    instead of by email. Everything here is a pure function so spec/supplier-portal_spec.lua can cover it;
    queries/SupplierPortalQueries.lua does the database work around it.

      STAGES / TRANSITIONS     the supplier-facing life of a PO:
                               draft → sent → acknowledged → proforma_received → part_paid → paid → dispatched
                               → delivered → invoiced → closed, and cancelled
      effectiveStage(po)       portal_stage and the existing purchase_orders.status, whichever is further on
      canTransition(f, t, by)  who may move a PO from f to t (by = "staff" | "supplier")
      stageAfterPayment(...)   part_paid / paid follow the payments while nothing has shipped yet
      pennies(v) / money(p)    exact money: decimal text ↔ whole pennies
      balance(total, inv, pay) what we owe (final invoices, else the latest proforma, else the PO) less payments
      invoiceFields / invoiceFlags / paymentFields / shipmentFields / deliveryFields / messageBody / inviteFields
                               validation of what staff and suppliers type
      sniff / checkFile / safeFilename   uploads: PDF, PNG or JPG only (by their bytes), ≤ 20 MB, clean names
      dropShipVisible / supplierPo        what a supplier may see of a PO: the deal code and the spec, never the
                                          customer (their address only on a confirmed or legacy drop-ship)
      supplierTimeline(rows)   the history a supplier sees (our staff shown as the company)
      safeRecipients(...)      who a notification may be emailed to: the supplier's own portal users, only when
                               supplier emails are switched on, never a customer
      signToken / verifyToken  short-lived download links (HMAC passed in)
]]

local DealCodes = require("lib.deal-codes")

local M = {}

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function nz(v)
    if v == nil or type(v) == "userdata" then return nil end
    if type(v) == "string" then
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" then return nil end
    end
    return v
end
M._nz = nz

local function text(v, max, field)
    v = nz(v)
    if v == nil then return nil end
    if type(v) ~= "string" and type(v) ~= "number" then return nil, field .. " must be text" end
    v = tostring(v)
    if #v > max then return nil, field .. " can be at most " .. max .. " characters" end
    return v
end

--- A real calendar date YYYY-MM-DD? Returns the date or nil.
function M.date(v)
    v = nz(v)
    if type(v) ~= "string" then return nil end
    local y, m, d = v:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 or y < 2000 or y > 2100 then return nil end
    local dim = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then dim[2] = 29 end
    if d > dim[m] then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- stages
-- ---------------------------------------------------------------------------

M.STAGES = { "draft", "sent", "acknowledged", "proforma_received", "part_paid", "paid", "dispatched", "delivered",
             "invoiced", "closed", "cancelled" }

M.LABELS = {
    draft = "Draft", sent = "Sent to supplier", acknowledged = "Acknowledged", proforma_received = "Proforma received",
    part_paid = "Part paid", paid = "Paid", dispatched = "Dispatched", delivered = "Delivered",
    invoiced = "Final invoice received", closed = "Closed", cancelled = "Cancelled",
}

local RANK = {}
for i, s in ipairs(M.STAGES) do RANK[s] = i end
RANK.cancelled = nil
M.RANK = RANK

-- Moves people make. part_paid / paid come from payments (stageAfterPayment), not by hand.
local TRANSITIONS = {
    draft = { sent = true, cancelled = true },
    sent = { acknowledged = true, cancelled = true },
    acknowledged = { proforma_received = true, dispatched = true, cancelled = true },
    proforma_received = { dispatched = true, cancelled = true },
    part_paid = { dispatched = true },
    paid = { dispatched = true },
    dispatched = { delivered = true },
    delivered = { invoiced = true, closed = true },
    invoiced = { closed = true },
    closed = {},
    cancelled = {},
}
M.TRANSITIONS = TRANSITIONS

-- What a supplier may do themselves; staff may make every move above.
local SUPPLIER_MOVES = { acknowledged = true, proforma_received = true, dispatched = true, delivered = true,
                         invoiced = true }

function M.isStage(s) return TRANSITIONS[s] ~= nil end

--- May `by` ("staff" | "supplier") move a PO from `from` to `to`?
function M.canTransition(from, to, by)
    local allowed = TRANSITIONS[from]
    if not allowed or not allowed[to] then return false end
    if by == "supplier" then return SUPPLIER_MOVES[to] == true end
    return by == "staff"
end

-- The existing purchase_orders.status (goods receipt and bills) as a stage.
M.STATUS_STAGE = {
    draft = "draft", sent = "sent", acknowledged = "acknowledged",
    partially_received = "dispatched", received = "delivered", billed = "invoiced", cancelled = "cancelled",
}

--- Where the PO is: a cancelled PO is cancelled; otherwise whichever of portal_stage and the status
-- (staff can still use Receive Goods / Bill on the PO page) is further on.
function M.effectiveStage(po)
    if po.status == "cancelled" or po.portal_stage == "cancelled" then return "cancelled" end
    local a = RANK[po.portal_stage or ""] and po.portal_stage or nil
    local b = M.STATUS_STAGE[po.status or ""] or "draft"
    if not a then return b end
    return (RANK[a] >= RANK[b]) and a or b
end

-- Stages where the supplier can still change things (upload, dispatch, message).
function M.supplierCanAct(stage)
    return stage ~= "draft" and stage ~= "closed" and stage ~= "cancelled"
end

local PAYABLE = { acknowledged = true, proforma_received = true, part_paid = true, paid = true }

--- The stage once payments change. Only before anything has shipped: after that the stage follows the goods
-- and the balance is shown on its own. state comes from M.balance.
function M.stageAfterPayment(stage, state, has_proforma)
    if not PAYABLE[stage] then return stage end
    if state == "paid" or state == "overpaid" then return "paid" end
    if state == "part_paid" then return "part_paid" end
    return has_proforma and "proforma_received" or "acknowledged"
end

-- ---------------------------------------------------------------------------
-- money (whole pennies, never floats)
-- ---------------------------------------------------------------------------

--- "5256.65" / 5256.65 / "5,256.65" → 525665. nil when it isn't a non-negative amount with at most 2 decimals.
function M.pennies(v)
    if type(v) == "number" then
        if v ~= v or v < 0 or v == math.huge then return nil end
        v = string.format("%.15g", v)
    end
    if type(v) ~= "string" then return nil end
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^£", "")
    if v:find(",", 1, true) then
        -- thousands separators only: 6,307.98 / 1,234,567
        local head, rest = v:match("^(%d%d?%d?)(,.*)$")
        if not head then return nil end
        local groups = rest:match("^(.-)%.%d*$") or rest
        if groups == "" or groups:gsub(",%d%d%d", "") ~= "" then return nil end
        v = v:gsub(",", "")
    end
    local int, frac = v:match("^(%d+)%.?(%d*)$")
    if not int then
        int, frac = "0", v:match("^%.(%d+)$")
        if not frac then return nil end
    end
    if #frac > 2 or #int > 13 then return nil end
    frac = (frac .. "00"):sub(1, 2)
    return tonumber(int) * 100 + tonumber(frac)
end

--- 525665 → "5256.65" (negative allowed: "-12.50").
function M.money(p)
    p = math.floor((tonumber(p) or 0) + 0.5)
    local sign = p < 0 and "-" or ""
    p = math.abs(p)
    return sign .. string.format("%d.%02d", math.floor(p / 100), p % 100)
end

--- What we owe the supplier and what we have paid.
-- invoices: {{ kind = proforma|invoice|credit_note, total }} oldest first (deleted ones left out)
-- payments: {{ amount }} (voided ones left out)
-- → { due, paid, balance (pennies), basis = invoice|proforma|purchase_order,
--     state = nothing_due|unpaid|part_paid|paid|overpaid, + the same as text: due_text, paid_text, balance_text }
function M.balance(po_total, invoices, payments)
    local final, has_final, credit, proforma = 0, false, 0, nil
    for _, inv in ipairs(invoices or {}) do
        local t = M.pennies(inv.total) or 0
        if inv.kind == "invoice" then
            final, has_final = final + t, true
        elseif inv.kind == "credit_note" then
            credit = credit + t
        elseif inv.kind == "proforma" then
            proforma = t
        end
    end
    local due, basis
    if has_final then
        due, basis = final, "invoice"
    elseif proforma then
        due, basis = proforma, "proforma"
    else
        due, basis = M.pennies(po_total) or 0, "purchase_order"
    end
    due = due - credit
    local paid = 0
    for _, p in ipairs(payments or {}) do paid = paid + (M.pennies(p.amount) or 0) end
    local balance = due - paid
    local state
    if due <= 0 and paid == 0 then
        state = "nothing_due"
    elseif paid == 0 then
        state = "unpaid"
    elseif balance > 0 then
        state = "part_paid"
    elseif balance == 0 then
        state = "paid"
    else
        state = "overpaid"
    end
    return { due = due, paid = paid, balance = balance, basis = basis, state = state,
             due_text = M.money(due), paid_text = M.money(paid), balance_text = M.money(balance) }
end

--- May staff close the PO? stage = effective stage, bal = M.balance(...), has_final = a final invoice exists.
-- Without everything settled staff must force it with a reason. → true | nil, message
function M.canClose(stage, bal, has_final, force, reason)
    if stage ~= "delivered" and stage ~= "invoiced" then
        return nil, "Only a delivered purchase order can be closed (it is " .. (M.LABELS[stage] or stage) .. ")"
    end
    local settled = bal and (bal.state == "paid" or bal.state == "nothing_due")
    if settled and has_final then return true end
    if force == true and type(reason) == "string" and #reason:gsub("%s", "") >= 3 then return true end
    local missing = {}
    if not has_final then missing[#missing + 1] = "the supplier's final VAT invoice isn't recorded" end
    if not settled then
        missing[#missing + 1] = bal and bal.state == "overpaid" and ("we have overpaid by " .. M.money(-bal.balance))
            or ("£" .. M.money(bal and bal.balance or 0) .. " is still to pay")
    end
    return nil, "Can't close yet: " .. table.concat(missing, " and ") .. ". To close it anyway, give a reason."
end

-- ---------------------------------------------------------------------------
-- validation of what people type
-- ---------------------------------------------------------------------------

M.INVOICE_KINDS = { proforma = true, invoice = true, credit_note = true }
M.KIND_LABEL = { proforma = "Proforma invoice", invoice = "Final VAT invoice", credit_note = "Credit note" }
M.PAYMENT_METHODS = { faster_payment = "Faster Payment", bacs = "BACS", chaps = "CHAPS", card = "Card", other = "Other" }

local function amount(body, key, required)
    local v = body[key]
    if nz(v) == nil then
        if required then return nil, key .. " is required" end
        return false
    end
    local p = M.pennies(v)
    if not p then return nil, key .. " must be an amount such as 5256.65 (at most 2 decimals)" end
    return p
end

--- A proforma / final VAT invoice / credit note as typed (body) → clean fields (pennies as text) | nil, message.
-- po_currency: the PO's currency (the default).
function M.invoiceFields(body, po_currency)
    body = type(body) == "table" and body or {}
    local kind = nz(body.kind)
    if not M.INVOICE_KINDS[kind or ""] then return nil, "kind must be proforma, invoice or credit_note" end
    local out = { kind = kind }
    local e
    out.number, e = text(body.number, 64, "number")
    if e then return nil, e end
    if not out.number then return nil, "The " .. M.KIND_LABEL[kind]:lower() .. " number is required" end
    out.invoice_date = M.date(body.invoice_date)
    if not out.invoice_date then return nil, "invoice_date must be a date (YYYY-MM-DD)" end
    if nz(body.due_date) then
        out.due_date = M.date(body.due_date)
        if not out.due_date then return nil, "due_date must be a date (YYYY-MM-DD)" end
    end
    for _, f in ipairs({ { "supplier_order_ref", 64 }, { "payment_terms", 200 }, { "incoterm", 16 },
                          { "bank_details", 1000 }, { "note", 1000 } }) do
        out[f[1]], e = text(body[f[1]], f[2], f[1])
        if e then return nil, e end
    end
    local total, terr = amount(body, "total", true)
    if not total then return nil, terr end
    local net, nerr = amount(body, "net", false)
    if net == nil then return nil, nerr end
    local vat, verr = amount(body, "vat", false)
    if vat == nil then return nil, verr end
    if net == false and vat ~= false then net = total - vat end
    if vat == false and net ~= false then vat = total - net end
    if net == false then net, vat = total, 0 end
    if net < 0 or vat < 0 then return nil, "net and vat can't be more than the total" end
    out.net, out.vat, out.total = M.money(net), M.money(vat), M.money(total)
    local cur = nz(body.currency) or po_currency or "GBP"
    cur = tostring(cur):upper()
    if not cur:match("^%u%u%u$") then return nil, "currency must be a 3-letter code such as GBP" end
    out.currency = cur
    if out.incoterm then out.incoterm = out.incoterm:upper() end
    return out
end

local function norm_bank(s)
    return (tostring(s or ""):lower():gsub("[^%w]", ""))
end

--- What staff should check on a proforma / invoice. po: { subtotal, tax_total, total, currency }.
-- ctx: { sale_net = pennies ex VAT we sell the deal for (shop order), previous_bank_details = text }
-- → list of { code, message }. Staff only: never shown to the supplier.
function M.invoiceFlags(inv, po, ctx)
    ctx = ctx or {}
    local flags = {}
    local function add(code, msg) flags[#flags + 1] = { code = code, message = msg } end
    local net, vat, total = M.pennies(inv.net) or 0, M.pennies(inv.vat) or 0, M.pennies(inv.total) or 0
    if net + vat ~= total then
        add("does_not_add_up", "Net " .. M.money(net) .. " + VAT " .. M.money(vat) .. " is not the total " .. M.money(total))
    end
    if po and inv.currency and po.currency and inv.currency ~= po.currency then
        add("currency_differs", "In " .. inv.currency .. ", the purchase order is in " .. po.currency)
    end
    if po and inv.kind ~= "credit_note" then
        local pt, pn, pv = M.pennies(po.total), M.pennies(po.subtotal), M.pennies(po.tax_total)
        if pt and total ~= pt then
            local d = total - pt
            add("total_differs", "Total " .. M.money(total) .. " is " .. M.money(math.abs(d)) .. (d > 0 and " more" or " less")
                .. " than the purchase order (" .. M.money(pt) .. ")")
        end
        if pn and net ~= pn then add("net_differs", "Net " .. M.money(net) .. " differs from the purchase order net " .. M.money(pn)) end
        if pv and vat ~= pv then add("vat_differs", "VAT " .. M.money(vat) .. " differs from the purchase order VAT " .. M.money(pv)) end
    end
    if inv.kind ~= "credit_note" and ctx.sale_net and net > ctx.sale_net then
        add("cost_above_sale", "Costs " .. M.money(net) .. " ex VAT, more than we sell this deal for (" .. M.money(ctx.sale_net)
            .. " ex VAT): below cost")
    end
    if nz(inv.bank_details) and nz(ctx.previous_bank_details)
        and norm_bank(inv.bank_details) ~= norm_bank(ctx.previous_bank_details) then
        add("bank_details_changed", "The bank details differ from this supplier's last invoice: confirm them by phone "
            .. "before paying")
    end
    return flags
end

--- A payment as typed → clean fields | nil, message. po_currency: payments are in the PO's currency.
function M.paymentFields(body, po_currency)
    body = type(body) == "table" and body or {}
    local out = {}
    local a = M.pennies(body.amount)
    if not a or a <= 0 then return nil, "amount must be more than 0 (at most 2 decimals)" end
    if a > 99999999999 then return nil, "amount is too large" end
    out.amount = M.money(a)
    local method = nz(body.method) or "faster_payment"
    if not M.PAYMENT_METHODS[method] then return nil, "method must be faster_payment, bacs, chaps, card or other" end
    out.method = method
    out.sent_on = M.date(body.sent_on)
    if not out.sent_on then return nil, "sent_on (the date it was paid) must be a date (YYYY-MM-DD)" end
    if nz(body.cleared_on) then
        out.cleared_on = M.date(body.cleared_on)
        if not out.cleared_on then return nil, "cleared_on must be a date (YYYY-MM-DD)" end
        if out.cleared_on < out.sent_on then return nil, "cleared_on can't be before sent_on" end
    end
    local e
    for _, f in ipairs({ { "bank_transaction_id", 100 }, { "payment_reference", 140 }, { "note", 1000 } }) do
        out[f[1]], e = text(body[f[1]], f[2], f[1])
        if e then return nil, e end
    end
    local cur = tostring(nz(body.currency) or po_currency or "GBP"):upper()
    if po_currency and cur ~= po_currency then
        return nil, "Payments are recorded in the purchase order's currency (" .. po_currency .. ")"
    end
    out.currency = cur
    return out
end

local function https_url(v)
    v = nz(v)
    if v == nil then return false end
    if type(v) ~= "string" or #v > 500 or not v:match("^https://[%w%.%-]+[%w]/?[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]*$") then
        return nil
    end
    return v
end

--- Dispatch details → clean fields | nil, message. today: YYYY-MM-DD (the default dispatch date).
function M.shipmentFields(body, today)
    body = type(body) == "table" and body or {}
    local out, e = {}
    out.carrier, e = text(body.carrier, 100, "carrier")
    if e then return nil, e end
    if not out.carrier then return nil, "carrier is required (for example DPD, DHL or our own van)" end
    out.tracking_number, e = text(body.tracking_number, 100, "tracking_number")
    if e then return nil, e end
    local url = https_url(body.tracking_url)
    if url == nil then return nil, "tracking_url must be an https:// link" end
    out.tracking_url = url or nil
    out.dispatched_on = nz(body.dispatched_on) and M.date(body.dispatched_on) or today
    if not out.dispatched_on then return nil, "dispatched_on must be a date (YYYY-MM-DD)" end
    if nz(body.expected_on) then
        out.expected_on = M.date(body.expected_on)
        if not out.expected_on then return nil, "expected_on must be a date (YYYY-MM-DD)" end
        if out.expected_on < out.dispatched_on then return nil, "expected_on can't be before dispatched_on" end
    end
    out.note, e = text(body.note, 1000, "note")
    if e then return nil, e end
    return out
end

--- Delivery details → clean fields | nil, message. latest: the last date allowed (default today; the queries pass
-- tomorrow, UTC, so a UK supplier just after midnight isn't refused).
function M.deliveryFields(body, today, latest)
    body = type(body) == "table" and body or {}
    local out, e = {}
    out.delivered_on = nz(body.delivered_on) and M.date(body.delivered_on) or today
    if not out.delivered_on then return nil, "delivered_on must be a date (YYYY-MM-DD)" end
    latest = latest or today
    if latest and out.delivered_on > latest then return nil, "delivered_on can't be in the future" end
    out.received_by, e = text(body.received_by, 100, "received_by")
    if e then return nil, e end
    out.note, e = text(body.note, 1000, "note")
    if e then return nil, e end
    return out
end

function M.messageBody(v)
    local s = nz(v)
    if type(s) ~= "string" then return nil, "Write a message" end
    if #s > 4000 then return nil, "Messages can be at most 4000 characters" end
    return s
end

local EMAIL = "^[%w%.%%%+%-_']+@[%w%.%-]+%.%a%a+$"
function M.email(v)
    local s = nz(v)
    if type(s) ~= "string" or #s > 254 or not s:match(EMAIL) or s:find("..", 1, true) then return nil end
    return s:lower()
end

--- Inviting a supplier contact → { email, first_name, last_name } | nil, message
function M.inviteFields(body)
    body = type(body) == "table" and body or {}
    local email = M.email(body.email)
    if not email then return nil, "Give the contact's email address" end
    local name, e = text(body.name, 120, "name")
    if e then return nil, e end
    local first, last = (name or ""):match("^(%S+)%s*(.*)$")
    return { email = email, first_name = first or email:match("^[^@]+"), last_name = last or "" }
end

-- ---------------------------------------------------------------------------
-- documents
-- ---------------------------------------------------------------------------

M.MAX_FILE_BYTES = 20 * 1024 * 1024

M.DOC_TYPES = {
    purchase_order = "Our purchase order", proforma = "Proforma invoice", payment_proof = "Payment proof",
    vat_invoice = "Final VAT invoice", delivery_note = "Delivery note", proof_of_delivery = "Proof of delivery",
    credit_note = "Credit note", other = "Other",
}
-- Suppliers upload their own paperwork; our PO and our payment proofs only come from staff.
M.SUPPLIER_DOC_TYPES = { proforma = true, vat_invoice = true, delivery_note = true, proof_of_delivery = true,
                         credit_note = true, other = true }
-- Documents that are also a proforma / invoice / credit note record.
M.DOC_INVOICE_KIND = { proforma = "proforma", vat_invoice = "invoice", credit_note = "credit_note" }

function M.mayUpload(doc_type, by)
    if not M.DOC_TYPES[doc_type or ""] then return false end
    if by == "supplier" then return M.SUPPLIER_DOC_TYPES[doc_type] == true end
    return by == "staff"
end

local TYPES = {
    ["application/pdf"] = { ext = "pdf", exts = { pdf = true } },
    ["image/png"] = { ext = "png", exts = { png = true } },
    ["image/jpeg"] = { ext = "jpg", exts = { jpg = true, jpeg = true } },
}
local DECLARED = {
    ["application/pdf"] = "application/pdf", ["application/x-pdf"] = "application/pdf",
    ["image/png"] = "image/png", ["image/jpeg"] = "image/jpeg", ["image/jpg"] = "image/jpeg",
    ["image/pjpeg"] = "image/jpeg",
}

--- The file's real type from its first bytes: application/pdf | image/png | image/jpeg | nil
function M.sniff(content)
    if type(content) ~= "string" then return nil end
    if content:sub(1, 5) == "%PDF-" then return "application/pdf" end
    if content:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
    if content:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
    return nil
end

--- A clean file name: no folders, no control or odd characters, at most 100 characters before the extension,
-- which is always the one for the real type.
function M.safeFilename(name, ext)
    local s = tostring(name or ""):gsub("\\", "/"):match("[^/]*$") or ""
    s = s:gsub("[%z\1-\31\127]", "")
    local base = s:match("^(.*)%.[%w]+$") or s
    base = base:gsub("[^%w%._%-() ]", "_"):gsub("_+", "_"):gsub("%s+", " "):gsub("^[%s%._]+", ""):gsub("[%s%._]+$", "")
    if #base > 100 then base = base:sub(1, 100):gsub("[%s%._]+$", "") end
    if base == "" then base = "document" end
    return base .. "." .. ext
end

--- Check an upload: { filename, content, content_type } → { filename, content_type, size, ext } | nil, message
function M.checkFile(file)
    if type(file) ~= "table" or type(file.content) ~= "string" then return nil, "Choose a file to upload" end
    local size = #file.content
    if size == 0 then return nil, "The file is empty" end
    if size > M.MAX_FILE_BYTES then return nil, "Files can be up to 20 MB" end
    local real = M.sniff(file.content)
    if not real then return nil, "Only PDF, PNG or JPG files can be uploaded" end
    local declared = nz(file.content_type)
    if declared then
        declared = tostring(declared):lower():match("^%s*([^;%s]+)")
        local d = DECLARED[declared or ""]
        if d and d ~= real then return nil, "The file's type doesn't match what is inside it" end
        if not d and declared ~= "application/octet-stream" and declared ~= "binary/octet-stream" then
            return nil, "Only PDF, PNG or JPG files can be uploaded"
        end
    end
    local ext = tostring(file.filename or ""):lower():match("%.([%w]+)$")
    if ext and (ext == "pdf" or ext == "png" or ext == "jpg" or ext == "jpeg") and not TYPES[real].exts[ext] then
        return nil, "The file's type doesn't match what is inside it"
    end
    if real == "application/pdf" then
        local scan = file.content
        if scan:find("/JavaScript", 1, true) or scan:find("/Launch", 1, true) or scan:find("/JS[%s%(<]") then
            return nil, "This PDF contains scripts or actions, so it can't be uploaded. Save it again as a plain PDF."
        end
    end
    return { filename = M.safeFilename(file.filename, TYPES[real].ext), content_type = real, size = size,
             ext = TYPES[real].ext }
end

-- ---------------------------------------------------------------------------
-- what a supplier sees
-- ---------------------------------------------------------------------------

--- Does the supplier see the customer's delivery address? Only for a drop-ship staff confirmed ("I confirm the
-- supplier will see this delivery address"), or a legacy one: a shop PO raised before deal codes that already
-- delivers to the customer (the supplier has that PO). → visible, "confirmed" | "legacy" | nil
function M.dropShipVisible(po)
    local m = type(po.metadata) == "table" and po.metadata or {}
    if m.drop_ship_confirmed == true then return true, "confirmed" end
    if nz(m.shop_order_uuid) and (m.drop_ship == true or (m.drop_ship == nil and nz(po.delivery_address))) then
        return true, "legacy"
    end
    return false, nil
end

local HIDDEN = "[hidden: customer details]"

local function addr_text(a)
    if type(a) ~= "table" then return nz(a) end
    local parts = {}
    for _, k in ipairs({ "company", "line1", "line2", "city", "county", "postcode", "country" }) do
        if nz(a[k]) then parts[#parts + 1] = tostring(a[k]) end
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

--- The PO as the supplier sees it. po: the purchase_orders row (metadata decoded) with items; ctx:
-- { stage, company_name, markers (customer markers of the deal, DealCodes.markers) }.
-- Shows the deal code and the spec (lines), our address, never staff-only data (project, receipts, bills,
-- creator, our customer's order number); anything that names the customer is hidden unless it is the delivery
-- address of a confirmed or legacy drop-ship.
function M.supplierPo(po, ctx)
    ctx = ctx or {}
    local m = type(po.metadata) == "table" and po.metadata or {}
    local drop, why = M.dropShipVisible(po)
    local delivery
    if drop then
        delivery = nz(po.delivery_address)
    elseif nz(m.shop_order_uuid) then
        -- a shop PO delivering to us: our own address
        delivery = (m.drop_ship == false) and (nz(po.delivery_address) or addr_text(m.deliver_to)) or nil
    else
        delivery = nz(po.delivery_address) -- typed by staff on a PO raised by hand
    end
    local items = {}
    for _, it in ipairs(po.items or {}) do
        items[#items + 1] = {
            description = it.description, quantity = it.quantity, unit_price = it.unit_price, tax_rate = it.tax_rate,
            tax_amount = it.tax_amount, line_total = it.line_total,
        }
    end
    local stage = ctx.stage or M.effectiveStage(po)
    local out = {
        id = po.uuid, po_number = po.po_number, stage = stage, stage_label = M.LABELS[stage] or stage,
        issue_date = po.issue_date, expected_date = nz(po.expected_date), currency = po.currency or "GBP",
        subtotal = po.subtotal, tax_total = po.tax_total, total = po.total,
        reference = nz(po.reference), deal_code = nz(m.deal_code) or nz(po.deal_code),
        notes = nz(po.notes), terms = nz(po.terms),
        delivery_address = delivery, delivery_method = nz(m.delivery_method),
        drop_ship = drop, drop_ship_kind = why,
        end_customer_po = (why == "confirmed") and nz(m.end_customer_po) or nil,
        supplier_account_number = nz(m.supplier_account_number),
        buyer = { name = ctx.company_name, bill_to = addr_text(m.bill_to) },
        sent_at = nz(po.sent_at), acknowledged_at = nz(po.acknowledged_at),
        items = items,
    }
    -- Belt and braces: nothing that names the customer, except a drop-ship's own address.
    local markers = ctx.markers or {}
    if #markers > 0 then
        local redacted = false
        local function guard(tbl, key)
            if tbl[key] ~= nil and #DealCodes.leaks(tbl[key], markers) > 0 then
                tbl[key] = HIDDEN
                redacted = true
            end
        end
        for _, k in ipairs({ "notes", "terms", "reference", "delivery_method", "supplier_account_number" }) do guard(out, k) end
        if not drop then guard(out, "delivery_address") end
        guard(out.buyer, "bill_to")
        for _, it in ipairs(items) do guard(it, "description") end
        out.redacted = redacted or nil
    end
    return out
end

M.HIDDEN = HIDDEN

-- History entries a supplier sees, and the details they may see of each.
M.SUPPLIER_TIMELINE = {
    ["po.stage_changed"] = true, ["po.acknowledged"] = true, ["po.cancelled"] = true, ["po.closed"] = true,
    ["po.sent"] = true, ["document.uploaded"] = true, ["invoice.recorded"] = true, ["payment.recorded"] = true,
    ["payment.voided"] = true, ["shipment.dispatched"] = true, ["shipment.delivered"] = true,
    ["message.posted"] = true,
}
local SAFE_DETAIL = { from = true, to = true, doc_type = true, filename = true, number = true, kind = true,
                      amount = true, currency = true, carrier = true, tracking_number = true, delivered_on = true,
                      dispatched_on = true, method = true, payment_reference = true }

--- rows: {{ action, detail (table), at, actor_kind = staff|supplier, actor_name }} → what the supplier sees:
-- our staff appear as the company, no internal notes, reasons or views.
function M.supplierTimeline(rows, company_name)
    local out = {}
    for _, r in ipairs(rows or {}) do
        if M.SUPPLIER_TIMELINE[r.action] then
            local d = {}
            for k, v in pairs(type(r.detail) == "table" and r.detail or {}) do
                if SAFE_DETAIL[k] and (type(v) == "string" or type(v) == "number") then d[k] = v end
            end
            out[#out + 1] = {
                action = r.action, detail = d, at = r.at,
                by = r.actor_kind == "supplier" and (r.actor_name or "Your team") or (company_name or "Us"),
                by_kind = r.actor_kind == "supplier" and "supplier" or "buyer",
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- notifications: who may be emailed
-- ---------------------------------------------------------------------------

--- The addresses a supplier notification may go to. Nothing unless supplier emails are switched on; then only
-- the supplier's own portal users (allowed), and never anyone who is one of our customers (customers).
-- candidates: list of emails; allowed / customers: sets (lower-case email → true).
-- → list, reason ("disabled" | "no_recipients" | nil)
function M.safeRecipients(enabled, candidates, allowed, customers)
    if enabled ~= true then return {}, "disabled" end
    local out, seen = {}, {}
    for _, c in ipairs(candidates or {}) do
        local e = M.email(c)
        if e and not seen[e] and (allowed or {})[e] and not (customers or {})[e] then
            seen[e] = true
            out[#out + 1] = e
        end
    end
    if #out == 0 then return out, "no_recipients" end
    return out, nil
end

-- ---------------------------------------------------------------------------
-- download links: base64url(payload) . base64url(HMAC-SHA256(payload))
-- ---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64I = {}
for i = 1, 64 do B64I[B64:sub(i, i)] = i - 1 end

function M.b64url(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
        for j = 1, chars do
            local idx = math.floor(n / 2 ^ (18 - 6 * (j - 1))) % 64
            out[#out + 1] = B64:sub(idx + 1, idx + 1)
        end
    end
    return table.concat(out)
end

function M.unb64url(s)
    if type(s) ~= "string" or s:find("[^%w%-_]") then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local chunk = s:sub(i, i + 3)
        if #chunk == 1 then return nil end
        local n = 0
        for j = 1, 4 do
            local ch = chunk:sub(j, j)
            n = n * 64 + (ch ~= "" and B64I[ch] or 0)
        end
        local bytes = #chunk - 1
        local b1, b2, b3 = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
        out[#out + 1] = string.char(b1)
        if bytes >= 2 then out[#out + 1] = string.char(b2) end
        if bytes >= 3 then out[#out + 1] = string.char(b3) end
    end
    return table.concat(out)
end

local function const_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

M.LINK_SECONDS = 120

--- A download token for document doc_uuid, for user_uuid, valid `ttl` seconds from now. hmac(key, msg) → raw bytes.
function M.signToken(doc_uuid, user_uuid, now, ttl, key, hmac)
    local payload = "v1|" .. tostring(doc_uuid) .. "|" .. tostring(user_uuid) .. "|" .. tostring(math.floor(now + (ttl or M.LINK_SECONDS)))
    return M.b64url(payload) .. "." .. M.b64url(hmac(key, payload))
end

--- → { doc_uuid, user_uuid, exp } | nil, "invalid" | "expired"
function M.verifyToken(token, now, key, hmac)
    if type(token) ~= "string" or #token > 600 then return nil, "invalid" end
    local p64, s64 = token:match("^([%w%-_]+)%.([%w%-_]+)$")
    if not p64 then return nil, "invalid" end
    local payload, sig = M.unb64url(p64), M.unb64url(s64)
    if not payload or not sig or not const_eq(sig, hmac(key, payload)) then return nil, "invalid" end
    local doc, user, exp = payload:match("^v1|([%w%-]+)|([%w%-]+)|(%d+)$")
    if not doc then return nil, "invalid" end
    if tonumber(exp) < now then return nil, "expired" end
    return { doc_uuid = doc, user_uuid = user, exp = tonumber(exp) }
end

return M
