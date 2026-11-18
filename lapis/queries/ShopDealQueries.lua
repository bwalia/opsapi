-- luacheck: max line length 160
--[[
    Deal codes: one private code per deal (lib/deal-codes.lua)
    ==========================================================
    The code links the customer side (CRM lead, quotes and revisions, orders) to the supplier side
    (supplier price requests, purchase orders) inside the back office only. Customer-facing shapes,
    documents and emails never carry it; supplier-facing ones carry it instead of the customer.

      enabled()                     the tables exist (migrations zzs55+)
      newCode(ns_id, user_id)       a fresh code (CSPRNG, retried on a clash with UNIQUE(code))
      forQuote / forOrder / forLead the row's code, assigning one when it has none (revisions take the
                                    original's, a quote its lead's, an order its quote's)
      joinLead(ns_id, quote_id, lead_id)  a quote and its CRM lead share one code
      link(ns_id, kind, uuid, body, user)  staff move a quote (its revision chain) or an order (and its POs)
                                    to another deal code, or to a new one
      get(ns_id, code, user)        the deal page: customer, quotes, orders, POs, supplier requests, notes,
                                    compare table, audit trail (the view is logged)
      search(ns_id, q)              by deal code, WSQ number, order number, supplier quote ref, customer email
      recent(ns_id, limit)          the newest deals, for the Deals page before anyone types
      supplier requests             list / create / update / delete / emailDraft (a draft only: never sent)
      audit(ns_id, code, action, user_id, detail)   namespace_audit_logs, entity_type 'shop_deal'
      backfill()                    every lead / quote / order / PO without a code (idempotent)
]]

local db = require("lapis.db")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Codes = require("lib.deal-codes")

local D = {}

local MAX_ATTEMPTS = 10
D.MAX_ATTEMPTS = MAX_ATTEMPTS

-- ---------------------------------------------------------------------------
-- plumbing
-- ---------------------------------------------------------------------------

local exists_cache = {}
local function exists(tbl, col)
    local key = tbl .. "." .. (col or "")
    if exists_cache[key] == nil then
        local r
        if col then
            r = db.query([[SELECT 1 AS ok FROM information_schema.columns
                            WHERE table_schema = current_schema() AND table_name = ? AND column_name = ?]], tbl, col)[1]
        else
            r = db.query("SELECT 1 AS ok WHERE to_regclass(?) IS NOT NULL", tbl)[1]
        end
        -- Only remember "yes": a table that appears after a migration is picked up without a restart.
        if r == nil then return false end
        exists_cache[key] = true
    end
    return exists_cache[key]
end
D.exists = exists

function D.enabled()
    return exists("shop_deal_codes")
end

local function has_leads() return exists("crm_leads", "deal_code") end
local function has_pos() return exists("purchase_orders", "deal_code") end

--- n secure random bytes: resty.random (strong) / OpenSSL, else /dev/urandom. Never a non-secure PRNG.
function D.random_bytes(n)
    local ok, b = pcall(U.random_bytes, n)
    if ok and type(b) == "string" and #b == n then return b end
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(n)
        f:close()
        if s and #s == n then return s end
    end
    error("no cryptographically secure random source available")
end

function D.settings(ns_id)
    local ok, rows = pcall(db.query, "SELECT deal_code_prefix, deal_code_length FROM shop_settings WHERE namespace_id = ?", ns_id)
    local r = ok and rows[1] or {}
    return {
        prefix = Codes.clean_prefix(U.nz(r.deal_code_prefix)) or Codes.DEFAULT_PREFIX,
        length = Codes.clean_length(U.nz(r.deal_code_length)) or Codes.DEFAULT_LENGTH,
    }
end

