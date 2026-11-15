--[[
    E-invoicing readiness (VAT plan phase 11): our invoices out as Peppol BIS Billing
    3.0 UBL, supplier e-invoices in (checked, de-duplicated, optionally recorded as
    purchases with their VAT coded). Every document is kept in vat_einvoice_documents.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local VAT = require("lib.vat")
local Einvoice = require("lib.vat-einvoice")

local Q = {}

local function null(v) return v == nil or v == db.NULL or (ngx and v == ngx.null) end
local function opt(v) if null(v) then return nil end return v end

local function decode(v)
    if type(v) == "table" then return v end
    if type(v) ~= "string" or v == "" then return nil end
    local ok, t = pcall(cjson.decode, v)
    return ok and t or nil
end

local function has_column(tbl, col)
    local r = db.query([[SELECT 1 FROM information_schema.columns WHERE table_name = ? AND column_name = ?]], tbl, col)
    return r and #r > 0
end

-- Keep a document; the same (direction, document id) replaces the earlier copy.
local function store(namespace_id, row)
    row.namespace_id = namespace_id
    local prev = db.query([[SELECT id, status FROM vat_einvoice_documents WHERE namespace_id = ? AND direction = ?
        AND document_id = ? LIMIT 1]], namespace_id, row.direction, row.document_id)[1]
    if prev then
        if prev.status == "recorded" then row.status = nil end -- never undo "recorded"
        row.updated_at = db.raw("NOW()")
        db.update("vat_einvoice_documents", row, { id = prev.id })
        return db.query("SELECT * FROM vat_einvoice_documents WHERE id = ?", prev.id)[1], true
    end
    db.insert("vat_einvoice_documents", row)
    return db.query([[SELECT * FROM vat_einvoice_documents WHERE namespace_id = ? AND direction = ?
        AND document_id = ?]], namespace_id, row.direction, row.document_id)[1], false
end

local function summary(res)
    return cjson.encode({ valid = res.valid, errors = res.errors, warnings = res.warnings })
end

-- ---------------------------------------------------------------------------
-- Out: our invoice as an e-invoice
-- ---------------------------------------------------------------------------

--- @return { xml, filename, check = {valid, errors, warnings}, problems, document } or nil, message, status
function Q.export(namespace_id, invoice_uuid, reg, actor_id)
    local inv = db.query([[SELECT * FROM invoices WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1]],
        invoice_uuid, namespace_id)[1]
    if not inv then return nil, "Invoice not found", 404 end
    if inv.status == "draft" or inv.status == "cancelled" or inv.status == "void" then
        return nil, "Only issued invoices can be sent as e-invoices", 409
    end
    local lines = db.query("SELECT * FROM invoice_line_items WHERE invoice_id = ? ORDER BY sort_order, id",
        inv.id) or {}
    local addr = decode(inv.customer_address) or decode(inv.billing_address) or opt(inv.customer_address)
    if type(addr) == "table" and next(addr) == nil then addr = decode(inv.billing_address) end
    local xml, problems = Einvoice.build({
        invoice_number = inv.invoice_number, issue_date = tostring(inv.issue_date), due_date = opt(inv.due_date)
            and tostring(inv.due_date), tax_point = opt(inv.tax_point) and tostring(inv.tax_point),
        currency = opt(inv.currency), customer_name = opt(inv.customer_name), customer_email = opt(inv.customer_email),
        customer_address = addr, customer_vat_number = opt(inv.customer_vat_number), notes = opt(inv.notes),
        po_number = opt(inv.po_number), amount_paid = tonumber(inv.amount_paid),
    }, lines, { name = reg and opt(reg.business_name), vrn = reg and reg.vrn,
        address = reg and opt(reg.business_address) })
    local res = Einvoice.check(xml)
    if not reg then
        table.insert(res.errors, 1, { rule = "SETUP", message = "Add the workspace's VAT registration first" })
        res.valid = false
    end
    for _, p in ipairs(problems) do res.errors[#res.errors + 1] = { rule = "UK-VAT", message = p } end
    if #problems > 0 then res.valid = false end
    local d = res.data or {}
    local doc = store(namespace_id, {
        registration_id = reg and reg.id or db.NULL, direction = "out", format = Einvoice.FORMAT,
        document_id = tostring(inv.invoice_number), invoice_id = inv.id, invoice_number = inv.invoice_number,
        issue_date = tostring(inv.issue_date), party_name = opt(inv.customer_name) or db.NULL,
        party_vat_id = d.buyer and d.buyer.vat_id or db.NULL, currency = d.currency or db.NULL,
        total = d.totals and d.totals.tax_inclusive or db.NULL, vat_total = d.totals and d.totals.tax or db.NULL,
        valid = res.valid, validation = summary(res), status = "generated", xml = xml, created_by = actor_id,
    })
    local safe = tostring(inv.invoice_number):gsub("[^%w%-_]", "_")
    return { xml = xml, filename = "einvoice-" .. safe .. ".xml",
        check = { valid = res.valid, errors = res.errors, warnings = res.warnings }, document = doc and doc.uuid }
end

-- ---------------------------------------------------------------------------
-- In: a supplier's e-invoice
-- ---------------------------------------------------------------------------

--- Check (and keep) a supplier's e-invoice; with record = true, add it as purchases
-- (accounting expenses, waiting for approval) with the VAT coded.
-- @return { check, data, purchases, document, duplicate?, recorded? } or nil, message, status
function Q.import(reg, actor, xml, record)
    if type(xml) ~= "string" or xml == "" then return nil, "Send the e-invoice XML (xml)", 400 end
    local res = Einvoice.check(xml)
    local d = res.data
    if not d then return nil, (res.errors[1] or {}).message or "Not a UBL invoice", 400 end
    local supplier_vat = d.supplier and d.supplier.vat_id
    if supplier_vat and tostring(supplier_vat):match("^GB") and not VAT.valid_vrn(supplier_vat) then
        res.warnings[#res.warnings + 1] = "The supplier's UK VAT number doesn't pass HMRC's check: don't reclaim the "
            .. "VAT until you've confirmed it."
    end
    if reg and reg.vrn and d.buyer and d.buyer.vat_id and tostring(d.buyer.vat_id):gsub("^GB", "") ~= reg.vrn then
        res.warnings[#res.warnings + 1] = "This invoice is addressed to a different VAT number ("
            .. tostring(d.buyer.vat_id) .. ")."
    end
    local purchases, perr = Einvoice.purchase_lines(d)
    if not purchases then res.warnings[#res.warnings + 1] = perr end
    local doc_id = tostring(supplier_vat or (d.supplier and d.supplier.name) or "?") .. ":"
        .. tostring(d.invoice_number or "?")
    local existing = db.query([[SELECT uuid, status FROM vat_einvoice_documents WHERE namespace_id = ?
        AND direction = 'in' AND document_id = ? LIMIT 1]], reg.namespace_id, doc_id)[1]
    local doc = store(reg.namespace_id, {
        registration_id = reg.id, direction = "in", format = Einvoice.FORMAT, document_id = doc_id:sub(1, 255),
        invoice_number = d.invoice_number and tostring(d.invoice_number):sub(1, 255) or db.NULL,
        issue_date = (d.issue_date and d.issue_date:match("^%d%d%d%d%-%d%d%-%d%d$")) and d.issue_date or db.NULL,
        party_name = d.supplier and d.supplier.name and tostring(d.supplier.name):sub(1, 255) or db.NULL,
        party_vat_id = supplier_vat and tostring(supplier_vat):sub(1, 30) or db.NULL,
        currency = d.currency and tostring(d.currency):sub(1, 3) or db.NULL,
        total = d.totals.tax_inclusive or db.NULL, vat_total = d.totals.tax or db.NULL, valid = res.valid,
        validation = summary(res), status = "received", xml = xml, created_by = actor and actor.id or db.NULL,
    })
    local out = { check = { valid = res.valid, errors = res.errors, warnings = res.warnings }, data = d,
        purchases = purchases, document = doc and doc.uuid, duplicate = existing ~= nil }
    if not record then return out end

    -- Recording: the workspace's purchases only, a valid invoice in pounds, once.
    if not null(reg.user_id) then
        return nil, "Recording e-invoices as purchases is for the workspace's VAT (use ?scope=namespace)", 400
    end
    if existing and existing.status == "recorded" then return nil, "This e-invoice is already recorded", 409 end
    if not res.valid then return nil, "Fix the e-invoice's errors before recording it", 422 end
    if d.currency ~= "GBP" then return nil, "Only invoices in pounds can be recorded for VAT", 422 end
    if not purchases then return nil, perr, 422 end
    local has_vat_cols = has_column("accounting_expenses", "vat_code")
    local ids = {}
    for _, p in ipairs(purchases) do
        local def = VAT.code(p.vat_code)
        local row = {
            namespace_id = reg.namespace_id, expense_date = d.issue_date,
            description = string.format("%s invoice %s (%s)", tostring(d.supplier.name or "Supplier"),
                tostring(d.invoice_number), def.label):sub(1, 1000),
            amount = p.gross, currency = "GBP", category = "Purchases", vendor = d.supplier.name or db.NULL,
            vat_rate = tonumber(p.rate) or 0, vat_amount = p.vat, is_vat_reclaimable = def.reclaimable > 0,
            status = "pending", submitted_by_uuid = actor and actor.uuid or "system",
            metadata = cjson.encode({ einvoice_document = doc and doc.uuid, supplier_vat_id = supplier_vat }),
        }
        if has_vat_cols then
            row.vat_code = p.vat_code
            row.net_amount = p.net
            row.vat_notional = p.notional_vat
            row.vat_reclaimable_pct = def.reclaimable
            row.vat_source = "einvoice"
            row.vat_confidence = 1
            row.vat_reason = "From the supplier's e-invoice"
            row.vat_evidence = cjson.encode({ supplier_vrn = supplier_vat, einvoice = doc and doc.uuid })
        end
        row.uuid = db.raw("gen_random_uuid()::text")
        local ins = db.insert("accounting_expenses", row, "uuid")
        ids[#ids + 1] = (ins[1] or ins).uuid
    end
    db.update("vat_einvoice_documents", { status = "recorded", expense_ids = cjson.encode(ids),
        updated_at = db.raw("NOW()") }, { id = doc.id })
    out.recorded = ids
    out.note = "Added as purchases waiting for approval (Accounting -> Expenses). They count on the VAT return once "
        .. "approved."
    return out
end

-- ---------------------------------------------------------------------------
-- Documents
-- ---------------------------------------------------------------------------

function Q.list(namespace_id, direction)
    local where = "namespace_id = " .. db.escape_literal(namespace_id)
    if direction == "in" or direction == "out" then
        where = where .. " AND direction = " .. db.escape_literal(direction)
    end
    return db.query([[SELECT uuid, direction, format, document_id, invoice_number, issue_date, party_name, party_vat_id,
            currency, total, vat_total, valid, status, created_at, updated_at
        FROM vat_einvoice_documents WHERE ]] .. where .. [[ ORDER BY updated_at DESC LIMIT 200]]) or {}
end

function Q.get(namespace_id, uuid)
    local r = db.query("SELECT * FROM vat_einvoice_documents WHERE uuid = ? AND namespace_id = ? LIMIT 1",
        uuid, namespace_id)[1]
    if not r then return nil, "E-invoice not found", 404 end
    r.validation = decode(r.validation)
    r.expense_ids = decode(r.expense_ids)
    return r
end

return Q
