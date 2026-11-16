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

local valid_date = VAT.valid_date

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
        attribution = not null(r.vat_attribution) and r.vat_attribution or nil,
    }
end

--- The workspaces whose records make up this registration's return: its own, plus
-- the active members when it is a VAT group's representative. Also the member names
-- (supplies to them are inside the group).
function Q.group_namespaces(reg)
    local ids, names = { reg.namespace_id }, {}
    if not null(reg.user_id) then return ids, names end
    local has = db.query("SELECT to_regclass('public.vat_group_members') IS NOT NULL AS ok")[1]
    if not (has and (has.ok == true or has.ok == "t")) then return ids, names end
    for _, m in ipairs(db.query([[SELECT member_namespace_id, member_name FROM vat_group_members
        WHERE group_registration_id = ? AND status = 'active' AND member_namespace_id IS NOT NULL]], reg.id) or {}) do
        ids[#ids + 1] = m.member_namespace_id
        names[#names + 1] = m.member_name
    end
    if #names > 0 and not null(reg.business_name) then names[#names + 1] = reg.business_name end
    return ids, names
end

local function in_list(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = db.escape_literal(id) end
    return "(" .. table.concat(out, ",") .. ")"
end

local function has_table(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)[1]
    return r and (r.ok == true or r.ok == "t")
end

local VAT_COLS = [[t.vat_code, t.net_amount, t.vat_amount, t.vat_notional, t.vat_reclaimable_pct,
    t.vat_attribution, t.vat_source, t.vat_confidence, t.vat_reason, t.vat_review, t.vat_review_reasons,
    t.vat_evidence, t.vat_registration_id, t.vat_decided_at]]

--- A business's lines as one SQL source "(...) l", the same columns whatever the table:
-- src (table), id, uuid, ref, date, dir ('CREDIT' = money in), amount (always positive),
-- description, category, merchant, tax_year, statement_id and the vat_* fields.
--   A person's VAT: their bank lines (tax_transactions).
--   A workspace's VAT (user_id NULL): its accounting bank lines (money out is stored
--   NEGATIVE there) and the approved expenses not paid through one, across a VAT group's
--   members: exactly what the return reads.
-- @return the SQL, or nil when none of those tables exist in this deployment
function Q.lines_from(reg)
    local parts = {}
    if not null(reg.user_id) then
        if has_table("tax_transactions") then
            parts[1] = [[SELECT 'tax_transactions' AS src, t.id, t.uuid, 't' || t.id AS ref,
                t.transaction_date AS date, t.transaction_type AS dir, t.amount, t.description, t.category,
                t.cleaned_merchant_name AS merchant, s.tax_year::text AS tax_year,
                t.statement_id::bigint AS statement_id,
                ]] .. VAT_COLS .. [[ FROM tax_transactions t LEFT JOIN tax_statements s ON s.id = t.statement_id
                WHERE t.user_id = ]] .. db.escape_literal(reg.user_id) .. " AND t.namespace_id = "
                .. db.escape_literal(reg.namespace_id)
        end
    else
        local ns = in_list((Q.group_namespaces(reg)))
        if has_table("accounting_bank_transactions") then
            parts[#parts + 1] = [[SELECT 'accounting_bank_transactions' AS src, t.id, t.uuid, 'b' || t.id AS ref,
                t.transaction_date AS date, upper(t.transaction_type) AS dir, abs(t.amount) AS amount, t.description,
                t.category, t.payee AS merchant, NULL::text AS tax_year, NULL::bigint AS statement_id,
                ]] .. VAT_COLS .. [[ FROM accounting_bank_transactions t
                WHERE t.namespace_id IN ]] .. ns .. " AND t.deleted_at IS NULL"
        end
        if has_table("accounting_expenses") then
            parts[#parts + 1] = [[SELECT 'accounting_expenses' AS src, t.id, t.uuid, 'e' || t.id AS ref,
                t.expense_date AS date, 'DEBIT' AS dir, abs(t.amount) AS amount, t.description, t.category,
                t.vendor AS merchant, NULL::text AS tax_year, NULL::bigint AS statement_id,
                ]] .. VAT_COLS .. [[ FROM accounting_expenses t
                WHERE t.namespace_id IN ]] .. ns .. [[ AND t.deleted_at IS NULL AND t.bank_transaction_id IS NULL
                  AND t.status IN ('approved', 'posted')]]
        end
    end
    if #parts == 0 then return nil end
    return "(" .. table.concat(parts, " UNION ALL ") .. ") l"
end

