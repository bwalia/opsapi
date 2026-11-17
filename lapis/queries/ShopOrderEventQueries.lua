-- luacheck: max line length 140
--[[
    Order progress and updates on the customer's order page
    ========================================================
    The customer's order page (shop /orders/:uuid?t=) shows two things built here:

      progress(o)   the same steps as the dashboard's "Progress" card (order placed, paid, supplier order raised,
                    ordered from supplier, goods received, shipped, delivered, invoiced), each { key, done, at,
                    detail? }. Customer-safe: never the supplier's name or our PO number.
      updates(o)    a log, newest first: staff comments and recorded events (shop_order_events, migration zzs62),
                    plus emails we sent the customer and delivery changes we approved (read from their own
                    tables, so older orders have a history too). Each { uuid?, kind, at, status?, title?, message? }.

    Staff (shop admin API):
      addComment(ns_id, order_uuid, body, actor, user_id)   body { message } → the new update
      remove(ns_id, order_uuid, event_uuid, actor)          hides a comment/event from the customer (soft delete)
      record(o, kind, fields)                               an event as it happens (status change, address change);
                                                            never fails the caller (logged and skipped instead)

    Messages are plain text (≤ 2000 characters); the shop renders them as text, never HTML. Authors are never
    shown to the customer.
]]

local db = require("lapis.db")
local Global = require("helper.global")
local U = require("lib.shop-util")
local R = require("lib.shop-delivery-change")

local Q = {}

Q.MESSAGE_MAX = 2000

-- Statuses worth telling the customer about when staff change them.
Q.LOGGED_STATUSES = { processing = true, shipped = true, delivered = true, cancelled = true, refunded = true }

