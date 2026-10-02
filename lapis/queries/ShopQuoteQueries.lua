--[[
    Shop quotes
    ===========
    A quote is an immutable snapshot of priced lines (§3 Line) with a random
    plaintext access_token: /quotes/<uuid>?t=<token> is a capability URL the
    admin may share. Public quote creation also captures a CRM lead.
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local Global = require("helper.global")
local U = require("lib.shop-util")
local Pricing = require("lib.shop-pricing")
local Catalog = require("queries.ShopCatalogQueries")
local Cart = require("queries.ShopCartQueries")

local ShopQuoteQueries = {}

local STATUSES = { draft = true, sent = true, accepted = true, expired = true, converted = true, cancelled = true }
ShopQuoteQueries.STATUSES = STATUSES
local SOURCES = { cart = true, chat = true, admin = true }

local QUOTE_COLS = [[
    q.id, q.uuid, q.namespace_id, q.quote_number, q.access_token, q.status, q.source, q.customer::text AS customer,
    q.notes, q.internal_notes, q.lines::text AS lines, q.subtotal_minor, q.vat_minor, q.shipping_minor,
    q.total_minor, q.currency, q.valid_until, q.cart_id, q.chat_session_id, q.order_id, q.crm_lead_id,
    q.viewed_at, q.created_by_user_id, q.created_at, q.updated_at,
    (q.valid_until < NOW()) AS is_past_validity
]]

local function url_path(q)
    return "/quotes/" .. q.uuid .. "?t=" .. q.access_token
end
ShopQuoteQueries.urlPath = url_path

--- Public Quote shape.
function ShopQuoteQueries.shape(q, opts)
    opts = opts or {}
    local out = {
        uuid = q.uuid,
        quote_number = q.quote_number,
        status = q.status,
        source = q.source,
        customer = U.dec(q.customer, {}),
        lines = U.arr(U.dec(q.lines, {})),
        subtotal_minor = q.subtotal_minor,
        vat_minor = q.vat_minor,
        shipping_minor = q.shipping_minor,
        total_minor = q.total_minor,
        currency = q.currency,
        valid_until = q.valid_until,
        created_at = q.created_at,
        notes = q.notes or U.null,
        url_path = url_path(q),
    }
    if opts.admin then
        out.internal_notes = q.internal_notes or U.null
        out.viewed_at = q.viewed_at or U.null
        out.updated_at = q.updated_at
        out.crm_lead_id = q.crm_lead_id or U.null
        out.order_uuid = q.order_uuid or U.null
        out.order_number = q.order_number or U.null
        out.chat_session_uuid = q.chat_session_uuid or U.null
        out.cart_uuid = q.cart_uuid or U.null
        local base = U.env("SHOP_PUBLIC_URL")
        out.public_url = base and (base:gsub("/+$", "") .. out.url_path) or out.url_path
        out.access_token = q.access_token
    end
    return out
end

local function next_number()
    local r = db.query([[
        SELECT 'WSQ-' || to_char(NOW(), 'YYYY') || '-' || lpad(nextval('shop_quote_number_seq')::text, 5, '0') AS n
    ]])[1]
    return r.n
end

--- Clean customer object from input. Returns (customer, err_message).
local function clean_customer(c, require_contact)
    if type(c) ~= "table" then
        if require_contact then return nil, "customer is required" end
        c = {}
    end
    local out = {}
    for _, k in ipairs({ "name", "email", "company", "phone", "vat_number" }) do
        local v = U.nz(c[k])
        if v ~= nil then out[k] = tostring(v):sub(1, 255) end
    end
    if type(c.address) == "table" then
        out.address = c.address
    elseif U.nz(c.address) then
        out.address = tostring(c.address):sub(1, 1000)
    end
    if require_contact then
        if not out.name then return nil, "customer.name is required" end
        if not out.email or not out.email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
            return nil, "a valid customer.email is required"
        end
    end
    return out
end
ShopQuoteQueries.cleanCustomer = clean_customer

--- Price an array of {product_slug, qty, selections, price_override_minor?}.
-- opts.admin allows overrides, inactive products and invalid configurations.
-- Returns (lines, err).
function ShopQuoteQueries.priceLines(ns_id, inputs, opts)
    opts = opts or {}
    if type(inputs) ~= "table" or #inputs == 0 then
        return nil, U.err(400, "VALIDATION_ERROR", "at least one line is required")
    end
    if #inputs > 100 then return nil, U.err(400, "VALIDATION_ERROR", "too many lines") end
    local lines = {}
    for i, l in ipairs(inputs) do
        if type(l) ~= "table" then return nil, U.err(400, "VALIDATION_ERROR", "line " .. i .. " is invalid") end
        local priced, bundle_or_err = Catalog.priceRequest(ns_id, l, { admin = opts.admin })
        if not priced then return nil, bundle_or_err end
        if not priced.valid and not opts.admin then
            return nil, U.err(422, "INVALID_CONFIGURATION", "Line " .. i .. " has an invalid configuration",
                { violations = priced.violations, line_index = i })
        end
        local line = Catalog.lineSnapshot(bundle_or_err, priced, U.nz(l.uuid))
        if opts.admin and U.nz(l.price_override_minor) ~= nil and U.int(l.price_override_minor, nil) then
            line = Pricing.apply_override(line, l.price_override_minor)
        end
        lines[#lines + 1] = line
    end
    return lines
end

--- Create a quote.
-- params: { lines (priced snapshots), customer, notes, internal_notes, source, cart_id, chat_session_id,
--           created_by_user_id, status, valid_until }
function ShopQuoteQueries.insert(ns_id, params)
    local t = Pricing.totals(params.lines, params.shipping_minor or 0)
    local row = db.query([[
        INSERT INTO shop_quotes (uuid, namespace_id, quote_number, access_token, status, source, customer, notes,
                                 internal_notes, lines, subtotal_minor, vat_minor, shipping_minor, total_minor,
                                 currency, valid_until, cart_id, chat_session_id, created_by_user_id,
                                 created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?::jsonb, ?, ?, ?::jsonb, ?, ?, ?, ?, 'GBP',
                COALESCE(?::timestamp, NOW() + interval '30 days'), ?, ?, ?, NOW(), NOW())
        RETURNING id
    ]], Global.generateUUID(), ns_id, next_number(), U.token(24), params.status or "draft",
        params.source or "cart", U.enc(params.customer or {}), U.nz(params.notes) or db.NULL,
        U.nz(params.internal_notes) or db.NULL, U.enc(U.arr(params.lines)), t.subtotal_minor, t.vat_minor,
        t.shipping_minor, t.total_minor, U.nz(params.valid_until) or db.NULL, params.cart_id or db.NULL,
        params.chat_session_id or db.NULL, params.created_by_user_id or db.NULL)[1]
    if params.chat_session_id then
        db.query("UPDATE shop_chat_sessions SET quote_id = ?, updated_at = NOW() WHERE id = ?", row.id,
            params.chat_session_id)
    end
    return ShopQuoteQueries.getById(row.id)
end

function ShopQuoteQueries.getById(id)
    return db.query("SELECT " .. QUOTE_COLS .. " FROM shop_quotes q WHERE q.id = ?", id)[1]
end

function ShopQuoteQueries.getByUuid(ns_id, uuid)
    return db.query("SELECT " .. QUOTE_COLS .. [[,
               o.uuid AS order_uuid, o.order_number, cs.uuid AS chat_session_uuid, c.uuid AS cart_uuid
          FROM shop_quotes q
          LEFT JOIN shop_orders o ON o.id = q.order_id
          LEFT JOIN shop_chat_sessions cs ON cs.id = q.chat_session_id
          LEFT JOIN shop_carts c ON c.id = q.cart_id
         WHERE q.namespace_id = ? AND q.uuid = ?]], ns_id, uuid)[1]
end

--- Capability lookup. Returns nil on bad token (callers answer 404 — no oracle).
function ShopQuoteQueries.getWithToken(ns_id, uuid, token)
    if not U.nz(uuid) or not U.nz(token) then return nil end
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q or not U.secure_equals(q.access_token, token) then return nil end
    return q
end

--- Expire quotes past validity that are still draft/sent.
local function maybe_expire(q)
    if q.is_past_validity and (q.status == "draft" or q.status == "sent") then
        db.query("UPDATE shop_quotes SET status = 'expired', updated_at = NOW() WHERE id = ?", q.id)
        q.status = "expired"
    end
    return q
end
ShopQuoteQueries.maybeExpire = maybe_expire

function ShopQuoteQueries.publicView(ns_id, uuid, token)
    local q = ShopQuoteQueries.getWithToken(ns_id, uuid, token)
    if not q then return nil end
    if not U.nz(q.viewed_at) then
        db.query("UPDATE shop_quotes SET viewed_at = NOW() WHERE id = ? AND viewed_at IS NULL", q.id)
    end
    return ShopQuoteQueries.shape(maybe_expire(q))
end

--- Best-effort CRM lead capture for a new quote.
local function capture_lead(ns_id, q, customer, total)
    local ok, err = pcall(function()
        local CrmLeadQueries = require("queries.CrmLeadQueries")
        local name = customer.name or ""
        local first, last = name:match("^(%S+)%s+(.+)$")
        local lead = CrmLeadQueries.createLeadFromPublic({
            namespace_id = ns_id,
            first_name = first or name,
            last_name = last,
            email = customer.email,
            phone = customer.phone,
            company_name = customer.company,
            source = "shop_quote",
            notes = q.quote_number .. " — " .. U.money(total) .. " inc VAT",
            metadata = U.enc({ quote_uuid = q.uuid, quote_number = q.quote_number, total_minor = total }),
        })
        if lead and lead.id then
            db.query("UPDATE shop_quotes SET crm_lead_id = ? WHERE id = ?", lead.id, q.id)
            q.crm_lead_id = lead.id
            pcall(function()
                local Notif = require("queries.CrmLeadNotificationQueries")
                local ns = db.query("SELECT id, slug, name FROM namespaces WHERE id = ?", ns_id)[1]
                if ns then Notif.notify(ns, lead) end
            end)
        end
    end)
    if not ok then ngx.log(ngx.WARN, "[shop] CRM lead capture failed for ", q.quote_number, ": ", tostring(err)) end
end

--- Public POST /quotes.
-- body: {from:"cart"|"lines", lines?, customer, notes?, chat_session_uuid?, source}
function ShopQuoteQueries.createPublic(ns_id, body, cart_token)
    local customer, cerr = clean_customer(body.customer, true)
    if not customer then return nil, U.err(400, "VALIDATION_ERROR", cerr) end
    local from = body.from or (U.nz(cart_token) and "cart" or "lines")
    local lines, cart, err
    if from == "cart" then
        cart = Cart.byToken(ns_id, cart_token)
        if not cart then return nil, U.err(404, "CART_NOT_FOUND", "Cart not found") end
        local view = Cart.view(ns_id, cart)
        if #view.lines == 0 then return nil, U.err(400, "EMPTY_CART", "The cart is empty") end
        for i, l in ipairs(view.lines) do
            if not l.valid then
                return nil, U.err(422, "INVALID_CONFIGURATION", "Line " .. i .. " has an invalid configuration",
                    { violations = l.violations, line_index = i })
            end
        end
        lines = view.lines
        if U.nz(customer.email) and not U.nz(cart.email) then
            db.query("UPDATE shop_carts SET email = ? WHERE id = ?", customer.email, cart.id)
        end
    elseif from == "lines" then
        lines, err = ShopQuoteQueries.priceLines(ns_id, body.lines)
        if not lines then return nil, err end
    else
        return nil, U.err(400, "VALIDATION_ERROR", "from must be cart or lines")
    end

    local chat_session_id
    if U.nz(body.chat_session_uuid) then
        local s = db.query("SELECT id FROM shop_chat_sessions WHERE namespace_id = ? AND uuid = ?", ns_id,
            body.chat_session_uuid)[1]
        if s then chat_session_id = s.id end
        if s and U.nz(customer.email) then
            db.query("UPDATE shop_chat_sessions SET email = COALESCE(email, ?) WHERE id = ?", customer.email, s.id)
        end
    end
    local source = SOURCES[body.source] and body.source or (chat_session_id and "chat" or "cart")
    if source == "admin" then source = "cart" end

    local q = ShopQuoteQueries.insert(ns_id, {
        lines = lines, customer = customer, notes = U.nz(body.notes) and tostring(body.notes):sub(1, 4000) or nil,
        source = source, cart_id = cart and cart.id or nil, chat_session_id = chat_session_id, status = "draft",
    })
    capture_lead(ns_id, q, customer, q.total_minor)
    return ShopQuoteQueries.shape(q)
end

-- ---------------------------------------------------------------------------
-- admin
-- ---------------------------------------------------------------------------

function ShopQuoteQueries.adminList(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 25), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "q.namespace_id = ?" }, { ns_id }
    if U.nz(params.status) then
        where[#where + 1] = "q.status = ?"
        vals[#vals + 1] = params.status
    end
    if U.nz(params.q) then
        local like = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(q.quote_number ILIKE ? OR q.customer->>'email' ILIKE ? OR q.customer->>'name' ILIKE ? "
            .. "OR q.customer->>'company' ILIKE ?)"
        for _ = 1, 4 do vals[#vals + 1] = like end
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. QUOTE_COLS .. [[, o.uuid AS order_uuid, o.order_number,
               cs.uuid AS chat_session_uuid, c.uuid AS cart_uuid, COUNT(*) OVER() AS total
          FROM shop_quotes q LEFT JOIN shop_orders o ON o.id = q.order_id
          LEFT JOIN shop_chat_sessions cs ON cs.id = q.chat_session_id
          LEFT JOIN shop_carts c ON c.id = q.cart_id
         WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY q.created_at DESC, q.id DESC LIMIT ? OFFSET ?",
        unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    local out = {}
    for _, r in ipairs(rows) do
        local s = ShopQuoteQueries.shape(maybe_expire(r), { admin = true })
        s.line_count = #s.lines
        out[#out + 1] = s
    end
    return U.arr(out), { total = total, limit = limit, offset = offset }
end

function ShopQuoteQueries.adminGet(ns_id, uuid)
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q then return nil end
    return ShopQuoteQueries.shape(q, { admin = true })
end

--- Admin-created quote (phone/email enquiries).
function ShopQuoteQueries.adminCreate(ns_id, body, user_id)
    local customer, cerr = clean_customer(body.customer, false)
    if not customer then return nil, U.err(400, "VALIDATION_ERROR", cerr) end
    local lines, err = ShopQuoteQueries.priceLines(ns_id, body.lines, { admin = true })
    if not lines then return nil, err end
    if body.status ~= nil and not STATUSES[body.status] then
        return nil, U.err(400, "VALIDATION_ERROR", "invalid status")
    end
    local q = ShopQuoteQueries.insert(ns_id, {
        lines = lines, customer = customer, notes = body.notes, internal_notes = body.internal_notes,
        source = "admin", status = body.status or "draft", valid_until = body.valid_until,
        shipping_minor = U.int(body.shipping_minor, 0), created_by_user_id = user_id,
    })
    return ShopQuoteQueries.adminGet(ns_id, q.uuid)
end

function ShopQuoteQueries.adminUpdate(ns_id, uuid, body)
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    local fields = { updated_at = db.raw("NOW()") }
    if body.status ~= nil then
        if not STATUSES[body.status] then return nil, U.err(400, "VALIDATION_ERROR", "invalid status") end
        fields.status = body.status
    end
    if body.notes ~= nil then fields.notes = U.nz(body.notes) or db.NULL end
    if body.internal_notes ~= nil then fields.internal_notes = U.nz(body.internal_notes) or db.NULL end
    if body.valid_until ~= nil then
        if not U.nz(body.valid_until) then return nil, U.err(400, "VALIDATION_ERROR", "valid_until is required") end
        fields.valid_until = body.valid_until
    end
    if body.customer ~= nil then
        local customer, cerr = clean_customer(body.customer, false)
        if not customer then return nil, U.err(400, "VALIDATION_ERROR", cerr) end
        fields.customer = db.raw(db.escape_literal(U.enc(customer)) .. "::jsonb")
    end
    local shipping = body.shipping_minor ~= nil and U.int(body.shipping_minor, 0) or tonumber(q.shipping_minor)
    local lines
    if body.lines ~= nil then
        if q.status == "converted" then
            return nil, U.err(409, "QUOTE_CONVERTED", "A converted quote's lines cannot be changed")
        end
        local err
        lines, err = ShopQuoteQueries.priceLines(ns_id, body.lines, { admin = true })
        if not lines then return nil, err end
    elseif body.shipping_minor ~= nil then
        lines = U.dec(q.lines, {})
    end
    if lines then
        local t = Pricing.totals(lines, shipping)
        fields.lines = db.raw(db.escape_literal(U.enc(U.arr(lines))) .. "::jsonb")
        fields.subtotal_minor = t.subtotal_minor
        fields.vat_minor = t.vat_minor
        fields.shipping_minor = t.shipping_minor
        fields.total_minor = t.total_minor
    end
    db.update("shop_quotes", fields, { id = q.id })
    return ShopQuoteQueries.adminGet(ns_id, uuid)
end

return ShopQuoteQueries
