-- luacheck: max line length 140
--[[
    Purchase invoices: every supplier invoice, proforma and credit note, across purchase orders
    =============================================================================================
    The records are the supplier portal's (purchase_order_supplier_invoices, recorded by staff on the PO page
    or uploaded by the supplier); this is the list for the accounts side: what we owe, what is overdue, what
    is paid. GET /api/v2/purchase-invoices (routes/supplier-portal.lua, RBAC purchase_orders read).

    What is paid: money we sent the supplier on a PO (purchase_order_payments, not voided) plus its credit
    notes, used up by the PO's final invoices oldest first (invoice date, then when recorded). So a payment
    recorded against a proforma or against the PO alone still pays the final invoice that follows it, and
    the sum over a PO's invoices never exceeds what was paid. Proformas and credit notes are listed for the
    record (state proforma / credit) and never count as owed.

    State of a final invoice: paid (nothing left) | overdue (something left and the due date has passed) |
    part_paid | unpaid.

      list(ns_id, params)   params { q?, state? (owed | overdue | paid | unpaid | part_paid | proforma | credit),
                            kind?, supplier?, from?, to? (invoice dates), limit? (≤ 200), offset? }
                            → rows, { total, limit, offset, summary = { currency → { owed, overdue, paid,
                              owed_count, overdue_count } } }

    Specced by spec/purchase-invoices_spec.lua.
]]

local db = require("lapis.db")
local U = require("lib.shop-util")

local Q = {}

Q.STATES = { owed = true, overdue = true, paid = true, unpaid = true, part_paid = true, proforma = true, credit = true }
Q.KINDS = { invoice = true, proforma = true, credit_note = true }

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return r and r[1] and r[1].ok == true
end

function Q.available()
    return table_exists("purchase_order_supplier_invoices") and table_exists("purchase_order_payments")
end