-- Supplier PO statuses that count (the dashboard's OPEN_PO): a cancelled PO is ignored.
local OPEN_PO = { draft = true, sent = true, acknowledged = true, partially_received = true, received = true, billed = true }

local function iso_tz(col) -- timestamptz → "2026-11-17T15:23:42Z"
    return "to_char(" .. col .. " AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"
end

local function nn(v) return U.nz(v) or U.null end

local function warn(msg)
    if ngx and ngx.log then ngx.log(ngx.WARN, "[shop] order events: ", msg) end
end

-- ---------------------------------------------------------------------------
-- progress
-- ---------------------------------------------------------------------------

local function active_po(order_uuid, ns_id)
    local ok, rows = pcall(db.query, [[
        SELECT status, ]] .. iso_tz("created_at::timestamptz") .. [[ AS created_at,
               ]] .. iso_tz("sent_at::timestamptz") .. [[ AS sent_at,
               ]] .. iso_tz("received_at::timestamptz") .. [[ AS received_at
          FROM purchase_orders
         WHERE namespace_id = ? AND metadata->>'shop_order_uuid' = ? AND deleted_at IS NULL
         ORDER BY created_at DESC, id DESC]], ns_id, order_uuid)
    for _, p in ipairs(ok and rows or {}) do
        if OPEN_PO[p.status] then return p end
    end
    return nil
end

local function invoice_of(o)
    if not U.nz(o.invoice_uuid) then return nil end
    local ok, rows = pcall(db.query, "SELECT COALESCE(customer_invoice_number, invoice_number) AS invoice_number, "
        .. iso_tz("created_at::timestamptz") .. [[ AS created_at
        FROM invoices WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL]], o.namespace_id, o.invoice_uuid)
    return ok and rows[1] or nil
end

local function order_times(o)
    local ok, rows = pcall(db.query, "SELECT " .. iso_tz("created_at::timestamptz") .. " AS created_at, "
        .. iso_tz("paid_at::timestamptz") .. " AS paid_at FROM shop_orders WHERE id = ?", o.id)
    return ok and rows[1] or {}
end

local function quote_number(o)
    if not U.nz(o.quote_id) then return nil end
    local ok, rows = pcall(db.query, "SELECT quote_number FROM shop_quotes WHERE id = ?", o.quote_id)
    return ok and rows[1] and U.nz(rows[1].quote_number) or nil
end

local function payment_kind(o)
    if U.nz(o.payment_method) then return o.payment_method end
    if U.nz(o.stripe_payment_intent_id) or U.nz(o.stripe_session_id) then return "card" end
    return nil
end

function Q.progress(o)
    local t = order_times(o)
    local po = active_po(o.uuid, o.namespace_id)
    local tracking = U.dec(o.tracking, {})
    if type(tracking) ~= "table" then tracking = {} end
    local inv = invoice_of(o)
    local shipped = o.status == "shipped" or o.status == "delivered"
    local track = table.concat({ U.nz(tracking.carrier) or "", U.nz(tracking.tracking_number) or "" }, " "):match("^%s*(.-)%s*$")
    local steps = {
        { key = "placed", done = true, at = nn(t.created_at), detail = nn(quote_number(o)) },
        { key = "paid", done = U.nz(t.paid_at) ~= nil, at = nn(t.paid_at), detail = nn(U.nz(t.paid_at) and payment_kind(o)) },
        { key = "supplier_order", done = po ~= nil, at = nn(po and po.created_at) },
        { key = "ordered_from_supplier", done = po ~= nil and U.nz(po.sent_at) ~= nil, at = nn(po and po.sent_at) },
        { key = "goods_received", done = po ~= nil and (po.status == "received" or po.status == "billed"),
          at = nn(po and po.received_at), detail = nn(po and po.status == "partially_received" and "part_received") },
        { key = "shipped", done = shipped, at = nn(U.nz(tracking.shipped_at)), detail = nn(track ~= "" and track or nil) },
        { key = "delivered", done = o.status == "delivered" },
        { key = "invoiced", done = inv ~= nil or U.nz(o.invoice_uuid) ~= nil, at = nn(inv and inv.created_at),
          detail = nn(inv and inv.invoice_number) },
    }
    for _, s in ipairs(steps) do
        if s.at == nil then s.at = U.null end
        if s.detail == nil then s.detail = U.null end
    end
    return U.arr(steps)
end

-- ---------------------------------------------------------------------------
-- updates
-- ---------------------------------------------------------------------------

local EVENT_COLS = "e.uuid, e.kind, e.status, e.message, e.author, " .. iso_tz("e.created_at") .. " AS at"

function Q.updates(o, opts)
    opts = opts or {}
    local out = {}
    local ok, rows = pcall(db.query, "SELECT " .. EVENT_COLS .. [[ FROM shop_order_events e
        WHERE e.order_id = ? AND e.deleted_at IS NULL ORDER BY e.created_at DESC, e.id DESC LIMIT 200]], o.id)
    for _, r in ipairs(ok and rows or {}) do -- empty before migration zzs62
        local item = { uuid = r.uuid, kind = r.kind, at = r.at, status = nn(r.status), message = nn(r.message) }
        if opts.admin then item.author = nn(r.author); item.removable = true end
        out[#out + 1] = item
    end
    -- Emails we sent the customer (not staff test copies).
    ok, rows = pcall(db.query, "SELECT e.uuid, e.headline, e.body, " .. iso_tz("e.created_at") .. [[ AS at
        FROM shop_order_emails e WHERE e.order_id = ? AND e.test = false ORDER BY e.created_at DESC LIMIT 50]], o.id)
    for _, r in ipairs(ok and rows or {}) do
        out[#out + 1] = { uuid = r.uuid, kind = "email", at = r.at, title = nn(r.headline), message = nn(r.body), status = U.null }
    end
    -- Delivery changes the customer asked for and we approved.
    ok, rows = pcall(db.query, "SELECT r.uuid, r.requested_address::text AS requested_address, r.requested_date::text AS d, "
        .. "r.requested_window AS w, " .. iso_tz("r.decided_at") .. [[ AS at FROM shop_delivery_change_requests r
        WHERE r.order_id = ? AND r.status = 'approved' AND r.decided_at IS NOT NULL ORDER BY r.decided_at DESC LIMIT 50]], o.id)
    for _, r in ipairs(ok and rows or {}) do
        local parts = { R.describe_address(U.dec(r.requested_address, nil)) }
        if U.nz(r.d) then parts[#parts + 1] = R.date_label(r.d) end
        if U.nz(r.w) then parts[#parts + 1] = R.window_label(r.w) end
        out[#out + 1] = { uuid = r.uuid, kind = "delivery_change", at = r.at, message = table.concat(parts, "; "), status = U.null }
    end
    table.sort(out, function(a, b) return tostring(a.at) > tostring(b.at) end)
    return U.arr(out)
end

-- ---------------------------------------------------------------------------
-- writes
-- ---------------------------------------------------------------------------

--- Record an event (status change, staff address change). Never raises: a failure is logged and skipped,
-- so the order change that triggered it still goes through. Call inside the caller's transaction.
function Q.record(o, kind, fields)
    fields = fields or {}
    local ok, err = pcall(db.query, [[
        INSERT INTO shop_order_events (uuid, namespace_id, order_id, kind, status, message, author, author_user_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        Global.generateUUID(), o.namespace_id, o.id, kind, U.nz(fields.status) or db.NULL,
        U.nz(fields.message) and U.cut(fields.message, Q.MESSAGE_MAX) or db.NULL,
        U.nz(fields.author) and U.cut(tostring(fields.author), 254) or db.NULL, tonumber(fields.author_user_id) or db.NULL)
    if not ok then warn(tostring(err)) end
    return ok
end

local function order_for(ns_id, order_uuid)
    local Orders = require("queries.ShopOrderQueries")
    return Orders.getByUuid(ns_id, tostring(order_uuid or ""))
end

function Q.addComment(ns_id, order_uuid, body, actor, user_id)
    body = type(body) == "table" and body or {}
    if type(body.message) == "string" and #body.message > Q.MESSAGE_MAX * 4 then
        return nil, U.err(400, "VALIDATION_ERROR", "Keep the update under " .. Q.MESSAGE_MAX .. " characters", { field = "message" })
    end
    local message = R.clean_note(body.message, Q.MESSAGE_MAX)
    if not message or #message < 2 then
        return nil, U.err(400, "VALIDATION_ERROR", "Write the update for the customer", { field = "message" })
    end
    local o = order_for(ns_id, order_uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    local uuid = Global.generateUUID()
    db.query([[INSERT INTO shop_order_events (uuid, namespace_id, order_id, kind, message, author, author_user_id)
               VALUES (?, ?, ?, 'comment', ?, ?, ?)]], uuid, o.namespace_id, o.id, message,
        U.nz(actor) and U.cut(tostring(actor), 254) or db.NULL, tonumber(user_id) or db.NULL)
    local row = db.query("SELECT " .. EVENT_COLS .. " FROM shop_order_events e WHERE e.uuid = ?", uuid)[1]
    return { uuid = row.uuid, kind = row.kind, at = row.at, status = U.null, message = row.message,
             author = nn(row.author), removable = true }
end

function Q.remove(ns_id, order_uuid, event_uuid, actor)
    local o = order_for(ns_id, order_uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    local res = db.query([[UPDATE shop_order_events SET deleted_at = NOW(), deleted_by = ?
        WHERE order_id = ? AND uuid = ? AND deleted_at IS NULL RETURNING uuid]],
        U.nz(actor) and U.cut(tostring(actor), 254) or db.NULL, o.id, tostring(event_uuid or ""))
    if not res[1] then return nil, U.err(404, "NOT_FOUND", "Update not found") end
    return { uuid = res[1].uuid, removed = true }
end

return Q
