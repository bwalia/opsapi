-- luacheck: max line length 140
--[[
    Supplier portal (database side)
    ===============================
    Rules live in lib/supplier-portal.lua (pure, specced); files in lib/supplier-portal-files.lua; notifications
    in lib/supplier-portal-notify.lua. Routes: routes/supplier-portal.lua.

    Who sees what
      - A supplier login (supplier_portal_users) belongs to ONE shop supplier. It sees only that supplier's
        purchase orders: purchase_orders.metadata->>'shop_supplier_uuid' = its supplier's uuid, not drafts, not
        deleted, in its own workspace. Every id-taking query joins back to that filter, so another supplier's id
        is simply "not found" (404).
      - Staff (purchase_orders permission) see everything on their workspace's POs.
      - Customers: a supplier never sees our customer (lib/supplier-portal.lua supplierPo); staff messages to the
        supplier that name the customer are refused.

    Every change is written to namespace_audit_logs (entity_type 'purchase_order', entity_id = the PO uuid) with
    who (staff or supplier, user id and name), when and the IP address: that is the PO's history.

    Functions return (value) or (nil, err) where err = U.err(status, code, message).
]]

local db = require("lapis.db")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Rules = require("lib.supplier-portal")
local Files = require("lib.supplier-portal-files")
local Notify = require("lib.supplier-portal-notify")
local DealCodes = require("lib.deal-codes")
local unpack = table.unpack or unpack -- luacheck: ignore 143 113

local Q = {}

local NULL = U.null

-- ---------------------------------------------------------------------------
-- plumbing
-- ---------------------------------------------------------------------------

local function today()
    return os.date("!%Y-%m-%d", ngx and ngx.time() or os.time())
end

local exists_cache = {}
local function table_exists(name)
    if exists_cache[name] then return true end
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    local ok = r and r[1] and r[1].ok == true
    if ok then exists_cache[name] = true end
    return ok
end
Q.tableExists = table_exists

function Q.available()
    return table_exists("supplier_portal_users") and table_exists("purchase_order_documents")
end

local function v(x)
    if x == nil or x == NULL then return nil end
    return x
end
local function sqlv(x)
    if x == nil or x == NULL or x == false then return db.NULL end
    return x
end

local function client_ip()
    local ok, ip = pcall(function() return require("helper.client-ip").get() end)
    if ok and ip then return tostring(ip):sub(1, 64) end
    return ngx and ngx.var and ngx.var.remote_addr or nil
end

local function user_agent()
    local ok, ua = pcall(function() return ngx.var.http_user_agent end)
    return ok and ua and tostring(ua):sub(1, 500) or nil
end

--- Write one history entry. actor = { kind = staff|supplier|system, user_id, name }
local function audit(ns_id, entity_type, entity_id, action, actor, detail)
    local d = {}
    for k, x in pairs(detail or {}) do d[k] = x end
    d.by = actor and actor.kind or "system"
    d.by_name = actor and actor.name or nil
    db.query([[INSERT INTO namespace_audit_logs (uuid, namespace_id, user_id, action, entity_type, entity_id, new_values,
                                                  ip_address, user_agent, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())]],
        Global.generateUUID(), ns_id, tonumber(actor and actor.user_id) or db.NULL, action, entity_type, entity_id,
        U.enc(d), sqlv(client_ip()), sqlv(user_agent()))
end
local function po_audit(ns_id, po_uuid, action, actor, detail)
    return audit(ns_id, "purchase_order", po_uuid, action, actor, detail)
end
Q.audit = audit

function Q.settings(ns_id)
    local ok, rows = pcall(db.query, [[SELECT supplier_portal_enabled, supplier_portal_emails_enabled
                                         FROM shop_settings WHERE namespace_id = ?]], ns_id)
    local r = ok and rows[1] or {}
    return { enabled = r.supplier_portal_enabled == true, emails_enabled = r.supplier_portal_emails_enabled == true }
end

local function full_name(first, last, fallback)
    local n = U.join(" ", U.nz(first), U.nz(last))
    if n == "" then n = nil end
    return n or fallback
end

-- ---------------------------------------------------------------------------
-- who is asking
-- ---------------------------------------------------------------------------

--- The supplier_portal_users row of a user (by uuid), or nil. Any status: a disabled supplier login is still a
-- supplier login (helper/supplier-portal-guard.lua keeps it out of everything else).
function Q.supplierUserRow(user_uuid)
    if not user_uuid or not table_exists("supplier_portal_users") then return nil end
    return db.query([[SELECT spu.* FROM supplier_portal_users spu JOIN users u ON u.id = spu.user_id
                       WHERE u.uuid = ? LIMIT 1]], tostring(user_uuid))[1]
end

function Q.isSupplierUserId(user_id)
    if not user_id or not table_exists("supplier_portal_users") then return false end
    return db.query("SELECT 1 AS x FROM supplier_portal_users WHERE user_id = ? LIMIT 1", user_id)[1] ~= nil
end

--- The signed-in supplier: { kind = "supplier", user_id, user_uuid, name, email, ns_id, ns_name, supplier_id,
-- supplier_uuid, supplier_name, portal_user_uuid } | nil, err
function Q.supplierContext(current_user)
    if not Q.available() then
        return nil, U.err(404, "NOT_AVAILABLE", "The supplier portal isn't available here")
    end
    local uuid = current_user and current_user.uuid
    local r = uuid and db.query([[
        SELECT spu.id, spu.uuid, spu.status, spu.namespace_id, spu.supplier_id, spu.contact_name, spu.last_seen_at,
               spu.last_seen_at < NOW() - INTERVAL '5 minutes' AS seen_stale,
               u.id AS user_id, u.uuid AS user_uuid, u.email, u.first_name, u.last_name, u.active,
               s.uuid AS supplier_uuid, s.name AS supplier_name, s.is_active AS supplier_active,
               s.portal_enabled AS supplier_portal_enabled, n.name AS ns_name, n.status AS ns_status
          FROM supplier_portal_users spu
          JOIN users u ON u.id = spu.user_id
          JOIN shop_suppliers s ON s.id = spu.supplier_id AND s.namespace_id = spu.namespace_id
          JOIN namespaces n ON n.id = spu.namespace_id
         WHERE u.uuid = ? LIMIT 1]], tostring(uuid))[1]
    if not r then
        return nil, U.err(403, "NOT_A_SUPPLIER", "This sign-in isn't a supplier portal account")
    end
    if r.status == "disabled" or r.active == false then
        return nil, U.err(403, "ACCOUNT_DISABLED", "Your supplier portal access has been switched off. Please contact us.")
    end
    if r.ns_status ~= "active" or r.supplier_active == false then
        return nil, U.err(403, "PORTAL_NOT_AVAILABLE", "The supplier portal isn't available at the moment. Please contact us.")
    end
    if not Q.settings(r.namespace_id).enabled or r.supplier_portal_enabled ~= true then
        return nil, U.err(403, "PORTAL_NOT_AVAILABLE",
            "The supplier portal isn't available yet. Please keep using email with us for now - we'll let you know when it opens.")
    end
    if r.status == "invited" then
        db.query([[UPDATE supplier_portal_users SET status = 'active', activated_at = NOW(), last_seen_at = NOW(),
                   updated_at = NOW() WHERE id = ? AND namespace_id = ? AND status = 'invited']], r.id, r.namespace_id)
    elseif r.last_seen_at == nil or r.seen_stale == true then
        db.query("UPDATE supplier_portal_users SET last_seen_at = NOW() WHERE id = ? AND namespace_id = ?", r.id, r.namespace_id)
    end
    return {
        kind = "supplier", user_id = r.user_id, user_uuid = r.user_uuid,
        name = U.nz(r.contact_name) or full_name(r.first_name, r.last_name, r.email), email = r.email,
        ns_id = r.namespace_id, ns_name = r.ns_name, supplier_id = r.supplier_id, supplier_uuid = r.supplier_uuid,
        supplier_name = r.supplier_name, portal_user_uuid = r.uuid,
    }
end

--- A staff actor from the request (self.current_user).
function Q.staffActor(current_user)
    local u = current_user or {}
    local row = u.uuid and db.query("SELECT id, first_name, last_name, email FROM users WHERE uuid = ?", u.uuid)[1]
    return { kind = "staff", user_id = row and row.id, user_uuid = u.uuid,
             name = row and full_name(row.first_name, row.last_name, row.email) or u.email }
end

-- A scope says whose POs are reachable: staff (the workspace) or one supplier.
local function staff_scope(ns_id) return { ns_id = ns_id, kind = "staff" } end
local function supplier_scope(ctx) return { ns_id = ctx.ns_id, kind = "supplier", supplier_uuid = ctx.supplier_uuid } end
Q.staffScope, Q.supplierScope = staff_scope, supplier_scope

-- ---------------------------------------------------------------------------
-- purchase orders
-- ---------------------------------------------------------------------------

local col_cache = {}
local function has_column(tbl, col)
    local key = tbl .. "." .. col
    if col_cache[key] then return true end
    local ok = db.query([[SELECT 1 AS x FROM information_schema.columns WHERE table_schema = current_schema()
                          AND table_name = ? AND column_name = ?]], tbl, col)[1] ~= nil
    if ok then col_cache[key] = true end
    return ok
end

