-- luacheck: max line length 180
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
local Leads = require("queries.ShopLeadQueries")
local Settings = require("queries.ShopSettingsQueries")
local Cart = require("queries.ShopCartQueries")
local PaymentMethods = require("queries.PaymentMethodQueries")
local PM = require("lib.payment-methods")
local Rules = require("lib.shop-quote-rules")

local ShopQuoteQueries = {}

local STATUSES = { draft = true, sent = true, accepted = true, expired = true, converted = true, cancelled = true }
ShopQuoteQueries.STATUSES = STATUSES
local SOURCES = { cart = true, chat = true, admin = true }

local QUOTE_COLS = [[
    q.id, q.uuid, q.namespace_id, q.quote_number, q.access_token, q.status, q.source, q.customer::text AS customer,
    q.notes, q.internal_notes, q.lines::text AS lines, q.subtotal_minor, q.vat_minor, q.shipping_minor,
    q.total_minor, q.currency, q.valid_until, q.cart_id, q.chat_session_id, q.order_id, q.crm_lead_id,
    q.viewed_at, q.created_by_user_id, q.created_at, q.updated_at, q.price_locked,
    q.kind, q.discount_minor, q.discount_label, q.trade_discount_minor, q.delivery_method,
    q.delivery_address::text AS delivery_address, q.sent_at, q.authorised_at, q.authorised_by_name,
    q.customer_po_number, q.revision_no, q.revision_of_id, q.superseded_by_id,
    (q.valid_until < NOW()) AS is_past_validity
]]

-- The revision a quote was replaced by, and the original it revises (for the shapes).
local REVISION_COLS = [[,
    sb.uuid AS superseded_by_uuid, sb.quote_number AS superseded_by_number, sb.access_token AS superseded_by_token,
    ro.uuid AS revision_of_uuid, ro.quote_number AS revision_of_number
]]
local REVISION_JOINS = [[
    LEFT JOIN shop_quotes sb ON sb.id = q.superseded_by_id
    LEFT JOIN shop_quotes ro ON ro.id = q.revision_of_id
]]

local function url_path(q)
    return "/quotes/" .. q.uuid .. "?t=" .. q.access_token
end
ShopQuoteQueries.urlPath = url_path

local PAYABLE_STATUSES = { draft = true, sent = true, accepted = true }
local KINDS = { quote = true, order = true }

--- A staff-built order ("Order Authorisation") is priced and checked by staff, so its customer can pay
-- even while public checkout is switched off.
local function staff_order(q) return q.kind == "order" end
ShopQuoteQueries.isStaffOrder = staff_order

--- Whole-quote discount (staff + VIP Trade), ex VAT.
local function discount_of(q)
    return (tonumber(q.discount_minor) or 0) + (tonumber(q.trade_discount_minor) or 0)
end
ShopQuoteQueries.discountOf = discount_of

--- How the customer reaches us about changes ("Need changes?" on the quote page): the phone and email
-- on the shop's "Bill to" settings, else SHOP_CALL_PHONE. Nil when neither is set.
local function contact_for(ns_id)
    local b = Settings.billTo(ns_id)
    b = type(b) == "table" and b or {}
    local phone = U.nz(b.phone) or U.env("SHOP_CALL_PHONE")
    local email = U.nz(b.email)
    if not phone and not email then return nil end
    return { phone = phone or U.null, email = email or U.null }
end
ShopQuoteQueries.contactFor = contact_for

--- The quote fields every order made from this quote carries. Use it wherever an order is created from
-- a quote (card checkout, bank transfer): { customer_po_number = "…" | nil }.
function ShopQuoteQueries.orderFieldsFromQuote(q)
    return Rules.order_fields(q or {})
end

