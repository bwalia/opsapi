--[[
    Purchase Order Queries
    ======================

    Business logic for supplier purchase orders: numbering, CRUD, line items,
    the status workflow, goods receipt and conversion to a bill.

    Every read and write is scoped by namespace_id (purchase_order_items carries
    its own namespace_id too). Functions return `value` on success or
    `nil, message, code` on failure, where code is one of:
        "not_found" (404), "invalid" (400), "conflict" (409 - wrong status)

    Status workflow (enforced by canTransition):
        draft -> sent -> acknowledged -> partially_received -> received -> billed
        draft | sent | acknowledged -> cancelled
        sent / acknowledged may jump straight to (partially_)received
        partially_received may be billed for what has arrived so far
]]

local Global = require("helper.global")
local InvoiceGenerator = require("helper.invoice-generator")
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
    partially_received = { partially_received = true, received = true, billed = true },
    received = { billed = true },
    billed = {},
    cancelled = {},
}
PurchaseOrderQueries.TRANSITIONS = TRANSITIONS

-- Header fields can change until goods start arriving; lines only while draft.
local HEADER_EDITABLE = { draft = true, sent = true, acknowledged = true }
local ITEMS_EDITABLE = { draft = true }

--- Is `from -> to` an allowed status change?
function PurchaseOrderQueries.canTransition(from, to)
    local allowed = TRANSITIONS[from]
    return allowed ~= nil and allowed[to] == true
end

function PurchaseOrderQueries.isValidStatus(status)
    return TRANSITIONS[status] ~= nil
end

local function round2(n)
    n = tonumber(n) or 0
    if n >= 0 then return math.floor(n * 100 + 0.5) / 100 end
    return -math.floor(-n * 100 + 0.5) / 100
end
PurchaseOrderQueries._round2 = round2

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

--- What a bill should be for: received quantity x price (+ line tax rate).
-- @return { net, tax, gross, vat_rate }
function PurchaseOrderQueries.billAmounts(items)
    local net, tax = 0, 0
    local rate_seen, single_rate = nil, true
    for _, it in ipairs(items) do
        local qty = tonumber(it.received_quantity) or 0
        if qty > 0 then
            local calc = InvoiceGenerator.calculateLineTotal(qty, it.unit_price, it.tax_rate, 0)
            net = net + calc.subtotal
            tax = tax + calc.tax
            local r = tonumber(it.tax_rate) or 0
            if rate_seen == nil then rate_seen = r elseif rate_seen ~= r then single_rate = false end
        end
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
               line_total, received_quantity, sort_order, created_at, updated_at
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

local function line_values(params, existing)
    existing = existing or {}
    local quantity = tonumber(params.quantity)
    if params.quantity == nil then quantity = tonumber(existing.quantity) or 1 end
    local unit_price = tonumber(params.unit_price)
    if params.unit_price == nil then unit_price = tonumber(existing.unit_price) or 0 end
    local tax_rate = tonumber(params.tax_rate)
    if params.tax_rate == nil then tax_rate = tonumber(existing.tax_rate) or 0 end

    if not quantity or quantity <= 0 then return err("quantity must be a number greater than 0") end
    if not unit_price or unit_price < 0 then return err("unit_price must be a number of 0 or more") end
    if not tax_rate or tax_rate < 0 or tax_rate > 100 then
        return err("tax_rate must be a percent between 0 and 100")
    end

    local description = params.description
    if description == nil then description = existing.description end
    if blank(description) then return err("description is required") end

    local calc = InvoiceGenerator.calculateLineTotal(quantity, unit_price, tax_rate, 0)
    return {
        description = tostring(description),
        quantity = quantity,
        unit_price = round2(unit_price),
        tax_rate = tax_rate,
        tax_amount = round2(calc.tax),
        line_total = round2(round2(calc.subtotal) + round2(calc.tax)),
    }
end

local function insert_item(po_id, namespace_id, params, sort_order)
    local v, e, code = line_values(params)
    if not v then return nil, e, code end
    local rows = db.query([[
        INSERT INTO purchase_order_items
            (uuid, purchase_order_id, namespace_id, description, quantity, unit_price,
             tax_rate, tax_amount, line_total, received_quantity, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NOW(), NOW())
        RETURNING *
    ]], Global.generateUUID(), po_id, namespace_id, v.description, v.quantity, v.unit_price,
        v.tax_rate, v.tax_amount, v.line_total, tonumber(params.sort_order) or sort_order or 0)
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
    if params.metadata ~= nil and type(params.metadata) ~= "table" then
        return err("metadata must be an object")
    end

    local ok, e, code = resolve_links(namespace_id, params)
    if not ok then return nil, e, code end
    if blank(params.supplier_name) then return err("supplier_name is required") end

    local currency = str_or_nil(params.currency) or "GBP"

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
            sql_str(params.delivery_address), currency:upper(), sql_str(params.notes),
            sql_str(params.terms), sql_str(params.project_uuid),
            encode_obj(params.metadata),
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