--- A new code for this workspace. The UNIQUE(code) index decides: a clash inserts nothing and we draw again
-- (ON CONFLICT DO NOTHING, so a clash never aborts the caller's transaction).
function D.newCode(ns_id, user_id)
    local s = D.settings(ns_id)
    for _ = 1, MAX_ATTEMPTS do
        local code = Codes.generate({ prefix = s.prefix, length = s.length, bytes = D.random_bytes })
        local r = db.query([[INSERT INTO shop_deal_codes (namespace_id, code, created_by_user_id, created_at)
                             VALUES (?, ?, ?, NOW()) ON CONFLICT (code) DO NOTHING RETURNING code]],
            ns_id, code, tonumber(user_id) or db.NULL)[1]
        if r and r.code then return r.code end
    end
    error("could not create a unique deal code after " .. MAX_ATTEMPTS .. " attempts")
end

--- Does this code belong to this workspace?
function D.known(ns_id, code)
    if not Codes.valid(code) then return false end
    return db.query("SELECT 1 AS ok FROM shop_deal_codes WHERE namespace_id = ? AND code = ?", ns_id, code)[1] ~= nil
end

--- Log to the deal's audit trail (namespace_audit_logs, entity_type 'shop_deal'). Never fails the caller.
function D.audit(ns_id, code, action, user_id, detail)
    if not U.nz(code) then return end
    pcall(function()
        local ip, ua
        if ngx and ngx.var then
            pcall(function()
                ip = ngx.var.remote_addr
                ua = ngx.var.http_user_agent
            end)
        end
        db.query([[INSERT INTO namespace_audit_logs (uuid, namespace_id, user_id, action, entity_type, entity_id, new_values,
                                                      ip_address, user_agent, created_at)
                   VALUES (?, ?, ?, ?, 'shop_deal', ?, ?, ?, ?, NOW())]],
            Global.generateUUID(), ns_id, tonumber(user_id) or db.NULL, "deal." .. action, code,
            detail and U.enc(detail) or db.NULL, ip and tostring(ip):sub(1, 64) or db.NULL,
            ua and tostring(ua):sub(1, 500) or db.NULL)
    end)
end

--- Forget a code nothing uses (a fresh quote's code when it joins its lead's deal).
local function drop_if_unused(ns_id, code)
    if not U.nz(code) then return end
    local used = db.query([[
        SELECT 1 AS ok FROM shop_quotes WHERE namespace_id = ? AND deal_code = ?
        UNION ALL SELECT 1 FROM shop_orders WHERE namespace_id = ? AND deal_code = ?
        UNION ALL SELECT 1 FROM shop_supplier_requests WHERE namespace_id = ? AND deal_code = ? LIMIT 1
    ]], ns_id, code, ns_id, code, ns_id, code)[1]
    if used then return end
    if has_leads() and db.query("SELECT 1 AS ok FROM crm_leads WHERE namespace_id = ? AND deal_code = ? LIMIT 1", ns_id, code)[1] then
        return
    end
    if has_pos() and db.query("SELECT 1 AS ok FROM purchase_orders WHERE namespace_id = ? AND deal_code = ? LIMIT 1", ns_id, code)[1] then
        return
    end
    if db.query("SELECT 1 AS ok FROM namespace_audit_logs WHERE namespace_id = ? AND entity_type = 'shop_deal' AND entity_id = ? LIMIT 1",
        ns_id, code)[1] then
        return
    end
    db.query("DELETE FROM shop_deal_codes WHERE namespace_id = ? AND code = ?", ns_id, code)
end

-- ---------------------------------------------------------------------------
-- assigning codes
-- ---------------------------------------------------------------------------

--- The lead's code, assigning a new one when it has none.
function D.forLead(ns_id, lead_id, user_id)
    if not D.enabled() or not has_leads() or not lead_id then return nil end
    local l = db.query("SELECT deal_code FROM crm_leads WHERE id = ? AND namespace_id = ?", lead_id, ns_id)[1]
    if not l then return nil end
    if U.nz(l.deal_code) then return l.deal_code end
    local code = D.newCode(ns_id, user_id)
    local r = db.query("UPDATE crm_leads SET deal_code = ? WHERE id = ? AND deal_code IS NULL RETURNING deal_code", code, lead_id)[1]
    if not r then -- someone else got there first
        drop_if_unused(ns_id, code)
        return db.query("SELECT deal_code FROM crm_leads WHERE id = ?", lead_id)[1].deal_code
    end
    return code
end

--- The quote's code, assigning one when it has none: a revision takes its original's, a quote with a CRM
-- lead takes the lead's, anything else a new code.
function D.forQuote(ns_id, quote_id, user_id)
    if not D.enabled() or not quote_id then return nil end
    local q = db.query("SELECT id, deal_code, revision_of_id, crm_lead_id FROM shop_quotes WHERE id = ? AND namespace_id = ?",
        quote_id, ns_id)[1]
    if not q then return nil end
    if U.nz(q.deal_code) then return q.deal_code end
    local code
    if U.nz(q.revision_of_id) then
        local root = db.query("SELECT id FROM shop_quotes WHERE id = ?", q.revision_of_id)[1]
        if root then code = D.forQuote(ns_id, root.id, user_id) end
    end
    if not code and U.nz(q.crm_lead_id) and has_leads() then
        local l = db.query("SELECT deal_code FROM crm_leads WHERE id = ?", q.crm_lead_id)[1]
        code = l and U.nz(l.deal_code)
    end
    local fresh = false
    if not code then
        code = D.newCode(ns_id, user_id)
        fresh = true
    end
    local r = db.query("UPDATE shop_quotes SET deal_code = ? WHERE id = ? AND deal_code IS NULL RETURNING deal_code", code, q.id)[1]
    if not r then
        if fresh then drop_if_unused(ns_id, code) end
        return db.query("SELECT deal_code FROM shop_quotes WHERE id = ?", q.id)[1].deal_code
    end
    if U.nz(q.crm_lead_id) and has_leads() then
        db.query("UPDATE crm_leads SET deal_code = ? WHERE id = ? AND deal_code IS NULL", code, q.crm_lead_id)
    end
    return code
end

--- The order's code: its quote's, else a new one (basket orders).
function D.forOrder(ns_id, order_id, user_id)
    if not D.enabled() or not order_id then return nil end
    local o = db.query("SELECT id, deal_code, quote_id FROM shop_orders WHERE id = ? AND namespace_id = ?", order_id, ns_id)[1]
    if not o then return nil end
    if U.nz(o.deal_code) then return o.deal_code end
    local code = U.nz(o.quote_id) and D.forQuote(ns_id, o.quote_id, user_id) or nil
    local fresh = false
    if not code then
        code = D.newCode(ns_id, user_id)
        fresh = true
    end
    local r = db.query("UPDATE shop_orders SET deal_code = ? WHERE id = ? AND deal_code IS NULL RETURNING deal_code", code, o.id)[1]
    if not r then
        if fresh then drop_if_unused(ns_id, code) end
        return db.query("SELECT deal_code FROM shop_orders WHERE id = ?", o.id)[1].deal_code
    end
    return code
end

--- After the current transaction commits (now, when none is open), give the row a code. Best effort: a
-- customer's quote or payment never fails because of it (the deal page and the backfill fill gaps).
function D.assignLater(kind, ns_id, id, user_id)
    local fn = ({ quote = D.forQuote, order = D.forOrder, lead = D.forLead })[kind]
    if not fn then return end
    U.afterCommit(function()
        local ok, err = pcall(fn, ns_id, id, user_id)
        if not ok then ngx.log(ngx.WARN, "[deal-codes] no code for ", kind, " ", tostring(id), ": ", tostring(err)) end
    end)
end

--- A quote and its CRM lead are one deal: the lead keeps its code and the quote (and its revision chain)
-- joins it; a lead without a code takes the quote's.
function D.joinLead(ns_id, quote_id, lead_id)
    if not D.enabled() or not has_leads() or not quote_id or not lead_id then return end
    local qcode = D.forQuote(ns_id, quote_id)
    local l = db.query("SELECT deal_code FROM crm_leads WHERE id = ? AND namespace_id = ?", lead_id, ns_id)[1]
    if not l then return end
    if not U.nz(l.deal_code) then
        db.query("UPDATE crm_leads SET deal_code = ? WHERE id = ? AND deal_code IS NULL", qcode, lead_id)
        return
    end
    if l.deal_code == qcode then return end
    local q = db.query("SELECT id, revision_of_id FROM shop_quotes WHERE id = ?", quote_id)[1]
    local root = tonumber(q.revision_of_id) or tonumber(q.id)
    db.query("UPDATE shop_quotes SET deal_code = ? WHERE namespace_id = ? AND (id = ? OR revision_of_id = ?)",
        l.deal_code, ns_id, root, root)
    drop_if_unused(ns_id, qcode)
end

--- Put a quote (and its revision chain) on this code: an Order Authorisation made from a quote joins
-- that quote's deal. The quote's own fresh code is dropped when nothing else uses it.
function D.adoptQuote(ns_id, quote_uuid, code)
    if not D.enabled() or not U.nz(code) then return end
    local q = db.query("SELECT id, deal_code, revision_of_id FROM shop_quotes WHERE namespace_id = ? AND uuid = ?", ns_id, quote_uuid)[1]
    if not q or q.deal_code == code then return end
    local root = tonumber(q.revision_of_id) or tonumber(q.id)
    db.query("UPDATE shop_quotes SET deal_code = ? WHERE namespace_id = ? AND (id = ? OR revision_of_id = ?)", code, ns_id, root, root)
    drop_if_unused(ns_id, q.deal_code)
end

-- ---------------------------------------------------------------------------
-- staff: link a quote or an order to a deal by hand
-- ---------------------------------------------------------------------------

--- kind: "quote" | "order". body: { deal_code } (an existing code of this workspace) or { new = true }.
-- A quote moves with its whole revision chain; an order with its purchase orders. Logged on both deals.
function D.link(ns_id, kind, uuid, body, user_id)
    body = type(body) == "table" and body or {}
    if not D.enabled() then return nil, U.err(501, "DEAL_CODES_UNAVAILABLE", "Deal codes are not set up yet") end
    local row
    if kind == "quote" then
        row = db.query("SELECT id, uuid, quote_number AS number, deal_code, revision_of_id FROM shop_quotes WHERE namespace_id = ? AND uuid = ?",
            ns_id, uuid)[1]
    elseif kind == "order" then
        row = db.query("SELECT id, uuid, order_number AS number, deal_code FROM shop_orders WHERE namespace_id = ? AND uuid = ?",
            ns_id, uuid)[1]
    end
    if not row then return nil, U.err(404, "NOT_FOUND", (kind == "order" and "Order" or "Quote") .. " not found") end
    local target
    if body.new == true then
        target = D.newCode(ns_id, user_id)
    else
        local s = D.settings(ns_id)
        target = Codes.normalize(type(body.deal_code) == "string" and body.deal_code or "", s.prefix)
        if not target then return nil, U.err(400, "VALIDATION_ERROR", "That is not a deal code (they look like WS-DT5Z-994X)") end
        if not D.known(ns_id, target) then return nil, U.err(404, "DEAL_NOT_FOUND", "No deal with code " .. target) end
    end
    local old = U.nz(row.deal_code)
    if old == target then return { deal_code = target, previous = old or U.null, moved = false } end
    U.tx(function()
        if kind == "quote" then
            local root = tonumber(row.revision_of_id) or tonumber(row.id)
            db.query("UPDATE shop_quotes SET deal_code = ?, updated_at = NOW() WHERE namespace_id = ? AND (id = ? OR revision_of_id = ?)",
                target, ns_id, root, root)
        else
            db.query("UPDATE shop_orders SET deal_code = ?, updated_at = NOW() WHERE id = ?", target, row.id)
            if has_pos() then
                db.query([[UPDATE purchase_orders SET deal_code = ?, metadata = COALESCE(metadata, '{}'::jsonb) || ?::jsonb
                            WHERE namespace_id = ? AND metadata->>'shop_order_uuid' = ? AND deleted_at IS NULL]],
                    target, U.enc({ deal_code = target }), ns_id, row.uuid)
            end
        end
        return true
    end)
    local detail = { kind = kind, number = row.number, from = old, to = target }
    D.audit(ns_id, target, "linked", user_id, detail)
    if old then D.audit(ns_id, old, "unlinked", user_id, detail) end
    return { deal_code = target, previous = old or U.null, moved = true }
end

-- ---------------------------------------------------------------------------
-- the deal page
-- ---------------------------------------------------------------------------

local function line_description(l)
    local s = tostring(l.product_name or l.label or l.name or "Item")
    if U.nz(l.sku) then s = s .. " (SKU " .. l.sku .. ")" end
    return s
end

--- Our customer lines for the compare table and new supplier requests: the newest live quote of the
-- deal (not cancelled or superseded), else the newest order.
local function current_lines(quotes, orders)
    local src
    for _, q in ipairs(quotes) do
        if q.status ~= "cancelled" then src = q break end
    end
    src = src or orders[1] or quotes[1]
    if not src then return {}, nil end
    local out = {}
    for _, l in ipairs(U.dec(src.lines, {})) do
        out[#out + 1] = { uuid = l.uuid, description = line_description(l), qty = tonumber(l.qty or l.quantity) or 1,
                          unit_price_minor = tonumber(l.unit_price_minor) }
    end
    return out, src
end

local REQUEST_COLS = [[r.uuid, r.deal_code, r.supplier_name, r.contact_name, r.contact_email, r.sent_at::text AS sent_at,
    r.spec, r.lines::text AS lines, r.supplier_quote_ref, r.lead_time, r.valid_until::text AS valid_until, r.notes,
    r.created_at, r.updated_at, s.uuid AS supplier_uuid]]

local function request_shape(r)
    return {
        uuid = r.uuid, deal_code = r.deal_code, supplier_uuid = r.supplier_uuid or U.null, supplier_name = r.supplier_name,
        contact_name = r.contact_name or U.null, contact_email = r.contact_email or U.null, sent_at = r.sent_at or U.null,
        spec = r.spec or U.null, lines = U.arr(U.dec(r.lines, {})), supplier_quote_ref = r.supplier_quote_ref or U.null,
        lead_time = r.lead_time or U.null, valid_until = r.valid_until or U.null, notes = r.notes or U.null,
        created_at = r.created_at, updated_at = r.updated_at,
    }
end

function D.requests(ns_id, code)
    local out = {}
    for _, r in ipairs(db.query("SELECT " .. REQUEST_COLS .. [[ FROM shop_supplier_requests r
            LEFT JOIN shop_suppliers s ON s.id = r.supplier_id
           WHERE r.namespace_id = ? AND r.deal_code = ? ORDER BY r.created_at, r.id]], ns_id, code)) do
        out[#out + 1] = request_shape(r)
    end
    return out
end

--- What identifies the customer of this deal (for the "never show a supplier" checks).
function D.customerMarkers(ns_id, code)
    local customers, numbers = {}, {}
    for _, q in ipairs(db.query("SELECT customer::text AS customer, quote_number FROM shop_quotes WHERE namespace_id = ? AND deal_code = ?",
        ns_id, code)) do
        customers[#customers + 1] = U.dec(q.customer, {})
        numbers[#numbers + 1] = q.quote_number
    end
    for _, o in ipairs(db.query("SELECT customer::text AS customer, email FROM shop_orders WHERE namespace_id = ? AND deal_code = ?", ns_id, code)) do
        local c = U.dec(o.customer, {})
        c.email = c.email or o.email
        customers[#customers + 1] = c
    end
    if has_leads() then
        for _, l in ipairs(db.query([[SELECT first_name, last_name, email, phone, company_name FROM crm_leads
                                       WHERE namespace_id = ? AND deal_code = ? AND deleted_at IS NULL]], ns_id, code)) do
            local name = U.join(" ", U.nz(l.first_name), U.nz(l.last_name))
            customers[#customers + 1] = { name = name ~= "Shop customer" and name or nil, email = l.email, phone = l.phone,
                                          company = l.company_name }
        end
    end
    local out = {}
    for i, c in ipairs(customers) do
        for _, m in ipairs(Codes.markers(c, i == 1 and numbers or nil)) do out[#out + 1] = m end
    end
    if #customers == 0 then
        for _, m in ipairs(Codes.markers({}, numbers)) do out[#out + 1] = m end
    end
    return out
end

function D.auditTrail(ns_id, code, limit)
    local rows = db.query([[
        SELECT a.action, a.new_values, a.created_at, u.email AS user_email,
               NULLIF(TRIM(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')), '') AS user_name
          FROM namespace_audit_logs a LEFT JOIN users u ON u.id = a.user_id
         WHERE a.namespace_id = ? AND a.entity_type = 'shop_deal' AND a.entity_id = ?
         ORDER BY a.id DESC LIMIT ?]], ns_id, code, limit or 100)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { action = (tostring(r.action):gsub("^deal%.", "")), detail = U.dec(r.new_values, U.null),
                          at = r.created_at, by = r.user_name or r.user_email or U.null }
    end
    return U.arr(out)
end

--- The deal page (staff only). Logs the view. Returns (deal) or (nil, err).
function D.get(ns_id, raw_code, user_id)
    if not D.enabled() then return nil, U.err(501, "DEAL_CODES_UNAVAILABLE", "Deal codes are not set up yet") end
    local code = Codes.normalize(raw_code or "", D.settings(ns_id).prefix)
    if not code or not D.known(ns_id, code) then return nil, U.err(404, "DEAL_NOT_FOUND", "Deal not found") end

    local quotes = db.query([[
        SELECT q.uuid, q.quote_number, q.revision_no, q.kind, q.status, q.total_minor, q.subtotal_minor, q.currency,
               q.created_at, q.customer::text AS customer, q.internal_notes, q.lines::text AS lines,
               q.superseded_by_id IS NOT NULL AS superseded, o.uuid AS order_uuid, o.order_number
          FROM shop_quotes q LEFT JOIN shop_orders o ON o.id = q.order_id
         WHERE q.namespace_id = ? AND q.deal_code = ? ORDER BY q.created_at DESC, q.id DESC]], ns_id, code)
    local orders = db.query([[
        SELECT o.uuid, o.order_number, o.status, o.total_minor, o.subtotal_minor, o.currency, o.paid_at, o.created_at,
               o.customer::text AS customer, o.email, o.internal_notes, o.lines::text AS lines, q.quote_number
          FROM shop_orders o LEFT JOIN shop_quotes q ON q.id = o.quote_id
         WHERE o.namespace_id = ? AND o.deal_code = ? ORDER BY o.created_at DESC, o.id DESC]], ns_id, code)
    local leads = {}
    if has_leads() then
        leads = db.query([[SELECT uuid, first_name, last_name, email, phone, company_name, status, source, created_at
                             FROM crm_leads WHERE namespace_id = ? AND deal_code = ? AND deleted_at IS NULL
                            ORDER BY created_at DESC]], ns_id, code)
    end
    local pos = {}
    if has_pos() then
        pos = db.query([[
            SELECT uuid, po_number, status, supplier_name, total, currency, reference, delivery_address, created_at, sent_at,
                   COALESCE((metadata->>'drop_ship')::boolean, false) AS drop_ship,
                   COALESCE((metadata->>'drop_ship_confirmed')::boolean, false) AS drop_ship_confirmed
              FROM purchase_orders WHERE namespace_id = ? AND deal_code = ? AND deleted_at IS NULL
             ORDER BY created_at DESC]], ns_id, code)
    end
    local requests = D.requests(ns_id, code)

    -- The customer: the newest quote's, else the newest order's, else the lead's.
    local customer = {}
    if quotes[1] then customer = U.dec(quotes[1].customer, {}) end
    if not next(customer) and orders[1] then
        customer = U.dec(orders[1].customer, {})
        customer.email = customer.email or orders[1].email
    end
    if not next(customer) and leads[1] then
        local l = leads[1]
        customer = { name = U.join(" ", U.nz(l.first_name), U.nz(l.last_name)), email = l.email, phone = l.phone,
                     company = l.company_name }
    end

    local notes = {}
    for _, q in ipairs(quotes) do
        if U.nz(q.internal_notes) then notes[#notes + 1] = { source = "Quote " .. q.quote_number, uuid = q.uuid, kind = "quote", text = q.internal_notes } end
    end
    for _, o in ipairs(orders) do
        if U.nz(o.internal_notes) then notes[#notes + 1] = { source = "Order " .. o.order_number, uuid = o.uuid, kind = "order", text = o.internal_notes } end
    end

    local lines, src = current_lines(quotes, orders)
    local cmp = Codes.compare(lines, requests)

    local function quote_shape(q)
        return { uuid = q.uuid, quote_number = q.quote_number, revision_no = tonumber(q.revision_no) or 0,
                 kind = q.kind or "quote", status = q.status, total_minor = tonumber(q.total_minor),
                 subtotal_minor = tonumber(q.subtotal_minor), currency = q.currency, created_at = q.created_at,
                 superseded = q.superseded == true, order_uuid = q.order_uuid or U.null, order_number = q.order_number or U.null }
    end
    local function order_shape(o)
        return { uuid = o.uuid, order_number = o.order_number, status = o.status, total_minor = tonumber(o.total_minor),
                 subtotal_minor = tonumber(o.subtotal_minor), currency = o.currency, paid_at = o.paid_at or U.null,
                 created_at = o.created_at, quote_number = o.quote_number or U.null }
    end
    local qs, os_ = {}, {}
    for _, q in ipairs(quotes) do qs[#qs + 1] = quote_shape(q) end
    for _, o in ipairs(orders) do os_[#os_ + 1] = order_shape(o) end
    local ls = {}
    for _, l in ipairs(leads) do
        ls[#ls + 1] = { uuid = l.uuid, name = U.join(" ", U.nz(l.first_name), U.nz(l.last_name)), email = l.email or U.null,
                        phone = l.phone or U.null, company = l.company_name or U.null, status = l.status, source = l.source or U.null,
                        created_at = l.created_at }
    end
    local ps = {}
    for _, p in ipairs(pos) do
        ps[#ps + 1] = { uuid = p.uuid, po_number = p.po_number, status = p.status, supplier_name = p.supplier_name,
                        total = p.total, currency = p.currency, reference = p.reference or U.null, created_at = p.created_at,
                        sent_at = p.sent_at or U.null, drop_ship = p.drop_ship == true or (p.drop_ship_confirmed == true),
                        drop_ship_confirmed = p.drop_ship_confirmed == true,
                        legacy_drop_ship = p.drop_ship == true and p.drop_ship_confirmed ~= true }
    end

    D.audit(ns_id, code, "viewed", user_id)
    for _, row in ipairs(cmp.rows) do row.suppliers = U.arr(row.suppliers) end
    return {
        deal_code = code,
        customer = {
            name = U.nz(customer.name) or U.null, email = U.nz(customer.email) or U.null,
            phone = U.nz(customer.phone) or U.null, company = U.nz(customer.company) or U.null,
        },
        leads = U.arr(ls), quotes = U.arr(qs), orders = U.arr(os_), purchase_orders = U.arr(ps),
        supplier_requests = U.arr(requests), notes = U.arr(notes),
        lines = U.arr(lines),
        lines_from = src and (src.quote_number and ("Quote " .. src.quote_number) or ("Order " .. tostring(src.order_number))) or U.null,
        compare = { rows = U.arr(cmp.rows), below_cost_count = cmp.below_cost_count },
        audit = D.auditTrail(ns_id, code, 100),
    }
end

-- ---------------------------------------------------------------------------
-- search
-- ---------------------------------------------------------------------------

--- GET /deals/search?q= — deals matching a deal code, WSQ quote number, order number, supplier quote reference
-- or customer email. { exact = code | null, results = [{ deal_code, matched_by, match, customer }] }.
function D.search(ns_id, q)
    if not D.enabled() then return { exact = U.null, results = U.arr({}) } end
    q = type(q) == "string" and q:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if #q < 2 then return { exact = U.null, results = U.arr({}) } end
    q = q:sub(1, 120)
    local code = Codes.normalize(q, D.settings(ns_id).prefix)
    if code and D.known(ns_id, code) then
        return { exact = code, results = U.arr({ { deal_code = code, matched_by = "deal_code", match = code } }) }
    end
    local like = "%" .. q:gsub("[%%_\\]", "\\%0") .. "%"
    local parts = {
        [[SELECT code AS deal_code, 'deal_code' AS matched_by, code AS match, created_at AS at FROM shop_deal_codes
           WHERE namespace_id = ? AND code ILIKE ?]],
        [[SELECT deal_code, 'quote_number', quote_number, created_at FROM shop_quotes
           WHERE namespace_id = ? AND deal_code IS NOT NULL AND quote_number ILIKE ?]],
        [[SELECT deal_code, 'order_number', order_number, created_at FROM shop_orders
           WHERE namespace_id = ? AND deal_code IS NOT NULL AND order_number ILIKE ?]],
        [[SELECT deal_code, 'supplier_quote_ref', supplier_quote_ref, created_at FROM shop_supplier_requests
           WHERE namespace_id = ? AND supplier_quote_ref ILIKE ?]],
        [[SELECT deal_code, 'customer_email', customer->>'email', created_at FROM shop_quotes
           WHERE namespace_id = ? AND deal_code IS NOT NULL AND customer->>'email' ILIKE ?]],
        [[SELECT deal_code, 'customer_email', email, created_at FROM shop_orders
           WHERE namespace_id = ? AND deal_code IS NOT NULL AND email ILIKE ?]],
    }
    local vals = {}
    for _ = 1, #parts do
        vals[#vals + 1] = ns_id
        vals[#vals + 1] = like
    end
    if has_leads() then
        parts[#parts + 1] = [[SELECT deal_code, 'customer_email', email, created_at FROM crm_leads
           WHERE namespace_id = ? AND deal_code IS NOT NULL AND deleted_at IS NULL AND email ILIKE ?]]
        vals[#vals + 1] = ns_id
        vals[#vals + 1] = like
    end
    local unpack_ = unpack or table.unpack -- luacheck: ignore 113 143
    local rows = db.query("SELECT * FROM (" .. table.concat(parts, " UNION ALL ") .. ") m ORDER BY at DESC LIMIT 60", unpack_(vals))
    local seen, out = {}, {}
    for _, r in ipairs(rows) do
        if not seen[r.deal_code] and #out < 20 then
            seen[r.deal_code] = true
            out[#out + 1] = { deal_code = r.deal_code, matched_by = r.matched_by, match = r.match }
        end
    end
    -- Who the deal is for (staff search results only).
    for _, r in ipairs(out) do
        local c = db.query([[SELECT customer->>'name' AS name, customer->>'company' AS company FROM shop_quotes
                              WHERE namespace_id = ? AND deal_code = ? ORDER BY created_at DESC LIMIT 1]], ns_id, r.deal_code)[1]
        r.customer = c and U.join(", ", U.nz(c.name), U.nz(c.company)) or U.null
        if r.customer == "" then r.customer = U.null end
    end
    return { exact = U.null, results = U.arr(out) }
end

--- GET /deals — the newest deals (the Deals page before anyone types), with who each is for.
-- { results = [{ deal_code, created_at, customer, quotes, orders, purchase_orders }] }.
function D.recent(ns_id, limit)
    if not D.enabled() then return { results = U.arr({}) } end
    limit = U.clamp(U.int(limit, 20), 1, 100)
    local po_count = has_pos() and [[(SELECT COUNT(*) FROM purchase_orders p WHERE p.namespace_id = c.namespace_id
                                          AND p.deal_code = c.code AND p.deleted_at IS NULL)]] or "0"
    local rows = db.query([[
        SELECT c.code, c.created_at,
               (SELECT COUNT(*) FROM shop_quotes q WHERE q.namespace_id = c.namespace_id AND q.deal_code = c.code)::int AS quotes,
               (SELECT COUNT(*) FROM shop_orders o WHERE o.namespace_id = c.namespace_id AND o.deal_code = c.code)::int AS orders,
               ]] .. po_count .. [[::int AS purchase_orders,
               COALESCE((SELECT NULLIF(concat_ws(', ', NULLIF(q.customer->>'name', ''), NULLIF(q.customer->>'company', '')), '')
                           FROM shop_quotes q WHERE q.namespace_id = c.namespace_id AND q.deal_code = c.code
                          ORDER BY q.created_at DESC LIMIT 1),
                        (SELECT NULLIF(concat_ws(', ', NULLIF(o.customer->>'name', ''), NULLIF(o.customer->>'company', '')), '')
                           FROM shop_orders o WHERE o.namespace_id = c.namespace_id AND o.deal_code = c.code
                          ORDER BY o.created_at DESC LIMIT 1)) AS customer
          FROM shop_deal_codes c
         WHERE c.namespace_id = ?
         ORDER BY c.created_at DESC, c.code
         LIMIT ?]], ns_id, limit)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { deal_code = r.code, created_at = r.created_at, customer = U.nz(r.customer) or U.null,
                          quotes = tonumber(r.quotes) or 0, orders = tonumber(r.orders) or 0,
                          purchase_orders = tonumber(r.purchase_orders) or 0 }
    end
    return { results = U.arr(out) }
end

-- ---------------------------------------------------------------------------
-- supplier price requests
-- ---------------------------------------------------------------------------

local function text(v, max)
    if v == nil or v == U.null then return nil end
    if type(v) ~= "string" and type(v) ~= "number" then return nil end
    local s = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return U.cut(s, max)
end

local function clean_lines(v)
    if v == nil or v == U.null then return {} end
    if type(v) ~= "table" then return nil, "lines must be a list" end
    if #v > 100 then return nil, "too many lines (100 at most)" end
    local out = {}
    for i, l in ipairs(v) do
        if type(l) ~= "table" then return nil, "line " .. i .. " is not valid" end
        local desc = text(l.description, 1000)
        if not desc then return nil, "line " .. i .. " needs a description" end
        local qty = tonumber(l.qty or 1)
        if not qty or qty < 1 or qty ~= math.floor(qty) or qty > 100000 then return nil, "line " .. i .. ": quantity must be a whole number" end
        local price = l.unit_price_minor
        if price == U.null or price == "" then price = nil end
        if price ~= nil then
            price = tonumber(price)
            if not price or price < 0 or price ~= math.floor(price) or price > 2147483647 then
                return nil, "line " .. i .. ": price must be pence ex VAT (0 or more)"
            end
        end
        out[#out + 1] = { line_uuid = text(l.line_uuid, 64), description = desc, qty = qty, unit_price_minor = price,
                          note = text(l.note, 500) }
    end
    return out
end

local FIELDS = { contact_name = 160, contact_email = 254, supplier_quote_ref = 120, lead_time = 160 }

--- Validate a create/update body. Returns (fields) or (nil, err). partial: only what is present.
local function request_fields(ns_id, body, partial)
    local f = {}
    if body.supplier_uuid ~= nil and U.nz(body.supplier_uuid) then
        local s = db.query("SELECT id, name, contact_email, po_email FROM shop_suppliers WHERE namespace_id = ? AND uuid = ?",
            ns_id, body.supplier_uuid)[1]
        if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
        f.supplier_id = s.id
        f.supplier_name = s.name
        if body.contact_email == nil and not partial then f.contact_email = U.nz(s.po_email) or U.nz(s.contact_email) end
    end
    if body.supplier_name ~= nil and text(body.supplier_name, 255) then f.supplier_name = text(body.supplier_name, 255) end
    if not partial and not f.supplier_name then
        return nil, U.err(400, "VALIDATION_ERROR", "Choose a supplier or type its name")
    end
    for k, max in pairs(FIELDS) do
        if body[k] ~= nil then f[k] = text(body[k], max) or db.NULL end
    end
    if f.contact_email and f.contact_email ~= db.NULL and not tostring(f.contact_email):match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
        return nil, U.err(400, "VALIDATION_ERROR", "The contact email is not a valid address")
    end
    for _, k in ipairs({ "sent_at", "valid_until" }) do
        if body[k] ~= nil then
            if U.nz(body[k]) and body[k] ~= U.null then
                local d = U.date(body[k])
                if not d then return nil, U.err(400, "VALIDATION_ERROR", k .. " must be a date (YYYY-MM-DD)") end
                f[k] = d
            else
                f[k] = db.NULL
            end
        end
    end
    if body.spec ~= nil then f.spec = text(body.spec, 8000) or db.NULL end
    if body.notes ~= nil then f.notes = text(body.notes, 4000) or db.NULL end
    if body.lines ~= nil then
        local lines, lerr = clean_lines(body.lines)
        if not lines then return nil, U.err(400, "VALIDATION_ERROR", lerr) end
        f.lines = lines
    end
    return f
end

--- What a supplier reads from a request (the draft email): never the customer.
local function check_private(ns_id, code, f)
    local markers = D.customerMarkers(ns_id, code)
    local found = Codes.leaks({ f.spec ~= db.NULL and f.spec or nil, f.lines }, markers)
    if #found > 0 then
        return nil, U.err(422, "CUSTOMER_DETAILS_FOR_SUPPLIER",
            "Suppliers must not see the customer's details. Remove the customer's " .. table.concat(found, ", ")
            .. " from the spec and lines (the deal code is the only reference they need)", { fields = U.arr(found) })
    end
    return true
end

local function get_request(ns_id, uuid)
    return db.query("SELECT r.id, " .. REQUEST_COLS .. [[ FROM shop_supplier_requests r
        LEFT JOIN shop_suppliers s ON s.id = r.supplier_id WHERE r.namespace_id = ? AND r.uuid = ?]], ns_id, uuid)[1]
end

function D.createRequest(ns_id, raw_code, body, user_id)
    body = type(body) == "table" and body or {}
    if not D.enabled() then return nil, U.err(501, "DEAL_CODES_UNAVAILABLE", "Deal codes are not set up yet") end
    local code = Codes.normalize(raw_code or "", D.settings(ns_id).prefix)
    if not code or not D.known(ns_id, code) then return nil, U.err(404, "DEAL_NOT_FOUND", "Deal not found") end
    local f, err = request_fields(ns_id, body, false)
    if not f then return nil, err end
    local ok, perr = check_private(ns_id, code, f)
    if not ok then return nil, perr end
    local function v(x) return (x == nil or x == db.NULL) and db.NULL or x end
    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO shop_supplier_requests (uuid, namespace_id, deal_code, supplier_id, supplier_name, contact_name, contact_email,
                                            sent_at, spec, lines, supplier_quote_ref, lead_time, valid_until, notes,
                                            created_by_user_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?::date, ?, ?::jsonb, ?, ?, ?::date, ?, ?, NOW(), NOW())
    ]], uuid, ns_id, code, v(f.supplier_id), f.supplier_name, v(f.contact_name), v(f.contact_email), v(f.sent_at), v(f.spec),
        U.enc(U.arr(f.lines or {})), v(f.supplier_quote_ref), v(f.lead_time), v(f.valid_until), v(f.notes), tonumber(user_id) or db.NULL)
    D.audit(ns_id, code, "supplier_request.created", user_id, { supplier = f.supplier_name, request = uuid })
    return request_shape(get_request(ns_id, uuid))
end

function D.updateRequest(ns_id, uuid, body, user_id)
    body = type(body) == "table" and body or {}
    local r = D.enabled() and get_request(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Supplier request not found") end
    local f, err = request_fields(ns_id, body, true)
    if not f then return nil, err end
    local ok, perr = check_private(ns_id, r.deal_code, f)
    if not ok then return nil, perr end
    local set = { updated_at = db.raw("NOW()") }
    for k, val in pairs(f) do
        if k == "lines" then
            set.lines = db.raw(db.escape_literal(U.enc(U.arr(val))) .. "::jsonb")
        else
            set[k] = val
        end
    end
    db.update("shop_supplier_requests", set, { id = r.id })
    D.audit(ns_id, r.deal_code, "supplier_request.updated", user_id, { supplier = f.supplier_name or r.supplier_name, request = uuid })
    return request_shape(get_request(ns_id, uuid))
end

function D.deleteRequest(ns_id, uuid, user_id)
    local r = D.enabled() and get_request(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Supplier request not found") end
    db.query("DELETE FROM shop_supplier_requests WHERE id = ?", r.id)
    D.audit(ns_id, r.deal_code, "supplier_request.deleted", user_id, { supplier = r.supplier_name, request = uuid })
    return { deleted = true }
end

--- POST /supplier-requests/:uuid/email-draft — the email to send the supplier, as a draft for staff to send
-- from their own mail program: { to, subject, body, mailto }. Nothing is sent.
function D.emailDraft(ns_id, uuid, user)
    local r = D.enabled() and get_request(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Supplier request not found") end
    local lines = U.dec(r.lines, {})
    local ok, perr = check_private(ns_id, r.deal_code, { spec = r.spec, lines = lines })
    if not ok then return nil, perr end
    user = user or {}
    local sender = U.nz(U.join(" ", U.nz(user.first_name), U.nz(user.last_name)))
    local brand = require("queries.ShopSettingsQueries").brandName(ns_id)
    local mail = Codes.request_email({ deal_code = r.deal_code, contact_name = r.contact_name, lines = lines, spec = r.spec },
        { company = brand, sender = sender })
    -- The draft itself must not leak either (our own name or the sender could not, the customer's would).
    local leaked = Codes.leaks(mail, D.customerMarkers(ns_id, r.deal_code))
    if #leaked > 0 then
        return nil, U.err(422, "CUSTOMER_DETAILS_FOR_SUPPLIER", "The draft would show the customer's " .. table.concat(leaked, ", "),
            { fields = U.arr(leaked) })
    end
    local to = U.nz(r.contact_email)
    local mailto = "mailto:" .. (to and ngx.escape_uri(to) or "") .. "?subject=" .. ngx.escape_uri(mail.subject)
        .. "&body=" .. ngx.escape_uri(mail.body)
    D.audit(ns_id, r.deal_code, "supplier_request.email_drafted", user.id, { supplier = r.supplier_name, request = uuid })
    return { to = to or U.null, subject = mail.subject, body = mail.body, mailto = mailto, sent = false }
end

-- ---------------------------------------------------------------------------
-- backfill (migration zzs57; safe to run again)
-- ---------------------------------------------------------------------------

function D.backfill()
    local n = { codes = 0, leads = 0, quotes = 0, orders = 0, purchase_orders = 0, legacy_drop_ship = 0 }
    if not D.enabled() then return n end
    local before = tonumber(db.query("SELECT COUNT(*)::int AS c FROM shop_deal_codes")[1].c) or 0

    -- Quotes, originals first (a revision takes its original's code; a quote its lead's).
    for _, q in ipairs(db.query([[SELECT id, namespace_id FROM shop_quotes WHERE deal_code IS NULL
                                  ORDER BY (revision_of_id IS NOT NULL), id]])) do
        if D.forQuote(q.namespace_id, q.id) then n.quotes = n.quotes + 1 end
    end
    if has_leads() then
        for _, l in ipairs(db.query("SELECT id, namespace_id FROM crm_leads WHERE deal_code IS NULL AND deleted_at IS NULL ORDER BY id")) do
            if D.forLead(l.namespace_id, l.id) then n.leads = n.leads + 1 end
        end
    end
    for _, o in ipairs(db.query("SELECT id, namespace_id FROM shop_orders WHERE deal_code IS NULL ORDER BY id")) do
        if D.forOrder(o.namespace_id, o.id) then n.orders = n.orders + 1 end
    end
    if has_pos() then
        local res = db.query([[
            UPDATE purchase_orders po SET deal_code = o.deal_code,
                   metadata = COALESCE(po.metadata, '{}'::jsonb) || jsonb_build_object('deal_code', o.deal_code)
              FROM shop_orders o
             WHERE po.deal_code IS NULL AND o.namespace_id = po.namespace_id AND o.uuid = po.metadata->>'shop_order_uuid'
               AND o.deal_code IS NOT NULL]])
        n.purchase_orders = tonumber(res and res.affected_rows) or 0
        -- POs already raised that deliver straight to the customer (e.g. PO-000001): legacy drop-ships. They stay
        -- as they are (the supplier has them); the deal's audit trail says so, once per PO.
        local legacy = db.query([[
            SELECT po.namespace_id, po.uuid, po.po_number, po.deal_code FROM purchase_orders po
             WHERE po.deal_code IS NOT NULL AND po.deleted_at IS NULL AND po.metadata->>'shop_order_uuid' IS NOT NULL
               -- every shop PO before deal codes was a drop-ship (metadata.drop_ship = true, the customer's address)
               AND (COALESCE((po.metadata->>'drop_ship')::boolean, false)
                    OR (po.metadata->>'drop_ship' IS NULL AND po.delivery_address IS NOT NULL))
               AND NOT COALESCE((po.metadata->>'drop_ship_confirmed')::boolean, false)
               AND NOT EXISTS (SELECT 1 FROM namespace_audit_logs a WHERE a.namespace_id = po.namespace_id
                                 AND a.entity_type = 'shop_deal' AND a.entity_id = po.deal_code
                                 AND a.action = 'deal.legacy_drop_ship' AND strpos(a.new_values, po.uuid) > 0)]])
        for _, p in ipairs(legacy) do
            D.audit(p.namespace_id, p.deal_code, "legacy_drop_ship", nil, {
                po_uuid = p.uuid, po_number = p.po_number,
                note = "Raised before deal codes: delivers to the customer's address (drop-ship) without a recorded "
                    .. "staff confirmation. Left as it is.",
            })
            n.legacy_drop_ship = n.legacy_drop_ship + 1
        end
    end
    local after = tonumber(db.query("SELECT COUNT(*)::int AS c FROM shop_deal_codes")[1].c) or 0
    n.codes = after - before
    return n
end

return D