local function load_po(scope, po_uuid, for_update)
    if not U.nz(po_uuid) then return nil end
    local sql = [[SELECT id, uuid, namespace_id, po_number, status, portal_stage, portal_stage_at, closed_at,
                         supplier_name, supplier_email, supplier_phone, supplier_address, reference, issue_date::text AS issue_date,
                         expected_date::text AS expected_date, delivery_address, currency, notes, terms, subtotal, tax_total,
                         total, metadata::text AS metadata, created_by_uuid, sent_at, acknowledged_at, received_at, billed_at,
                         cancelled_at, created_at]] .. (has_column("purchase_orders", "deal_code") and ", deal_code" or "") .. [[
                    FROM purchase_orders WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL]]
    local args = { tostring(po_uuid), scope.ns_id }
    if scope.kind == "supplier" then
        sql = sql .. " AND metadata->>'shop_supplier_uuid' = ? AND status <> 'draft'"
        args[#args + 1] = scope.supplier_uuid
    end
    if for_update then sql = sql .. " FOR UPDATE" end
    local rows = db.query(sql, unpack(args))
    local po = rows[1]
    if not po then return nil end
    po.metadata = U.dec(po.metadata, {})
    if type(po.metadata) ~= "table" then po.metadata = {} end
    po.deal_code = v(po.deal_code) or v(po.metadata.deal_code)
    po.stage = Rules.effectiveStage(po)
    return po
end
Q._loadPo = load_po

local function not_found() return U.err(404, "NOT_FOUND", "Purchase order not found") end

local function po_items(po)
    return db.query([[SELECT description, quantity, unit_price, tax_rate, tax_amount, line_total
                        FROM purchase_order_items WHERE purchase_order_id = ? AND namespace_id = ?
                       ORDER BY sort_order, id]], po.id, po.namespace_id)
end

local function customer_markers(po)
    if not po.deal_code or not table_exists("shop_deal_codes") then return {} end
    local ok, m = pcall(function() return require("queries.ShopDealQueries").customerMarkers(po.namespace_id, po.deal_code) end)
    return ok and m or {}
end

local function invoices_of(po)
    return db.query([[SELECT i.id, i.uuid, i.kind, i.number, i.invoice_date::text AS invoice_date, i.due_date::text AS due_date,
                             i.supplier_order_ref, i.net, i.vat, i.total, i.currency, i.payment_terms, i.incoterm,
                             i.bank_details, i.note, i.created_by_kind, i.created_at, d.uuid AS document_uuid
                        FROM purchase_order_supplier_invoices i
                        LEFT JOIN purchase_order_documents d ON d.id = i.document_id AND d.deleted_at IS NULL
                       WHERE i.purchase_order_id = ? AND i.namespace_id = ? AND i.deleted_at IS NULL
                       ORDER BY i.created_at, i.id]], po.id, po.namespace_id)
end

local function payments_of(po, include_voided)
    return db.query([[SELECT p.id, p.uuid, p.amount, p.currency, p.method, p.sent_on::text AS sent_on,
                             p.cleared_on::text AS cleared_on, p.bank_transaction_id, p.payment_reference, p.note,
                             p.created_at, p.voided_at, p.void_reason, i.uuid AS invoice_uuid, i.number AS invoice_number,
                             i.kind AS invoice_kind, d.uuid AS proof_document_uuid
                        FROM purchase_order_payments p
                        LEFT JOIN purchase_order_supplier_invoices i ON i.id = p.supplier_invoice_id
                        LEFT JOIN purchase_order_documents d ON d.id = p.proof_document_id AND d.deleted_at IS NULL
                       WHERE p.purchase_order_id = ? AND p.namespace_id = ?]]
        .. (include_voided and "" or " AND p.voided_at IS NULL") .. " ORDER BY p.sent_on, p.id", po.id, po.namespace_id)
end

local function balance_of(po)
    local live = {}
    for _, p in ipairs(payments_of(po, false)) do live[#live + 1] = p end
    local invs = invoices_of(po)
    local has_final, has_proforma = false, false
    for _, i in ipairs(invs) do
        if i.kind == "invoice" then has_final = true end
        if i.kind == "proforma" then has_proforma = true end
    end
    local b = Rules.balance(po.total, invs, live)
    b.has_final, b.has_proforma = has_final, has_proforma
    return b, invs
end
Q._balanceOf = balance_of

local function shape_balance(b, currency)
    return { state = b.state, basis = b.basis, due = b.due_text, paid = b.paid_text, balance = b.balance_text,
             currency = currency or "GBP" }
end

--- Change the stored stage (inside a transaction, PO row locked). Keeps purchase_orders.status in step for the
-- moves the old PO page also knows (acknowledged, cancelled). opts: { system = true (payments), reason }
local function set_stage(po, to, actor, opts)
    opts = opts or {}
    local from = po.stage
    if from == to then return true end
    if not opts.system and not Rules.canTransition(from, to, actor.kind) then
        return nil, U.err(409, "WRONG_STAGE", "Can't change a purchase order that is " .. (Rules.LABELS[from] or from)
            .. " to " .. (Rules.LABELS[to] or to))
    end
    if to == "acknowledged" and po.status == "sent" then
        db.query([[UPDATE purchase_orders SET status = 'acknowledged', acknowledged_at = NOW(), updated_at = NOW()
                   WHERE id = ? AND namespace_id = ?]], po.id, po.namespace_id)
        po.status = "acknowledged"
    end
    if to == "cancelled" then
        if po.status ~= "draft" and po.status ~= "sent" and po.status ~= "acknowledged" then
            return nil, U.err(409, "WRONG_STAGE", "Goods have been received on this purchase order, so it can't be cancelled")
        end
        db.query([[UPDATE purchase_orders SET status = 'cancelled', cancelled_at = NOW(), updated_at = NOW()
                   WHERE id = ? AND namespace_id = ?]], po.id, po.namespace_id)
        po.status = "cancelled"
    end
    db.query([[UPDATE purchase_orders SET portal_stage = ?, portal_stage_at = NOW(),
               closed_at = CASE WHEN ? = 'closed' THEN NOW() ELSE closed_at END, updated_at = NOW()
               WHERE id = ? AND namespace_id = ?]], to, to, po.id, po.namespace_id)
    po.portal_stage = to
    po.stage = Rules.effectiveStage(po)
    po_audit(po.namespace_id, po.uuid, "po.stage_changed", actor,
        { from = from, to = to, reason = U.nz(opts.reason), auto = opts.system or nil })
    return true
end

-- Payments moved: part_paid / paid follow them while nothing has shipped.
local function restage_after_payment(po, actor)
    local b = balance_of(po)
    local to = Rules.stageAfterPayment(po.stage, b.state, b.has_proforma)
    if to ~= po.stage then
        local ok, err = set_stage(po, to, actor, { system = true })
        if not ok then return nil, err end
    end
    return b
end

-- ---------------------------------------------------------------------------
-- shapes
-- ---------------------------------------------------------------------------

local function doc_shape(d, for_supplier, ctx)
    local out = {
        id = d.uuid, doc_type = d.doc_type, label = Rules.DOC_TYPES[d.doc_type] or d.doc_type, filename = d.filename,
        content_type = d.content_type, size = tonumber(d.size_bytes), created_at = d.created_at,
        uploaded_by_kind = d.uploaded_by_kind, note = v(d.note) or NULL,
        po_id = d.po_uuid, po_number = d.po_number,
    }
    if for_supplier then
        out.uploaded_by = d.uploaded_by_kind == "supplier" and (v(d.uploader_name) or "Your team") or (ctx and ctx.ns_name or "Us")
    else
        out.uploaded_by = v(d.uploader_name) or NULL
        out.visible_to_supplier = d.visible_to_supplier == true
        out.scan_status = d.scan_status
        out.sha256 = d.sha256
        out.deleted_at = v(d.deleted_at) or NULL
        out.delete_reason = v(d.delete_reason) or NULL
    end
    return out
end

local DOC_COLS = [[d.uuid, d.doc_type, d.filename, d.content_type, d.size_bytes, d.sha256, d.scan_status,
                   d.visible_to_supplier, d.note, d.uploaded_by_kind, d.created_at, d.deleted_at, d.delete_reason,
                   po.uuid AS po_uuid, po.po_number,
                   NULLIF(TRIM(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')), '') AS uploader_name]]

local function docs_of(po, for_supplier)
    return db.query("SELECT " .. DOC_COLS .. [[
          FROM purchase_order_documents d JOIN purchase_orders po ON po.id = d.purchase_order_id
          LEFT JOIN users u ON u.id = d.uploaded_by_user_id
         WHERE d.purchase_order_id = ? AND d.namespace_id = ?]]
        .. (for_supplier and " AND d.deleted_at IS NULL AND d.visible_to_supplier" or "")
        .. " ORDER BY d.created_at, d.id", po.id, po.namespace_id)
end

local function invoice_shape(i, for_supplier, flags)
    local out = {
        id = i.uuid, kind = i.kind, label = Rules.KIND_LABEL[i.kind], number = i.number, invoice_date = i.invoice_date,
        due_date = v(i.due_date) or NULL, supplier_order_ref = v(i.supplier_order_ref) or NULL,
        net = i.net, vat = i.vat, total = i.total, currency = i.currency,
        payment_terms = v(i.payment_terms) or NULL, incoterm = v(i.incoterm) or NULL,
        bank_details = v(i.bank_details) or NULL, document_id = v(i.document_uuid) or NULL,
        created_by_kind = i.created_by_kind, created_at = i.created_at,
    }
    if not for_supplier then
        out.note = v(i.note) or NULL
        out.flags = U.arr(flags or {})
    end
    return out
end

local function payment_shape(p, for_supplier)
    local out = {
        id = p.uuid, amount = p.amount, currency = p.currency, method = p.method,
        method_label = Rules.PAYMENT_METHODS[p.method] or p.method, sent_on = p.sent_on,
        cleared_on = v(p.cleared_on) or NULL, payment_reference = v(p.payment_reference) or NULL,
        against = v(p.invoice_uuid) and { id = p.invoice_uuid, number = p.invoice_number, kind = p.invoice_kind } or NULL,
        proof_document_id = v(p.proof_document_uuid) or NULL, created_at = p.created_at,
        voided = v(p.voided_at) ~= nil, po_id = p.po_uuid, po_number = p.po_number,
    }
    if not for_supplier then
        out.bank_transaction_id = v(p.bank_transaction_id) or NULL
        out.note = v(p.note) or NULL
        out.voided_at = v(p.voided_at) or NULL
        out.void_reason = v(p.void_reason) or NULL
    end
    return out
end

local function shipments_of(po)
    return db.query([[SELECT s.uuid, s.carrier, s.tracking_number, s.tracking_url, s.dispatched_on::text AS dispatched_on,
                             s.expected_on::text AS expected_on, s.delivered_on::text AS delivered_on, s.received_by, s.note,
                             s.delivery_note, s.created_by_kind, s.created_at, d.uuid AS pod_document_uuid
                        FROM purchase_order_shipments s
                        LEFT JOIN purchase_order_documents d ON d.id = s.pod_document_id AND d.deleted_at IS NULL
                       WHERE s.purchase_order_id = ? AND s.namespace_id = ? ORDER BY s.dispatched_on, s.id]],
        po.id, po.namespace_id)
end

local function shipment_shape(s)
    return {
        id = s.uuid, carrier = s.carrier, tracking_number = v(s.tracking_number) or NULL,
        tracking_url = v(s.tracking_url) or NULL, dispatched_on = s.dispatched_on, expected_on = v(s.expected_on) or NULL,
        delivered_on = v(s.delivered_on) or NULL, received_by = v(s.received_by) or NULL, note = v(s.note) or NULL,
        delivery_note = v(s.delivery_note) or NULL, created_by_kind = s.created_by_kind,
        pod_document_id = v(s.pod_document_uuid) or NULL,
    }
end

local function messages_of(po)
    return db.query([[SELECT m.uuid, m.body, m.author_kind, m.created_at,
                             COALESCE(spu.contact_name, NULLIF(TRIM(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')), ''),
                                      u.email) AS author_name
                        FROM purchase_order_messages m
                        LEFT JOIN users u ON u.id = m.author_user_id
                        LEFT JOIN supplier_portal_users spu ON spu.user_id = m.author_user_id
                       WHERE m.purchase_order_id = ? AND m.namespace_id = ? AND m.deleted_at IS NULL
                       ORDER BY m.created_at, m.id]], po.id, po.namespace_id)
end

local function message_shape(m, for_supplier, ns_name)
    local by = m.author_name
    if for_supplier and m.author_kind == "staff" then by = ns_name or "Us" end
    return { id = m.uuid, body = m.body, author_kind = m.author_kind, author = by or NULL, created_at = m.created_at }
end

-- History: the audit rows of the PO, plus the dates the PO itself carries from before the portal existed.
local function history_of(po)
    local rows = db.query([[SELECT action, new_values, created_at FROM namespace_audit_logs
                             WHERE namespace_id = ? AND entity_type = 'purchase_order' AND entity_id = ?
                             ORDER BY id LIMIT 1000]], po.namespace_id, po.uuid)
    local out, seen = {}, {}
    for _, r in ipairs(rows) do
        local d = U.dec(r.new_values, {})
        if type(d) ~= "table" then d = {} end
        out[#out + 1] = { action = r.action, detail = d, at = r.created_at, actor_kind = d.by, actor_name = d.by_name }
        if r.action == "po.stage_changed" then seen[d.to or ""] = true end
    end
    local synthetic = {}
    local function add(at, to)
        if v(at) and not seen[to] then
            synthetic[#synthetic + 1] = { action = "po.stage_changed", detail = { to = to }, at = at, actor_kind = "staff" }
        end
    end
    add(po.sent_at, "sent")
    add(po.acknowledged_at, "acknowledged")
    add(po.cancelled_at, "cancelled")
    for _, s in ipairs(synthetic) do table.insert(out, 1, s) end
    table.sort(out, function(a, b) return tostring(a.at) < tostring(b.at) end)
    return out
end

local function staff_timeline(rows)
    local out = {}
    for _, r in ipairs(rows) do
        local d = {}
        for k, x in pairs(r.detail) do
            if k ~= "by" and k ~= "by_name" then d[k] = x end
        end
        out[#out + 1] = { action = r.action, detail = d, at = r.at, by_kind = r.actor_kind or "system",
                          by = r.actor_name or NULL }
    end
    return out
end

-- Our sale price of the deal, ex VAT, in pennies (to flag a supplier cost above it).
local function sale_net(po)
    local order_uuid = po.metadata.shop_order_uuid
    if not order_uuid or not table_exists("shop_orders") then return nil end
    local ok, rows = pcall(db.query, "SELECT subtotal_minor FROM shop_orders WHERE namespace_id = ? AND uuid = ?",
        po.namespace_id, order_uuid)
    return ok and rows[1] and tonumber(rows[1].subtotal_minor) or nil
end

local function previous_bank_details(po, before_id)
    local sup = po.metadata.shop_supplier_uuid
    if not sup then return nil end
    local r = db.query([[SELECT i.bank_details FROM purchase_order_supplier_invoices i
                           JOIN purchase_orders p ON p.id = i.purchase_order_id
                          WHERE i.namespace_id = ? AND p.metadata->>'shop_supplier_uuid' = ? AND i.bank_details IS NOT NULL
                            AND i.deleted_at IS NULL AND i.id < ? ORDER BY i.id DESC LIMIT 1]],
        po.namespace_id, sup, before_id or 9e15)[1]
    return r and r.bank_details
end

local function invoice_flags(po, inv)
    return Rules.invoiceFlags(inv, po, { sale_net = sale_net(po), previous_bank_details = previous_bank_details(po, inv.id) })
end

-- ---------------------------------------------------------------------------
-- supplier: reads
-- ---------------------------------------------------------------------------

local LIST_SQL = [[
    SELECT po.uuid, po.po_number, po.status, po.portal_stage, po.issue_date::text AS issue_date,
           po.expected_date::text AS expected_date, po.currency, po.total, po.reference, po.metadata->>'deal_code' AS deal_code,
           po.sent_at, po.updated_at,
           (SELECT COALESCE(SUM(amount), 0) FROM purchase_order_payments p
             WHERE p.purchase_order_id = po.id AND p.namespace_id = po.namespace_id AND p.voided_at IS NULL) AS paid,
           (SELECT COALESCE(SUM(total), 0) FROM purchase_order_supplier_invoices i WHERE i.purchase_order_id = po.id
               AND i.namespace_id = po.namespace_id AND i.kind = 'invoice' AND i.deleted_at IS NULL) AS invoiced,
           (SELECT COUNT(*) FROM purchase_order_supplier_invoices i WHERE i.purchase_order_id = po.id
               AND i.namespace_id = po.namespace_id AND i.kind = 'invoice' AND i.deleted_at IS NULL) AS invoice_count,
           (SELECT COALESCE(SUM(total), 0) FROM purchase_order_supplier_invoices i WHERE i.purchase_order_id = po.id
               AND i.namespace_id = po.namespace_id AND i.kind = 'credit_note' AND i.deleted_at IS NULL) AS credited,
           (SELECT total FROM purchase_order_supplier_invoices i WHERE i.purchase_order_id = po.id
               AND i.namespace_id = po.namespace_id AND i.kind = 'proforma' AND i.deleted_at IS NULL
             ORDER BY i.created_at DESC, i.id DESC LIMIT 1) AS proforma_total
      FROM purchase_orders po
     WHERE po.namespace_id = ? AND po.deleted_at IS NULL AND po.metadata->>'shop_supplier_uuid' = ? AND po.status <> 'draft'
]]

local function list_balance(r)
    local invs = {}
    if tonumber(r.invoice_count) and tonumber(r.invoice_count) > 0 then invs[#invs + 1] = { kind = "invoice", total = r.invoiced } end
    if v(r.proforma_total) then invs[#invs + 1] = { kind = "proforma", total = r.proforma_total } end
    if (Rules.pennies(r.credited) or 0) > 0 then invs[#invs + 1] = { kind = "credit_note", total = r.credited } end
    return Rules.balance(r.total, invs, { { amount = r.paid } })
end

--- GET /supplier-portal/purchase-orders?stage=open|all|<stage>&search=&page=&perPage=
function Q.supplierList(ctx, params)
    params = params or {}
    local page = math.max(1, U.int(params.page, 1) or 1)
    local per = U.clamp(U.int(params.perPage or params.per_page, 25) or 25, 1, 100)
    local sql, args = LIST_SQL, { ctx.ns_id, ctx.supplier_uuid }
    if U.nz(params.search) then
        sql = sql .. " AND (po.po_number ILIKE ? OR po.reference ILIKE ? OR po.metadata->>'deal_code' ILIKE ?)"
        local like = "%" .. tostring(params.search):sub(1, 60):gsub("[%%_\\]", "\\%0") .. "%"
        args[#args + 1], args[#args + 2], args[#args + 3] = like, like, like
    end
    sql = sql .. " ORDER BY po.issue_date DESC, po.id DESC"
    local rows = db.query(sql, unpack(args))
    local wanted = U.nz(params.stage) or "all"
    local out = {}
    for _, r in ipairs(rows) do
        local meta = { status = r.status, portal_stage = v(r.portal_stage) }
        local stage = Rules.effectiveStage(meta)
        local open = stage ~= "closed" and stage ~= "cancelled"
        if wanted == "all" or (wanted == "open" and open) or wanted == stage then
            local b = list_balance(r)
            out[#out + 1] = {
                id = r.uuid, po_number = r.po_number, stage = stage, stage_label = Rules.LABELS[stage],
                issue_date = r.issue_date, expected_date = v(r.expected_date) or NULL, currency = r.currency,
                total = r.total, reference = v(r.reference) or NULL, deal_code = v(r.deal_code) or NULL,
                balance = shape_balance(b, r.currency), updated_at = r.updated_at,
            }
        end
    end
    local total = #out
    local paged = {}
    for i = (page - 1) * per + 1, math.min(total, page * per) do paged[#paged + 1] = out[i] end
    return { data = U.arr(paged), meta = { total = total, page = page, perPage = per } }
end

--- What the supplier may do now.
local function supplier_can(po, b)
    local s = po.stage
    local act = Rules.supplierCanAct(s)
    return {
        acknowledge = s == "sent",
        upload = act,
        upload_proforma = act and Rules.RANK[s] <= Rules.RANK.paid,
        dispatch = act and (s == "sent" or s == "acknowledged" or s == "proforma_received" or s == "part_paid" or s == "paid"
            or s == "dispatched"),
        mark_delivered = act and s == "dispatched",
        upload_invoice = act,
        message = s ~= "draft",
        _balance = b and b.state or nil,
    }
end

--- GET /supplier-portal/purchase-orders/:uuid — the PO with its documents, invoices, payments, deliveries,
-- messages and history, as the supplier may see it. Logs the view.
function Q.supplierGet(ctx, po_uuid)
    local po = load_po(supplier_scope(ctx), po_uuid)
    if not po then return nil, not_found() end
    po.items = po_items(po)
    local b, invs = balance_of(po)
    local docs, inv_out, pay_out, ship_out, msg_out = {}, {}, {}, {}, {}
    for _, d in ipairs(docs_of(po, true)) do docs[#docs + 1] = doc_shape(d, true, ctx) end
    for _, i in ipairs(invs) do inv_out[#inv_out + 1] = invoice_shape(i, true) end
    for _, p in ipairs(payments_of(po, false)) do pay_out[#pay_out + 1] = payment_shape(p, true) end
    for _, s in ipairs(shipments_of(po)) do ship_out[#ship_out + 1] = shipment_shape(s) end
    for _, m in ipairs(messages_of(po)) do
        local shaped = message_shape(m, true, ctx.ns_name)
        msg_out[#msg_out + 1] = shaped
    end
    -- one "viewed" entry per person per PO per hour
    local recent = db.query([[SELECT 1 AS x FROM namespace_audit_logs WHERE namespace_id = ? AND entity_type = 'purchase_order'
                               AND entity_id = ? AND action = 'po.viewed' AND user_id = ?
                               AND created_at > NOW() - INTERVAL '1 hour' LIMIT 1]], ctx.ns_id, po.uuid, ctx.user_id)[1]
    if not recent then po_audit(ctx.ns_id, po.uuid, "po.viewed", ctx) end
    local can = supplier_can(po, b)
    can._balance = nil
    return {
        purchase_order = Rules.supplierPo(po, { stage = po.stage, company_name = ctx.ns_name, markers = customer_markers(po) }),
        balance = shape_balance(b, po.currency),
        documents = U.arr(docs), invoices = U.arr(inv_out), payments = U.arr(pay_out), shipments = U.arr(ship_out),
        messages = U.arr(msg_out),
        timeline = U.arr(Rules.supplierTimeline(history_of(po), ctx.ns_name)),
        can = can,
    }
end

--- GET /supplier-portal/documents?doc_type= — every document on this supplier's POs.
function Q.supplierDocuments(ctx, params)
    params = params or {}
    local sql = "SELECT " .. DOC_COLS .. [[
          FROM purchase_order_documents d JOIN purchase_orders po ON po.id = d.purchase_order_id AND po.namespace_id = d.namespace_id
          LEFT JOIN users u ON u.id = d.uploaded_by_user_id
         WHERE d.namespace_id = ? AND po.deleted_at IS NULL AND po.status <> 'draft' AND po.metadata->>'shop_supplier_uuid' = ?
           AND d.deleted_at IS NULL AND d.visible_to_supplier]]
    local args = { ctx.ns_id, ctx.supplier_uuid }
    if U.nz(params.doc_type) and Rules.DOC_TYPES[params.doc_type] then
        sql = sql .. " AND d.doc_type = ?"
        args[#args + 1] = params.doc_type
    end
    local rows = db.query(sql .. " ORDER BY d.created_at DESC, d.id DESC LIMIT 500", unpack(args))
    local out = {}
    for _, d in ipairs(rows) do out[#out + 1] = doc_shape(d, true, ctx) end
    return U.arr(out)
end

--- GET /supplier-portal/payments — every payment we made on this supplier's POs.
function Q.supplierPayments(ctx)
    local rows = db.query([[
        SELECT p.uuid, p.amount, p.currency, p.method, p.sent_on::text AS sent_on, p.cleared_on::text AS cleared_on,
               p.payment_reference, p.created_at, p.voided_at, i.uuid AS invoice_uuid, i.number AS invoice_number,
               i.kind AS invoice_kind, d.uuid AS proof_document_uuid, po.uuid AS po_uuid, po.po_number
          FROM purchase_order_payments p
          JOIN purchase_orders po ON po.id = p.purchase_order_id AND po.namespace_id = p.namespace_id
          LEFT JOIN purchase_order_supplier_invoices i ON i.id = p.supplier_invoice_id
          LEFT JOIN purchase_order_documents d ON d.id = p.proof_document_id AND d.deleted_at IS NULL AND d.visible_to_supplier
         WHERE p.namespace_id = ? AND po.deleted_at IS NULL AND po.status <> 'draft' AND po.metadata->>'shop_supplier_uuid' = ?
           AND p.voided_at IS NULL
         ORDER BY p.sent_on DESC, p.id DESC LIMIT 500]], ctx.ns_id, ctx.supplier_uuid)
    local out = {}
    for _, p in ipairs(rows) do out[#out + 1] = payment_shape(p, true) end
    return U.arr(out)
end

--- GET /supplier-portal/messages — the latest messages on this supplier's POs.
function Q.supplierMessages(ctx)
    local rows = db.query([[
        SELECT m.uuid, m.body, m.author_kind, m.created_at, po.uuid AS po_uuid, po.po_number,
               COALESCE(spu.contact_name, NULLIF(TRIM(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')), ''),
                        u.email) AS author_name
          FROM purchase_order_messages m
          JOIN purchase_orders po ON po.id = m.purchase_order_id AND po.namespace_id = m.namespace_id
          LEFT JOIN users u ON u.id = m.author_user_id
          LEFT JOIN supplier_portal_users spu ON spu.user_id = m.author_user_id
         WHERE m.namespace_id = ? AND po.deleted_at IS NULL AND po.status <> 'draft' AND po.metadata->>'shop_supplier_uuid' = ?
           AND m.deleted_at IS NULL
         ORDER BY m.created_at DESC, m.id DESC LIMIT 200]], ctx.ns_id, ctx.supplier_uuid)
    local out = {}
    for _, m in ipairs(rows) do
        local s = message_shape(m, true, ctx.ns_name)
        s.po_id, s.po_number = m.po_uuid, m.po_number
        out[#out + 1] = s
    end
    return U.arr(out)
end

-- ---------------------------------------------------------------------------
-- actions shared by staff and suppliers
-- ---------------------------------------------------------------------------

--- Acknowledge a PO (supplier, or staff on the supplier's behalf).
function Q.acknowledge(scope, po_uuid, actor, body)
    body = type(body) == "table" and body or {}
    local po_out
    local res, err = U.tx(function()
        local po = load_po(scope, po_uuid, true)
        if not po then return nil, not_found() end
        if po.stage ~= "sent" then
            return nil, U.err(409, "WRONG_STAGE", "Only a purchase order that has just been sent can be acknowledged (this one is "
                .. (Rules.LABELS[po.stage] or po.stage) .. ")")
        end
        local ok, serr = set_stage(po, "acknowledged", actor, { reason = U.nz(body.note) })
        if not ok then return nil, serr end
        po_out = po
        return true
    end)
    if not res then return nil, err end
    if actor.kind == "supplier" then
        Notify.toStaff(scope.ns_id, po_out, "acknowledged", { summary = actor.name .. " acknowledged " .. po_out.po_number })
    end
    return true
end

-- Customer details must never reach the supplier: refuse staff text that names the customer (deal-coded POs).
local function check_private(po, texts)
    local drop = Rules.dropShipVisible(po)
    if drop then return true end
    local markers = customer_markers(po)
    if #markers == 0 then return true end
    local leaked = DealCodes.leaks(texts, markers)
    if #leaked > 0 then
        return nil, U.err(422, "CUSTOMER_DETAILS_FOR_SUPPLIER", "The supplier must not see our customer's details. Remove the customer's "
            .. table.concat(leaked, ", ") .. " (the deal code is the only reference they need)", { fields = U.arr(leaked) })
    end
    return true
end

local function insert_doc(po, d, actor)
    local row = db.query([[
        INSERT INTO purchase_order_documents (uuid, namespace_id, purchase_order_id, doc_type, filename, content_type, size_bytes,
               sha256, storage_bucket, storage_key, scan_status, visible_to_supplier, note, uploaded_by_user_id, uploaded_by_kind,
               created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW()) RETURNING id, uuid]],
        d.uuid, po.namespace_id, po.id, d.doc_type, d.filename, d.content_type, d.size, d.sha256, sqlv(d.bucket), d.key,
        d.scan_status, d.visible ~= false, sqlv(d.note), tonumber(actor.user_id) or db.NULL, actor.kind)[1]
    po_audit(po.namespace_id, po.uuid, "document.uploaded", actor,
        { document = d.uuid, doc_type = d.doc_type, filename = d.filename, size = d.size,
          visible_to_supplier = d.visible ~= false })
    return row
end

local function insert_invoice(po, f, actor, document_id)
    local dup = db.query([[SELECT 1 AS x FROM purchase_order_supplier_invoices WHERE namespace_id = ? AND purchase_order_id = ?
                            AND kind = ? AND lower(number) = lower(?) AND deleted_at IS NULL]],
        po.namespace_id, po.id, f.kind, f.number)[1]
    if dup then
        return nil, U.err(409, "DUPLICATE_NUMBER", (Rules.KIND_LABEL[f.kind] or "Invoice") .. " " .. f.number
            .. " is already on this purchase order. Ask us to remove the old one first, or use the new number.")
    end
    local row = db.query([[
        INSERT INTO purchase_order_supplier_invoices (uuid, namespace_id, purchase_order_id, kind, number, invoice_date, due_date,
               supplier_order_ref, net, vat, total, currency, payment_terms, incoterm, bank_details, note, document_id,
               created_by_user_id, created_by_kind, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?::date, ?::date, ?, ?::numeric, ?::numeric, ?::numeric, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
        RETURNING id, uuid]],
        Global.generateUUID(), po.namespace_id, po.id, f.kind, f.number, f.invoice_date, sqlv(f.due_date),
        sqlv(f.supplier_order_ref), f.net, f.vat, f.total, f.currency, sqlv(f.payment_terms), sqlv(f.incoterm),
        sqlv(f.bank_details), sqlv(f.note), document_id or db.NULL, tonumber(actor.user_id) or db.NULL, actor.kind)[1]
    po_audit(po.namespace_id, po.uuid, "invoice.recorded", actor,
        { invoice = row.uuid, kind = f.kind, number = f.number, total = f.total, currency = f.currency })
    return row
end

-- Stage moves after a proforma / final invoice is recorded.
local function stage_after_invoice(po, kind, actor)
    if kind == "proforma" then
        if po.stage == "sent" then
            local ok, err = set_stage(po, "acknowledged", actor)
            if not ok then return nil, err end
        end
        if po.stage == "acknowledged" then
            local ok, err = set_stage(po, "proforma_received", actor)
            if not ok then return nil, err end
        end
    elseif kind == "invoice" and po.stage == "delivered" then
        local ok, err = set_stage(po, "invoiced", actor)
        if not ok then return nil, err end
    end
    return true
end

-- Validate, scan and store a file (before any transaction). → stored doc fields | nil, err
local function store_file(po, file, doc_type, _, extra)
    local checked, ferr = Rules.checkFile(file)
    if not checked then
        local too_big = type(file) == "table" and type(file.content) == "string" and #file.content > Rules.MAX_FILE_BYTES
        return nil, U.err(too_big and 413 or 400, "INVALID_FILE", ferr)
    end
    local scan, serr = Files.scan(file.content)
    if not scan then return nil, U.err(422, "FILE_REFUSED", serr) end
    if not Files.configured() then
        return nil, U.err(503, "STORAGE_UNAVAILABLE", "File storage isn't set up here, so documents can't be uploaded yet")
    end
    local uuid = Global.generateUUID()
    local key = Files.key(po.namespace_id, po.uuid, uuid)
    local stored, perr = Files.put(key, file.content, checked.content_type)
    if not stored then return nil, U.err(503, "STORAGE_UNAVAILABLE", perr) end
    return {
        uuid = uuid, doc_type = doc_type, filename = checked.filename, content_type = checked.content_type,
        size = checked.size, sha256 = Files.sha256hex(file.content), bucket = stored.bucket, key = stored.key,
        scan_status = scan, note = extra and extra.note, visible = extra and extra.visible,
    }
end

--- Upload a document (multipart). fields: { doc_type, note?, invoice? (for proforma / vat_invoice / credit_note:
-- number, invoice_date, net, vat, total, ...), visible_to_supplier? (staff) }
function Q.upload(scope, po_uuid, actor, file, fields)
    fields = type(fields) == "table" and fields or {}
    local doc_type = U.nz(fields.doc_type)
    if not Rules.DOC_TYPES[doc_type or ""] then
        return nil, U.err(400, "VALIDATION_ERROR", "doc_type must be one of: proforma, vat_invoice, delivery_note, "
            .. "proof_of_delivery, credit_note, other" .. (actor.kind == "staff" and ", purchase_order, payment_proof" or ""))
    end
    if not Rules.mayUpload(doc_type, actor.kind) then
        return nil, U.err(403, "NOT_ALLOWED", "Only we can add " .. Rules.DOC_TYPES[doc_type]:lower() .. " documents")
    end
    local po = load_po(scope, po_uuid)
    if not po then return nil, not_found() end
    if actor.kind == "supplier" and not Rules.supplierCanAct(po.stage) then
        return nil, U.err(409, "WRONG_STAGE", "This purchase order is " .. Rules.LABELS[po.stage]:lower()
            .. ", so nothing more can be added")
    end
    local note = U.nz(fields.note)
    if note and #tostring(note) > 1000 then return nil, U.err(400, "VALIDATION_ERROR", "note can be at most 1000 characters") end
    local inv
    local kind = Rules.DOC_INVOICE_KIND[doc_type]
    if kind then
        local given = fields.invoice
        if type(given) == "string" then given = U.dec(given, nil) end
        if type(given) ~= "table" then
            return nil, U.err(400, "VALIDATION_ERROR", "Fill in the " .. Rules.KIND_LABEL[kind]:lower()
                .. " details (number, date, net, VAT and total)")
        end
        given.kind = kind
        local ierr
        inv, ierr = Rules.invoiceFields(given, po.currency)
        if not inv then return nil, U.err(400, "VALIDATION_ERROR", ierr) end
    end
    local visible = true
    if actor.kind == "staff" and (fields.visible_to_supplier == false or fields.visible_to_supplier == "false") then visible = false end
    if actor.kind == "staff" and visible then
        local ok, perr = check_private(po, { note or "", file and file.filename or "" })
        if not ok then return nil, perr end
    end
    local stored, serr = store_file(po, file, doc_type, actor, { note = note, visible = visible })
    if not stored then return nil, serr end
    local out, locked_po
    local res, err = U.tx(function()
        local p = load_po(scope, po_uuid, true)
        if not p then return nil, not_found() end
        if actor.kind == "supplier" and not Rules.supplierCanAct(p.stage) then
            return nil, U.err(409, "WRONG_STAGE", "This purchase order can't be changed any more")
        end
        local d = insert_doc(p, stored, actor)
        out = { document = { id = d.uuid, doc_type = doc_type, filename = stored.filename, size = stored.size } }
        if inv then
            local row, ierr = insert_invoice(p, inv, actor, d.id)
            if not row then return nil, ierr end
            local ok, sterr = stage_after_invoice(p, inv.kind, actor)
            if not ok then return nil, sterr end
            out.invoice = { id = row.uuid, kind = inv.kind, number = inv.number, total = inv.total }
        end
        out.stage = p.stage
        locked_po = p
        return true
    end)
    if not res then
        Files.remove(stored.bucket, stored.key)
        return nil, err
    end
    local summary = (actor.name or "") .. " added " .. (Rules.DOC_TYPES[doc_type] or doc_type):lower() .. " " .. stored.filename
    if actor.kind == "supplier" then
        Notify.toStaff(scope.ns_id, locked_po, "document_uploaded", { summary = summary })
    elseif visible then
        out.notification = Notify.toSupplier(scope.ns_id, locked_po, "document_uploaded",
            { summary = (Rules.DOC_TYPES[doc_type] or doc_type) .. ": " .. stored.filename })
    end
    return out
end

--- Record dispatch: { carrier, tracking_number?, tracking_url?, dispatched_on?, expected_on?, note? }
function Q.dispatch(scope, po_uuid, actor, body)
    local f, ferr = Rules.shipmentFields(body, today())
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local po_out, ship_uuid
    local res, err = U.tx(function()
        local po = load_po(scope, po_uuid, true)
        if not po then return nil, not_found() end
        if actor.kind == "supplier" and not Rules.supplierCanAct(po.stage) then
            return nil, U.err(409, "WRONG_STAGE", "This purchase order can't be changed any more")
        end
        if po.stage == "sent" then
            local ok, serr = set_stage(po, "acknowledged", actor)
            if not ok then return nil, serr end
        end
        local s = po.stage
        if not (s == "acknowledged" or s == "proforma_received" or s == "part_paid" or s == "paid" or s == "dispatched") then
            return nil, U.err(409, "WRONG_STAGE", "Dispatch can't be recorded on a purchase order that is " .. Rules.LABELS[s]:lower())
        end
        ship_uuid = Global.generateUUID()
        db.query([[INSERT INTO purchase_order_shipments (uuid, namespace_id, purchase_order_id, carrier, tracking_number, tracking_url,
                   dispatched_on, expected_on, note, created_by_user_id, created_by_kind, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?::date, ?::date, ?, ?, ?, NOW(), NOW())]],
            ship_uuid, po.namespace_id, po.id, f.carrier, sqlv(f.tracking_number), sqlv(f.tracking_url), f.dispatched_on,
            sqlv(f.expected_on), sqlv(f.note), tonumber(actor.user_id) or db.NULL, actor.kind)
        po_audit(po.namespace_id, po.uuid, "shipment.dispatched", actor,
            { shipment = ship_uuid, carrier = f.carrier, tracking_number = f.tracking_number, dispatched_on = f.dispatched_on })
        if s ~= "dispatched" then
            local ok, serr = set_stage(po, "dispatched", actor)
            if not ok then return nil, serr end
        end
        po_out = po
        return true
    end)
    if not res then return nil, err end
    if actor.kind == "supplier" then
        Notify.toStaff(scope.ns_id, po_out, "dispatched", { summary = po_out.po_number .. " dispatched with " .. f.carrier
            .. (f.tracking_number and (" (tracking " .. f.tracking_number .. ")") or "") })
    end
    return { shipment = { id = ship_uuid }, stage = po_out.stage }
end

--- Mark delivered, with the proof of delivery (file now, or one already uploaded).
-- body: { delivered_on?, received_by?, note?, shipment_id? }
function Q.delivered(scope, po_uuid, actor, body, file)
    local f, ferr = Rules.deliveryFields(body, today(), os.date("!%Y-%m-%d", (ngx and ngx.time() or os.time()) + 86400))
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local po = load_po(scope, po_uuid)
    if not po then return nil, not_found() end
    if po.stage ~= "dispatched" then
        return nil, U.err(409, "WRONG_STAGE", "Record the dispatch first: only a dispatched purchase order can be marked delivered")
    end
    local stored
    if type(file) == "table" and file.content then
        local serr
        stored, serr = store_file(po, file, "proof_of_delivery", actor, { note = f.note })
        if not stored then return nil, serr end
    end
    local po_out
    local res, err = U.tx(function()
        local p = load_po(scope, po_uuid, true)
        if not p then return nil, not_found() end
        if p.stage ~= "dispatched" then return nil, U.err(409, "WRONG_STAGE", "This purchase order isn't dispatched any more") end
        local pod_id
        if stored then
            pod_id = insert_doc(p, stored, actor).id
        else
            local existing = db.query([[SELECT id FROM purchase_order_documents WHERE purchase_order_id = ? AND namespace_id = ?
                                         AND doc_type IN ('proof_of_delivery', 'delivery_note') AND deleted_at IS NULL
                                         ORDER BY id DESC LIMIT 1]], p.id, p.namespace_id)[1]
            if not existing then
                return nil, U.err(400, "POD_REQUIRED", "Attach the proof of delivery (a signed delivery note or the courier's proof)")
            end
            pod_id = existing.id
        end
        local only_one, args = "", { p.id, p.namespace_id }
        if U.nz(body and body.shipment_id) then
            only_one = " AND uuid = ?"
            args[#args + 1] = tostring(body.shipment_id)
        end
        db.query([[UPDATE purchase_order_shipments SET delivered_on = ?::date, received_by = ?, delivery_note = ?,
                   pod_document_id = ?, delivered_by_user_id = ?, delivered_by_kind = ?, updated_at = NOW()
                   WHERE purchase_order_id = ? AND namespace_id = ? AND delivered_on IS NULL]] .. only_one,
            f.delivered_on, sqlv(f.received_by), sqlv(f.note), pod_id, tonumber(actor.user_id) or db.NULL, actor.kind,
            unpack(args))
        po_audit(p.namespace_id, p.uuid, "shipment.delivered", actor, { delivered_on = f.delivered_on, received_by = f.received_by })
        local ok, serr = set_stage(p, "delivered", actor)
        if not ok then return nil, serr end
        local fin = db.query([[SELECT 1 AS x FROM purchase_order_supplier_invoices WHERE purchase_order_id = ? AND namespace_id = ?
                                AND kind = 'invoice' AND deleted_at IS NULL LIMIT 1]], p.id, p.namespace_id)[1]
        if fin then
            ok, serr = set_stage(p, "invoiced", actor, { system = true })
            if not ok then return nil, serr end
        end
        po_out = p
        return true
    end)
    if not res then
        if stored then Files.remove(stored.bucket, stored.key) end
        return nil, err
    end
    if actor.kind == "supplier" then
        Notify.toStaff(scope.ns_id, po_out, "delivered", { summary = po_out.po_number .. " delivered on " .. f.delivered_on })
    end
    return { stage = po_out.stage }
end

--- Post a message on the PO thread.
function Q.postMessage(scope, po_uuid, actor, body)
    local text, terr = Rules.messageBody(type(body) == "table" and body.body or nil)
    if not text then return nil, U.err(400, "VALIDATION_ERROR", terr) end
    local po = load_po(scope, po_uuid)
    if not po then return nil, not_found() end
    if po.stage == "draft" and actor.kind == "staff" then
        return nil, U.err(409, "WRONG_STAGE", "Send the purchase order before writing to the supplier")
    end
    if actor.kind == "staff" then
        local ok, perr = check_private(po, { text })
        if not ok then return nil, perr end
    end
    local id = Global.generateUUID()
    local res, err = U.tx(function()
        local p = load_po(scope, po_uuid, true)
        if not p then return nil, not_found() end
        db.query([[INSERT INTO purchase_order_messages (uuid, namespace_id, purchase_order_id, author_user_id, author_kind, body,
                   created_at)
                   VALUES (?, ?, ?, ?, ?, ?, NOW())]], id, p.namespace_id, p.id, tonumber(actor.user_id) or db.NULL, actor.kind, text)
        po_audit(p.namespace_id, p.uuid, "message.posted", actor, { message = id })
        return true
    end)
    if not res then return nil, err end
    local out = { id = id }
    if actor.kind == "supplier" then
        Notify.toStaff(scope.ns_id, po, "message_posted", { summary = actor.name .. ": " .. text:sub(1, 200) })
    else
        out.notification = Notify.toSupplier(scope.ns_id, po, "message_posted", { summary = "We wrote to you about " .. po.po_number })
    end
    return out
end

--- A short-lived download link for one document the caller may see.
function Q.documentLink(scope, doc_uuid, actor)
    if not U.nz(doc_uuid) then return nil, U.err(404, "NOT_FOUND", "Document not found") end
    local sql = [[SELECT d.uuid, d.doc_type, d.filename, po.uuid AS po_uuid FROM purchase_order_documents d
                    JOIN purchase_orders po ON po.id = d.purchase_order_id AND po.namespace_id = d.namespace_id
                   WHERE d.uuid = ? AND d.namespace_id = ? AND d.deleted_at IS NULL AND po.deleted_at IS NULL]]
    local args = { tostring(doc_uuid), scope.ns_id }
    if scope.kind == "supplier" then
        sql = sql .. " AND d.visible_to_supplier AND po.status <> 'draft' AND po.metadata->>'shop_supplier_uuid' = ?"
        args[#args + 1] = scope.supplier_uuid
    end
    local d = db.query(sql, unpack(args))[1]
    if not d then return nil, U.err(404, "NOT_FOUND", "Document not found") end
    local link = Files.signLink(d.uuid, actor.user_uuid)
    link.filename = d.filename
    return link
end

--- GET /api/v2/public/supplier-portal/files/:token — the file, if the link is valid and its person may still see it.
-- → { content, content_type, filename } | nil, err
function Q.download(token)
    local t, why = Files.verifyLink(token)
    if not t then
        return nil, U.err(why == "expired" and 410 or 403, why == "expired" and "LINK_EXPIRED" or "INVALID_LINK",
            why == "expired" and "This download link has expired: open the document again from the portal"
                or "This download link isn't valid")
    end
    local d = db.query([[SELECT d.id, d.uuid, d.namespace_id, d.doc_type, d.filename, d.content_type, d.storage_bucket,
                                d.storage_key, d.visible_to_supplier, po.uuid AS po_uuid, po.status AS po_status,
                                po.metadata->>'shop_supplier_uuid' AS supplier_uuid
                           FROM purchase_order_documents d
                           JOIN purchase_orders po ON po.id = d.purchase_order_id AND po.namespace_id = d.namespace_id
                          WHERE d.uuid = ? AND d.deleted_at IS NULL AND po.deleted_at IS NULL]], t.doc_uuid)[1]
    if not d then return nil, U.err(404, "NOT_FOUND", "Document not found") end
    local user = db.query("SELECT id, uuid, first_name, last_name, email, active FROM users WHERE uuid = ?", t.user_uuid)[1]
    if not user or user.active == false then return nil, U.err(403, "INVALID_LINK", "This download link isn't valid") end
    local actor
    local sup = db.query([[SELECT spu.status, spu.namespace_id, spu.contact_name, s.uuid AS supplier_uuid
                             FROM supplier_portal_users spu JOIN shop_suppliers s ON s.id = spu.supplier_id
                            WHERE spu.user_id = ?]], user.id)[1]
    if sup then
        local ctx = Q.supplierContext({ uuid = user.uuid })
        if not ctx or sup.namespace_id ~= d.namespace_id or sup.supplier_uuid ~= d.supplier_uuid or d.visible_to_supplier ~= true
            or d.po_status == "draft" then
            return nil, U.err(403, "INVALID_LINK", "This download link isn't valid")
        end
        actor = ctx
    else
        -- staff: still an active member of the workspace with purchase order access
        local m = db.query([[SELECT nm.id, nm.is_owner FROM namespace_members nm
                              WHERE nm.user_id = ? AND nm.namespace_id = ? AND nm.status = 'active']], user.id, d.namespace_id)[1]
        local allowed = m and (m.is_owner == true)
        if m and not allowed then
            local ok, perms = pcall(function() return require("queries.NamespaceMemberQueries").getPermissions(m.id) end)
            local p = ok and type(perms) == "table" and perms.purchase_orders
            if type(p) == "table" then
                for _, a in ipairs(p) do if a == "read" or a == "manage" then allowed = true end end
            end
        end
        if not allowed then
            local AdminCheck = require("helper.admin-check")
            local ok, pa = pcall(AdminCheck.isPlatformAdmin, { uuid = user.uuid, id = user.id })
            allowed = ok and pa == true
        end
        if not allowed then return nil, U.err(403, "INVALID_LINK", "This download link isn't valid") end
        actor = { kind = "staff", user_id = user.id, name = full_name(user.first_name, user.last_name, user.email) }
    end
    local content, gerr = Files.get(d.storage_bucket, d.storage_key)
    if not content then return nil, U.err(503, "STORAGE_UNAVAILABLE", gerr) end
    pcall(po_audit, d.namespace_id, d.po_uuid, "document.downloaded", actor,
        { document = d.uuid, doc_type = d.doc_type, filename = d.filename })
    return { content = content, content_type = d.content_type, filename = d.filename }
end

-- ---------------------------------------------------------------------------
-- staff
-- ---------------------------------------------------------------------------

local function linked_supplier(po)
    local sup_uuid = po.metadata.shop_supplier_uuid
    if not sup_uuid then return nil end
    return db.query("SELECT id, uuid, name, portal_enabled, is_active FROM shop_suppliers WHERE uuid = ? AND namespace_id = ?",
        sup_uuid, po.namespace_id)[1]
end

local function portal_users_of(ns_id, supplier_id)
    local rows = db.query([[SELECT spu.uuid, spu.contact_name, spu.email, spu.status, spu.invited_at, spu.activated_at,
                                   spu.last_seen_at, spu.disabled_at
                              FROM supplier_portal_users spu WHERE spu.namespace_id = ? AND spu.supplier_id = ?
                             ORDER BY spu.id]], ns_id, supplier_id)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { id = r.uuid, name = v(r.contact_name) or NULL, email = r.email, status = r.status,
                          invited_at = r.invited_at, activated_at = v(r.activated_at) or NULL,
                          last_seen_at = v(r.last_seen_at) or NULL, disabled_at = v(r.disabled_at) or NULL }
    end
    return out
end

local STAFF_MOVES = { acknowledged = true, cancelled = true, closed = true }

--- GET /purchase-orders/:uuid/portal — everything on the staff PO page's supplier panels.
function Q.staffPanel(ns_id, po_uuid)
    local po = load_po(staff_scope(ns_id), po_uuid)
    if not po then return nil, not_found() end
    local b, invs = balance_of(po)
    local docs, inv_out, pay_out, ship_out, msg_out = {}, {}, {}, {}, {}
    for _, d in ipairs(docs_of(po, false)) do docs[#docs + 1] = doc_shape(d, false) end
    local latest_proforma
    for _, i in ipairs(invs) do if i.kind == "proforma" then latest_proforma = i.uuid end end
    for _, i in ipairs(invs) do
        local s = invoice_shape(i, false, invoice_flags(po, i))
        s.superseded = i.kind == "proforma" and i.uuid ~= latest_proforma or nil
        inv_out[#inv_out + 1] = s
    end
    for _, p in ipairs(payments_of(po, true)) do pay_out[#pay_out + 1] = payment_shape(p, false) end
    for _, s in ipairs(shipments_of(po)) do ship_out[#ship_out + 1] = shipment_shape(s) end
    for _, m in ipairs(messages_of(po)) do msg_out[#msg_out + 1] = message_shape(m, false) end
    local next_stages = {}
    for to in pairs(STAFF_MOVES) do
        if Rules.canTransition(po.stage, to, "staff") then next_stages[#next_stages + 1] = to end
    end
    table.sort(next_stages)
    local sup = linked_supplier(po)
    local settings = Q.settings(ns_id)
    local users = sup and portal_users_of(ns_id, sup.id) or {}
    local drop, drop_kind = Rules.dropShipVisible(po)
    return {
        purchase_order = { id = po.uuid, po_number = po.po_number, status = po.status, stage = po.stage,
                           stage_label = Rules.LABELS[po.stage], portal_stage = v(po.portal_stage) or NULL,
                           total = po.total, subtotal = po.subtotal, tax_total = po.tax_total, currency = po.currency,
                           supplier_name = po.supplier_name, deal_code = po.deal_code or NULL,
                           drop_ship = drop, drop_ship_kind = drop_kind or NULL, closed_at = v(po.closed_at) or NULL },
        stages = U.arr(Rules.STAGES), next_stages = U.arr(next_stages),
        balance = shape_balance(b, po.currency), has_final_invoice = b.has_final,
        documents = U.arr(docs), invoices = U.arr(inv_out), payments = U.arr(pay_out), shipments = U.arr(ship_out),
        messages = U.arr(msg_out), timeline = U.arr(staff_timeline(history_of(po))),
        supplier = sup and { id = sup.uuid, name = sup.name, portal_enabled = sup.portal_enabled == true,
                             users = U.arr(users) } or NULL,
        portal = {
            enabled = settings.enabled, emails_enabled = settings.emails_enabled,
            supplier_can_see = sup ~= nil and settings.enabled and sup.portal_enabled == true and #users > 0
                and po.status ~= "draft",
            notice = settings.emails_enabled and "Supplier emails are on: the supplier's portal users are emailed about changes."
                or "Supplier emails are off: nothing is emailed to the supplier. They see changes when they sign in to the portal.",
        },
    }
end

--- Link a PO to a shop supplier (POs raised by hand, or before the portal). body: { supplier_id, confirm? }
function Q.link(ns_id, po_uuid, actor, body)
    body = type(body) == "table" and body or {}
    local sup = U.nz(body.supplier_id) and db.query("SELECT id, uuid, name FROM shop_suppliers WHERE uuid = ? AND namespace_id = ?",
        tostring(body.supplier_id), ns_id)[1]
    if not sup then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
    local res, err = U.tx(function()
        local po = load_po(staff_scope(ns_id), po_uuid, true)
        if not po then return nil, not_found() end
        local cur = po.metadata.shop_supplier_uuid
        if cur == sup.uuid then return true end
        if cur and body.confirm ~= true then
            return nil, U.err(409, "ALREADY_LINKED", "This purchase order is already linked to another supplier: confirm to move it")
        end
        db.query([[UPDATE purchase_orders
                   SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('shop_supplier_uuid', ?::text),
                   updated_at = NOW() WHERE id = ? AND namespace_id = ?]], sup.uuid, po.id, ns_id)
        po_audit(ns_id, po.uuid, "po.supplier_linked", actor, { supplier = sup.uuid, supplier_name = sup.name, previous = cur })
        return true
    end)
    if not res then return nil, err end
    return Q.staffPanel(ns_id, po_uuid)
end

--- Staff stage moves: acknowledged (on the supplier's behalf), cancelled, closed. body: { to, reason?, force? }
function Q.staffStage(ns_id, po_uuid, actor, body)
    body = type(body) == "table" and body or {}
    local to = U.nz(body.to)
    if not STAFF_MOVES[to or ""] then
        return nil, U.err(400, "VALIDATION_ERROR", "to must be acknowledged, cancelled or closed (other stages follow the "
            .. "documents, payments and deliveries)")
    end
    local reason = U.nz(body.reason)
    if reason and #tostring(reason) > 1000 then return nil, U.err(400, "VALIDATION_ERROR", "reason can be at most 1000 characters") end
    local po_out
    local res, err = U.tx(function()
        local po = load_po(staff_scope(ns_id), po_uuid, true)
        if not po then return nil, not_found() end
        if to == "closed" then
            local b = balance_of(po)
            local ok, cerr = Rules.canClose(po.stage, b, b.has_final, body.force == true or body.force == "true", reason)
            if not ok then return nil, U.err(409, "CANNOT_CLOSE", cerr) end
        end
        local ok, serr = set_stage(po, to, actor, { reason = reason })
        if not ok then return nil, serr end
        po_out = po
        return true
    end)
    if not res then return nil, err end
    if to == "cancelled" then Notify.toSupplier(ns_id, po_out, "po_cancelled", { summary = po_out.po_number .. " was cancelled" }) end
    return Q.staffPanel(ns_id, po_uuid)
end

--- Record a proforma / final invoice / credit note without a file (it came by email; attach it later), or
-- with document_id of a document already uploaded. body: invoice fields + kind, document_id?
function Q.recordInvoice(ns_id, po_uuid, actor, body)
    body = type(body) == "table" and body or {}
    local po = load_po(staff_scope(ns_id), po_uuid)
    if not po then return nil, not_found() end
    local f, ferr = Rules.invoiceFields(body, po.currency)
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local res, err = U.tx(function()
        local p = load_po(staff_scope(ns_id), po_uuid, true)
        if not p then return nil, not_found() end
        local doc_id
        if U.nz(body.document_id) then
            local d = db.query([[SELECT id FROM purchase_order_documents WHERE uuid = ? AND purchase_order_id = ? AND namespace_id = ?
                                  AND deleted_at IS NULL]], tostring(body.document_id), p.id, ns_id)[1]
            if not d then return nil, U.err(404, "NOT_FOUND", "Document not found on this purchase order") end
            doc_id = d.id
        end
        local row, ierr = insert_invoice(p, f, actor, doc_id)
        if not row then return nil, ierr end
        local ok, serr = stage_after_invoice(p, f.kind, actor)
        if not ok then return nil, serr end
        return true
    end)
    if not res then return nil, err end
    return Q.staffPanel(ns_id, po_uuid)
end

--- Remove (soft-delete) an invoice record. body: { reason }
function Q.deleteInvoice(ns_id, po_uuid, inv_uuid, actor, body)
    local reason = U.nz(type(body) == "table" and body.reason or nil)
    if not reason then return nil, U.err(400, "VALIDATION_ERROR", "Give a reason for removing it") end
    local res, err = U.tx(function()
        local po = load_po(staff_scope(ns_id), po_uuid, true)
        if not po then return nil, not_found() end
        local i = db.query([[SELECT id, kind, number FROM purchase_order_supplier_invoices WHERE uuid = ? AND purchase_order_id = ?
                              AND namespace_id = ? AND deleted_at IS NULL]], tostring(inv_uuid), po.id, ns_id)[1]
        if not i then return nil, U.err(404, "NOT_FOUND", "Invoice not found") end
        db.query([[UPDATE purchase_order_supplier_invoices SET deleted_at = NOW(), deleted_by_user_id = ?, delete_reason = ?,
                   updated_at = NOW() WHERE id = ? AND namespace_id = ?]], tonumber(actor.user_id) or db.NULL,
            tostring(reason):sub(1, 1000), i.id, ns_id)
        po_audit(ns_id, po.uuid, "invoice.removed", actor, { kind = i.kind, number = i.number, reason = reason })
        local ok, rerr = restage_after_payment(po, actor)
        if not ok then return nil, rerr end
        return true
    end)
    if not res then return nil, err end
    return Q.staffPanel(ns_id, po_uuid)
end

--- Remove (soft-delete) a document. Staff only; the file stays in storage for the record.
function Q.deleteDocument(ns_id, po_uuid, doc_uuid, actor, body)
    local reason = U.nz(type(body) == "table" and body.reason or nil)
    if not reason then return nil, U.err(400, "VALIDATION_ERROR", "Give a reason for removing it") end
    local res, err = U.tx(function()
        local po = load_po(staff_scope(ns_id), po_uuid, true)
        if not po then return nil, not_found() end
        local d = db.query([[SELECT id, doc_type, filename FROM purchase_order_documents WHERE uuid = ? AND purchase_order_id = ?
                              AND namespace_id = ? AND deleted_at IS NULL]], tostring(doc_uuid), po.id, ns_id)[1]
        if not d then return nil, U.err(404, "NOT_FOUND", "Document not found") end
        db.query([[UPDATE purchase_order_documents SET deleted_at = NOW(), deleted_by_user_id = ?, delete_reason = ?
                   WHERE id = ? AND namespace_id = ?]], tonumber(actor.user_id) or db.NULL, tostring(reason):sub(1, 1000), d.id, ns_id)
        po_audit(ns_id, po.uuid, "document.removed", actor, { document = doc_uuid, doc_type = d.doc_type, filename = d.filename,
                                                             reason = reason })
        return true
    end)
    if not res then return nil, err end
    return Q.staffPanel(ns_id, po_uuid)
end

--- Record a payment (staff only), optionally with the bank's confirmation as a file.
-- body: { amount, method, sent_on, cleared_on?, bank_transaction_id?, payment_reference?, invoice_id?, note?,
--         proof_document_id? }
function Q.recordPayment(ns_id, po_uuid, actor, body, file)
    body = type(body) == "table" and body or {}
    local po = load_po(staff_scope(ns_id), po_uuid)
    if not po then return nil, not_found() end
    if po.stage == "draft" or po.stage == "cancelled" then
        return nil, U.err(409, "WRONG_STAGE", "Payments can't be recorded on a " .. Rules.LABELS[po.stage]:lower() .. " purchase order")
    end
    local f, ferr = Rules.paymentFields(body, po.currency)
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local stored
    if type(file) == "table" and file.content then
        local serr
        stored, serr = store_file(po, file, "payment_proof", actor, { note = "Payment " .. f.amount .. " " .. f.currency })
        if not stored then return nil, serr end
    end
    local pay_uuid = Global.generateUUID()
    local po_out
    local res, err = U.tx(function()
        local p = load_po(staff_scope(ns_id), po_uuid, true)
        if not p then return nil, not_found() end
        local inv_id
        if U.nz(body.invoice_id) then
            local i = db.query([[SELECT id FROM purchase_order_supplier_invoices WHERE uuid = ? AND purchase_order_id = ?
                                  AND namespace_id = ? AND deleted_at IS NULL]], tostring(body.invoice_id), p.id, ns_id)[1]
            if not i then return nil, U.err(404, "NOT_FOUND", "That proforma or invoice isn't on this purchase order") end
            inv_id = i.id
        end
        local proof_id
        if stored then
            proof_id = insert_doc(p, stored, actor).id
        elseif U.nz(body.proof_document_id) then
            local d = db.query([[SELECT id FROM purchase_order_documents WHERE uuid = ? AND purchase_order_id = ? AND namespace_id = ?
                                  AND deleted_at IS NULL]], tostring(body.proof_document_id), p.id, ns_id)[1]
            if not d then return nil, U.err(404, "NOT_FOUND", "Proof document not found on this purchase order") end
            proof_id = d.id
        end
        db.query([[INSERT INTO purchase_order_payments (uuid, namespace_id, purchase_order_id, supplier_invoice_id, amount, currency,
                   method, sent_on, cleared_on, bank_transaction_id, payment_reference, proof_document_id, note, created_by_user_id,
                   created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?::numeric, ?, ?, ?::date, ?::date, ?, ?, ?, ?, ?, NOW(), NOW())]],
            pay_uuid, ns_id, p.id, inv_id or db.NULL, f.amount, f.currency, f.method, f.sent_on, sqlv(f.cleared_on),
            sqlv(f.bank_transaction_id), sqlv(f.payment_reference), proof_id or db.NULL, sqlv(f.note),
            tonumber(actor.user_id) or db.NULL)
        po_audit(ns_id, p.uuid, "payment.recorded", actor, { payment = pay_uuid, amount = f.amount, currency = f.currency,
            method = f.method, payment_reference = f.payment_reference, sent_on = f.sent_on, cleared_on = f.cleared_on })
        local b, rerr = restage_after_payment(p, actor)
        if not b then return nil, rerr end
        po_out = p
        return true
    end)
    if not res then
        if stored then Files.remove(stored.bucket, stored.key) end
        return nil, err
    end
    local note = Notify.toSupplier(ns_id, po_out, "payment_recorded",
        { summary = "Payment of " .. f.amount .. " " .. f.currency .. " sent on " .. f.sent_on
            .. (f.payment_reference and (", reference " .. f.payment_reference) or "") })
    local panel = Q.staffPanel(ns_id, po_uuid)
    panel.notification = note
    panel.recorded_payment = pay_uuid
    return panel
end

--- Update the details of a payment we can still learn later: cleared_on, bank_transaction_id, payment_reference, note.
function Q.updatePayment(ns_id, po_uuid, pay_uuid, actor, body)
    body = type(body) == "table" and body or {}
    local res, err = U.tx(function()
        local po = load_po(staff_scope(ns_id), po_uuid, true)
        if not po then return nil, not_found() end
        local p = db.query([[SELECT id, sent_on::text AS sent_on, amount, method, cleared_on::text AS cleared_on, bank_transaction_id,
                                    payment_reference, note, currency FROM purchase_order_payments WHERE uuid = ? AND purchase_order_id = ?
                                AND namespace_id = ? AND voided_at IS NULL]], tostring(pay_uuid), po.id, ns_id)[1]
        if not p then return nil, U.err(404, "NOT_FOUND", "Payment not found") end
        local merged = { amount = p.amount, method = p.method, sent_on = p.sent_on, currency = p.currency }
        for _, k in ipairs({ "cleared_on", "bank_transaction_id", "payment_reference", "note" }) do
            if body[k] ~= nil then merged[k] = body[k] else merged[k] = v(p[k]) end
        end
        local f, ferr = Rules.paymentFields(merged, po.currency)
        if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
        db.query([[UPDATE purchase_order_payments SET cleared_on = ?::date, bank_transaction_id = ?, payment_reference = ?, note = ?,
                   updated_at = NOW() WHERE id = ? AND namespace_id = ?]], sqlv(f.cleared_on), sqlv(f.bank_transaction_id),
            sqlv(f.payment_reference), sqlv(f.note), p.id, ns_id)
        po_audit(ns_id, po.uuid, "payment.updated", actor, { payment = pay_uuid, cleared_on = f.cleared_on })
        return true
    end)
    if not res then return nil, err end
    return Q.staffPanel(ns_id, po_uuid)
end

--- Void a payment recorded by mistake (never deleted). body: { reason }
function Q.voidPayment(ns_id, po_uuid, pay_uuid, actor, body)
    local reason = U.nz(type(body) == "table" and body.reason or nil)
    if not reason then return nil, U.err(400, "VALIDATION_ERROR", "Give a reason for voiding it") end
    local res, err = U.tx(function()
        local po = load_po(staff_scope(ns_id), po_uuid, true)
        if not po then return nil, not_found() end
        local p = db.query([[SELECT id, amount, currency FROM purchase_order_payments WHERE uuid = ? AND purchase_order_id = ?
                              AND namespace_id = ? AND voided_at IS NULL]], tostring(pay_uuid), po.id, ns_id)[1]
        if not p then return nil, U.err(404, "NOT_FOUND", "Payment not found") end
        db.query([[UPDATE purchase_order_payments SET voided_at = NOW(), voided_by_user_id = ?, void_reason = ?, updated_at = NOW()
                   WHERE id = ? AND namespace_id = ?]], tonumber(actor.user_id) or db.NULL, tostring(reason):sub(1, 1000), p.id, ns_id)
        po_audit(ns_id, po.uuid, "payment.voided", actor, { payment = pay_uuid, amount = p.amount, currency = p.currency, reason = reason })
        local ok, rerr = restage_after_payment(po, actor)
        if not ok then return nil, rerr end
        return true
    end)
    if not res then return nil, err end
    return Q.staffPanel(ns_id, po_uuid)
end

--- The PO has been shared with the supplier (marked sent): tell them, if supplier emails are on.
-- Never raises: the PO was sent whatever happens here.
function Q.notifyShared(ns_id, po_uuid)
    local ok, res = pcall(function()
        if not Q.available() then return nil end
        local po = load_po(staff_scope(ns_id), po_uuid)
        if not po or not po.metadata.shop_supplier_uuid then return nil end
        return Notify.toSupplier(ns_id, po, "po_shared", { summary = "Purchase order " .. po.po_number .. " is in your portal" })
    end)
    if not ok then ngx.log(ngx.WARN, "[supplier-portal] PO shared notice failed: ", tostring(res)) end
    return ok and res or nil
end

-- ---------------------------------------------------------------------------
-- staff: supplier portal logins
-- ---------------------------------------------------------------------------

local function supplier_row(ns_id, supplier_uuid)
    return U.nz(supplier_uuid) and db.query("SELECT id, uuid, name, portal_enabled FROM shop_suppliers WHERE uuid = ? AND namespace_id = ?",
        tostring(supplier_uuid), ns_id)[1] or nil
end

function Q.listPortalUsers(ns_id, supplier_uuid)
    local sup = supplier_row(ns_id, supplier_uuid)
    if not sup then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
    local s = Q.settings(ns_id)
    return { supplier = { id = sup.uuid, name = sup.name, portal_enabled = sup.portal_enabled == true },
             users = U.arr(portal_users_of(ns_id, sup.id)), portal = s }
end

-- The workspace's "supplier" role: no permissions at all; signs in to /supplier.
local function supplier_role(ns_id)
    local r = db.query("SELECT id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'supplier'", ns_id)[1]
    if r then return r.id end
    local has_landing = has_column("namespace_roles", "landing_path")
    r = db.query([[INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, description, permissions, is_system,
                   is_default, priority, created_at, updated_at]] .. (has_landing and ", landing_path" or "") .. [[)
                   VALUES (?, ?, 'supplier', 'Supplier (portal only)', ?, '{}', true, false, 0, NOW(), NOW()]]
                   .. (has_landing and ", '/supplier'" or "") .. [[) ON CONFLICT (namespace_id, role_name) DO NOTHING RETURNING id]],
        Global.generateUUID(), ns_id, "Supplier contacts: they only see their own purchase orders in the supplier portal")[1]
    if r then return r.id end
    return db.query("SELECT id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'supplier'", ns_id)[1].id
end

local INVITE_DAYS = 7

local function set_password_link(user_id)
    local PasswordReset = require("helper.password-reset")
    local raw, perr = PasswordReset.create(user_id, client_ip(), INVITE_DAYS * 86400)
    if not raw then return nil, perr end
    return "/reset-password?token=" .. raw
end

--- Invite a supplier contact: a login of its own (never an existing user), member of this workspace with only the
-- "supplier" role, linked to this supplier. Returns the set-password link (valid 7 days) for staff to pass on;
-- it is emailed only when supplier emails are on. body: { email, name? }
function Q.invite(ns_id, supplier_uuid, actor, body)
    local f, ferr = Rules.inviteFields(body)
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local sup = supplier_row(ns_id, supplier_uuid)
    if not sup then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
    local existing = db.query("SELECT id FROM users WHERE lower(email) = ? OR lower(username) = ?", f.email, f.email)[1]
    if existing then
        local spu = db.query("SELECT uuid, supplier_id, namespace_id FROM supplier_portal_users WHERE user_id = ?", existing.id)[1]
        if spu and spu.supplier_id == sup.id and spu.namespace_id == ns_id then
            return nil, U.err(409, "ALREADY_INVITED",
                "This contact already has a portal login: use \"New sign-in link\" to send them a new one")
        end
        return nil, U.err(409, "EMAIL_IN_USE", "This email already has a login here (staff, a customer or another supplier). "
            .. "Use a different address for the supplier's portal login, for example name+supplier@yourdomain.co.uk.")
    end
    local spu_uuid, user_id
    local res, err = U.tx(function()
        local random = U.token(32)
        local u = db.query([[INSERT INTO users (uuid, email, username, first_name, last_name, password, active, created_at, updated_at)
                             VALUES (?, ?, ?, ?, ?, ?, true, NOW(), NOW()) RETURNING id]],
            Global.generateUUID(), f.email, f.email, f.first_name, f.last_name, Global.hashPassword(random))[1]
        user_id = u.id
        local role_id = supplier_role(ns_id)
        local m = db.query([[INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, invited_by,
                             created_at, updated_at) VALUES (?, ?, ?, 'active', false, NOW(), ?, NOW(), NOW()) RETURNING id]],
            Global.generateUUID(), ns_id, u.id, tonumber(actor.user_id) or db.NULL)[1]
        db.query([[INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
                   VALUES (?, ?, ?, NOW(), NOW())]], Global.generateUUID(), m.id, role_id)
        if table_exists("user_namespace_settings") then
            db.query([[INSERT INTO user_namespace_settings (user_id, default_namespace_id, last_active_namespace_id, created_at, updated_at)
                       VALUES (?, ?, ?, NOW(), NOW())]], u.id, ns_id, ns_id)
        end
        spu_uuid = Global.generateUUID()
        db.query([[INSERT INTO supplier_portal_users (uuid, namespace_id, supplier_id, user_id, contact_name, email, status,
                   invited_by_user_id, invited_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 'invited', ?, NOW(), NOW(), NOW())]],
            spu_uuid, ns_id, sup.id, u.id, U.nz(body.name) or db.NULL, f.email, tonumber(actor.user_id) or db.NULL)
        db.query("UPDATE shop_suppliers SET portal_enabled = true, updated_at = NOW() WHERE id = ?", sup.id)
        audit(ns_id, "shop_supplier", sup.uuid, "supplier_portal.user_invited", actor, { portal_user = spu_uuid, email = f.email })
        return true
    end)
    if not res then return nil, err end
    local path, lerr = set_password_link(user_id)
    if not path then ngx.log(ngx.ERR, "[supplier-portal] invite link failed: ", tostring(lerr)) end
    local settings = Q.settings(ns_id)
    return {
        user = { id = spu_uuid, email = f.email, name = U.nz(body.name) or NULL, status = "invited" },
        set_password_path = path or NULL, expires_in_days = INVITE_DAYS,
        emailed = false,
        message = settings.enabled
            and "Login created. Nothing has been emailed: copy the sign-in link and pass it on yourself."
            or "Login created. The supplier portal is still switched off (Shop → Settings), so they will see \"not available yet\" "
                .. "until you switch it on. Nothing has been emailed.",
    }
end

--- A new set-password link for a contact (the old one stops working).
function Q.newLink(ns_id, supplier_uuid, pu_uuid, actor)
    local sup = supplier_row(ns_id, supplier_uuid)
    if not sup then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
    local r = db.query([[SELECT id, user_id, status FROM supplier_portal_users WHERE uuid = ? AND namespace_id = ? AND supplier_id = ?]],
        tostring(pu_uuid), ns_id, sup.id)[1]
    if not r then return nil, U.err(404, "NOT_FOUND", "Portal login not found") end
    if r.status == "disabled" then return nil, U.err(409, "ACCOUNT_DISABLED", "Switch this login back on first") end
    local path = set_password_link(r.user_id)
    audit(ns_id, "shop_supplier", sup.uuid, "supplier_portal.link_issued", actor, { portal_user = pu_uuid })
    return { set_password_path = path or NULL, expires_in_days = INVITE_DAYS, emailed = false }
end

--- Switch a contact's login off or on again. Off also ends their sessions.
function Q.setUserStatus(ns_id, supplier_uuid, pu_uuid, actor, enabled)
    local sup = supplier_row(ns_id, supplier_uuid)
    if not sup then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
    local r = db.query([[SELECT id, user_id, status, activated_at FROM supplier_portal_users WHERE uuid = ? AND namespace_id = ?
                          AND supplier_id = ?]], tostring(pu_uuid), ns_id, sup.id)[1]
    if not r then return nil, U.err(404, "NOT_FOUND", "Portal login not found") end
    local status = enabled and (r.activated_at and r.activated_at ~= NULL and "active" or "invited") or "disabled"
    db.query([[UPDATE supplier_portal_users SET status = ?, disabled_at = CASE WHEN ? = 'disabled' THEN NOW() ELSE NULL END,
               updated_at = NOW() WHERE id = ? AND namespace_id = ?]], status, status, r.id, ns_id)
    if not enabled then
        pcall(db.query, "UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = ? AND revoked_at IS NULL", r.user_id)
    end
    audit(ns_id, "shop_supplier", sup.uuid, enabled and "supplier_portal.user_enabled" or "supplier_portal.user_disabled", actor,
        { portal_user = pu_uuid })
    return Q.listPortalUsers(ns_id, supplier_uuid)
end

return Q