--- WHERE pieces for the optional line filters { tax_year, statement_id, period_start,
-- period_end }. Tax years and statements are a person's (tax_transactions) only.
function Q.line_filters(reg, opts)
    opts = opts or {}
    local w = {}
    if not null(reg.user_id) then
        if opts.tax_year and opts.tax_year ~= "" then
            w[#w + 1] = "l.tax_year = " .. db.escape_literal(opts.tax_year)
        end
        if tonumber(opts.statement_id) then
            w[#w + 1] = "l.statement_id = " .. db.escape_literal(tonumber(opts.statement_id))
        end
    end
    if valid_date(opts.period_start) and valid_date(opts.period_end) then
        w[#w + 1] = "l.date BETWEEN " .. db.escape_literal(opts.period_start) .. " AND "
            .. db.escape_literal(opts.period_end)
    end
    return w
end

--- Write VAT fields to one line of a lines_from() source (where_extra: "AND ..." with ? args).
function Q.write_line(src, id, fields, where_extra, ...)
    if src ~= "tax_transactions" then fields.is_vat_applicable = nil end -- only that table has it
    if where_extra then
        return db.update(src, fields, "id = ? " .. where_extra, id, ...)
    end
    return db.update(src, fields, { id = id })
end

--- The VAT-coded lines (and the count of uncoded ones) for a business and period.
function Q.collect_lines(reg, period_start, period_end)
    local from = Q.lines_from(reg)
    local rows = from and db.query([[SELECT l.ref, l.date, l.dir, l.amount, l.description, l.vat_code,
            l.net_amount, l.vat_amount, l.vat_notional, l.vat_reclaimable_pct, l.vat_attribution
        FROM ]] .. from .. " WHERE l.date BETWEEN ? AND ?", period_start, period_end)
    rows = rows or {}
    local notes = {}
    local inv_lines = {}
    if null(reg.user_id) then
        local ids, member_names = Q.group_namespaces(reg)
        for _, ns_id in ipairs(ids) do
            local part = {}
            for k, v in pairs(reg) do part[k] = v end
            part.namespace_id = ns_id
            local l2, n2 = Q.invoice_lines(part, period_start, period_end)
            for _, l in ipairs(l2) do inv_lines[#inv_lines + 1] = l end
            for _, n in ipairs(n2) do notes[#notes + 1] = n end
        end
        -- Invoices to another member of the VAT group are inside the group.
        if #member_names > 0 then
            local lower = {}
            for _, nm in ipairs(member_names) do lower[nm:lower()] = true end
            for _, l in ipairs(inv_lines) do
                if l.customer_name and lower[tostring(l.customer_name):lower()] then l.intra_group = true end
            end
            notes[#notes + 1] = "VAT group: invoices to other members are left off. Code bank payments "
                .. "between members as Outside the scope."
        end
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
    local cv = db.query([[SELECT 1 FROM information_schema.columns WHERE table_name = 'invoices'
        AND column_name = 'customer_vat_number']])
    local vat_col = (cv and #cv > 0) and "i.customer_vat_number" or "NULL"
    local invs = db.query([[SELECT i.id, i.invoice_number, i.status, i.issue_date, i.tax_point, i.currency,
            i.customer_name, ]] .. vat_col .. [[ AS customer_vat_number
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

--- The negative margin carried forward from the latest earlier return (margin scheme).
function Q.margin_brought_forward(reg, period_start)
    local prev = db.query([[SELECT calculation FROM vat_returns WHERE registration_id = ? AND period_end < ?
        AND status IN ('draft', 'submitting', 'submitted') ORDER BY period_end DESC,
        (status = 'submitted') DESC, id DESC LIMIT 1]], reg.id, period_start)[1]
    if not prev then return 0 end
    local c = prev.calculation
    if type(c) == "string" then
        local ok, t = pcall(cjson.decode, c); c = ok and t or nil
    end
    local m = type(c) == "table" and type(c.margin) == "table" and tonumber(c.margin.carried_forward) or 0
    return m or 0
end

--- The VAT group this registration's workspace is a member of (not as representative), or nil.
function Q.group_of(reg)
    if not null(reg.user_id) then return nil end
    local has = db.query("SELECT to_regclass('public.vat_group_members') IS NOT NULL AS ok")[1]
    if not (has and (has.ok == true or has.ok == "t")) then return nil end
    return db.query([[SELECT m.uuid, m.member_name, r.business_name AS group_name, r.vrn AS group_vrn
        FROM vat_group_members m JOIN vat_registrations r ON r.id = m.group_registration_id
        WHERE m.member_namespace_id = ? AND m.status = 'active' AND m.group_registration_id <> ? LIMIT 1]],
        reg.namespace_id, reg.id)[1]
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
        margin_brought_forward = Q.margin_brought_forward(reg, period_start),
    })
    local group = Q.group_of(reg)
    if group then
        table.insert(result.warnings, 1, "This workspace is in a VAT group (" .. tostring(group.group_name or "")
            .. "): the group's representative files one return for every member.")
        result.group_member_of = group
    end
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
            flat_rate = res.flat_rate, partial_exemption = res.partial_exemption, margin = res.margin,
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
    elseif f.type == "cgs" or f.type == "pe_annual" then
        ok, err = money("vat", true); if not ok then return nil, err, 400 end
        if f.capital_item_id then
            -- Only this business's own capital item (ids are sequential).
            local item = db.query("SELECT id FROM vat_capital_items WHERE id = ? AND registration_id = ?",
                tonumber(f.capital_item_id) or 0, reg.id)[1]
            if not item then return nil, "Capital item not found", 404 end
            row.capital_item_id = item.id
        end
        if f.interval_no then row.interval_no = tonumber(f.interval_no) end
    elseif f.type == "correction" then
        ok, err = money("box1"); if not ok then return nil, err, 400 end
        ok, err = money("box4"); if not ok then return nil, err, 400 end
        if row.box1 == nil and row.box4 == nil then return nil, "Give the Box 1 and/or Box 4 correction", 400 end
    else
        return nil, "type must be fuel_scale, bad_debt_relief, correction, cgs or pe_annual", 400
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
