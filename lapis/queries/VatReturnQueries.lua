--[[
    VAT returns (VAT plan phase 2): gather a business's VAT-coded lines for a period,
    build the 9 boxes with lib/vat-return.lua, keep drafts, show the lines behind each
    box, and manage adjustments (fuel scale, bad debt relief, earlier errors).

    A person's business (vat_registrations.user_id set) reads their bank lines
    (tax_transactions). A namespace's business (user_id NULL, accounting) reads the
    accounting bank lines plus expenses not paid through one (no double counting).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local VAT = require("lib.vat")
local Return = require("lib.vat-return")
local VatInvoice = require("lib.vat-invoice")

local Q = {}

local function null(v) return v == nil or v == db.NULL or (ngx and v == ngx.null) end

local function valid_date(s) return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil end

--- Check a period. @return months (approx) or nil + message
function Q.check_period(period_start, period_end)
    if not valid_date(period_start) or not valid_date(period_end) then
        return nil, "Give period_start and period_end like 2026-01-01 and 2026-03-31"
    end
    if period_end < period_start then return nil, "The period ends before it starts" end
    local m = (Return._months_between(period_start, period_end) or 0) + 1
    if m > 13 then return nil, "A VAT period is at most 12 months" end
    return math.max(1, m)
end

local function to_line(r, direction)
    return {
        id = r.ref, date = r.date, direction = direction, vat_code = not null(r.vat_code) and r.vat_code or nil,
        net = tonumber(r.net_amount), vat = tonumber(r.vat_amount) or 0, notional_vat = tonumber(r.vat_notional) or 0,
        reclaimable_pct = not null(r.vat_reclaimable_pct) and tonumber(r.vat_reclaimable_pct) or nil,
        gross = math.abs(tonumber(r.amount) or 0), description = r.description,
    }
end

--- The VAT-coded lines (and the count of uncoded ones) for a business and period.
function Q.collect_lines(reg, period_start, period_end)
    local rows
    if not null(reg.user_id) then
        rows = db.query([[SELECT 't' || t.id AS ref, t.transaction_date AS date, t.transaction_type AS dir,
                t.amount, t.description, t.vat_code, t.net_amount, t.vat_amount, t.vat_notional,
                t.vat_reclaimable_pct
            FROM tax_transactions t
            WHERE t.namespace_id = ? AND t.user_id = ? AND t.transaction_date BETWEEN ? AND ?]],
            reg.namespace_id, reg.user_id, period_start, period_end)
    else
        rows = db.query([[SELECT 'b' || b.id AS ref, b.transaction_date AS date, upper(b.transaction_type) AS dir,
                b.amount, b.description, b.vat_code, b.net_amount, b.vat_amount, b.vat_notional,
                b.vat_reclaimable_pct
            FROM accounting_bank_transactions b
            WHERE b.namespace_id = ? AND b.deleted_at IS NULL AND b.transaction_date BETWEEN ? AND ?
            UNION ALL
            SELECT 'e' || e.id, e.expense_date, 'DEBIT', e.amount, e.description, e.vat_code, e.net_amount,
                e.vat_amount, e.vat_notional, e.vat_reclaimable_pct
            FROM accounting_expenses e
            WHERE e.namespace_id = ? AND e.deleted_at IS NULL AND e.bank_transaction_id IS NULL
              AND e.status IN ('approved', 'posted') AND e.expense_date BETWEEN ? AND ?]],
            reg.namespace_id, period_start, period_end, reg.namespace_id, period_start, period_end)
    end
    rows = rows or {}
    local notes = {}
    local inv_lines = {}
    if null(reg.user_id) then
        inv_lines, notes = Q.invoice_lines(reg, period_start, period_end)
        local mode = reg.sales_from or "auto"
        local use_invoices = mode == "invoices" or (mode == "auto" and #inv_lines > 0)
        if use_invoices then
            -- Sales come from the invoices: customer payments in the bank aren't sales again.
            local kept = {}
            for _, r in ipairs(rows) do if r.dir ~= "CREDIT" then kept[#kept + 1] = r end end
            rows = kept
            notes[#notes + 1] = "Sales are taken from your issued invoices; money received in the bank isn't "
                .. "counted again."
        else
            inv_lines = {}
        end
    end
    local lines, uncoded = {}, 0
    for _, r in ipairs(rows) do
        local direction = (r.dir == "CREDIT") and "sale" or "purchase"
        if null(r.vat_code) or null(r.net_amount) then
            uncoded = uncoded + 1
        else
            lines[#lines + 1] = to_line(r, direction)
        end
    end
    for _, l in ipairs(inv_lines) do
        lines[#lines + 1] = l
        -- So the drill-down can show invoice lines too.
        rows[#rows + 1] = { ref = l.id, date = l.date, description = l.description, amount = l.gross,
            vat_code = l.vat_code, net_amount = l.net, vat_amount = l.vat, vat_notional = l.notional_vat,
            dir = "CREDIT" }
    end
    return lines, uncoded, rows, notes
end

--- Engine sale lines from a workspace's issued invoices for a period (lib/vat-invoice),
-- plus notes about invoices left out (not in pounds, rates that aren't UK VAT rates).
function Q.invoice_lines(reg, period_start, period_end)
    local has = db.query("SELECT to_regclass('public.invoices') IS NOT NULL AS ok")[1]
    if not (has and (has.ok == true or has.ok == "t")) then return {}, {} end
    local invs = db.query([[SELECT i.id, i.invoice_number, i.status, i.issue_date, i.tax_point, i.currency
        FROM invoices i
        WHERE i.namespace_id = ? AND i.deleted_at IS NULL
          AND i.status IN ('sent', 'paid', 'partially_paid', 'overdue')
          AND (COALESCE(i.tax_point, i.issue_date) BETWEEN ? AND ?
               OR EXISTS (SELECT 1 FROM invoice_payments p WHERE p.invoice_id = i.id
                          AND p.payment_date BETWEEN ? AND ?))]],
        reg.namespace_id, period_start, period_end, period_start, period_end) or {}
    if #invs == 0 then return {}, {} end
    local ids = {}
    for _, i in ipairs(invs) do ids[#ids + 1] = db.escape_literal(i.id) end
    local by_inv = {}
    for _, l in ipairs(db.query("SELECT * FROM invoice_line_items WHERE invoice_id IN (" .. table.concat(ids, ",")
        .. ") ORDER BY invoice_id, sort_order, id") or {}) do
        by_inv[l.invoice_id] = by_inv[l.invoice_id] or {}
        table.insert(by_inv[l.invoice_id], l)
    end
    local pays = {}
    for _, p in ipairs(db.query("SELECT invoice_id, amount, payment_date FROM invoice_payments WHERE invoice_id IN ("
        .. table.concat(ids, ",") .. ")") or {}) do
        pays[p.invoice_id] = pays[p.invoice_id] or {}
        table.insert(pays[p.invoice_id], p)
    end
    for _, i in ipairs(invs) do
        i.lines = by_inv[i.id] or {}
        i.payments = pays[i.id] or {}
        if not null(i.tax_point) then i.tax_point = tostring(i.tax_point) else i.tax_point = nil end
        i.issue_date = tostring(i.issue_date)
    end
    local lines, skipped = VatInvoice.engine_lines(invs, { period_start = period_start, period_end = period_end,
        scheme = reg.scheme })
    local notes = {}
    if skipped.foreign_currency > 0 then
        notes[#notes + 1] = skipped.foreign_currency .. " invoice(s) aren't in pounds and were left out: the VAT "
            .. "return needs the sterling figures."
    end
    if skipped.unknown_rate > 0 then
        notes[#notes + 1] = skipped.unknown_rate .. " invoice line(s) use a tax rate that isn't a UK VAT rate and "
            .. "were left out."
    end
    return lines, notes
end

function Q.list_adjustments(reg, period_start, period_end)
    return db.query([[SELECT * FROM vat_adjustments WHERE registration_id = ?
        AND period_start = ? AND period_end = ? ORDER BY id]], reg.id, period_start, period_end) or {}
end

local function adj_for_engine(rows)
    local out = {}
    for _, a in ipairs(rows) do
        out[#out + 1] = { id = a.uuid, type = a.type, vat = tonumber(a.vat), net = tonumber(a.net),
            box1 = tonumber(a.box1), box4 = tonumber(a.box4),
            due_date = not null(a.due_date) and a.due_date or nil, written_off = a.written_off }
    end
    return out
end

--- Build (without saving) the return for a period.
-- opts: { relevant_goods_gross? }  @return result or nil, message
function Q.preview(reg, period_start, period_end, opts)
    opts = opts or {}
    local months, err = Q.check_period(period_start, period_end)
    if not months then return nil, err end
    local lines, uncoded, _, notes = Q.collect_lines(reg, period_start, period_end)
    local adjustments = Q.list_adjustments(reg, period_start, period_end)
    local result = Return.build(lines, reg, {
        period_start = period_start, period_end = period_end, period_months = months,
        adjustments = adj_for_engine(adjustments),
        relevant_goods_gross = tonumber(opts.relevant_goods_gross),
    })
    result.period = { start = period_start, ["end"] = period_end,
        due_date = VAT.due_date(period_end, reg.scheme) }
    result.line_count = #lines
    result.uncoded_count = uncoded
    if uncoded > 0 then
        table.insert(result.warnings, 1, uncoded .. " line(s) in this period have no VAT code yet and are "
            .. "left out. Code them before filing.")
    end
    for _, n in ipairs(notes or {}) do table.insert(result.notes, n) end
    local ok_valid, errs = Return.validate(result.boxes)
    result.valid = ok_valid
    result.validation = ok_valid and nil or errs
    return result
end

--- Save (or refresh) the draft return for a period.
function Q.save_draft(reg, period_start, period_end, actor_id, opts)
    local done = db.query([[SELECT uuid FROM vat_returns WHERE registration_id = ? AND period_start = ?
        AND period_end = ? AND status IN ('submitting', 'submitted') LIMIT 1]], reg.id, period_start, period_end)
    if done and #done > 0 then return nil, "The return for this period has already been filed.", 409 end
    local res, err = Q.preview(reg, period_start, period_end, opts)
    if not res then return nil, err, 400 end
    local row = {
        box1 = res.boxes.box1, box2 = res.boxes.box2, box3 = res.boxes.box3, box4 = res.boxes.box4,
        box5 = res.boxes.box5, box6 = res.boxes.box6, box7 = res.boxes.box7, box8 = res.boxes.box8,
        box9 = res.boxes.box9, direction = res.direction, scheme = reg.scheme,
        line_count = res.line_count, uncoded_count = res.uncoded_count,
        due_date = res.period.due_date or db.NULL,
        calculation = cjson.encode({ warnings = res.warnings, notes = res.notes, audit = res.audit,
            flat_rate = res.flat_rate, partial_exemption = res.partial_exemption,
            corrections = res.corrections, valid = res.valid, validation = res.validation }),
        updated_at = db.raw("NOW()"),
    }
    local existing = db.query([[SELECT id FROM vat_returns WHERE registration_id = ? AND period_start = ?
        AND period_end = ? AND status = 'draft' LIMIT 1]], reg.id, period_start, period_end)
    if existing and existing[1] then
        db.update("vat_returns", row, { id = existing[1].id })
    else
        row.registration_id = reg.id
        row.namespace_id = reg.namespace_id
        row.period_start = period_start
        row.period_end = period_end
        row.created_by = actor_id
        db.insert("vat_returns", row)
    end
    return Q.get(reg, nil, { period_start = period_start, period_end = period_end, status = "draft" })
end

local function decode(v)
    if type(v) == "table" then return v end
    if type(v) ~= "string" or v == "" then return nil end
    local ok, t = pcall(cjson.decode, v)
    return ok and t or nil
end

function Q.list(reg)
    return db.query([[SELECT uuid, period_start, period_end, period_key, due_date, status, box1, box3, box4,
            box5, box6, box7, direction, line_count, uncoded_count, submitted_at, updated_at
        FROM vat_returns WHERE registration_id = ? ORDER BY period_end DESC, id DESC]], reg.id) or {}
end

--- One return. With opts.lines, also the lines behind each box (the audit trail).
function Q.get(reg, uuid, opts)
    opts = opts or {}
    local row
    if uuid then
        row = db.query("SELECT * FROM vat_returns WHERE uuid = ? AND registration_id = ? LIMIT 1", uuid, reg.id)[1]
    else
        row = db.query([[SELECT * FROM vat_returns WHERE registration_id = ? AND period_start = ? AND period_end = ?
            AND status = ? ORDER BY id DESC LIMIT 1]], reg.id, opts.period_start, opts.period_end, opts.status)[1]
    end
    if not row then return nil, "VAT return not found", 404 end
    row.calculation = decode(row.calculation)
    row.hmrc_receipt = decode(row.hmrc_receipt)
    if opts.lines and row.calculation and row.calculation.audit then
        local _, _, all = Q.collect_lines(reg, row.period_start, row.period_end)
        local by_ref = {}
        for _, r in ipairs(all) do by_ref[r.ref] = r end
        local adj_by = {}
        for _, a in ipairs(Q.list_adjustments(reg, row.period_start, row.period_end)) do
            adj_by["adj:" .. a.uuid] = a
        end
        local boxes = {}
        for box, refs in pairs(row.calculation.audit) do
            local list = {}
            for _, ref in ipairs(refs) do
                local r = by_ref[ref]
                if r then
                    list[#list + 1] = { ref = ref, date = r.date, description = r.description, amount = r.amount,
                        vat_code = r.vat_code, net = r.net_amount, vat = r.vat_amount, notional_vat = r.vat_notional,
                        reclaimable_pct = r.vat_reclaimable_pct }
                elseif adj_by[ref] then
                    local a = adj_by[ref]
                    list[#list + 1] = { ref = ref, adjustment = a.type, description = a.description,
                        vat = a.vat, net = a.net, box1 = a.box1, box4 = a.box4 }
                end
            end
            boxes[box] = list
        end
        row.lines_by_box = boxes
    end
    return row
end

-- ---------------------------------------------------------------------------
-- Adjustments
-- ---------------------------------------------------------------------------

function Q.create_adjustment(reg, f, actor_id)
    f = f or {}
    local months, perr = Q.check_period(f.period_start, f.period_end)
    if not months then return nil, perr, 400 end
    local filed = db.query([[SELECT 1 FROM vat_returns WHERE registration_id = ? AND period_start = ?
        AND period_end = ? AND status IN ('submitting', 'submitted')]], reg.id, f.period_start, f.period_end)
    if filed and #filed > 0 then return nil, "That period's return has already been filed.", 409 end
    local row = { registration_id = reg.id, period_start = f.period_start, period_end = f.period_end,
        type = f.type, description = f.description and tostring(f.description):sub(1, 1000) or db.NULL,
        created_by = actor_id }
    local function money(k, required)
        local v = f[k]
        if v == nil or v == "" then
            if required then return nil, k .. " is required" end
            return true
        end
        v = tonumber(v)
        if not v then return nil, k .. " must be a number" end
        row[k] = VAT.round2(v)
        return true
    end
    local ok, err
    if f.type == "fuel_scale" then
        ok, err = money("vat", true); if not ok then return nil, err, 400 end
        ok, err = money("net", true); if not ok then return nil, err, 400 end
    elseif f.type == "bad_debt_relief" then
        ok, err = money("vat", true); if not ok then return nil, err, 400 end
        if not valid_date(f.due_date) then return nil, "due_date (when the invoice was due) is required", 400 end
        row.due_date = f.due_date
        row.written_off = f.written_off == true or f.written_off == "true"
    elseif f.type == "correction" then
        ok, err = money("box1"); if not ok then return nil, err, 400 end
        ok, err = money("box4"); if not ok then return nil, err, 400 end
        if row.box1 == nil and row.box4 == nil then return nil, "Give the Box 1 and/or Box 4 correction", 400 end
    else
        return nil, "type must be fuel_scale, bad_debt_relief or correction", 400
    end
    db.insert("vat_adjustments", row)
    return db.query([[SELECT * FROM vat_adjustments WHERE registration_id = ? ORDER BY id DESC LIMIT 1]], reg.id)[1]
end

function Q.delete_adjustment(reg, uuid)
    local a = db.query("SELECT * FROM vat_adjustments WHERE uuid = ? AND registration_id = ? LIMIT 1",
        uuid, reg.id)[1]
    if not a then return nil, "Adjustment not found", 404 end
    local filed = db.query([[SELECT 1 FROM vat_returns WHERE registration_id = ? AND period_start = ?
        AND period_end = ? AND status IN ('submitting', 'submitted')]], reg.id, a.period_start, a.period_end)
    if filed and #filed > 0 then return nil, "That period's return has already been filed.", 409 end
    db.query("DELETE FROM vat_adjustments WHERE id = ?", a.id)
    return true
end

return Q
