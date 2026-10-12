--[[
    Purchase Order Queries
    ======================

    Business logic for supplier purchase orders: numbering, CRUD, line items,
    the status workflow, goods receipt, bills (several per PO), close short
    and voiding a bill.

    Every read and write is scoped by namespace_id (purchase_order_items carries
    its own namespace_id too). Functions return `value` on success or
    `nil, message, code` on failure, where code is one of:
        "not_found" (404), "invalid" (400), "conflict" (409 - wrong status)

    Status workflow (enforced by canTransition):
        draft -> sent -> acknowledged -> partially_received -> received -> billed
        draft | sent | acknowledged -> cancelled
        sent / acknowledged may jump straight to (partially_)received

    Bills: a (partially) received PO can be billed any number of times; each
    bill covers what was received and not yet billed (billed_quantity per
    line, plus the pennies billed so the bills of a line always add up to it)
    and is kept in metadata.bills[]. The status follows the goods, so a
    partly billed PO stays open for receipts; it becomes `billed` once every
    line is received and billed, or when it is closed short (no more goods
    coming: partially_received -> received, or -> billed if nothing is left to
    bill). Voiding a bill whose ledger expense is still pending rolls its
    quantities back (billed -> received).

    Money is worked out in Postgres NUMERIC from the stored values, one rule
    everywhere: net = ROUND(qty x price, 2), tax = ROUND(net x rate %, 2).
    Inputs are checked once at the boundary (price 2 dp, qty 3 dp, rate 2 dp).
]]

local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson.safe")
local unpack = table.unpack or unpack -- luacheck: ignore 143 113

local PurchaseOrderQueries = {}

-- ============================================================
-- Status workflow (pure; covered by spec/purchase-orders_spec.lua)
-- ============================================================

PurchaseOrderQueries.STATUSES = {
    "draft", "sent", "acknowledged", "partially_received", "received", "billed", "cancelled",
}

local TRANSITIONS = {
    draft = { sent = true, cancelled = true },
    sent = { acknowledged = true, partially_received = true, received = true, cancelled = true },
    acknowledged = { partially_received = true, received = true, cancelled = true },
    -- -> received when the rest arrives or it is closed short; -> billed when
    -- closed short with everything received already billed.
    partially_received = { partially_received = true, received = true, billed = true },
    received = { billed = true },
    billed = { received = true }, -- a bill was voided
    cancelled = {},
}
PurchaseOrderQueries.TRANSITIONS = TRANSITIONS

-- Header fields can change until goods start arriving; lines only while draft.
local HEADER_EDITABLE = { draft = true, sent = true, acknowledged = true }
local ITEMS_EDITABLE = { draft = true }
-- Goods can arrive until the PO is fully received or closed; bills follow receipts.
local RECEIVABLE = { sent = true, acknowledged = true, partially_received = true }
local BILLABLE = { partially_received = true, received = true }

-- The accounting purchase ledger records this currency only (journals, VAT
-- returns and the ledger UI sum amounts without conversion).
PurchaseOrderQueries.LEDGER_CURRENCY = "GBP"

--- Is `from -> to` an allowed status change?
function PurchaseOrderQueries.canTransition(from, to)
    local allowed = TRANSITIONS[from]
    return allowed ~= nil and allowed[to] == true
end

function PurchaseOrderQueries.isValidStatus(status)
    return TRANSITIONS[status] ~= nil
end

-- Half away from zero, like Postgres ROUND(numeric, 2). The nudge stops a
-- double just under a half penny (1.005 is stored as 1.00499...) rounding down.
local function round2(n)
    n = tonumber(n) or 0
    local sign = n < 0 and -1 or 1
    return sign * math.floor(math.abs(n) * 100 + 0.5 + 1e-9) / 100
end
PurchaseOrderQueries._round2 = round2

--- A non-negative decimal with at most `places` decimals and `int_digits`
-- integer digits, as exact text for a NUMERIC column. JSON numbers arrive as
-- doubles; %.15g gives back what was typed (0.1 + 0.2 -> "0.3").
-- @return string | nil when it isn't one
function PurchaseOrderQueries.decimal(v, places, int_digits)
    if type(v) == "number" then
        if v ~= v or v < 0 or v == math.huge then return nil end
        v = string.format("%.15g", v)
    end
    if type(v) ~= "string" then return nil end
    local int, frac = v:match("^%s*(%d*)%.?(%d*)%s*$")
    if not int or (int == "" and frac == "") then return nil end
    int, frac = (int:gsub("^0+", "")), (frac:gsub("0+$", ""))
    if #frac > places or #int > int_digits then return nil end
    return (int == "" and "0" or int) .. (frac ~= "" and ("." .. frac) or "")
end

--- Status after a receipt, from the lines' ordered vs received quantities.
-- @return "received" | "partially_received" | nil (nothing received)
function PurchaseOrderQueries.receiptStatus(items)
    local any, all = false, #items > 0
    for _, it in ipairs(items) do
        local ordered = tonumber(it.quantity) or 0
        local got = tonumber(it.received_quantity) or 0
        if got > 0 then any = true end
        if got < ordered then all = false end
    end
    if all then return "received" end
    if any then return "partially_received" end
    return nil
end

--- Totals of a bill from its lines ({ net, tax, tax_rate }; each line's net
-- and tax are already whole pennies from SQL, so the sums are exact).
-- @return { net, tax, gross, vat_rate }
function PurchaseOrderQueries.billAmounts(lines)
    local net, tax = 0, 0
    local rate_seen, single_rate = nil, true
    for _, l in ipairs(lines) do
        net = net + (tonumber(l.net) or 0)
        tax = tax + (tonumber(l.tax) or 0)
        local r = tonumber(l.tax_rate) or 0
        if rate_seen == nil then rate_seen = r elseif rate_seen ~= r then single_rate = false end
    end
    net, tax = round2(net), round2(tax)
    local vat_rate = 0
    if single_rate and rate_seen then
        vat_rate = rate_seen
    elseif net > 0 then
        vat_rate = round2(tax / net * 100)
    end
    return { net = net, tax = tax, gross = round2(net + tax), vat_rate = vat_rate }
end

-- ============================================================
-- Internals
-- ============================================================

local function err(message, code) return nil, message, code or "invalid" end