--- Public Quote shape. opts.admin: the back-office shape; opts.contact: add phone/contact (public page).
function ShopQuoteQueries.shape(q, opts)
    opts = opts or {}
    local lines = U.dec(q.lines, {})
    local unpriced = Pricing.unpriced_lines(lines)
    local out = {
        -- payable: what checkout will accept (checkout switched on, status, validity and
        -- every item priced); pending_pricing: items we still have to price before the customer can pay
        payable = PAYABLE_STATUSES[q.status] == true and q.is_past_validity ~= true and #unpriced == 0
            and (staff_order(q) or Settings.checkoutEnabled(q.namespace_id)),
        pending_pricing = U.arr(unpriced),
        uuid = q.uuid,
        quote_number = q.quote_number,
        status = q.status,
        source = q.source,
        customer = U.dec(q.customer, {}),
        lines = U.arr(lines),
        subtotal_minor = q.subtotal_minor,
        vat_minor = q.vat_minor,
        shipping_minor = q.shipping_minor,
        total_minor = q.total_minor,
        currency = q.currency,
        valid_until = q.valid_until,
        price_locked = q.price_locked == true,
        created_at = q.created_at,
        notes = q.notes or U.null,
        url_path = url_path(q),
        kind = q.kind or "quote",
        document_title = staff_order(q) and "Order Authorisation" or "Quote",
        discount_minor = tonumber(q.discount_minor) or 0,
        discount_label = q.discount_label or U.null,
        trade_discount_minor = tonumber(q.trade_discount_minor) or 0,
        delivery_method = q.delivery_method or U.null,
        delivery_address = U.nz(q.delivery_address) and U.dec(q.delivery_address, nil) or U.null,
        sent_at = q.sent_at or U.null,
        authorised_at = q.authorised_at or U.null,
        authorised_by_name = q.authorised_by_name or U.null,
        customer_po_number = U.nz(q.customer_po_number) or U.null,
        revision_no = tonumber(q.revision_no) or 0,
        -- authorised, turned into an order, converted or replaced: the customer can't change anything
        locked_for_customer = Rules.locked_for_customer(q),
        superseded_by = U.null,
    }
    -- Order Authorisations: how to pay by bank transfer ("Getting paid" methods, reference = the OA number),
    -- whether the customer can choose bank transfer now, and the order a bank transfer already created.
    out.payment_methods = U.arr({})
    out.payment_reference = U.null
    out.bank_transfer_available = false
    out.order_url_path = U.null
    if staff_order(q) then
        local methods = PaymentMethods.forDocuments(q.namespace_id)
        out.payment_methods = methods
        out.payment_reference = q.quote_number
        out.bank_transfer_available = PM.bankTransferAllowed({
            kind = q.kind, status = q.status, is_past_validity = q.is_past_validity, unpriced = #unpriced,
            total_minor = q.total_minor,
        }, methods) == true
    end
    if U.nz(q.order_uuid) and U.nz(q.order_access_token) then
        out.order_url_path = "/orders/" .. q.order_uuid .. "?t=" .. q.order_access_token
    end
    if U.nz(q.superseded_by_uuid) then
        out.superseded_by = { quote_number = q.superseded_by_number,
            url_path = url_path({ uuid = q.superseded_by_uuid, access_token = q.superseded_by_token }) }
    end
    if opts.contact then
        local c = contact_for(q.namespace_id)
        out.contact = c or U.null
        out.phone = c and c.phone or U.null
        out.contact_phone = out.phone
    end
    -- Before any discount, for the "Subtotal / Discount / Net" rows on the documents.
    local list = Pricing.totals(lines, q.shipping_minor)
    out.list_subtotal_minor = list.subtotal_minor
    out.list_vat_minor = list.vat_minor
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
        out.revision_of = U.nz(q.revision_of_uuid) and { uuid = q.revision_of_uuid, quote_number = q.revision_of_number } or U.null
        if U.nz(q.superseded_by_uuid) then
            out.superseded_by = { uuid = q.superseded_by_uuid, quote_number = q.superseded_by_number,
                url_path = out.superseded_by.url_path }
        end
        out.has_order = Rules.has_order(q)
        out.can_revise = (Rules.can_revise(q))
        out.can_edit = (Rules.can_edit_content(q))
        out.order_status = q.order_status or U.null
        out.order_paid_at = q.order_paid_at or U.null
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
        if opts.admin and (l.custom == true or (not U.nz(l.product_slug) and U.nz(l.name))) then
            -- Free-text line (a service, a membership month, a part from a supplier quote).
            local line, cerr = Pricing.custom_line(l, U.nz(l.uuid) or Global.generateUUID())
            if not line then return nil, U.err(400, "VALIDATION_ERROR", "Line " .. i .. ": " .. cerr) end
            lines[#lines + 1] = line
            goto continue
        end
        do
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
        ::continue::
    end
    return lines
end

--- Create a quote.
-- params: { lines (priced snapshots), customer, notes, internal_notes, source, cart_id, chat_session_id,
--           created_by_user_id, status, valid_until }
function ShopQuoteQueries.insert(ns_id, params)
    local t = Pricing.discounted_totals(params.lines, params.shipping_minor or 0,
        (params.discount_minor or 0) + (params.trade_discount_minor or 0))
    local row = db.query([[
        INSERT INTO shop_quotes (uuid, namespace_id, quote_number, access_token, status, source, customer, notes,
                                 internal_notes, lines, subtotal_minor, vat_minor, shipping_minor, total_minor,
                                 currency, valid_until, cart_id, chat_session_id, created_by_user_id,
                                 created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?::jsonb, ?, ?, ?::jsonb, ?, ?, ?, ?, 'GBP',
                COALESCE(?::timestamp, NOW() + interval '30 days'), ?, ?, ?, NOW(), NOW())
        RETURNING id
    ]], Global.generateUUID(), ns_id, params.quote_number or next_number(), U.token(24), params.status or "draft",
        params.source or "cart", U.enc(params.customer or {}), U.nz(params.notes) or db.NULL,
        U.nz(params.internal_notes) or db.NULL, U.enc(U.arr(params.lines)), t.subtotal_minor, t.vat_minor,
        t.shipping_minor, t.total_minor, U.nz(params.valid_until) or db.NULL, params.cart_id or db.NULL,
        params.chat_session_id or db.NULL, params.created_by_user_id or db.NULL)[1]
    if params.kind or params.discount_minor or params.trade_discount_minor or params.delivery_method
        or params.delivery_address then
        db.query([[
            UPDATE shop_quotes SET kind = ?, discount_minor = ?, discount_label = ?, trade_discount_minor = ?,
                   delivery_method = ?, delivery_address = ?::jsonb WHERE id = ?
        ]], params.kind or "quote", params.discount_minor or 0, U.nz(params.discount_label) or db.NULL,
            params.trade_discount_minor or 0, U.nz(params.delivery_method) or db.NULL,
            params.delivery_address and U.enc(params.delivery_address) or db.NULL, row.id)
    end
    if params.customer_po_number or params.revision_of_id then
        db.query("UPDATE shop_quotes SET customer_po_number = ?, revision_no = ?, revision_of_id = ? WHERE id = ?",
            params.customer_po_number or db.NULL, params.revision_no or 0, params.revision_of_id or db.NULL, row.id)
    end
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
    return db.query("SELECT " .. QUOTE_COLS .. REVISION_COLS .. [[,
               o.uuid AS order_uuid, o.order_number, o.access_token AS order_access_token, o.status AS order_status,
               o.payment_method AS order_payment_method, o.paid_at AS order_paid_at,
               cs.uuid AS chat_session_uuid, c.uuid AS cart_uuid
          FROM shop_quotes q
          LEFT JOIN shop_orders o ON o.id = q.order_id
          LEFT JOIN shop_chat_sessions cs ON cs.id = q.chat_session_id
          LEFT JOIN shop_carts c ON c.id = q.cart_id
         ]] .. REVISION_JOINS .. [[
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

function ShopQuoteQueries.publicView(ns_id, uuid, token, opts)
    local q = ShopQuoteQueries.getWithToken(ns_id, uuid, token)
    if not q then return nil end
    -- opts.track == false: not the customer viewing the page (a PDF download, staff, our own email fetch).
    if not (opts and opts.track == false) and not U.nz(q.viewed_at) then
        db.query("UPDATE shop_quotes SET viewed_at = NOW() WHERE id = ? AND viewed_at IS NULL", q.id)
    end
    return ShopQuoteQueries.shape(maybe_expire(q), { contact = true })
end

--- A signed-in customer's own quotes (GET /customer/quotes). `email` is the session's email, which
-- an emailed link or Google / Apple verified, so matching the quote's customer email is ownership.
function ShopQuoteQueries.forCustomer(ns_id, email, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 50), 1, 100)
    local offset = math.max(0, U.int(params.offset, 0))
    local rows = db.query("SELECT " .. QUOTE_COLS .. REVISION_COLS .. [[, o.uuid AS order_uuid, o.order_number,
               o.access_token AS order_access_token, COUNT(*) OVER() AS total
          FROM shop_quotes q LEFT JOIN shop_orders o ON o.id = q.order_id
         ]] .. REVISION_JOINS .. [[
         WHERE q.namespace_id = ? AND lower(q.customer->>'email') = lower(?) AND q.status <> 'cancelled'
         ORDER BY q.created_at DESC, q.id DESC LIMIT ? OFFSET ?]], ns_id, email, limit, offset)
    local total = rows[1] and tonumber(rows[1].total) or 0
    local out = {}
    for _, r in ipairs(rows) do
        local s = ShopQuoteQueries.shape(maybe_expire(r))
        s.line_count = #s.lines
        s.order_number = r.order_number or U.null
        out[#out + 1] = s
    end
    return U.arr(out), { total = total, limit = limit, offset = offset }
end

--- Attach a new quote to the customer's CRM lead (one open lead per email; never fails the quote).
local function capture_lead(ns_id, q, customer, total, chat_session)
    local lead = Leads.safeUpsert(ns_id, {
        email = customer.email, name = customer.name, company = customer.company, phone = customer.phone,
        source = "shop_quote",
        note = "Quote " .. q.quote_number .. " — " .. U.money(total) .. " inc VAT",
        quote = { uuid = q.uuid, number = q.quote_number, total_minor = total },
        chat_session_uuid = chat_session and chat_session.uuid or nil,
    })
    if not lead then return end
    db.query("UPDATE shop_quotes SET crm_lead_id = ? WHERE id = ?", lead.id, q.id)
    q.crm_lead_id = lead.id
    if chat_session then
        db.query("UPDATE shop_chat_sessions SET crm_lead_id = ? WHERE id = ?", lead.id, chat_session.id)
    end
end

--- Public POST /quotes.
-- body: {from:"cart"|"lines", lines?, customer, notes?, chat_session_uuid?, source, delivery_address?}
function ShopQuoteQueries.createPublic(ns_id, body, cart_token)
    local customer, cerr = clean_customer(body.customer, true)
    if not customer then return nil, U.err(400, "VALIDATION_ERROR", cerr) end
    -- "Start a new quote" from an earlier one can bring a delivery address (the supplier PO's "Deliver to").
    local delivery, derr = ShopQuoteQueries.cleanAddress(body.delivery_address)
    if derr then return nil, U.err(400, "VALIDATION_ERROR", derr) end
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

    local chat_session_id, chat_session
    if U.nz(body.chat_session_uuid) then
        local s = db.query("SELECT id, uuid FROM shop_chat_sessions WHERE namespace_id = ? AND uuid = ?", ns_id,
            body.chat_session_uuid)[1]
        if s then chat_session_id, chat_session = s.id, s end
        if s and U.nz(customer.email) then
            db.query("UPDATE shop_chat_sessions SET email = COALESCE(email, ?) WHERE id = ?", customer.email, s.id)
        end
    end
    local source = SOURCES[body.source] and body.source or (chat_session_id and "chat" or "cart")
    if source == "admin" then source = "cart" end

    -- Trade price lock: a signed-in, active member's own quote holds its prices for lock_days (60/120)
    -- instead of 30. Checkout from a quote already charges the quote's snapshot prices.
    local member = ngx.ctx and ngx.ctx.shop_member
    local locked = member ~= nil and member.active == true and U.nz(customer.email)
        and tostring(customer.email):lower() == member.email
    local q = ShopQuoteQueries.insert(ns_id, {
        lines = lines, customer = customer, notes = U.nz(body.notes) and tostring(body.notes):sub(1, 4000) or nil,
        source = source, cart_id = cart and cart.id or nil, chat_session_id = chat_session_id, status = "draft",
        delivery_address = delivery,
        valid_until = locked and os.date("!%Y-%m-%d %H:%M:%S", os.time() + member.lock_days * 86400) or nil,
    })
    if locked then
        db.query("UPDATE shop_quotes SET price_locked = true WHERE id = ?", q.id)
        q.price_locked = true
    end
    capture_lead(ns_id, q, customer, q.total_minor, chat_session)
    return ShopQuoteQueries.shape(q)
end


-- ---------------------------------------------------------------------------
-- back-office orders: discounts, delivery, VIP Trade discount
-- ---------------------------------------------------------------------------

local ADDRESS_KEYS = { "name", "company", "line1", "line2", "city", "county", "postcode", "country", "email",
                       "phone", "vat_number" }

--- Clean a delivery address (structured, for the supplier PO's "Deliver directly to").
local function clean_address(a)
    if a == nil or a == U.null then return nil end
    if type(a) ~= "table" then return nil, "delivery_address must be an object" end
    local out, any = {}, false
    for _, k in ipairs(ADDRESS_KEYS) do
        local v = U.nz(a[k])
        if v ~= nil then out[k] = tostring(v):sub(1, 255); any = true end
    end
    return any and out or nil
end
ShopQuoteQueries.cleanAddress = clean_address

--- Validate the back-office order fields of a create/update body. Returns (fields, err): only the keys
-- present in the body are returned (kind, discount_minor, discount_label, delivery_method,
-- delivery_address, trade = "apply" | "clear" | number).
local function order_fields(body)
    local f = {}
    if body.kind ~= nil then
        if not KINDS[body.kind] then return nil, "kind must be quote or order" end
        f.kind = body.kind
    end
    if body.discount_minor ~= nil then
        local d = U.int(body.discount_minor, nil)
        if d == nil or d < 0 then return nil, "discount_minor must be 0 or more (pence, ex VAT)" end
        f.discount_minor = d
    end
    if body.discount_label ~= nil then f.discount_label = U.nz(body.discount_label) and tostring(body.discount_label):sub(1, 120) or false end
    if body.delivery_method ~= nil then f.delivery_method = U.nz(body.delivery_method) and tostring(body.delivery_method):sub(1, 160) or false end
    if body.delivery_address ~= nil then
        local a, aerr = clean_address(body.delivery_address)
        if aerr then return nil, aerr end
        f.delivery_address = a or false
    end
    if body.apply_trade_discount == true then
        f.trade = "apply"
    elseif body.apply_trade_discount == false then
        f.trade = "clear"
    elseif body.trade_discount_minor ~= nil then
        local d = U.int(body.trade_discount_minor, nil)
        if d == nil or d < 0 then return nil, "trade_discount_minor must be 0 or more (pence, ex VAT)" end
        f.trade = d
    end
    return f
end

--- The VIP Trade discount this customer's membership gives an order of these lines (after the staff
-- discount), or 0 when they hold no membership in force.
local function trade_discount(ns_id, email, lines, shipping, staff_discount)
    local Membership = require("queries.ShopMembershipQueries")
    local t = Pricing.totals(lines, shipping)
    local net = math.max(0, t.subtotal_minor - (staff_discount or 0))
    local res = Membership.tradeDiscountFor(ns_id, email, net, Pricing.effective_vat_rate(t.subtotal_minor, t.vat_minor),
        t.shipping_minor)
    return res and res.discount_minor or 0, res
end

--- GET /quotes/:uuid/trade-discount preview for the dashboard ("Apply VIP discount" button).
function ShopQuoteQueries.tradeDiscountPreview(ns_id, uuid)
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    local email = U.dec(q.customer, {}).email
    local amount, res = trade_discount(ns_id, email, U.dec(q.lines, {}), q.shipping_minor, tonumber(q.discount_minor) or 0)
    return { member = res ~= nil, discount_minor = amount, tier = res and res.tier or U.null,
             pct = res and res.pct or U.null, cap_remaining_minor = res and res.cap_remaining_minor or U.null }
end

--- The customer-facing PDF, rendered by the shop app (shop/src/lib/pdf/quote-pdf.tsx). Returns the
-- bytes or (nil, reason). Best effort: the email still goes out with the link if this fails.
local function fetch_pdf(q)
    local base = U.env("SHOP_PUBLIC_URL")
    if not base then return nil, "SHOP_PUBLIC_URL is not set" end
    local url = base:gsub("/+$", "") .. "/api/quotes/" .. q.uuid .. "/pdf?t=" .. ngx.escape_uri(q.access_token)
    local ok, res_or_err = pcall(function()
        local http = require("resty.http").new()
        http:set_timeout(20000)
        return http:request_uri(url, { method = "GET", ssl_verify = true,
            headers = { ["User-Agent"] = "opsapi-shop/1.0", Accept = "application/pdf" } })
    end)
    local res = ok and res_or_err or nil
    if not res then return nil, ok and "no response" or tostring(res_or_err) end
    if res.status ~= 200 or not res.body or res.body:sub(1, 4) ~= "%PDF" then
        return nil, "shop returned " .. tostring(res.status)
    end
    return res.body
end


--- POST /quotes/:uuid/order-authorisation — turn a quote (e.g. one the customer requested online) into a
-- new Order Authorisation: same lines at the quoted prices, the customer (with any completed details),
-- the VIP Trade discount when they are a member (unless apply_trade_discount = false), the delivery
-- address (default: the customer's address). The source quote is noted and left as it is.
-- body: { customer?, delivery_address?, delivery_method?, apply_trade_discount?, discount_minor?,
--         discount_label?, valid_until?, notes? }
--- A quote's lines as priceLines inputs that keep the quoted prices: catalogue lines are re-priced with
-- that price as the override (so a catalogue change since doesn't move it); free-text lines are copied.
-- Returns (inputs) or (nil, err).
local function quote_line_inputs(ns_id, src)
    local inputs = {}
    for _, l in ipairs(U.dec(src.lines, {})) do
        if l.custom then
            inputs[#inputs + 1] = { custom = true, name = l.product_name or l.label, description = l.description,
                qty = l.qty, unit_price_minor = l.unit_price_minor, vat_rate = l.vat_rate,
                period_start = l.period_start, period_end = l.period_end }
        else
            local slug = l.product_slug
            if not U.nz(slug) and U.nz(l.product_uuid) then
                local p = db.query("SELECT slug FROM shop_products WHERE namespace_id = ? AND uuid = ?", ns_id, l.product_uuid)[1]
                slug = p and p.slug
            end
            if not U.nz(slug) then
                return nil, U.err(409, "PRODUCT_GONE", "A product on this quote is no longer in the catalogue: "
                    .. tostring(l.product_name))
            end
            inputs[#inputs + 1] = { product_slug = slug, qty = l.qty, selections = l.selections,
                price_override_minor = l.price_override_minor or l.unit_price_minor }
        end
    end
    return inputs
end

function ShopQuoteQueries.orderFromQuote(ns_id, uuid, body, user_id)
    body = body or {}
    local src = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not src then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    if src.status == "cancelled" then return nil, U.err(409, "QUOTE_CANCELLED", "This quote is cancelled") end
    local inputs, ierr = quote_line_inputs(ns_id, src)
    if not inputs then return nil, ierr end
    local customer = U.dec(src.customer, {})
    if type(body.customer) == "table" then
        for k, v in pairs(body.customer) do customer[k] = v end
    end
    local delivery = body.delivery_address
    if delivery == nil then
        local a = type(customer.address) == "table" and customer.address or {}
        delivery = {
            name = customer.name, company = customer.company, line1 = a.line1, line2 = a.line2, city = a.city,
            county = a.state or a.county, postcode = a.postal_code or a.postcode, country = a.country,
            email = customer.email, phone = customer.phone, vat_number = customer.vat_number,
        }
    end
    local notes = { "Order Authorisation from quote " .. src.quote_number .. "." }
    if U.nz(src.notes) then notes[#notes + 1] = "Customer's note on the quote: " .. src.notes end
    if U.nz(src.internal_notes) then notes[#notes + 1] = src.internal_notes end
    local res, err = ShopQuoteQueries.adminCreate(ns_id, {
        kind = "order", status = "draft", customer = customer, lines = inputs,
        shipping_minor = tonumber(src.shipping_minor) or 0,
        apply_trade_discount = body.apply_trade_discount ~= false,
        discount_minor = body.discount_minor, discount_label = body.discount_label,
        delivery_address = delivery, delivery_method = body.delivery_method,
        valid_until = body.valid_until, notes = body.notes,
        customer_po_number = body.customer_po_number ~= nil and body.customer_po_number or src.customer_po_number,
        internal_notes = table.concat(notes, "\n\n"),
    }, user_id)
    if not res then return nil, err end
    db.query([[UPDATE shop_quotes SET internal_notes = COALESCE(internal_notes || E'\n', '') || ?, updated_at = NOW()
               WHERE id = ?]], "Order Authorisation " .. res.quote_number .. " created from this quote.", src.id)
    if src.crm_lead_id then
        db.query("UPDATE shop_quotes SET crm_lead_id = ? WHERE uuid = ? AND namespace_id = ?", src.crm_lead_id, res.uuid, ns_id)
    end
    return ShopQuoteQueries.adminGet(ns_id, res.uuid)
end

--- POST /quotes/:uuid/crm-customer — save the quote's customer to the CRM: the company as an account
-- (address and VAT number from the delivery address or the customer) and the person as a contact in it.
-- Reuses an account with the same name and a contact with the same email; fills in what they lack.
-- Returns { account_uuid, contact_uuid, account_created, contact_created }.
function ShopQuoteQueries.saveCrmCustomer(ns_id, uuid, owner_uuid)
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    if not U.nz(owner_uuid) then return nil, U.err(403, "USER_REQUIRED", "Sign in as a user to save CRM records") end
    local c = U.dec(q.customer, {})
    local d = U.nz(q.delivery_address) and U.dec(q.delivery_address, {}) or {}
    local ca = type(c.address) == "table" and c.address or {}
    local company = U.nz(c.company) or U.nz(d.company)
    local email = U.nz(c.email) and tostring(c.email):lower() or nil
    if not company and not email then
        return nil, U.err(400, "VALIDATION_ERROR", "The customer needs a company or an email")
    end
    local addr = {
        line1 = U.nz(ca.line1) or U.nz(d.line1), line2 = U.nz(ca.line2) or U.nz(d.line2),
        city = U.nz(ca.city) or U.nz(d.city), state = U.nz(ca.state) or U.nz(ca.county) or U.nz(d.county),
        postal_code = U.nz(ca.postal_code) or U.nz(ca.postcode) or U.nz(d.postcode),
        country = U.nz(ca.country) or U.nz(d.country),
    }
    local vat = U.nz(c.vat_number) or U.nz(d.vat_number)
    local out = { account_created = false, contact_created = false }
    local ok, terr = pcall(U.tx, function()
        local account
        if company then
            account = db.query([[SELECT * FROM crm_accounts WHERE namespace_id = ? AND lower(name) = lower(?) AND deleted_at IS NULL
                                 ORDER BY created_at LIMIT 1]], ns_id, company)[1]
            local meta = { vat_number = vat, from_shop_quote = q.quote_number }
            if not account then
                account = db.query([[
                    INSERT INTO crm_accounts (uuid, namespace_id, name, phone, email, address_line1, address_line2, city,
                                              state, postal_code, country, owner_user_uuid, status, metadata,
                                              created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?::jsonb, NOW(), NOW()) RETURNING *
                ]], Global.generateUUID(), ns_id, company, U.nz(c.phone) or db.NULL, email or db.NULL,
                    addr.line1 or db.NULL, addr.line2 or db.NULL, addr.city or db.NULL, addr.state or db.NULL,
                    addr.postal_code or db.NULL, addr.country or db.NULL, owner_uuid, U.enc(meta))[1]
                out.account_created = true
            else
                -- Fill in only what the account lacks; never overwrite what staff typed in the CRM.
                db.query([[
                    UPDATE crm_accounts SET phone = COALESCE(phone, ?), email = COALESCE(email, ?),
                           address_line1 = COALESCE(address_line1, ?), address_line2 = COALESCE(address_line2, ?),
                           city = COALESCE(city, ?), state = COALESCE(state, ?), postal_code = COALESCE(postal_code, ?),
                           country = COALESCE(country, ?),
                           -- existing keys win (the right side of || overrides)
                           metadata = jsonb_strip_nulls(?::jsonb) || COALESCE(metadata, '{}'::jsonb), updated_at = NOW()
                     WHERE id = ?
                ]], U.nz(c.phone) or db.NULL, email or db.NULL, addr.line1 or db.NULL, addr.line2 or db.NULL,
                    addr.city or db.NULL, addr.state or db.NULL, addr.postal_code or db.NULL, addr.country or db.NULL,
                    U.enc({ vat_number = vat }), account.id)
            end
            out.account_uuid = account.uuid
        end
        if email then
            local contact = db.query([[SELECT * FROM crm_contacts WHERE namespace_id = ? AND lower(email) = ? AND deleted_at IS NULL
                                       ORDER BY created_at LIMIT 1]], ns_id, email)[1]
            if not contact then
                local name = tostring(U.nz(c.name) or email)
                local first, last = name:match("^%s*(%S+)%s+(.-)%s*$")
                contact = db.query([[
                    INSERT INTO crm_contacts (uuid, namespace_id, account_id, first_name, last_name, email, phone,
                                              owner_user_uuid, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?::jsonb, NOW(), NOW()) RETURNING *
                ]], Global.generateUUID(), ns_id, account and account.id or db.NULL, first or name, last or db.NULL,
                    email, U.nz(c.phone) or db.NULL, owner_uuid, U.enc({ from_shop_quote = q.quote_number }))[1]
                out.contact_created = true
            elseif account and not contact.account_id then
                db.query("UPDATE crm_contacts SET account_id = ?, updated_at = NOW() WHERE id = ?", account.id, contact.id)
            end
            out.contact_uuid = contact.uuid
        end
        return true
    end)
    if not ok then
        ngx.log(ngx.ERR, "[shop-quotes] CRM customer not saved for ", q.quote_number, ": ", tostring(terr))
        return nil, U.err(500, "CRM_SAVE_FAILED", "Could not save the customer to the CRM")
    end
    out.account_uuid = out.account_uuid or U.null
    out.contact_uuid = out.contact_uuid or U.null
    return out
end

--- POST /quotes/:uuid/send — email the customer the Order Authorisation (or quote) with the PDF attached
-- and the link to confirm and pay. Marks a draft as sent. Returns ({ to, attached, sent_at }) or (nil, err).
-- opts.test: a test send to staff (opts.to, else the signed-in user, else the workspace owner) — the same
-- email marked TEST, its link opens the page in preview (confirm and pay turned off), and the quote is not
-- marked as sent.
function ShopQuoteQueries.sendToCustomer(ns_id, uuid, opts)
    opts = opts or {}
    if opts.test and not U.nz(opts.to) then
        local me = opts.user_id and db.query("SELECT email FROM users WHERE id = ?", opts.user_id)[1]
        opts.to = me and U.nz(me.email) or nil
        if not opts.to then
            local N = require("queries.CrmLeadNotificationQueries")
            opts.to = N.resolveAdminEmail(ns_id, N.getEffective(ns_id))
        end
    end
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    maybe_expire(q)
    if q.status ~= "draft" and q.status ~= "sent" and q.status ~= "accepted" then
        return nil, U.err(409, "QUOTE_NOT_SENDABLE", "This " .. (staff_order(q) and "order" or "quote")
            .. " can't be sent (status " .. q.status .. ")")
    end
    local customer = U.dec(q.customer, {})
    local to = U.nz(opts.to) or customer.email
    if not to or not tostring(to):match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
        return nil, U.err(400, "VALIDATION_ERROR", opts.test and "No email address to send the test to"
            or "The customer needs an email address")
    end
    if #Pricing.unpriced_lines(U.dec(q.lines, {})) > 0 then
        return nil, U.err(409, "QUOTE_PRICING_PENDING", "Price every line before sending it")
    end
    local shaped = ShopQuoteQueries.shape(q, { admin = true })
    local title = shaped.document_title
    local pdf, perr = fetch_pdf(q)
    -- The shop's PDF route reads the quote through the public endpoint, which stamps viewed_at; our own
    -- fetch is not the customer viewing it.
    if not U.nz(q.viewed_at) then db.query("UPDATE shop_quotes SET viewed_at = NULL WHERE id = ?", q.id) end
    if not pdf then ngx.log(ngx.WARN, "[shop-quotes] PDF not attached to ", q.quote_number, ": ", tostring(perr)) end

    local Mail = require("helper.mail")
    local NamespaceMail = require("helper.namespace-mail")
    local smtp = NamespaceMail.smtp(ns_id)
    if smtp and not NamespaceMail.hostOk(smtp.host) then smtp = nil end
    if not smtp and not Mail.isConfigured() then
        return nil, U.err(503, "EMAIL_NOT_CONFIGURED", "No email server is set up for this workspace")
    end
    local discount = discount_of(q)
    local sent, merr = Mail.send({
        to = to, subject = (opts.test and "[TEST] " or "") .. title .. " " .. q.quote_number .. " from Workstation",
        template = "shop_order_authorisation",
        smtp = smtp, sync = true,
        from_email = smtp and smtp.from_email or nil,
        from_name = smtp and smtp.from_name or "Workstation",
        reply_to = smtp and smtp.reply_to or nil,
        data = {
            app_name = "Workstation", document_title = title, number = q.quote_number, is_order = staff_order(q),
            customer_name = customer.name, total = U.money(tonumber(q.total_minor) or 0),
            po_number = U.nz(q.customer_po_number), revision_no = tonumber(q.revision_no) or 0,
            discount = discount > 0 and U.money(discount) or nil, delivery_method = q.delivery_method,
            valid_until = q.valid_until and tostring(q.valid_until):sub(1, 10) or nil,
            test = opts.test == true, test_customer = opts.test and customer.email or nil,
            link = opts.test and (shaped.public_url .. "&preview=1") or shaped.public_url, attached = pdf ~= nil, call_phone = U.env("SHOP_CALL_PHONE") or "+44 7515 356 146",
        },
        attachments = pdf and { { filename = q.quote_number .. ".pdf", content_type = "application/pdf",
                                  content_b64 = ngx.encode_base64(pdf) } } or nil,
    })
    if not sent then
        ngx.log(ngx.ERR, "[shop-quotes] email for ", q.quote_number, " failed: ", tostring(merr))
        return nil, U.err(502, "EMAIL_FAILED", "The email could not be sent: " .. tostring(merr):sub(1, 200))
    end
    if not opts.test then
        db.query([[UPDATE shop_quotes SET sent_at = NOW(), updated_at = NOW(),
                   status = CASE WHEN status = 'draft' THEN 'sent' ELSE status END WHERE id = ?]], q.id)
    end
    return { to = to, test = opts.test == true, attached = pdf ~= nil, pdf_error = pdf and U.null or perr, quote = ShopQuoteQueries.adminGet(ns_id, uuid) }
end

--- Public POST /quotes/:uuid/authorise — the customer confirms the order (the shop app has recorded
-- their acceptance of the terms in the legal ledger first). Idempotent; returns the public shape.
function ShopQuoteQueries.authorise(ns_id, uuid, token, body)
    local q = ShopQuoteQueries.getWithToken(ns_id, uuid, token)
    if not q then return nil, U.err(404, "QUOTE_NOT_FOUND", "Quote not found") end
    if Rules.is_superseded(q) then
        return nil, U.err(409, "QUOTE_SUPERSEDED", "This has been replaced by a newer revision: please use the latest one",
            { superseded_by = q.superseded_by_number })
    end
    maybe_expire(q)
    if q.status == "expired" or q.is_past_validity then
        return nil, U.err(409, "QUOTE_EXPIRED", "This has expired — please ask us for a new one")
    end
    if q.status ~= "draft" and q.status ~= "sent" and q.status ~= "accepted" then
        return nil, U.err(409, "QUOTE_NOT_AUTHORISABLE", "This can no longer be confirmed (status " .. q.status .. ")")
    end
    if body.accept_terms ~= true then
        return nil, U.err(400, "TERMS_REQUIRED", "Please accept the terms to confirm the order")
    end
    -- Authorising is the customer's last say: once it is authorised (or has an order) nothing they send
    -- changes it, so confirming again just returns it.
    if Rules.locked_for_customer(q) then
        return ShopQuoteQueries.shape(q, { contact = true })
    end
    local po, perr = Rules.clean_po_number(body.customer_po_number)
    if perr then return nil, U.err(400, "VALIDATION_ERROR", perr) end
    local name = U.nz(body.name) and tostring(body.name):sub(1, 160) or U.dec(q.customer, {}).name
    -- status guard: two confirmations at once can't both write.
    db.query([[UPDATE shop_quotes SET status = 'accepted', authorised_at = COALESCE(authorised_at, NOW()),
               authorised_by_name = COALESCE(authorised_by_name, ?),
               customer_po_number = CASE WHEN ?::text IS NULL THEN customer_po_number ELSE ?::text END,
               updated_at = NOW() WHERE id = ? AND status IN ('draft', 'sent')]],
        name or db.NULL, po or db.NULL, po or db.NULL, q.id)
    if q.crm_lead_id then
        pcall(Leads.safeUpsert, ns_id, { email = U.dec(q.customer, {}).email, source = "shop_quote",
            note = (staff_order(q) and "Order " or "Quote ") .. q.quote_number .. " confirmed by the customer"
                .. (name and (" (" .. name .. ")") or "") .. (po and (", their PO " .. po) or "") })
    end
    return ShopQuoteQueries.shape(ShopQuoteQueries.getByUuid(ns_id, uuid), { contact = true })
end

-- ---------------------------------------------------------------------------
-- admin
-- ---------------------------------------------------------------------------

--- Does this column / table exist? (Columns another feature adds, e.g. shop_orders.payment_method.)
local exists_cache = {}
local function column_exists(tbl, col)
    local key = tbl .. "." .. (col or "")
    if exists_cache[key] == nil then
        local r
        if col then
            r = db.query([[SELECT 1 AS ok FROM information_schema.columns
                            WHERE table_schema = current_schema() AND table_name = ? AND column_name = ?]], tbl, col)[1]
        else
            r = db.query("SELECT 1 AS ok WHERE to_regclass(?) IS NOT NULL", tbl)[1]
        end
        exists_cache[key] = r ~= nil
    end
    return exists_cache[key]
end
ShopQuoteQueries.columnExists = column_exists

--- SQL (on shop_orders o) for "paid, and no supplier PO raised for it yet".
function ShopQuoteQueries.needsSupplierPoSql()
    local sql = "o.status IN ('paid', 'processing')"
    if column_exists("purchase_orders") then
        sql = sql .. [[ AND NOT EXISTS (SELECT 1 FROM purchase_orders po WHERE po.namespace_id = o.namespace_id
                         AND po.metadata->>'shop_order_uuid' = o.uuid AND po.deleted_at IS NULL
                         AND po.status <> 'cancelled')]]
    end
    return sql
end

--- Quick filters for the back office (GET /quotes?filter=…).
local function quick_filter_sql(name)
    if name == "awaiting_authorisation" then
        return "q.status = 'sent' AND q.order_id IS NULL"
    elseif name == "awaiting_payment" then
        return "q.status = 'accepted' AND (q.order_id IS NULL OR o.status = 'pending_payment')"
    elseif name == "needs_supplier_po" then
        return "q.order_id IS NOT NULL AND " .. ShopQuoteQueries.needsSupplierPoSql()
    elseif name == "bank_transfer_due" then
        if not column_exists("shop_orders", "payment_method") then return "false" end
        return "o.status = 'pending_payment' AND o.payment_method = 'bank_transfer'"
    end
    return nil
end
ShopQuoteQueries.QUICK_FILTERS = { "awaiting_authorisation", "awaiting_payment", "needs_supplier_po", "bank_transfer_due" }

function ShopQuoteQueries.adminList(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 25), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "q.namespace_id = ?" }, { ns_id }
    if U.nz(params.status) then
        where[#where + 1] = "q.status = ?"
        vals[#vals + 1] = params.status
    end
    if U.nz(params.filter) then
        local f = quick_filter_sql(params.filter)
        if not f then return nil, U.err(400, "VALIDATION_ERROR", "filter must be one of "
            .. table.concat(ShopQuoteQueries.QUICK_FILTERS, ", ")) end
        where[#where + 1] = "(" .. f .. ")"
    end
    if U.nz(params.kind) and KINDS[params.kind] then
        where[#where + 1] = "q.kind = ?"
        vals[#vals + 1] = params.kind
    end
    if U.nz(params.q) then
        local like = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(q.quote_number ILIKE ? OR q.customer->>'email' ILIKE ? OR q.customer->>'name' ILIKE ? "
            .. "OR q.customer->>'company' ILIKE ? OR q.customer_po_number ILIKE ?)"
        for _ = 1, 5 do vals[#vals + 1] = like end
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. QUOTE_COLS .. REVISION_COLS .. [[, o.uuid AS order_uuid, o.order_number,
               o.status AS order_status, o.paid_at AS order_paid_at,
               cs.uuid AS chat_session_uuid, c.uuid AS cart_uuid, COUNT(*) OVER() AS total
          FROM shop_quotes q LEFT JOIN shop_orders o ON o.id = q.order_id
          LEFT JOIN shop_chat_sessions cs ON cs.id = q.chat_session_id
          LEFT JOIN shop_carts c ON c.id = q.cart_id
         ]] .. REVISION_JOINS .. [[
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

--- Every quote in this quote's revision chain (the original first).
function ShopQuoteQueries.revisionChain(q)
    local root = tonumber(q.revision_of_id) or tonumber(q.id)
    return db.query([[
        SELECT uuid, quote_number, revision_no, status, superseded_by_id IS NOT NULL AS superseded, created_at
          FROM shop_quotes WHERE id = ? OR revision_of_id = ? ORDER BY revision_no, id
    ]], root, root)
end

function ShopQuoteQueries.adminGet(ns_id, uuid)
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q then return nil end
    local s = ShopQuoteQueries.shape(q, { admin = true })
    local chain = ShopQuoteQueries.revisionChain(q)
    s.revisions = U.arr(#chain > 1 and chain or {})
    return s
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
    local f, ferr = order_fields(body)
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local po, perr = Rules.clean_po_number(body.customer_po_number)
    if perr then return nil, U.err(400, "VALIDATION_ERROR", perr) end
    local shipping = U.int(body.shipping_minor, 0)
    local staff = f.discount_minor or 0
    local trade = type(f.trade) == "number" and f.trade or 0
    if f.trade == "apply" then trade = trade_discount(ns_id, customer.email, lines, shipping, staff) end
    local q = ShopQuoteQueries.insert(ns_id, {
        lines = lines, customer = customer, notes = body.notes, internal_notes = body.internal_notes,
        source = "admin", status = body.status or "draft", valid_until = body.valid_until,
        shipping_minor = shipping, created_by_user_id = user_id,
        kind = f.kind or "quote", discount_minor = staff, discount_label = f.discount_label or nil,
        trade_discount_minor = trade, delivery_method = f.delivery_method or nil,
        delivery_address = f.delivery_address or nil, customer_po_number = po,
    })
    return ShopQuoteQueries.adminGet(ns_id, q.uuid)
end

function ShopQuoteQueries.adminUpdate(ns_id, uuid, body)
    local q = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not q then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    -- Once it has turned into an order (or been replaced by a revision) what the customer agreed to stays.
    local content_change = body.lines ~= nil or body.shipping_minor ~= nil or body.customer ~= nil
        or body.discount_minor ~= nil or body.discount_label ~= nil or body.apply_trade_discount ~= nil
        or body.trade_discount_minor ~= nil or body.delivery_address ~= nil or body.delivery_method ~= nil
        or body.kind ~= nil
    if content_change then
        local ok, code, msg = Rules.can_edit_content(q)
        if not ok then return nil, U.err(409, code, msg) end
    end
    local fields = { updated_at = db.raw("NOW()") }
    if body.customer_po_number ~= nil then
        local ok, code, msg = Rules.can_edit_po_number(q)
        if not ok then return nil, U.err(409, code, msg) end
        local po, perr = Rules.clean_po_number(body.customer_po_number ~= U.null and body.customer_po_number or nil)
        if perr then return nil, U.err(400, "VALIDATION_ERROR", perr) end
        fields.customer_po_number = po or db.NULL
    end
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
    local f, ferr = order_fields(body)
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local pricing_change = f.discount_minor ~= nil or f.trade ~= nil
    if (pricing_change or body.lines ~= nil or body.shipping_minor ~= nil) and q.status == "converted" then
        return nil, U.err(409, "QUOTE_CONVERTED", "A paid (converted) quote's prices cannot be changed")
    end
    if f.kind then fields.kind = f.kind end
    if f.discount_label ~= nil then fields.discount_label = f.discount_label or db.NULL end
    if f.delivery_method ~= nil then fields.delivery_method = f.delivery_method or db.NULL end
    if f.delivery_address ~= nil then
        fields.delivery_address = f.delivery_address and db.raw(db.escape_literal(U.enc(f.delivery_address)) .. "::jsonb")
            or db.NULL
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
    elseif body.shipping_minor ~= nil or pricing_change then
        lines = U.dec(q.lines, {})
    end
    if lines then
        local staff = f.discount_minor or tonumber(q.discount_minor) or 0
        local trade = tonumber(q.trade_discount_minor) or 0
        if f.trade == "apply" then
            local email = (body.customer ~= nil and type(body.customer) == "table" and body.customer.email)
                or U.dec(q.customer, {}).email
            trade = trade_discount(ns_id, email, lines, shipping, staff)
        elseif f.trade == "clear" then
            trade = 0
        elseif type(f.trade) == "number" then
            trade = f.trade
        end
        local t = Pricing.discounted_totals(lines, shipping, staff + trade)
        fields.discount_minor = staff
        fields.trade_discount_minor = trade
        fields.lines = db.raw(db.escape_literal(U.enc(U.arr(lines))) .. "::jsonb")
        fields.subtotal_minor = t.subtotal_minor
        fields.vat_minor = t.vat_minor
        fields.shipping_minor = t.shipping_minor
        fields.total_minor = t.total_minor
    end
    db.update("shop_quotes", fields, { id = q.id })
    return ShopQuoteQueries.adminGet(ns_id, uuid)
end

--- POST /quotes/:uuid/revise — a small correction to a quote or Order Authorisation the customer has seen:
-- a copy (same kind, lines at the same prices, discounts, delivery, PO number, notes) numbered
-- <original>-R<n>, starting as a draft. The old one is cancelled and points at it. For different products,
-- quantities or a different customer staff raise a new quote instead.
-- body: { reason*, customer?, delivery_address?, delivery_method?, customer_po_number?, valid_until? }
function ShopQuoteQueries.revise(ns_id, uuid, body, user_id)
    body = type(body) == "table" and body or {}
    local reason = type(body.reason) == "string" and body.reason:gsub("%c", " "):match("^%s*(.-)%s*$") or ""
    if #reason < 3 or #reason > 500 then
        return nil, U.err(400, "VALIDATION_ERROR", "reason is required (3–500 characters)")
    end
    local src = ShopQuoteQueries.getByUuid(ns_id, uuid)
    if not src then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    local ok, code, msg = Rules.can_revise(src)
    if not ok then return nil, U.err(409, code, msg) end

    local customer = U.dec(src.customer, {})
    if type(body.customer) == "table" then
        for k, v in pairs(body.customer) do customer[k] = v end
    end
    local cerr
    customer, cerr = clean_customer(customer, false)
    if not customer then return nil, U.err(400, "VALIDATION_ERROR", cerr) end
    local f, ferr = order_fields({ delivery_address = body.delivery_address, delivery_method = body.delivery_method })
    if not f then return nil, U.err(400, "VALIDATION_ERROR", ferr) end
    local delivery = f.delivery_address
    if delivery == nil then delivery = U.nz(src.delivery_address) and U.dec(src.delivery_address, nil) or nil end
    local method = f.delivery_method
    if method == nil then method = U.nz(src.delivery_method) end
    local po = src.customer_po_number
    if body.customer_po_number ~= nil then
        local perr
        po, perr = Rules.clean_po_number(body.customer_po_number ~= U.null and body.customer_po_number or nil)
        if perr then return nil, U.err(400, "VALIDATION_ERROR", perr) end
    end
    local inputs, ierr = quote_line_inputs(ns_id, src)
    if not inputs then return nil, ierr end
    local lines, lerr = ShopQuoteQueries.priceLines(ns_id, inputs, { admin = true })
    if not lines then return nil, lerr end
    -- Still in date: keep the date; expired: a fresh 30 days (or what staff chose).
    local valid_until = U.nz(body.valid_until) or (not src.is_past_validity and src.valid_until) or nil

    local new_id, terr = U.tx(function()
        -- Lock the old quote and the original so two revisions can't take the same number.
        local root_id = tonumber(src.revision_of_id) or tonumber(src.id)
        local locked = db.query("SELECT id, status, order_id, superseded_by_id FROM shop_quotes WHERE id IN (?, ?) FOR UPDATE",
            src.id, root_id)
        for _, r in ipairs(locked) do
            if tonumber(r.id) == tonumber(src.id) then
                local still, c2, m2 = Rules.can_revise(r)
                if not still then return nil, U.err(409, c2, m2) end
            end
        end
        local root = db.query("SELECT quote_number FROM shop_quotes WHERE id = ?", root_id)[1]
        local nos = {}
        for _, r in ipairs(db.query("SELECT revision_no FROM shop_quotes WHERE id = ? OR revision_of_id = ?", root_id, root_id)) do
            nos[#nos + 1] = r.revision_no
        end
        local n = Rules.next_revision_no(nos)
        local note = "Revision " .. n .. " of " .. root.quote_number .. " (replaces " .. src.quote_number .. "): " .. reason
        local q = ShopQuoteQueries.insert(ns_id, {
            quote_number = Rules.revision_number(root.quote_number, n), revision_no = n, revision_of_id = root_id,
            lines = lines, customer = customer, notes = src.notes,
            internal_notes = U.nz(src.internal_notes) and (src.internal_notes .. "\n\n" .. note) or note,
            source = src.source, status = "draft", valid_until = valid_until,
            shipping_minor = tonumber(src.shipping_minor) or 0, created_by_user_id = user_id,
            kind = src.kind or "quote", discount_minor = tonumber(src.discount_minor) or 0,
            discount_label = src.discount_label, trade_discount_minor = tonumber(src.trade_discount_minor) or 0,
            delivery_method = method or nil, delivery_address = delivery or nil, customer_po_number = po,
        })
        db.query([[UPDATE shop_quotes SET price_locked = ?, crm_lead_id = ? WHERE id = ?]],
            src.price_locked == true, src.crm_lead_id or db.NULL, q.id)
        db.query([[UPDATE shop_quotes SET status = 'cancelled', superseded_by_id = ?, updated_at = NOW(),
                   internal_notes = COALESCE(internal_notes || E'\n', '') || ? WHERE id = ?]],
            q.id, "Superseded by " .. q.quote_number .. ": " .. reason, src.id)
        return q.id
    end)
    if not new_id then return nil, terr end
    local new = ShopQuoteQueries.getById(new_id)
    return ShopQuoteQueries.adminGet(ns_id, new.uuid)
end

return ShopQuoteQueries