--- Update header fields (draft / sent / acknowledged only).
function PurchaseOrderQueries.update(uuid, namespace_id, params)
    params = params or {}
    local row = find_row(uuid, namespace_id)
    if not row then return err("Purchase order not found", "not_found") end
    if not HEADER_EDITABLE[row.status] then
        return err("Cannot edit a purchase order with status: " .. row.status, "conflict")
    end

    local link_params = {
        supplier_company_uuid = params.supplier_company_uuid,
        project_uuid = params.project_uuid,
        supplier_name = params.supplier_name == nil and row.supplier_name or params.supplier_name,
        supplier_email = params.supplier_email or row.supplier_email,
        supplier_phone = params.supplier_phone or row.supplier_phone,
        supplier_address = params.supplier_address or row.supplier_address,
    }
    local ok, e, code = resolve_links(namespace_id, link_params)
    if not ok then return nil, e, code end
    -- A blank name may be filled from the linked CRM company; otherwise refuse it.
    if params.supplier_name ~= nil and blank(params.supplier_name) then
        if blank(link_params.supplier_name) then return err("supplier_name cannot be blank") end
        params.supplier_name = link_params.supplier_name
    end

    local sets, values = {}, {}
    for _, f in ipairs(HEADER_FIELDS) do
        if params[f] ~= nil then
            local v = str_or_nil(params[f])
            if f == "currency" then v = v and v:upper() or "GBP" end
            if f == "issue_date" and v == nil then v = row.issue_date end
            local cast = (f == "issue_date" or f == "expected_date") and "?::date" or "?"
            sets[#sets + 1] = f .. " = " .. cast
            values[#values + 1] = v == nil and db.NULL or v
        end
    end
    if type(params.metadata) == "table" then
        sets[#sets + 1] = "metadata = COALESCE(metadata, '{}'::jsonb) || ?::jsonb"
        values[#values + 1] = encode_obj(params.metadata)
    end
    if #sets == 0 then return PurchaseOrderQueries.get(uuid, namespace_id) end

    values[#values + 1] = row.id
    values[#values + 1] = namespace_id
    db.query("UPDATE purchase_orders SET " .. table.concat(sets, ", ")
        .. ", updated_at = NOW() WHERE id = ? AND namespace_id = ?", unpack(values))
    return PurchaseOrderQueries.get(uuid, namespace_id)
end

--- Soft-delete a draft PO.
function PurchaseOrderQueries.delete(uuid, namespace_id)
    local row = find_row(uuid, namespace_id)
    if not row then return err("Purchase order not found", "not_found") end
    if row.status ~= "draft" then
        return err("Only draft purchase orders can be deleted - cancel it instead", "conflict")
    end
    db.query("UPDATE purchase_orders SET deleted_at = NOW(), updated_at = NOW() WHERE id = ? AND namespace_id = ?",
        row.id, namespace_id)
    return true
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
    local row = find_row(uuid, namespace_id)
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
end

-- Item + its parent PO, both namespace-checked.
local function find_item(item_uuid, namespace_id)
    if blank(item_uuid) then return nil end
    local rows = db.query([[
        SELECT i.*, po.status AS po_status
        FROM purchase_order_items i
        JOIN purchase_orders po ON po.id = i.purchase_order_id AND po.namespace_id = i.namespace_id
        WHERE i.uuid = ? AND i.namespace_id = ? AND po.deleted_at IS NULL
    ]], tostring(item_uuid), namespace_id)
    return rows and rows[1]
end

function PurchaseOrderQueries.updateItem(item_uuid, namespace_id, params)
    local item = find_item(item_uuid, namespace_id)
    if not item then return err("Line item not found", "not_found") end
    if not ITEMS_EDITABLE[item.po_status] then
        return err("Lines can only be changed while the purchase order is a draft", "conflict")
    end
    local v, e, code = line_values(params or {}, item)
    if not v then return nil, e, code end
    local rows = db.query([[
        UPDATE purchase_order_items
        SET description = ?, quantity = ?, unit_price = ?, tax_rate = ?, tax_amount = ?, line_total = ?,
            sort_order = COALESCE(?, sort_order), updated_at = NOW()
        WHERE id = ? AND namespace_id = ?
        RETURNING *
    ]], v.description, v.quantity, v.unit_price, v.tax_rate, v.tax_amount, v.line_total,
        tonumber(params and params.sort_order) or db.NULL, item.id, namespace_id)
    recalc_totals(item.purchase_order_id, namespace_id)
    return shape_item(rows[1])
end

function PurchaseOrderQueries.deleteItem(item_uuid, namespace_id)
    local item = find_item(item_uuid, namespace_id)
    if not item then return err("Line item not found", "not_found") end
    if not ITEMS_EDITABLE[item.po_status] then
        return err("Lines can only be changed while the purchase order is a draft", "conflict")
    end
    db.query("DELETE FROM purchase_order_items WHERE id = ? AND namespace_id = ?", item.id, namespace_id)
    recalc_totals(item.purchase_order_id, namespace_id)
    return true
end

-- ============================================================
-- Goods receipt
-- ============================================================

--- Record received quantities.
-- @param body { items = [{ item_uuid|id, received_quantity }], receive_all = bool, note }
--   received_quantity is the line's new running total received (not a delta),
--   0 <= received_quantity <= ordered quantity. Lines not mentioned keep theirs.
function PurchaseOrderQueries.receive(uuid, namespace_id, user_uuid, body)
    body = body or {}
    local lines = body.items or body.lines
    if lines ~= nil and type(lines) ~= "table" then return err("items must be an array") end
    if not body.receive_all and (not lines or #lines == 0) then
        return err("Pass items [{item_uuid, received_quantity}] or receive_all: true")
    end

    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if not (PurchaseOrderQueries.canTransition(row.status, "partially_received")
            or PurchaseOrderQueries.canTransition(row.status, "received")) then
            return err("Cannot receive goods on a " .. row.status .. " purchase order", "conflict")
        end

        local items = items_for(row.id, namespace_id)
        local by_uuid = {}
        for _, it in ipairs(items) do by_uuid[it.uuid] = it end

        local changes = {}
        if body.receive_all == true or body.receive_all == "true" then
            for _, it in ipairs(items) do
                changes[#changes + 1] = { item = it, qty = tonumber(it.quantity) }
            end
        end
        for i, l in ipairs(lines or {}) do
            if type(l) ~= "table" then return err("each item must be an object") end
            local it = by_uuid[tostring(l.item_uuid or l.uuid or l.id or "")]
            if not it then return err("Line " .. i .. " is not on this purchase order", "not_found") end
            local qty = tonumber(l.received_quantity)
            if not qty or qty < 0 then return err("Line " .. i .. ": received_quantity must be 0 or more") end
            if qty > (tonumber(it.quantity) or 0) then
                return err("Line " .. i .. ": received " .. qty .. " is more than the "
                    .. tostring(it.quantity) .. " ordered")
            end
            changes[#changes + 1] = { item = it, qty = qty }
        end

        local log = {}
        for _, c in ipairs(changes) do
            c.item.received_quantity = c.qty
            db.query([[
                UPDATE purchase_order_items SET received_quantity = ?, updated_at = NOW()
                WHERE id = ? AND namespace_id = ?
            ]], c.qty, c.item.id, namespace_id)
            log[#log + 1] = { item_uuid = c.item.uuid, received_quantity = c.qty }
        end

        local new_status = PurchaseOrderQueries.receiptStatus(items)
        if not new_status then return err("Nothing has been received - enter at least one quantity") end
        if not PurchaseOrderQueries.canTransition(row.status, new_status) then
            return err("Cannot change a " .. row.status .. " purchase order to " .. new_status, "conflict")
        end

        db.query([[
            UPDATE purchase_orders
            SET status = ?,
                received_at = CASE WHEN ? = 'received' THEN NOW() ELSE received_at END,
                metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{receipts}',
                    COALESCE(metadata->'receipts', '[]'::jsonb) || ?::jsonb),
                updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], new_status, new_status, cjson.encode({ {
            at = ngx and ngx.utctime and ngx.utctime() or os.date("!%Y-%m-%d %H:%M:%S"),
            by = user_uuid,
            note = str_or_nil(body.note),
            lines = log,
        } }), row.id, namespace_id)
        return row
    end)
    if not done then return nil, e, code end
    return PurchaseOrderQueries.get(uuid, namespace_id)
end

-- ============================================================
-- Convert to bill
-- ============================================================

--- Bill a received / partially received PO. When the accounting feature is on,
-- creates an expense (vendor = supplier) in the purchase ledger and stores its
-- id + uuid in metadata (expense_id, expense_uuid). Billed POs are final.
-- @param opts { bill_date, category, notes }
function PurchaseOrderQueries.convertToBill(uuid, namespace_id, user_uuid, opts)
    opts = opts or {}
    local ProjectConfig = require("helper.project-config")
    local accounting_on = ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.ACCOUNTING)
        and table_exists("accounting_expenses")

    local done, e, code = in_transaction(function()
        local row = find_row(uuid, namespace_id, true)
        if not row then return err("Purchase order not found", "not_found") end
        if not PurchaseOrderQueries.canTransition(row.status, "billed") then
            return err("Only received or partially received purchase orders can be billed (this one is "
                .. row.status .. ")", "conflict")
        end
        local meta = type(row.metadata) == "table" and row.metadata or (cjson.decode(row.metadata or "{}") or {})
        if meta.expense_uuid then return err("This purchase order has already been billed", "conflict") end

        local amounts = PurchaseOrderQueries.billAmounts(items_for(row.id, namespace_id))
        if amounts.gross <= 0 then return err("Nothing received to bill") end

        local bill = {
            net = amounts.net, tax = amounts.tax, gross = amounts.gross, currency = row.currency,
            billed_by = user_uuid, bill_date = str_or_nil(opts.bill_date),
        }
        local patch = { bill = bill }

        if accounting_on then
            local AccountingQueries = require("queries.AccountingQueries")
            local label = row.po_number .. " - " .. row.supplier_name
            if not blank(row.reference) then label = label .. " (" .. row.reference .. ")" end
            local expense = AccountingQueries.createExpense({
                namespace_id = namespace_id,
                expense_date = str_or_nil(opts.bill_date) or os.date("%Y-%m-%d"),
                description = "Purchase order " .. label,
                amount = amounts.gross,
                currency = row.currency,
                category = str_or_nil(opts.category) or "purchases",
                vat_rate = amounts.vat_rate,
                vat_amount = amounts.tax,
                vendor = row.supplier_name,
                notes = str_or_nil(opts.notes),
                status = "pending",
                submitted_by_uuid = user_uuid,
                metadata = cjson.encode({
                    source = "purchase_order",
                    purchase_order_uuid = row.uuid,
                    po_number = row.po_number,
                    project_uuid = row.project_uuid,
                }),
            })
            if not expense then error("Failed to create the purchase-ledger expense") end
            patch.expense_id = expense.id
            patch.expense_uuid = expense.uuid
            bill.expense_uuid = expense.uuid
        end

        db.query([[
            UPDATE purchase_orders SET status = 'billed', billed_at = NOW(), updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], row.id, namespace_id)
        patch_metadata(row.id, namespace_id, patch)
        return row
    end)
    if not done then return nil, e, code end
    local po = PurchaseOrderQueries.get(uuid, namespace_id)
    po.accounting_expense_created = accounting_on
    return po
end

-- ============================================================
-- Stats (list page cards)
-- ============================================================

function PurchaseOrderQueries.getStats(namespace_id)
    local rows = db.query([[
        SELECT
            COUNT(*) AS total_count,
            COALESCE(SUM(total) FILTER (WHERE status <> 'cancelled'), 0) AS total_value,
            COUNT(*) FILTER (WHERE status = 'draft') AS draft_count,
            COUNT(*) FILTER (WHERE status IN ('sent','acknowledged','partially_received')) AS open_count,
            COALESCE(SUM(total) FILTER (WHERE status IN ('sent','acknowledged','partially_received')), 0) AS open_value,
            COUNT(*) FILTER (WHERE status IN ('sent','acknowledged','partially_received')
                             AND expected_date < CURRENT_DATE) AS overdue_count,
            COUNT(*) FILTER (WHERE status = 'received') AS to_bill_count,
            COALESCE(SUM(total) FILTER (WHERE status = 'received'), 0) AS to_bill_value,
            COALESCE(SUM(total) FILTER (WHERE status = 'billed'), 0) AS billed_value
        FROM purchase_orders
        WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id)
    local by_status = db.query([[
        SELECT status, COUNT(*) AS count, COALESCE(SUM(total), 0) AS total
        FROM purchase_orders
        WHERE namespace_id = ? AND deleted_at IS NULL
        GROUP BY status
    ]], namespace_id)

    local r = rows and rows[1] or {}
    local out = { by_status = by_status or {} }
    for _, k in ipairs({ "total_count", "total_value", "draft_count", "open_count", "open_value",
        "overdue_count", "to_bill_count", "to_bill_value", "billed_value" }) do
        out[k] = tonumber(r[k]) or 0
    end
    return out
end

return PurchaseOrderQueries