local function blank(v) return v == nil or v == "" or v == cjson.null end

local function str_or_nil(v)
    if blank(v) then return nil end
    return tostring(v)
end

-- SQL parameter: db.query can't take a nil in the middle of its arguments.
local function sql_str(v)
    if blank(v) then return db.NULL end
    return tostring(v)
end

-- JSON object text for a jsonb column. Routes switch cjson to encode empty
-- tables as arrays, so an empty table is spelled out as "{}" here.
local function encode_obj(t)
    if type(t) ~= "table" or next(t) == nil then return "{}" end
    return cjson.encode(t)
end

local function now_utc()
    return ngx and ngx.utctime and ngx.utctime() or os.date("!%Y-%m-%d %H:%M:%S")
end

-- Not a real YYYY-MM-DD? (Postgres rejects 2026-02-30 with an error that
-- reads like a server fault, so dates are checked here.)
local function bad_date(v)
    if blank(v) then return false end
    local y, m, d = tostring(v):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return true end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    local back = t and os.date("*t", t)
    return not back or back.year ~= y or back.month ~= m or back.day ~= d
end
PurchaseOrderQueries._badDate = bad_date

local function currency_code(v)
    local c = str_or_nil(v)
    if not c then return "GBP" end
    c = c:upper()
    return c:match("^%u%u%u$") and c or nil
end
PurchaseOrderQueries._currency = currency_code

-- Keys the server writes (receipts, bills, closure, reasons): a client's
-- metadata can't set them.
local SERVER_META = { receipts = true, bill = true, bills = true, expense_uuid = true, expense_id = true,
    closed = true }

--- The client-writable part of a metadata object. @return table | nil, err
function PurchaseOrderQueries.clientMetadata(m)
    if m == nil then return nil end
    if type(m) ~= "table" then return nil, "metadata must be an object" end
    local out = {}
    for k, v in pairs(m) do
        if type(k) == "string" and not SERVER_META[k] and not k:match("_reason$") then out[k] = v end
    end
    return out
end

-- metadata[key] (an array) with ? appended; anything else there is replaced.
local function append_sql(key)
    return "jsonb_set(COALESCE(metadata, '{}'::jsonb), '{" .. key .. "}', CASE WHEN jsonb_typeof(metadata->'"
        .. key .. "') = 'array' THEN metadata->'" .. key .. "' ELSE '[]'::jsonb END || ?::jsonb)"
end

local function table_exists(name)
    local rows = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return rows and rows[1] and rows[1].ok == true
end

-- Run fn inside a transaction. fn returns value | nil, msg, code. Business
-- failures and raised errors both roll back; raised errors are re-raised.
local function in_transaction(fn)
    db.query("BEGIN")
    local ok, a, b, c = pcall(fn)
    if not ok then
        pcall(db.query, "ROLLBACK")
        error(a, 0)
    end
    if a == nil then
        db.query("ROLLBACK")
        return nil, b, c
    end
    db.query("COMMIT")
    return a
end

-- Public shape: uuid as `id` (house convention), no internal numeric ids.
local function shape_po(row)
    if not row then return nil end
    row.internal_id = nil
    row.id = row.uuid
    row.namespace_id = nil
    if type(row.metadata) == "string" then
        row.metadata = cjson.decode(row.metadata) or {}
    end
    return row
end

local function shape_item(row)
    if not row then return nil end
    row.id = row.uuid
    row.purchase_order_id = nil
    row.namespace_id = nil
    return row
end

local PO_COLUMNS = [[
    uuid, po_number, status, supplier_name, supplier_email, supplier_phone,
    supplier_address, supplier_company_uuid, reference, issue_date, expected_date,
    delivery_address, currency, notes, terms, subtotal, tax_total, total,
    project_uuid, metadata, created_by_uuid, sent_at, acknowledged_at, received_at,
    billed_at, cancelled_at, created_at, updated_at
]]

-- Raw row (with id) for internal use; nil when missing / other namespace / deleted.
local function find_row(uuid, namespace_id, for_update)
    if blank(uuid) then return nil end
    local rows = db.query(
        "SELECT * FROM purchase_orders WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL"
            .. (for_update and " FOR UPDATE" or ""),
        tostring(uuid), namespace_id)
    return rows and rows[1]
end

local function items_for(po_id, namespace_id)
    return db.query([[
        SELECT id, uuid, description, quantity, unit_price, tax_rate, tax_amount,
               line_total, received_quantity, billed_quantity, billed_net, billed_tax, sort_order,
               created_at, updated_at
        FROM purchase_order_items
        WHERE purchase_order_id = ? AND namespace_id = ?
        ORDER BY sort_order ASC, id ASC
    ]], po_id, namespace_id) or {}
end

--- Next PO number for a namespace (atomic upsert; never reused): PO-000123
function PurchaseOrderQueries._nextNumber(namespace_id)
    local rows = db.query([[
        INSERT INTO purchase_order_sequences (namespace_id, prefix, current_number, created_at, updated_at)
        VALUES (?, 'PO', 1, NOW(), NOW())
        ON CONFLICT (namespace_id) DO UPDATE
            SET current_number = purchase_order_sequences.current_number + 1,
                updated_at = NOW()
        RETURNING prefix, current_number
    ]], namespace_id)
    local seq = rows[1]
    return (seq.prefix or "PO") .. "-" .. string.format("%06d", tonumber(seq.current_number))
end

local function recalc_totals(po_id, namespace_id)
    db.query([[
        UPDATE purchase_orders po
        SET subtotal = t.subtotal, tax_total = t.tax_total, total = t.total, updated_at = NOW()
        FROM (
            SELECT COALESCE(SUM(ROUND(quantity * unit_price, 2)), 0) AS subtotal,
                   COALESCE(SUM(tax_amount), 0) AS tax_total,
                   COALESCE(SUM(line_total), 0) AS total
            FROM purchase_order_items
            WHERE purchase_order_id = ? AND namespace_id = ?
        ) t
        WHERE po.id = ? AND po.namespace_id = ?
    ]], po_id, namespace_id, po_id, namespace_id)
end