-- Every invoice of the workspace with what is paid on it and its state (one CTE, filtered afterwards so the
-- oldest-first allocation always sees the PO's whole history).
local BASE = [[
WITH pay AS (
    SELECT purchase_order_id, SUM(amount) AS s FROM purchase_order_payments
     WHERE namespace_id = ? AND voided_at IS NULL GROUP BY purchase_order_id
), cred AS (
    SELECT purchase_order_id, SUM(total) AS s FROM purchase_order_supplier_invoices
     WHERE namespace_id = ? AND deleted_at IS NULL AND kind = 'credit_note' GROUP BY purchase_order_id
), inv AS (
    SELECT i.uuid, i.kind, i.number, i.invoice_date, i.due_date, i.net, i.vat, i.total, i.currency, i.supplier_order_ref,
           i.payment_terms, i.document_id IS NOT NULL AS has_document, i.created_by_kind, i.created_at,
           po.uuid AS po_uuid, po.po_number, po.supplier_name, po.reference AS po_reference,
           COALESCE(pay.s, 0) + COALESCE(cred.s, 0) AS pool,
           COALESCE(SUM(CASE WHEN i.kind = 'invoice' THEN i.total ELSE 0 END) OVER (
               PARTITION BY i.purchase_order_id ORDER BY i.invoice_date, i.created_at, i.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS before
      FROM purchase_order_supplier_invoices i
      JOIN purchase_orders po ON po.id = i.purchase_order_id AND po.namespace_id = i.namespace_id AND po.deleted_at IS NULL
      LEFT JOIN pay ON pay.purchase_order_id = i.purchase_order_id
      LEFT JOIN cred ON cred.purchase_order_id = i.purchase_order_id
     WHERE i.namespace_id = ? AND i.deleted_at IS NULL
), paid AS (
    SELECT inv.*, CASE WHEN kind = 'invoice' THEN LEAST(total, GREATEST(0, pool - before)) ELSE 0 END AS paid FROM inv
), x AS (
    SELECT paid.*, CASE WHEN kind = 'invoice' THEN total - paid ELSE 0 END AS outstanding,
           CASE WHEN kind = 'proforma' THEN 'proforma'
                WHEN kind = 'credit_note' THEN 'credit'
                WHEN paid >= total THEN 'paid'
                WHEN due_date IS NOT NULL AND due_date < CURRENT_DATE THEN 'overdue'
                WHEN paid > 0 THEN 'part_paid'
                ELSE 'unpaid' END AS state
      FROM paid
)
]]

local function valid_date(s)
    return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

--- WHERE parts on x for the filters. → sql, values | nil, err
function Q.filters(params)
    local where, vals = {}, {}
    if U.nz(params.state) then
        if not Q.STATES[params.state] then
            return nil, U.err(400, "VALIDATION_ERROR", "state must be owed, overdue, paid, unpaid, part_paid, proforma or credit")
        end
        if params.state == "owed" then
            where[#where + 1] = "state IN ('unpaid', 'part_paid', 'overdue')"
        else
            where[#where + 1] = "state = ?"
            vals[#vals + 1] = params.state
        end
    end
    if U.nz(params.kind) then
        if not Q.KINDS[params.kind] then return nil, U.err(400, "VALIDATION_ERROR", "kind must be invoice, proforma or credit_note") end
        where[#where + 1] = "kind = ?"
        vals[#vals + 1] = params.kind
    end
    for key, op in pairs({ from = ">=", to = "<=" }) do
        if U.nz(params[key]) then
            if not valid_date(params[key]) then return nil, U.err(400, "VALIDATION_ERROR", key .. " must be a date (YYYY-MM-DD)") end
            where[#where + 1] = "invoice_date " .. op .. " ?::date"
            vals[#vals + 1] = params[key]
        end
    end
    if U.nz(params.supplier) then
        where[#where + 1] = "supplier_name ILIKE ?"
        vals[#vals + 1] = U.cut(tostring(params.supplier), 120):gsub("[%%_\\]", "\\%0")
    end
    if U.nz(params.q) then
        local like = "%" .. U.cut(tostring(params.q), 120):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(number ILIKE ? OR supplier_name ILIKE ? OR po_number ILIKE ? OR supplier_order_ref ILIKE ? "
            .. "OR po_reference ILIKE ?)"
        for _ = 1, 5 do vals[#vals + 1] = like end
    end
    return (#where > 0 and (" WHERE " .. table.concat(where, " AND ")) or ""), vals
end

local function n(v) return tonumber(v) or 0 end
local function money(v) return string.format("%.2f", n(v)) end

local unpack_ = table.unpack or unpack -- luacheck: ignore 113 143

function Q.list(ns_id, params)
    params = params or {}
    if not Q.available() then return {}, { total = 0, limit = 0, offset = 0, summary = {} } end
    local limit = U.clamp(U.int(params.limit, 50), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = Q.filters(params)
    if not where then return nil, vals end

    local head = { ns_id, ns_id, ns_id }
    local args = {}
    for _, v in ipairs(head) do args[#args + 1] = v end
    for _, v in ipairs(vals) do args[#args + 1] = v end
    args[#args + 1] = limit
    args[#args + 1] = offset
    local rows = db.query(BASE .. [[
        SELECT x.*, invoice_date::text AS invoice_date_s, due_date::text AS due_date_s,
               CASE WHEN due_date IS NOT NULL THEN (CURRENT_DATE - due_date) END AS days_late,
               COUNT(*) OVER () AS total_count
          FROM x]] .. where .. [[
         ORDER BY (state = 'overdue') DESC, invoice_date DESC, created_at DESC
         LIMIT ? OFFSET ?]], unpack_(args))

    -- Totals for the cards, per currency, over the same filters (not the page).
    local sargs = {}
    for _, v in ipairs(head) do sargs[#sargs + 1] = v end
    for _, v in ipairs(vals) do sargs[#sargs + 1] = v end
    local sums = db.query(BASE .. [[
        SELECT currency,
               COALESCE(SUM(outstanding) FILTER (WHERE state IN ('unpaid','part_paid','overdue')), 0) AS owed,
               COUNT(*) FILTER (WHERE state IN ('unpaid','part_paid','overdue')) AS owed_count,
               COALESCE(SUM(outstanding) FILTER (WHERE state = 'overdue'), 0) AS overdue,
               COUNT(*) FILTER (WHERE state = 'overdue') AS overdue_count,
               COALESCE(SUM(paid) FILTER (WHERE kind = 'invoice'), 0) AS paid
          FROM x]] .. where .. [[ GROUP BY currency]], unpack_(sargs))
    local summary = {}
    for _, s in ipairs(sums) do
        summary[s.currency or "GBP"] = { owed = money(s.owed), overdue = money(s.overdue), paid = money(s.paid),
            owed_count = n(s.owed_count), overdue_count = n(s.overdue_count) }
    end

    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            uuid = r.uuid, kind = r.kind, number = r.number, state = r.state,
            invoice_date = r.invoice_date_s, due_date = U.nz(r.due_date_s) or U.null,
            days_late = (r.state == "overdue" and tonumber(r.days_late)) or U.null,
            net = money(r.net), vat = money(r.vat), total = money(r.total), paid = money(r.paid),
            outstanding = money(r.outstanding), currency = r.currency or "GBP",
            supplier_name = r.supplier_name, supplier_order_ref = U.nz(r.supplier_order_ref) or U.null,
            payment_terms = U.nz(r.payment_terms) or U.null, has_document = r.has_document == true,
            recorded_by = r.created_by_kind, purchase_order = { uuid = r.po_uuid, po_number = r.po_number },
        }
    end
    local total = rows[1] and n(rows[1].total_count) or 0
    return U.arr(out), { total = total, limit = limit, offset = offset, summary = summary }
end

return Q