--- Validated line fields, numbers as exact decimal text (amounts are worked
-- out in SQL, see LINE_VALUES). @return table | nil, err
function PurchaseOrderQueries.lineValues(params, existing)
    existing = existing or {}
    local function pick(k, default)
        if params[k] ~= nil then return params[k] end
        if existing[k] ~= nil then return existing[k] end
        return default
    end
    local q = PurchaseOrderQueries.decimal(pick("quantity", 1), 3, 12)
    if not q or tonumber(q) <= 0 then return err("quantity must be a number greater than 0 (at most 3 decimals)") end
    local p = PurchaseOrderQueries.decimal(pick("unit_price", 0), 2, 13)
    if not p then return err("unit_price must be an amount of 0 or more (at most 2 decimals)") end
    local r = PurchaseOrderQueries.decimal(pick("tax_rate", 0), 2, 3)
    if not r or tonumber(r) > 100 then
        return err("tax_rate must be a percent between 0 and 100 (at most 2 decimals)")
    end
    if tonumber(q) * tonumber(p) >= 1e12 then return err("The line total is too large") end

    local description = params.description
    if description == nil then description = existing.description end
    if blank(description) then return err("description is required") end
    return { description = tostring(description), quantity = q, unit_price = p, tax_rate = r }
end
local line_values = PurchaseOrderQueries.lineValues

-- A line's money in exact NUMERIC from (qty, price, rate): v.net, v.tax.
local LINE_VALUES = [[
    (SELECT q, p, r, ROUND(q * p, 2) AS net, ROUND(ROUND(q * p, 2) * r / 100, 2) AS tax
     FROM (SELECT ?::numeric AS q, ?::numeric AS p, ?::numeric AS r) x) v
]]

local function insert_item(po_id, namespace_id, params, sort_order)
    local v, e, code = line_values(params)
    if not v then return nil, e, code end
    local rows = db.query([[
        INSERT INTO purchase_order_items
            (uuid, purchase_order_id, namespace_id, description, quantity, unit_price,
             tax_rate, tax_amount, line_total, received_quantity, sort_order, created_at, updated_at)
        SELECT ?, ?, ?, ?, v.q, v.p, v.r, v.tax, v.net + v.tax, 0, ?, NOW(), NOW()
        FROM ]] .. LINE_VALUES .. [[
        RETURNING *
    ]], Global.generateUUID(), po_id, namespace_id, v.description,
        tonumber(params.sort_order) or sort_order or 0, v.quantity, v.unit_price, v.tax_rate)
    return rows[1]
end

-- Validate the optional CRM company / kanban project links (namespace-scoped).
-- Fills supplier_* fields from the CRM company when they are blank.
local function resolve_links(namespace_id, params)
    if not blank(params.supplier_company_uuid) then
        if not table_exists("crm_accounts") then
            return err("CRM companies are not available in this workspace")
        end
        local rows = db.query([[
            SELECT uuid, name, email, phone, address_line1, address_line2, city, postal_code, country
            FROM crm_accounts WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL
        ]], tostring(params.supplier_company_uuid), namespace_id)
        local acc = rows and rows[1]
        if not acc then return err("Supplier company not found", "not_found") end
        if blank(params.supplier_name) then params.supplier_name = acc.name end
        if blank(params.supplier_email) then params.supplier_email = acc.email end
        if blank(params.supplier_phone) then params.supplier_phone = acc.phone end
        if blank(params.supplier_address) then
            local parts = {}
            for _, k in ipairs({ "address_line1", "address_line2", "city", "postal_code", "country" }) do
                if not blank(acc[k]) then parts[#parts + 1] = acc[k] end
            end
            if #parts > 0 then params.supplier_address = table.concat(parts, ", ") end
        end
    end
    if not blank(params.project_uuid) then
        if not table_exists("kanban_projects") then
            return err("Projects are not available in this workspace")
        end
        local rows = db.query([[
            SELECT uuid FROM kanban_projects WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL
        ]], tostring(params.project_uuid), namespace_id)
        if not (rows and rows[1]) then return err("Project not found", "not_found") end
    end
    return true
end

local function patch_metadata(po_id, namespace_id, patch)
    db.query([[
        UPDATE purchase_orders
        SET metadata = COALESCE(metadata, '{}'::jsonb) || ?::jsonb, updated_at = NOW()
        WHERE id = ? AND namespace_id = ?
    ]], encode_obj(patch), po_id, namespace_id)
end

-- ============================================================
-- Purchase orders
-- ============================================================

local SORTABLE = {
    created_at = true, issue_date = true, expected_date = true, po_number = true,
    total = true, supplier_name = true, status = true,
}

local HEADER_FIELDS = {
    "supplier_name", "supplier_email", "supplier_phone", "supplier_address",
    "supplier_company_uuid", "reference", "issue_date", "expected_date",
    "delivery_address", "currency", "notes", "terms", "project_uuid",
}

--- Create a draft PO (optionally with items).
-- @param namespace_id number
-- @param user_uuid string creator
-- @param params table header fields + items[] ({description, quantity, unit_price, tax_rate})
function PurchaseOrderQueries.create(namespace_id, user_uuid, params)
    params = params or {}
    local items = params.items or params.line_items
    if items ~= nil and type(items) ~= "table" then return err("items must be an array") end
    for _, it in ipairs(items or {}) do
        if type(it) ~= "table" then return err("each item must be an object") end
    end
    local metadata, merr = PurchaseOrderQueries.clientMetadata(params.metadata)
    if merr then return err(merr) end
    for _, f in ipairs({ "issue_date", "expected_date" }) do
        if bad_date(params[f]) then return err(f .. " must be a date (YYYY-MM-DD)") end
    end
    local currency = currency_code(params.currency)
    if not currency then return err("currency must be a 3-letter ISO code such as GBP") end

    local ok, e, code = resolve_links(namespace_id, params)
    if not ok then return nil, e, code end
    if blank(params.supplier_name) then return err("supplier_name is required") end

    local created, cerr, ccode = in_transaction(function()
        local po_number = PurchaseOrderQueries._nextNumber(namespace_id)
        local rows = db.query([[
            INSERT INTO purchase_orders
                (uuid, namespace_id, po_number, status, supplier_name, supplier_email, supplier_phone,
                 supplier_address, supplier_company_uuid, reference, issue_date, expected_date,
                 delivery_address, currency, notes, terms, project_uuid, metadata, created_by_uuid,
                 created_at, updated_at)
            VALUES (?, ?, ?, 'draft', ?, ?, ?, ?, ?, ?, COALESCE(?::date, CURRENT_DATE), ?::date,
                    ?, ?, ?, ?, ?, ?::jsonb, ?, NOW(), NOW())
            RETURNING id, uuid
        ]], Global.generateUUID(), namespace_id, po_number,
            tostring(params.supplier_name), sql_str(params.supplier_email), sql_str(params.supplier_phone),
            sql_str(params.supplier_address), sql_str(params.supplier_company_uuid),
            sql_str(params.reference), sql_str(params.issue_date), sql_str(params.expected_date),
            sql_str(params.delivery_address), currency, sql_str(params.notes),
            sql_str(params.terms), sql_str(params.project_uuid),
            encode_obj(metadata),
            sql_str(user_uuid))
        local po = rows[1]
        for i, it in ipairs(items or {}) do
            local item, ierr, icode = insert_item(po.id, namespace_id, it, i)
            if not item then return nil, "Item " .. i .. ": " .. tostring(ierr), icode end
        end
        recalc_totals(po.id, namespace_id)
        return po.uuid
    end)
    if not created then return nil, cerr, ccode end
    return PurchaseOrderQueries.get(created, namespace_id)
end

--- List POs with filters + pagination.
-- @param params { page, perPage, status (one or comma list), supplier, supplier_company_uuid,
--                 project_uuid, from_date, to_date, search, order_by, order_dir }
function PurchaseOrderQueries.list(namespace_id, params)
    params = params or {}
    local page = Global.pageParam(params.page)
    local perPage = Global.perPageParam(params.perPage, 20, 500)
    local offset = (page - 1) * perPage

    local conds = { "po.namespace_id = " .. db.escape_literal(namespace_id), "po.deleted_at IS NULL" }

    if not blank(params.status) and params.status ~= "all" then
        local wanted = {}
        for s in tostring(params.status):gmatch("[^,%s]+") do
            if TRANSITIONS[s] then wanted[#wanted + 1] = db.escape_literal(s) end
        end
        if #wanted == 0 then
            return { data = {}, total = 0, page = page, perPage = perPage }
        end
        conds[#conds + 1] = "po.status IN (" .. table.concat(wanted, ", ") .. ")"
    end
    if not blank(params.supplier) then
        local like = db.escape_literal("%" .. tostring(params.supplier) .. "%")
        conds[#conds + 1] = "(po.supplier_name ILIKE " .. like .. " OR po.supplier_email ILIKE " .. like .. ")"
    end
    if not blank(params.supplier_company_uuid) then
        conds[#conds + 1] = "po.supplier_company_uuid = " .. db.escape_literal(tostring(params.supplier_company_uuid))
    end
    if not blank(params.project_uuid) then
        conds[#conds + 1] = "po.project_uuid = " .. db.escape_literal(tostring(params.project_uuid))
    end
    if bad_date(params.from_date) or bad_date(params.to_date) then
        return err("from_date and to_date must be dates (YYYY-MM-DD)")
    end
    if not blank(params.from_date) then
        conds[#conds + 1] = "po.issue_date >= " .. db.escape_literal(tostring(params.from_date)) .. "::date"
    end
    if not blank(params.to_date) then
        conds[#conds + 1] = "po.issue_date <= " .. db.escape_literal(tostring(params.to_date)) .. "::date"
    end
    if not blank(params.search) then
        local like = db.escape_literal("%" .. tostring(params.search) .. "%")
        conds[#conds + 1] = "(po.po_number ILIKE " .. like .. " OR po.supplier_name ILIKE " .. like
            .. " OR po.reference ILIKE " .. like .. ")"
    end

    local where = table.concat(conds, " AND ")
    local order_dir_in = not blank(params.order_dir) and tostring(params.order_dir) or nil
    local order_by, order_dir = Global.sanitizeOrderBy(str_or_nil(params.order_by), order_dir_in,
        SORTABLE, "created_at", "desc")

    local count = db.query("SELECT COUNT(*) AS total FROM purchase_orders po WHERE " .. where)
    local total = count and count[1] and tonumber(count[1].total) or 0

    local rows = db.query([[
        SELECT po.uuid AS id, po.uuid, po.po_number, po.status, po.supplier_name, po.supplier_email,
               po.supplier_company_uuid, po.reference, po.issue_date, po.expected_date, po.currency,
               po.subtotal, po.tax_total, po.total, po.project_uuid, po.created_by_uuid,
               po.sent_at, po.received_at, po.billed_at, po.created_at, po.updated_at,
               (SELECT COUNT(*) FROM purchase_order_items i
                 WHERE i.purchase_order_id = po.id AND i.namespace_id = po.namespace_id) AS item_count
        FROM purchase_orders po
        WHERE ]] .. where .. [[
        ORDER BY po.]] .. order_by .. " " .. order_dir .. [[, po.id DESC
        LIMIT ]] .. perPage .. " OFFSET " .. offset)

    return { data = rows or {}, total = total, page = page, perPage = perPage }
end

--- One PO with its items, linked project (name) and bill details.
function PurchaseOrderQueries.get(uuid, namespace_id)
    local row = find_row(uuid, namespace_id)
    if not row then return nil end
    local items = items_for(row.id, namespace_id)
    for _, it in ipairs(items) do shape_item(it) end

    local po = {}
    for col in PO_COLUMNS:gmatch("[%w_]+") do po[col] = row[col] end
    shape_po(po)
    po.items = items

    po.project = nil
    if row.project_uuid and table_exists("kanban_projects") then
        local p = db.query([[
            SELECT uuid, name, status FROM kanban_projects
            WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL
        ]], row.project_uuid, namespace_id)
        if p and p[1] then po.project = p[1] end
    end
    return po
end

local SUPPLIER_FIELDS = { "supplier_name", "supplier_email", "supplier_phone", "supplier_address" }

--- Update header fields (draft / sent / acknowledged only).
function PurchaseOrderQueries.update(uuid, namespace_id, params)
    params = params or {}
    for _, f in ipairs({ "issue_date", "expected_date" }) do
        if bad_date(params[f]) then return err(f .. " must be a date (YYYY-MM-DD)") end
    end
    local metadata, merr = PurchaseOrderQueries.clientMetadata(params.metadata)
    if merr then return err(merr) end
    local currency
    if params.currency ~= nil then
        currency = currency_code(params.currency)
        if not currency then return err("currency must be a 3-letter ISO code such as GBP") end
    end

    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if not HEADER_EDITABLE[row.status] then
            return err("Cannot edit a purchase order with status: " .. row.status, "conflict")
        end
        if currency and currency ~= row.currency and row.status ~= "draft" then
            return err("The currency can't change once the purchase order has been sent", "conflict")
        end

        local link_params
        local company_changed = not blank(params.supplier_company_uuid)
            and tostring(params.supplier_company_uuid) ~= (row.supplier_company_uuid or "")
        if company_changed then
            -- Another CRM company: its details replace the old supplier's,
            -- except fields the client changed in this request.
            for _, f in ipairs(SUPPLIER_FIELDS) do
                if params[f] == nil or params[f] == row[f] then params[f] = "" end
            end
            link_params = params
        else
            link_params = {
                supplier_company_uuid = params.supplier_company_uuid,
                project_uuid = params.project_uuid,
                supplier_name = params.supplier_name == nil and row.supplier_name or params.supplier_name,
                supplier_email = params.supplier_email or row.supplier_email,
                supplier_phone = params.supplier_phone or row.supplier_phone,
                supplier_address = params.supplier_address or row.supplier_address,
            }
        end
        local ok, lerr, lcode = resolve_links(namespace_id, link_params)
        if not ok then return nil, lerr, lcode end
        -- A blank name may be filled from the linked CRM company; otherwise refuse it.
        if params.supplier_name ~= nil and blank(params.supplier_name) then
            if blank(link_params.supplier_name) then return err("supplier_name cannot be blank") end
            params.supplier_name = link_params.supplier_name
        end

        local sets, values = {}, {}
        for _, f in ipairs(HEADER_FIELDS) do
            if params[f] ~= nil then
                local v = str_or_nil(params[f])
                if f == "currency" then v = currency end
                if f == "issue_date" and v == nil then v = row.issue_date end
                local cast = (f == "issue_date" or f == "expected_date") and "?::date" or "?"
                sets[#sets + 1] = f .. " = " .. cast
                values[#values + 1] = v == nil and db.NULL or v
            end
        end
        if metadata then
            sets[#sets + 1] = "metadata = COALESCE(metadata, '{}'::jsonb) || ?::jsonb"
            values[#values + 1] = encode_obj(metadata)
        end
        if #sets > 0 then
            values[#values + 1] = row.id
            values[#values + 1] = namespace_id
            db.query("UPDATE purchase_orders SET " .. table.concat(sets, ", ")
                .. ", updated_at = NOW() WHERE id = ? AND namespace_id = ?", unpack(values))
        end
        return row
    end)
    if not done then return nil, e, code end
    return PurchaseOrderQueries.get(uuid, namespace_id)
end

--- Soft-delete a draft PO.
function PurchaseOrderQueries.delete(uuid, namespace_id)
    return in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if row.status ~= "draft" then
            return err("Only draft purchase orders can be deleted - cancel it instead", "conflict")
        end
        db.query("UPDATE purchase_orders SET deleted_at = NOW(), updated_at = NOW() WHERE id = ? AND namespace_id = ?",
            row.id, namespace_id)
        return true
    end)
end

-- Generic status change with a timestamp column; validates the transition.
local STATUS_TIMESTAMP = {
    sent = "sent_at", acknowledged = "acknowledged_at", received = "received_at",
    billed = "billed_at", cancelled = "cancelled_at",
}

function PurchaseOrderQueries.transition(uuid, namespace_id, to_status, opts)
    opts = opts or {}
    if not TRANSITIONS[to_status] then return err("Unknown status: " .. tostring(to_status)) end
    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if opts.allow_same and row.status == to_status then return row end
        if not PurchaseOrderQueries.canTransition(row.status, to_status) then
            return err("Cannot change a " .. row.status .. " purchase order to " .. to_status, "conflict")
        end
        if to_status == "sent" then
            local n = db.query([[
                SELECT COUNT(*) AS n FROM purchase_order_items WHERE purchase_order_id = ? AND namespace_id = ?
            ]], row.id, namespace_id)
            if (tonumber(n[1].n) or 0) == 0 then return err("Add at least one line before sending") end
        end
        local ts = STATUS_TIMESTAMP[to_status]
        db.query("UPDATE purchase_orders SET status = ?, " .. (ts and (ts .. " = NOW(), ") or "")
            .. "updated_at = NOW() WHERE id = ? AND namespace_id = ?", to_status, row.id, namespace_id)
        if opts.reason and opts.reason ~= "" then
            patch_metadata(row.id, namespace_id, { [to_status .. "_reason"] = tostring(opts.reason) })
        end
        return row
    end)
    if not done then return nil, e, code end
    return PurchaseOrderQueries.get(uuid, namespace_id)
end

function PurchaseOrderQueries.send(uuid, namespace_id)
    return PurchaseOrderQueries.transition(uuid, namespace_id, "sent")
end

function PurchaseOrderQueries.acknowledge(uuid, namespace_id)
    return PurchaseOrderQueries.transition(uuid, namespace_id, "acknowledged")
end

function PurchaseOrderQueries.cancel(uuid, namespace_id, reason)
    return PurchaseOrderQueries.transition(uuid, namespace_id, "cancelled", { reason = reason })
end

-- ============================================================
-- Line items (draft only)
-- ============================================================

function PurchaseOrderQueries.addItem(uuid, namespace_id, params)
    return in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if not ITEMS_EDITABLE[row.status] then
            return err("Lines can only be changed while the purchase order is a draft", "conflict")
        end
        local nxt = db.query([[
            SELECT COALESCE(MAX(sort_order), 0) + 1 AS n
            FROM purchase_order_items WHERE purchase_order_id = ? AND namespace_id = ?
        ]], row.id, namespace_id)
        local item, e, code = insert_item(row.id, namespace_id, params or {}, tonumber(nxt[1].n))
        if not item then return nil, e, code end
        recalc_totals(row.id, namespace_id)
        return shape_item(item)
    end)
end

-- Item + its parent PO (row locked, current status), both namespace-checked.
local function find_item(item_uuid, namespace_id)
    if blank(item_uuid) then return nil end
    local rows = db.query([[
        SELECT i.*, po.status AS po_status
        FROM purchase_order_items i
        JOIN purchase_orders po ON po.id = i.purchase_order_id AND po.namespace_id = i.namespace_id
        WHERE i.uuid = ? AND i.namespace_id = ? AND po.deleted_at IS NULL
        FOR UPDATE OF po
    ]], tostring(item_uuid), namespace_id)
    return rows and rows[1]
end

function PurchaseOrderQueries.updateItem(item_uuid, namespace_id, params)
    params = params or {}
    return in_transaction(function()
        local item = find_item(item_uuid, namespace_id)
        if not item then return err("Line item not found", "not_found") end
        if not ITEMS_EDITABLE[item.po_status] then
            return err("Lines can only be changed while the purchase order is a draft", "conflict")
        end
        local v, e, code = line_values(params, item)
        if not v then return nil, e, code end
        local rows = db.query([[
            UPDATE purchase_order_items i
            SET description = ?, quantity = v.q, unit_price = v.p, tax_rate = v.r, tax_amount = v.tax,
                line_total = v.net + v.tax, sort_order = COALESCE(?, i.sort_order), updated_at = NOW()
            FROM ]] .. LINE_VALUES .. [[
            WHERE i.id = ? AND i.namespace_id = ?
            RETURNING i.*
        ]], v.description, tonumber(params.sort_order) or db.NULL, v.quantity, v.unit_price, v.tax_rate,
            item.id, namespace_id)
        recalc_totals(item.purchase_order_id, namespace_id)
        return shape_item(rows[1])
    end)
end

function PurchaseOrderQueries.deleteItem(item_uuid, namespace_id)
    return in_transaction(function()
        local item = find_item(item_uuid, namespace_id)
        if not item then return err("Line item not found", "not_found") end
        if not ITEMS_EDITABLE[item.po_status] then
            return err("Lines can only be changed while the purchase order is a draft", "conflict")
        end
        db.query("DELETE FROM purchase_order_items WHERE id = ? AND namespace_id = ?", item.id, namespace_id)
        recalc_totals(item.purchase_order_id, namespace_id)
        return true
    end)
end

-- ============================================================
-- Goods receipt
-- ============================================================

--- Record goods received now.
-- @param body { items = [{ item_uuid|id, quantity }], receive_all = bool, note }
--   quantity is what arrived now (added to the line's received quantity under
--   the PO row lock, never above the ordered quantity); receive_all receives
--   everything outstanding.
function PurchaseOrderQueries.receive(uuid, namespace_id, user_uuid, body)
    body = body or {}
    local lines = body.items or body.lines
    if lines ~= nil and type(lines) ~= "table" then return err("items must be an array") end
    local all = body.receive_all == true or body.receive_all == "true"
    if not all and (not lines or #lines == 0) then
        return err("Pass items [{item_uuid, quantity}] (the quantity received now) or receive_all: true")
    end

    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if not RECEIVABLE[row.status] then
            return err("Cannot receive goods on a " .. row.status .. " purchase order", "conflict")
        end

        local items = items_for(row.id, namespace_id)
        local by_uuid = {}
        for _, it in ipairs(items) do by_uuid[it.uuid] = it end

        local adds = {}
        if all then
            for _, it in ipairs(items) do
                local left = (tonumber(it.quantity) or 0) - (tonumber(it.received_quantity) or 0)
                if left > 0 then
                    -- Both are 3-decimal values: %.3f drops the double's noise.
                    local qty = PurchaseOrderQueries.decimal(string.format("%.3f", left), 3, 12)
                    adds[#adds + 1] = { item = it, qty = qty }
                end
            end
        end
        for i, l in ipairs(lines or {}) do
            if type(l) ~= "table" then return err("each item must be an object") end
            if l.quantity == nil and l.received_quantity ~= nil then
                return err("Line " .. i .. ": send quantity (what arrived now); the running total "
                    .. "received_quantity is no longer accepted")
            end
            local it = by_uuid[tostring(l.item_uuid or l.uuid or l.id or "")]
            if not it then return err("Line " .. i .. " is not on this purchase order", "not_found") end
            local qty = PurchaseOrderQueries.decimal(l.quantity, 3, 12)
            if not qty or tonumber(qty) <= 0 then
                return err("Line " .. i .. ": quantity must be more than 0 (at most 3 decimals)")
            end
            adds[#adds + 1] = { item = it, qty = qty, n = i }
        end
        if #adds == 0 then return err("Nothing is left to receive", "conflict") end

        local log = {}
        for _, a in ipairs(adds) do
            local r = db.query([[
                UPDATE purchase_order_items
                SET received_quantity = received_quantity + ?::numeric, updated_at = NOW()
                WHERE id = ? AND namespace_id = ? AND received_quantity + ?::numeric <= quantity
                RETURNING received_quantity
            ]], a.qty, a.item.id, namespace_id, a.qty)
            if not r[1] then
                return err("Line " .. (a.n or a.item.description) .. ": receiving " .. a.qty
                    .. " would be more than the " .. tostring(a.item.quantity) .. " ordered ("
                    .. tostring(a.item.received_quantity) .. " already received)", "conflict")
            end
            a.item.received_quantity = r[1].received_quantity
            log[#log + 1] = { item_uuid = a.item.uuid, quantity = tonumber(a.qty),
                received_quantity = r[1].received_quantity }
        end

        local new_status = PurchaseOrderQueries.receiptStatus(items)
        db.query([[
            UPDATE purchase_orders
            SET status = ?,
                received_at = CASE WHEN ? = 'received' THEN NOW() ELSE received_at END,
                metadata = ]] .. append_sql("receipts") .. [[,
                updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], new_status, new_status, cjson.encode({ {
            at = now_utc(), by = user_uuid, note = str_or_nil(body.note), lines = log,
        } }), row.id, namespace_id)
        return row
    end)
    if not done then return nil, e, code end
    return PurchaseOrderQueries.get(uuid, namespace_id)
end

-- ============================================================
-- Bills
-- ============================================================

--- Is the accounting purchase ledger available (feature on + table)?
function PurchaseOrderQueries.ledgerOn()
    local ProjectConfig = require("helper.project-config")
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.ACCOUNTING) and table_exists("accounting_expenses")
end

--- Bill what has been received and not yet billed. With the accounting
-- feature on, the bill is a pending expense (vendor = supplier) in the
-- purchase ledger, unless the PO isn't in the ledger currency (then the bill
-- says so in ledger_note and nothing is posted).
-- @param opts { bill_date, category, notes }
-- @return PO with `bill` (this bill) and accounting_expense_created
function PurchaseOrderQueries.convertToBill(uuid, namespace_id, user_uuid, opts)
    opts = opts or {}
    if bad_date(opts.bill_date) then return err("bill_date must be a date (YYYY-MM-DD)") end
    local ledger_on = PurchaseOrderQueries.ledgerOn()
    local bill

    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if not BILLABLE[row.status] then
            return err("Only received or partially received purchase orders can be billed (this one is "
                .. row.status .. ")", "conflict")
        end

        -- Each line bills (the amount of everything received) - (what its bills
        -- already hold), so a line's bills add up to its amount, to the penny,
        -- whatever was billed or voided in between.
        local lines = db.query([[
            SELECT uuid AS item_uuid, tax_rate, received_quantity - billed_quantity AS quantity,
                   ROUND(received_quantity * unit_price, 2) - billed_net AS net,
                   ROUND(ROUND(received_quantity * unit_price, 2) * tax_rate / 100, 2) - billed_tax AS tax
            FROM purchase_order_items
            WHERE purchase_order_id = ? AND namespace_id = ? AND received_quantity > billed_quantity
            ORDER BY sort_order ASC, id ASC
        ]], row.id, namespace_id)
        if #lines == 0 then return err("Everything received so far has already been billed", "conflict") end
        local amounts = PurchaseOrderQueries.billAmounts(lines)

        bill = {
            uuid = Global.generateUUID(), at = now_utc(), by = user_uuid,
            bill_date = str_or_nil(opts.bill_date) or os.date("!%Y-%m-%d"),
            net = amounts.net, tax = amounts.tax, gross = amounts.gross, vat_rate = amounts.vat_rate,
            currency = row.currency, lines = lines,
            category = (str_or_nil(opts.category) or "purchases"):sub(1, 60),
            notes = str_or_nil(opts.notes) and str_or_nil(opts.notes):sub(1, 1000),
        }
        if ledger_on and row.currency ~= PurchaseOrderQueries.LEDGER_CURRENCY then
            bill.ledger_note = "Not posted to the purchase ledger: it records " .. PurchaseOrderQueries.LEDGER_CURRENCY
                .. " only and this order is in " .. row.currency .. ". Enter it there in "
                .. PurchaseOrderQueries.LEDGER_CURRENCY .. "."
        elseif ledger_on and amounts.gross > 0 then
            local AccountingQueries = require("queries.AccountingQueries")
            local label = row.po_number .. " - " .. row.supplier_name
            if not blank(row.reference) then label = label .. " (" .. row.reference .. ")" end
            local expense = AccountingQueries.createExpense({
                namespace_id = namespace_id,
                expense_date = bill.bill_date,
                description = "Purchase order " .. label,
                amount = amounts.gross,
                currency = row.currency,
                category = bill.category,
                vat_rate = amounts.vat_rate,
                vat_amount = amounts.tax,
                vendor = row.supplier_name,
                notes = bill.notes,
                status = "pending",
                submitted_by_uuid = user_uuid,
                metadata = cjson.encode({
                    source = "purchase_order",
                    purchase_order_uuid = row.uuid,
                    po_number = row.po_number,
                    project_uuid = row.project_uuid,
                    bill_uuid = bill.uuid,
                }),
            })
            if not expense then error("Failed to create the purchase-ledger expense") end
            bill.expense_uuid = expense.uuid
        end

        db.query([[
            UPDATE purchase_order_items
            SET billed_quantity = received_quantity, billed_net = ROUND(received_quantity * unit_price, 2),
                billed_tax = ROUND(ROUND(received_quantity * unit_price, 2) * tax_rate / 100, 2), updated_at = NOW()
            WHERE purchase_order_id = ? AND namespace_id = ? AND received_quantity > billed_quantity
        ]], row.id, namespace_id)
        -- Fully received (or closed short) and now all billed: done.
        local status = row.status == "received" and "billed" or row.status
        db.query([[
            UPDATE purchase_orders
            SET status = ?, billed_at = CASE WHEN ? = 'billed' THEN NOW() ELSE billed_at END,
                metadata = ]] .. append_sql("bills") .. [[, updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], status, status, cjson.encode({ bill }), row.id, namespace_id)
        return row
    end)
    if not done then return nil, e, code end
    local po = PurchaseOrderQueries.get(uuid, namespace_id)
    po.bill = bill
    po.accounting_expense_created = bill.expense_uuid ~= nil
    return po
end

--- Close a partially received PO short: no more goods are coming. What has
-- arrived and isn't billed yet can still be billed (status received);
-- with nothing left to bill it is done (billed).
function PurchaseOrderQueries.close(uuid, namespace_id, user_uuid, reason)
    reason = str_or_nil(reason)
    if not reason then return err("Give a reason for closing the order short") end
    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if row.status ~= "partially_received" then
            return err("Only a partially received purchase order can be closed short (this one is "
                .. row.status .. ")", "conflict")
        end
        local short, unbilled = {}, false
        for _, it in ipairs(items_for(row.id, namespace_id)) do
            local ordered, got = tonumber(it.quantity) or 0, tonumber(it.received_quantity) or 0
            if got < ordered then short[#short + 1] = { item_uuid = it.uuid, ordered = ordered, received = got } end
            if got > (tonumber(it.billed_quantity) or 0) then unbilled = true end
        end
        local status = unbilled and "received" or "billed"
        db.query([[
            UPDATE purchase_orders
            SET status = ?, received_at = NOW(), billed_at = CASE WHEN ? = 'billed' THEN NOW() ELSE billed_at END,
                metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{closed}', ?::jsonb), updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], status, status, cjson.encode({
            at = now_utc(), by = user_uuid, reason = reason:sub(1, 500), short = short,
        }), row.id, namespace_id)
        return row
    end)
    if not done then return nil, e, code end
    return PurchaseOrderQueries.get(uuid, namespace_id)
end

--- Void a bill: its ledger expense is removed if still pending (a rejected or
-- deleted one is left as it is; an approved/posted one must be reversed in
-- Bookkeeping first), its quantities are billable again (billed -> received)
-- and the bill stays in metadata.bills marked voided.
function PurchaseOrderQueries.voidBill(uuid, namespace_id, user_uuid, bill_uuid, reason)
    if blank(bill_uuid) then return err("bill_uuid is required") end
    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        local meta = type(row.metadata) == "table" and row.metadata or (cjson.decode(row.metadata or "{}") or {})
        local bill, index
        for i, b in ipairs(type(meta.bills) == "table" and meta.bills or {}) do
            if type(b) == "table" and b.uuid == tostring(bill_uuid) then bill, index = b, i end
        end
        if not bill then return err("Bill not found on this purchase order", "not_found") end
        if bill.voided_at then return err("This bill has already been voided", "conflict") end

        if type(bill.expense_uuid) == "string" and table_exists("accounting_expenses") then
            local ex = db.query([[
                SELECT uuid, status, deleted_at FROM accounting_expenses
                WHERE uuid = ? AND namespace_id = ? FOR UPDATE
            ]], bill.expense_uuid, namespace_id)[1]
            if ex and (ex.deleted_at == nil or ex.deleted_at == db.NULL) then
                if ex.status == "pending" then
                    if not require("queries.AccountingQueries").deleteExpense(ex.uuid) then
                        error("Failed to remove the purchase-ledger expense")
                    end
                elseif ex.status ~= "rejected" then
                    return err("The purchase-ledger expense for this bill is already " .. tostring(ex.status)
                        .. " - reverse it in Bookkeeping; only a bill whose expense is still pending can be voided",
                        "conflict")
                end
            end
        end

        for _, l in ipairs(type(bill.lines) == "table" and bill.lines or {}) do
            local q = type(l) == "table" and PurchaseOrderQueries.decimal(l.quantity, 3, 12)
            if q then
                db.query([[
                    UPDATE purchase_order_items
                    SET billed_quantity = GREATEST(billed_quantity - ?::numeric, 0),
                        billed_net = GREATEST(billed_net - ?::numeric, 0),
                        billed_tax = GREATEST(billed_tax - ?::numeric, 0), updated_at = NOW()
                    WHERE uuid = ? AND purchase_order_id = ? AND namespace_id = ?
                ]], q, PurchaseOrderQueries.decimal(l.net, 2, 13) or "0", PurchaseOrderQueries.decimal(l.tax, 2, 13)
                    or "0", tostring(l.item_uuid), row.id, namespace_id)
            end
        end
        local status = row.status == "billed" and "received" or row.status
        db.query([[
            UPDATE purchase_orders
            SET status = ?, billed_at = NULL,
                metadata = jsonb_set(metadata, ARRAY['bills', ?::text], (metadata->'bills'->?::int) || ?::jsonb),
                updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], status, index - 1, index - 1, cjson.encode({
            voided_at = now_utc(), voided_by = user_uuid, void_reason = reason and tostring(reason):sub(1, 500),
        }), row.id, namespace_id)
        return row
    end)
    if not done then return nil, e, code end
    return PurchaseOrderQueries.get(uuid, namespace_id)
end

-- ============================================================
-- Stats (list page cards)
-- ============================================================

local STAT_KEYS = { "total_count", "total_value", "draft_count", "open_count", "open_value",
    "overdue_count", "to_bill_count", "to_bill_value", "billed_value" }

--- Counts for the whole workspace; values per currency (never added across
-- currencies). to_bill = received and not yet billed, part-received POs too.
function PurchaseOrderQueries.getStats(namespace_id)
    local rows = db.query([[
        WITH po AS (
            SELECT p.currency, p.status, p.total, p.expected_date,
                   COALESCE(SUM(ROUND(i.received_quantity * i.unit_price, 2)
                       + ROUND(ROUND(i.received_quantity * i.unit_price, 2) * i.tax_rate / 100, 2)
                       - i.billed_net - i.billed_tax), 0) AS unbilled,
                   COALESCE(SUM(i.billed_net + i.billed_tax), 0) AS billed
            FROM purchase_orders p
            LEFT JOIN purchase_order_items i ON i.purchase_order_id = p.id AND i.namespace_id = p.namespace_id
            WHERE p.namespace_id = ? AND p.deleted_at IS NULL
            GROUP BY p.id
        )
        SELECT currency,
            COUNT(*) AS total_count,
            COALESCE(SUM(total) FILTER (WHERE status <> 'cancelled'), 0) AS total_value,
            COUNT(*) FILTER (WHERE status = 'draft') AS draft_count,
            COUNT(*) FILTER (WHERE status IN ('sent','acknowledged','partially_received')) AS open_count,
            COALESCE(SUM(total) FILTER (WHERE status IN ('sent','acknowledged','partially_received')), 0) AS open_value,
            COUNT(*) FILTER (WHERE status IN ('sent','acknowledged','partially_received')
                             AND expected_date < CURRENT_DATE) AS overdue_count,
            COUNT(*) FILTER (WHERE status IN ('partially_received','received') AND unbilled > 0) AS to_bill_count,
            COALESCE(SUM(unbilled) FILTER (WHERE status IN ('partially_received','received')), 0) AS to_bill_value,
            COALESCE(SUM(billed), 0) AS billed_value
        FROM po
        GROUP BY currency
        ORDER BY COUNT(*) DESC, currency
    ]], namespace_id)
    local by_status = db.query([[
        SELECT status, COUNT(*) AS count
        FROM purchase_orders
        WHERE namespace_id = ? AND deleted_at IS NULL
        GROUP BY status
    ]], namespace_id)

    local out = { by_status = by_status or {}, by_currency = {} }
    for _, k in ipairs(STAT_KEYS) do
        if k:match("_count$") then out[k] = 0 end
    end
    for _, r in ipairs(rows or {}) do
        local c = { currency = r.currency }
        for _, k in ipairs(STAT_KEYS) do
            c[k] = tonumber(r[k]) or 0
            if k:match("_count$") then out[k] = out[k] + c[k] end
        end
        out.by_currency[#out.by_currency + 1] = c
    end
    return out
end

return PurchaseOrderQueries
