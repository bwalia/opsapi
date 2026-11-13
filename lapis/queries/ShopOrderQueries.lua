-- luacheck: max line length 140
--[[
    Shop orders + checkout (Stripe hosted Checkout)
    ================================================
    BUILD.prompt.md §4:
      1. load lines (cart re-priced now, or a payable quote's snapshot)
      2. ONE transaction: order (pending_payment) + held stock reservations (35 min)
      3. Stripe Checkout Session (gbp, one line per line + a VAT line + shipping),
         idempotency key shop-order-<uuid>; save stripe_session_id
      4. the cart is converted only when payment succeeds (webhook / reconciler)
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local cjson = require("cjson")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Pricing = require("lib.shop-pricing")
local Catalog = require("queries.ShopCatalogQueries")
local Cart = require("queries.ShopCartQueries")
local Quote = require("queries.ShopQuoteQueries")
local Stock = require("queries.ShopStockQueries")
local PaymentMethods = require("queries.PaymentMethodQueries")
local PM = require("lib.payment-methods")
local Rules = require("lib.shop-quote-rules")

local ShopOrderQueries = {}

local STATUSES = {
    pending_payment = true, paid = true, processing = true, shipped = true, delivered = true,
    cancelled = true, refunded = true, payment_failed = true,
}
ShopOrderQueries.STATUSES = STATUSES

local RESERVATION_MINUTES = 35
local SESSION_MINUTES = 31
local ALLOWED_SHIP_COUNTRIES = { "GB", "IE", "FR", "DE", "NL", "BE", "ES", "IT" }

local ORDER_COLS = [[
    o.id, o.uuid, o.namespace_id, o.order_number, o.access_token, o.status, o.email, o.customer::text AS customer,
    o.shipping_address::text AS shipping_address, o.billing_address::text AS billing_address,
    o.lines::text AS lines, o.subtotal_minor, o.vat_minor, o.shipping_minor, o.total_minor, o.credit_minor, o.member_discount_minor, o.member_discount_pct, o.currency,
    o.discount_minor, o.delivery_method, o.delivery_address::text AS delivery_address,
    o.refunded_minor, o.returned_net_minor, o.refund_clawback_minor,
    o.cart_id, o.quote_id, o.stripe_session_id, o.stripe_payment_intent_id, o.paid_at,
    o.tracking::text AS tracking, o.internal_notes, o.created_at, o.updated_at,
    o.payment_method, o.paid_reference, o.paid_amount_minor, o.invoice_uuid, o.customer_po_number
]]
ShopOrderQueries.ORDER_COLS = ORDER_COLS

local function url_path(o)
    return "/orders/" .. o.uuid .. "?t=" .. o.access_token
end

function ShopOrderQueries.shape(o, opts)
    opts = opts or {}
    local out = {
        uuid = o.uuid,
        order_number = o.order_number,
        status = o.status,
        email = o.email or U.null,
        customer = U.dec(o.customer, {}),
        shipping_address = U.dec(o.shipping_address, U.null),
        billing_address = U.dec(o.billing_address, U.null),
        lines = U.arr(U.dec(o.lines, {})),
        subtotal_minor = o.subtotal_minor,
        vat_minor = o.vat_minor,
        shipping_minor = o.shipping_minor,
        total_minor = o.total_minor,
        credit_minor = tonumber(o.credit_minor) or 0,
        member_discount_minor = tonumber(o.member_discount_minor) or 0,
        member_discount_pct = tonumber(o.member_discount_pct) or U.null,
        discount_minor = tonumber(o.discount_minor) or 0,
        delivery_method = o.delivery_method or U.null,
        delivery_address = U.nz(o.delivery_address) and U.dec(o.delivery_address, U.null) or U.null,
        currency = o.currency,
        paid_at = o.paid_at or U.null,
        created_at = o.created_at,
        tracking = U.dec(o.tracking, U.null),
        url_path = url_path(o),
        -- card (Stripe Checkout; older orders have no value) | bank_transfer | cheque | other
        payment_method = U.nz(o.payment_method) or "card",
        -- Bank transfer: where to pay and the reference to use (the order number). [] otherwise.
        payment_methods = U.arr({}),
        payment_reference = U.null,
        customer_po_number = U.nz(o.customer_po_number) or U.null,
    }
    if o.payment_method == "bank_transfer" then
        out.payment_methods = PaymentMethods.forDocuments(o.namespace_id)
        out.payment_reference = o.order_number
    end
    if opts.admin then
        out.refunded_minor = tonumber(o.refunded_minor) or 0
        out.returned_net_minor = tonumber(o.returned_net_minor) or 0
        out.refund_clawback_minor = tonumber(o.refund_clawback_minor) or 0
        out.internal_notes = o.internal_notes or U.null
        out.stripe_session_id = o.stripe_session_id or U.null
        out.stripe_payment_intent_id = o.stripe_payment_intent_id or U.null
        out.updated_at = o.updated_at
        out.quote_uuid = o.quote_uuid or U.null
        out.quote_number = o.quote_number or U.null
        out.cart_uuid = o.cart_uuid or U.null
        out.chat_session_uuid = o.chat_session_uuid or U.null
        local base = U.env("SHOP_PUBLIC_URL")
        out.public_url = base and (base:gsub("/+$", "") .. out.url_path) or out.url_path
        out.access_token = o.access_token
        out.stripe_mode = (U.env("STRIPE_SECRET_KEY") or ""):find("_live_", 1, true) and "live" or "test"
        out.paid_reference = o.paid_reference or U.null
        out.paid_amount_minor = tonumber(o.paid_amount_minor) or U.null
        out.invoice_uuid = o.invoice_uuid or U.null
        -- "Bank transfer due": awaiting a bank transfer, and for how long (whole days).
        out.bank_transfer_due = o.status == "pending_payment" and o.payment_method == "bank_transfer"
        out.days_waiting = tonumber(o.days_waiting) or U.null
    end
    return out
end

function ShopOrderQueries.getById(id)
    return db.query("SELECT " .. ORDER_COLS .. " FROM shop_orders o WHERE o.id = ?", id)[1]
end

function ShopOrderQueries.getByUuid(ns_id, uuid)
    return db.query("SELECT " .. ORDER_COLS .. [[, q.uuid AS quote_uuid, q.quote_number, c.uuid AS cart_uuid,
               EXTRACT(DAY FROM NOW() - o.created_at)::int AS days_waiting,
               (SELECT cs.uuid FROM shop_chat_sessions cs WHERE cs.order_id = o.id OR (o.cart_id IS NOT NULL
                   AND cs.cart_id = o.cart_id) ORDER BY cs.id DESC LIMIT 1) AS chat_session_uuid
          FROM shop_orders o
          LEFT JOIN shop_quotes q ON q.id = o.quote_id
          LEFT JOIN shop_carts c ON c.id = o.cart_id
         WHERE o.namespace_id = ? AND o.uuid = ?]], ns_id, uuid)[1]
end

function ShopOrderQueries.publicView(ns_id, uuid, token)
    if not U.nz(uuid) or not U.nz(token) then return nil end
    local o = ShopOrderQueries.getByUuid(ns_id, uuid)
    if not o or not U.secure_equals(o.access_token, token) then return nil end
    return ShopOrderQueries.shape(o)
end

local function next_number()
    return db.query([[
        SELECT 'WSO-' || to_char(NOW(), 'YYYY') || '-' || lpad(nextval('shop_order_number_seq')::text, 5, '0') AS n
    ]])[1].n
end

-- ---------------------------------------------------------------------------
-- checkout
-- ---------------------------------------------------------------------------

local function substitute(url, order_uuid, order_token)
    url = url:gsub("{ORDER_UUID}", order_uuid):gsub("%%7BORDER_UUID%%7D", order_uuid)
    url = url:gsub("{ORDER_TOKEN}", order_token):gsub("%%7BORDER_TOKEN%%7D", order_token)
    return url
end

--- Demand for every line: re-load each product and run the engine on the
-- line's own selections/qty (prices from the snapshot are kept as-is).
local function demand_for_lines(ns_id, lines)
    local agg, order = {}, {}
    for _, l in ipairs(lines) do
        local bundle = U.nz(l.product_uuid) and Catalog.loadBundle(ns_id, { uuid = l.product_uuid })
        if bundle then
            local _, demand = Catalog.priceBundle(bundle, l.selections, l.qty)
            for _, d in ipairs(demand) do
                local a = agg[d.stock_key]
                if not a then
                    a = { stock_key = d.stock_key, qty = 0, name = d.name, allow_backorder = d.allow_backorder }
                    agg[d.stock_key] = a
                    order[#order + 1] = a
                end
                a.qty = a.qty + d.qty
            end
        end
    end
    return order
end

--- Current availability for demand rows (inside the locked transaction).
local function shortages_for(demand)
    local pids, oids = {}, {}
    for _, d in ipairs(demand) do
        local kind, id = d.stock_key:match("^(%a):(%d+)$")
        if kind == "p" then pids[#pids + 1] = tonumber(id) elseif kind == "o" then oids[#oids + 1] = tonumber(id) end
    end
    local pav, oav = Stock.forProducts(pids), Stock.forOptions(oids)
    local blocking = {}
    for _, d in ipairs(demand) do
        local kind, id = d.stock_key:match("^(%a):(%d+)$")
        local a = (kind == "p" and pav[tonumber(id)]) or (kind == "o" and oav[tonumber(id)]) or nil
        if a and d.qty > a.available and not d.allow_backorder then
            blocking[#blocking + 1] = { name = d.name, requested = d.qty, available = math.max(0, a.available) }
        end
    end
    return blocking
end

--- Build Stripe line_items from order lines.
local function stripe_line_items(lines, totals)
    local items = {}
    for _, l in ipairs(lines) do
        local name = tostring(l.label or l.product_name or "Item")
        if #name > 250 then name = name:sub(1, 247) .. "..." end
        items[#items + 1] = {
            price_data = {
                currency = "gbp",
                unit_amount = math.max(0, math.floor(tonumber(l.unit_price_minor) or 0)),
                product_data = { name = name },
            },
            quantity = math.max(1, math.floor(tonumber(l.qty) or 1)),
        }
    end
    if totals.vat_minor > 0 then
        local rate_label = "20%"
        local first = lines[1] and tonumber(lines[1].vat_rate)
        if first then
            local same = true
            for _, l in ipairs(lines) do if tonumber(l.vat_rate) ~= first then same = false end end
            rate_label = same and (tostring(Pricing.round(first * 100)) .. "%") or "mixed"
        end
        items[#items + 1] = {
            price_data = { currency = "gbp", unit_amount = totals.vat_minor, product_data = { name = "VAT (" .. rate_label .. ")" } },
            quantity = 1,
        }
    end
    if totals.shipping_minor > 0 then
        items[#items + 1] = {
            price_data = { currency = "gbp", unit_amount = totals.shipping_minor, product_data = { name = "Shipping" } },
            quantity = 1,
        }
    end
    return items
end

-- Trade discount / refund VAT uses the basket's weighted rate, not one line's (lib/shop-pricing).
local effective_vat_rate = Pricing.effective_vat_rate

--- POST /checkout.
-- body: {from:"cart"|"quote", quote_uuid?, quote_token?, email?, name?, company?, phone?, success_url, cancel_url}
-- Returns ({order_uuid, order_token, checkout_url}) or (nil, err)
function ShopOrderQueries.checkout(ns_id, body, cart_token)
    local PaymentProvider = require("lib.payment-provider")
    -- A staff-built order (Order Authorisation) was priced and checked by staff, so its customer can pay
    -- for it even while public checkout is switched off.
    local staff_order = false
    if body.from == "quote" then
        local pq = Quote.getWithToken(ns_id, body.quote_uuid, body.quote_token)
        staff_order = pq ~= nil and Quote.isStaffOrder(pq)
    end
    if not staff_order and not require("queries.ShopSettingsQueries").checkoutEnabled(ns_id) then
        return nil, U.err(409, "CHECKOUT_DISABLED",
            "Online checkout is closed — request a quote and we'll confirm your final price")
    end
    if not U.env("STRIPE_SECRET_KEY") then
        return nil, U.err(503, "PAYMENTS_DISABLED", "Online payment is not available — please request a quote")
    end
    if not U.url_allowed(body.success_url) or not U.url_allowed(body.cancel_url) then
        return nil, U.err(400, "INVALID_REDIRECT_URL",
            "success_url and cancel_url must start with an allowed origin (SHOP_ALLOWED_ORIGINS)")
    end
    local email = U.nz(body.email)
    if email and not tostring(email):match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
        return nil, U.err(400, "VALIDATION_ERROR", "email is invalid")
    end

    local from = body.from or "cart"
    local lines, cart, quote, customer
    if from == "cart" then
        cart = Cart.byToken(ns_id, cart_token)
        if not cart then return nil, U.err(404, "CART_NOT_FOUND", "Cart not found") end
        local view = Cart.view(ns_id, cart)
        if #view.lines == 0 then return nil, U.err(400, "EMPTY_CART", "The cart is empty") end
        local reasons = {}
        for _, l in ipairs(view.lines) do
            if l.price_mode == "quote_only" then
                reasons[#reasons + 1] = { line_uuid = l.uuid, reason = "quote_only", name = l.product_name }
            elseif not l.valid then
                reasons[#reasons + 1] = { line_uuid = l.uuid, reason = "invalid", name = l.product_name,
                    violations = l.violations }
            end
        end
        if #reasons > 0 then
            return nil, U.err(409, "QUOTE_REQUIRED", "Some items need a quote before they can be purchased",
                { lines = U.arr(reasons) })
        end
        lines = view.lines
        email = email or U.nz(cart.email)
        customer = {}
    elseif from == "quote" then
        quote = Quote.getWithToken(ns_id, body.quote_uuid, body.quote_token)
        if not quote then return nil, U.err(404, "QUOTE_NOT_FOUND", "Quote not found") end
        Quote.maybeExpire(quote)
        if quote.status == "expired" or quote.is_past_validity then
            return nil, U.err(409, "QUOTE_EXPIRED", "This quote has expired — please ask for a new one")
        end
        if quote.status ~= "draft" and quote.status ~= "sent" and quote.status ~= "accepted" then
            return nil, U.err(409, "QUOTE_NOT_PAYABLE", "This quote cannot be paid (status " .. quote.status .. ")")
        end
        lines = U.dec(quote.lines, {})
        if #lines == 0 then return nil, U.err(400, "EMPTY_QUOTE", "The quote has no lines") end
        -- quote_only items sit on a self-service quote at no price; paying now would buy them for
        -- nothing. They become payable once staff price the line (price_override_minor).
        local unpriced = Pricing.unpriced_lines(lines)
        if #unpriced > 0 then
            return nil, U.err(409, "QUOTE_PRICING_PENDING", "We still need to price " .. table.concat(unpriced, ", ")
                .. ". We'll send you the updated quote to pay.", { products = U.arr(unpriced) })
        end
        customer = U.dec(quote.customer, {})
        email = email or U.nz(customer.email)
    else
        return nil, U.err(400, "VALIDATION_ERROR", "from must be cart or quote")
    end
    local bc = type(body.customer) == "table" and body.customer or {}
    for _, k in ipairs({ "name", "company", "phone", "vat_number" }) do
        local v = U.nz(bc[k]) or U.nz(body[k])
        if v then customer[k] = tostring(v):sub(1, 255) end
    end
    if not email and U.nz(bc.email) and tostring(bc.email):match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
        email = bc.email
    end
    if email then customer.email = email end

    local totals
    -- What the quote takes off (staff discount + VIP Trade discount agreed in the back office), ex VAT.
    local quote_discount = quote and Quote.discountOf(quote) or 0
    local quote_trade = quote and (tonumber(quote.trade_discount_minor) or 0) or 0
    if quote then
        totals = {
            subtotal_minor = tonumber(quote.subtotal_minor), vat_minor = tonumber(quote.vat_minor),
            shipping_minor = tonumber(quote.shipping_minor) or 0, total_minor = tonumber(quote.total_minor),
        }
    else
        totals = Pricing.totals(lines, 0)
    end
    if (totals.total_minor or 0) <= 0 then
        return nil, U.err(409, "QUOTE_REQUIRED", "This order has no payable amount — please request a quote")
    end

    -- Trade discount + member credit: only for a signed-in member paying with their own email
    -- (ngx.ctx.shop_member is set by the public route from X-Member-Token). Both reduce the subtotal
    -- ex VAT and VAT is recomputed. The trade discount (by membership tier, active/past_due only)
    -- applies to basket orders, never to quotes (those keep their quoted prices), and comes first;
    -- credit then applies to the discounted subtotal.
    local credit, trade
    local gross_before = totals.total_minor
    -- Stripe line items are the undiscounted lines + undiscounted VAT; the coupon below takes off
    -- amount_off, so Stripe's total equals the order total exactly.
    local stripe_totals = totals
    if quote_discount > 0 then
        -- The quote's totals are already discounted: Stripe gets the list lines and the coupon the rest.
        stripe_totals = Pricing.totals(lines, totals.shipping_minor)
        gross_before = stripe_totals.total_minor
    end

    -- Joining Trade with this order (body.membership): reserve the spot now, give this order the
    -- Trade discount for the tier they join at, and charge the first fee in the same Stripe payment.
    local join
    if type(body.membership) == "table" then
        if from ~= "cart" and quote_trade > 0 then
            return nil, U.err(400, "VALIDATION_ERROR", "This quote already includes the Trade discount")
        end
        local Membership = require("queries.ShopMembershipQueries")
        local R = require("lib.shop-membership")
        local bm = body.membership
        local s, jemail, interval = Membership.validateJoin(ns_id, {
            email = email, interval = bm.interval, accept_terms = bm.accept_terms, terms_version = bm.terms_version,
        })
        if not s then return nil, jemail end
        join = { settings = s, m = Membership.reserve(ns_id, s, jemail, interval) }
        local vat_rate = effective_vat_rate(totals.subtotal_minor, totals.vat_minor)
        -- A new membership year: the whole yearly cap is available to the order they join with.
        local d = R.apply_trade(s, join.m.tier, totals.subtotal_minor, vat_rate, totals.shipping_minor,
            R.cap_remaining(s, 0))
        if d.discount_minor > 0 then
            trade = { pct = d.pct, discount_minor = d.discount_minor }
            totals = { subtotal_minor = d.subtotal_minor, vat_minor = d.vat_minor,
                       shipping_minor = d.shipping_minor, total_minor = d.total_minor }
        end
    end
    local function abandon_join()
        if join then require("queries.ShopMembershipQueries").abandon(join.m) end
    end

    local member = ngx.ctx and ngx.ctx.shop_member
    if member and (not email or tostring(email):lower() == member.email) then
        local Membership = require("queries.ShopMembershipQueries")
        local R = require("lib.shop-membership")
        local vat_rate = effective_vat_rate(totals.subtotal_minor, totals.vat_minor)
        local m = member.membership
        -- Basket orders, and quotes that don't already carry a Trade discount agreed by staff.
        if (from == "cart" or (quote and quote_trade == 0)) and not trade and member.active and type(m) == "table"
            and (m.status == "active" or m.status == "past_due") then
            -- Limited to what is left of this membership year's cap (order discounts + join credits so far).
            local ms = Membership.settings(ns_id)
            local d = R.apply_trade(ms, m.tier, totals.subtotal_minor, vat_rate, totals.shipping_minor,
                Membership.capRemaining(ns_id, m, ms))
            if d.discount_minor > 0 then
                trade = { pct = d.pct, discount_minor = d.discount_minor }
                totals = { subtotal_minor = d.subtotal_minor, vat_minor = d.vat_minor,
                           shipping_minor = d.shipping_minor, total_minor = d.total_minor }
                email = email or member.email
                customer.email = email
            end
        end
        local available = Membership.availableCredits(ns_id, member.email)
        if #available > 0 then
            local applied = R.apply_credits(totals.subtotal_minor, vat_rate, totals.shipping_minor, available)
            if applied.credit_minor > 0 then
                if applied.total_minor < 50 then
                    abandon_join()
                    return nil, U.err(409, "CREDIT_COVERS_ORDER",
                        "Your credit covers this whole order — please request a quote and we'll arrange it for you")
                end
                credit = applied
                totals = { subtotal_minor = applied.subtotal_minor, vat_minor = applied.vat_minor,
                           shipping_minor = applied.shipping_minor, total_minor = applied.total_minor }
                email = email or member.email
                customer.email = email
            end
        end
    end
    -- Everything off the order (trade discount, credit and the VAT they save) as one amount for Stripe.
    local amount_off = gross_before - totals.total_minor

    local stripe, serr = PaymentProvider.get_stripe()
    if not stripe then
        ngx.log(ngx.ERR, "[shop] checkout: ", tostring(serr))
        abandon_join()
        return nil, U.err(503, "PAYMENTS_DISABLED", "Online payment is not available — please request a quote")
    end

    -- 2. order + reservations in one transaction (serialised per namespace so
    -- two checkouts cannot both take the last unit)
    local order, terr = U.tx(function()
        db.query("SELECT pg_advisory_xact_lock(hashtext('shop_stock_' || ?))", tostring(ns_id))
        local demand = demand_for_lines(ns_id, lines)
        local blocking = shortages_for(demand)
        if #blocking > 0 then
            return nil, U.err(409, "OUT_OF_STOCK", "Some items are out of stock", { shortages = U.arr(blocking) })
        end
        local token = U.token(24)
        local row = db.query([[
            INSERT INTO shop_orders (uuid, namespace_id, order_number, access_token, status, email, customer, lines,
                                     subtotal_minor, vat_minor, shipping_minor, total_minor, credit_minor,
                                     member_discount_minor, member_discount_pct, discount_minor, delivery_method,
                                     delivery_address, currency, cart_id, quote_id, customer_po_number,
                                     created_at, updated_at)
            VALUES (?, ?, ?, ?, 'pending_payment', ?, ?::jsonb, ?::jsonb, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, 'GBP', ?, ?, ?,
                    NOW(), NOW())
            RETURNING id, uuid, order_number, access_token
        ]], Global.generateUUID(), ns_id, next_number(), token, email or db.NULL, U.enc(customer),
            U.enc(U.arr(lines)), totals.subtotal_minor, totals.vat_minor, totals.shipping_minor,
            totals.total_minor, credit and credit.credit_minor or 0,
            -- The quote's Trade discount counts towards the member's yearly cap like a basket one.
            (trade and trade.discount_minor or 0) + quote_trade, trade and trade.pct or db.NULL,
            quote_discount - quote_trade,
            quote and U.nz(quote.delivery_method) or db.NULL,
            quote and U.nz(quote.delivery_address) or db.NULL,
            cart and cart.id or db.NULL, quote and quote.id or db.NULL,
            quote and Quote.orderFieldsFromQuote(quote).customer_po_number or db.NULL)[1]
        Stock.hold(ns_id, row.id, demand, RESERVATION_MINUTES)
        if credit then require("queries.ShopMembershipQueries").reserveCredits(ns_id, row.id, credit.applied) end
        return row
    end)
    if not order then
        abandon_join()
        return nil, terr
    end

    -- 3. Stripe Checkout Session
    local meta = { order_uuid = order.uuid, namespace_id = tostring(ns_id), source = "workstation-shop" }
    local opts = {
        mode = "payment",
        success_url = substitute(body.success_url, order.uuid, order.access_token),
        cancel_url = substitute(body.cancel_url, order.uuid, order.access_token),
        line_items = stripe_line_items(lines, stripe_totals),
        shipping_address_collection = { allowed_countries = ALLOWED_SHIP_COUNTRIES },
        billing_address_collection = "required",
        phone_number_collection = { enabled = true },
        tax_id_collection = { enabled = true },
        expires_at = os.time() + SESSION_MINUTES * 60,
        client_reference_id = order.uuid,
        metadata = meta,
        payment_intent_data = { metadata = meta },
        idempotency_key = "shop-order-" .. order.uuid,
    }
    if join then
        -- One payment for both: subscription mode with the hardware as one-off items on the first
        -- invoice. The session stays an order session (its webhook also activates the membership via
        -- metadata.membership_uuid); the subscription carries the membership's own metadata.
        local Membership = require("queries.ShopMembershipQueries")
        local sub_meta = Membership.joinMeta(ns_id, join.m)
        sub_meta.order_uuid = order.uuid
        meta.membership_uuid = join.m.uuid
        local items = Membership.joinItems(join.settings, join.m)
        for _, it in ipairs(opts.line_items) do items[#items + 1] = it end
        opts.mode = "subscription"
        opts.line_items = items
        opts.payment_intent_data = nil
        opts.subscription_data = { metadata = sub_meta }
        opts.idempotency_key = "shop-order-trade-" .. order.uuid
    end
    if email then opts.customer_email = email end
    if amount_off > 0 then
        -- Stripe line items can't be negative: the trade discount and/or credit (plus the VAT they save)
        -- go on as one one-off coupon.
        local coupon_name = (trade and credit) and "Trade discount + credit"
            or trade and (trade.pct and ("Trade discount " .. tostring(trade.pct) .. "%") or "Trade discount")
            or credit and "Workstation credit"
            or (quote_trade > 0 and quote_trade == quote_discount) and "VIP Trade discount"
            or (quote and U.nz(quote.discount_label)) or "Discount"
        if credit and quote_discount > 0 then coupon_name = "Discount + credit" end
        local coupon, cerr = stripe:_request("POST", "/coupons", {
            amount_off = amount_off, currency = "gbp", duration = "once", max_redemptions = 1,
            name = coupon_name, metadata = { order_uuid = order.uuid },
        }, "shop-credit-" .. order.uuid)
        if not coupon or not coupon.id then
            ngx.log(ngx.ERR, "[shop] discount coupon failed for ", order.order_number, ": ", tostring(cerr))
            U.tx(function()
                db.query("UPDATE shop_orders SET status = 'cancelled', updated_at = NOW() WHERE id = ?", order.id)
                Stock.release(order.id)
                require("queries.ShopMembershipQueries").releaseCredits(order.id)
                return true
            end)
            abandon_join()
            return nil, U.err(502, "PAYMENT_PROVIDER_ERROR", "Could not start checkout — please try again or request a quote")
        end
        opts.discounts = { { coupon = coupon.id } }
        db.query("UPDATE shop_orders SET stripe_coupon_id = ? WHERE id = ?", coupon.id, order.id)
    end
    local session, stripe_err = stripe:create_checkout_session(opts)
    if not session or not session.url then
        ngx.log(ngx.ERR, "[shop] Stripe checkout session failed for ", order.order_number, ": ", tostring(stripe_err))
        U.tx(function()
            db.query([[UPDATE shop_orders SET status = 'cancelled', updated_at = NOW(),
                       internal_notes = ? WHERE id = ?]], "Stripe session creation failed: "
                .. tostring(stripe_err):sub(1, 500), order.id)
            Stock.release(order.id)
            require("queries.ShopMembershipQueries").releaseCredits(order.id)
            return true
        end)
        abandon_join()
        return nil, U.err(502, "PAYMENT_PROVIDER_ERROR", "Could not start checkout — please try again or request a quote")
    end
    db.query("UPDATE shop_orders SET stripe_session_id = ?, updated_at = NOW() WHERE id = ?", session.id, order.id)
    if staff_order then
        -- Paying is confirming: the shop app recorded their acceptance of the terms before checkout.
        db.query([[UPDATE shop_quotes SET status = CASE WHEN status IN ('draft', 'sent') THEN 'accepted' ELSE status END,
                   authorised_at = COALESCE(authorised_at, NOW()), updated_at = NOW() WHERE id = ?]], quote.id)
    end
    if join then
        db.query("UPDATE shop_memberships SET stripe_session_id = ?, updated_at = NOW() WHERE id = ?", session.id, join.m.id)
        db.query([[UPDATE shop_orders SET internal_notes = COALESCE(internal_notes || E'\n', '') || ? WHERE id = ?]],
            "Joining Trade with this order: membership " .. join.m.uuid .. " (" .. join.m.tier .. ", "
                .. join.m.billing_interval .. "ly)", order.id)
    end
    return { order_uuid = order.uuid, order_token = order.access_token, checkout_url = session.url,
             order_number = order.order_number, credit_minor = credit and credit.credit_minor or 0,
             member_discount_minor = trade and trade.discount_minor or 0,
             member_discount_pct = trade and trade.pct or U.null,
             membership_uuid = join and join.m.uuid or U.null }
end

-- ---------------------------------------------------------------------------
-- payment state transitions (webhook + reconciler share these)
-- ---------------------------------------------------------------------------

local function nz(v) return U.nz(v) end

--- Copy the quote fields an order carries (ShopQuoteQueries.orderFieldsFromQuote: customer PO number) onto
-- an order made from it. quote: a quote row or its id. opts.only_missing: keep what the order already has.
-- For every path that creates an order from a quote (card checkout, bank transfer).
function ShopOrderQueries.applyQuoteFields(order_id, quote, opts)
    if type(quote) ~= "table" then
        quote = nz(quote) and db.query("SELECT customer_po_number FROM shop_quotes WHERE id = ?", quote)[1]
    end
    if not quote then return end
    local f = Quote.orderFieldsFromQuote(quote)
    if not f.customer_po_number then return end
    db.query("UPDATE shop_orders SET customer_po_number = ? WHERE id = ?" ..
        ((opts and opts.only_missing) and " AND customer_po_number IS NULL" or ""), f.customer_po_number, order_id)
end

--- Mark an order paid from a Stripe checkout session object. Idempotent.
-- Must run inside a transaction.
function ShopOrderQueries.applyPaid(order, session)
    if order.status == "paid" or order.status == "processing" or order.status == "shipped"
        or order.status == "delivered" or order.status == "refunded" then
        return false
    end
    session = session or {}
    local cd = type(session.customer_details) == "table" and session.customer_details or {}
    local customer = U.dec(order.customer, {})
    if nz(cd.name) then customer.name = customer.name or cd.name end
    if nz(cd.phone) then customer.phone = cd.phone end
    if nz(cd.email) then customer.email = cd.email end
    if type(cd.tax_ids) == "table" and #cd.tax_ids > 0 then
        customer.tax_ids = cd.tax_ids
        if not customer.vat_number and type(cd.tax_ids[1]) == "table" then customer.vat_number = cd.tax_ids[1].value end
    end
    local shipping = session.shipping_details
    if type(shipping) ~= "table" and type(session.collected_information) == "table" then
        shipping = session.collected_information.shipping_details
    end
    local billing = type(cd.address) == "table" and { name = cd.name, address = cd.address } or nil
    local pi = session.payment_intent
    if type(pi) == "table" then pi = pi.id end

    db.query([[
        UPDATE shop_orders SET status = 'paid', paid_at = COALESCE(paid_at, NOW()),
               stripe_payment_intent_id = COALESCE(?, stripe_payment_intent_id),
               stripe_session_id = COALESCE(stripe_session_id, ?),
               email = COALESCE(?, email), customer = ?::jsonb,
               shipping_address = COALESCE(?::jsonb, shipping_address),
               billing_address = COALESCE(?::jsonb, billing_address),
               updated_at = NOW()
         WHERE id = ?
    ]], nz(pi) or db.NULL, nz(session.id) or db.NULL, nz(cd.email) or db.NULL, U.enc(customer),
        type(shipping) == "table" and U.enc(shipping) or db.NULL,
        billing and U.enc(billing) or db.NULL, order.id)

    Stock.commit(order.namespace_id, order.id, order.order_number)
    Cart.markConverted(order.cart_id)
    if nz(order.quote_id) then
        -- An earlier bank-transfer order for the same Order Authorisation that the customer then paid another
        -- way (card): cancel it and give its stock back, so only the paid order goes ahead.
        local stale = db.query([[SELECT id FROM shop_orders WHERE quote_id = ? AND id <> ? AND status = 'pending_payment'
                                  AND payment_method = 'bank_transfer']], order.quote_id, order.id)
        for _, st in ipairs(stale) do
            db.query([[UPDATE shop_orders SET status = 'cancelled', updated_at = NOW(),
                       internal_notes = COALESCE(internal_notes || E'\n', '') || ? WHERE id = ?]],
                "Cancelled: the customer paid " .. tostring(order.order_number) .. " instead of paying by bank transfer",
                st.id)
            Stock.release(st.id)
        end
        db.query("UPDATE shop_quotes SET status = 'converted', order_id = ?, updated_at = NOW() WHERE id = ?",
            order.id, order.quote_id)
        -- An order made before the quote fields were carried over (or by another path) gets them now.
        ShopOrderQueries.applyQuoteFields(order.id, order.quote_id, { only_missing = true })
    end
    db.query([[UPDATE shop_chat_sessions SET order_id = ?, updated_at = NOW()
                WHERE cart_id = ? AND order_id IS NULL]], order.id, order.cart_id or 0)
    local Membership = require("queries.ShopMembershipQueries")
    Membership.useCredits(order.id)
    order.email = nz(cd.email) or order.email
    Membership.maybeIssueRefundCredit(order)
    return true
end

--- Cancel / fail a pending order and release its held stock. Must run in a tx.
function ShopOrderQueries.applyUnpaid(order, status, note)
    if order.status ~= "pending_payment" then
        Stock.release(order.id)
        return false
    end
    db.query([[UPDATE shop_orders SET status = ?, updated_at = NOW(),
               internal_notes = CASE WHEN ?::text IS NULL THEN internal_notes
                                     ELSE COALESCE(internal_notes || E'\n', '') || ?::text END
               WHERE id = ?]], status, note or db.NULL, note or db.NULL, order.id)
    Stock.release(order.id)
    require("queries.ShopMembershipQueries").releaseCredits(order.id)
    return true
end

-- ---------------------------------------------------------------------------
-- bank transfer (Order Authorisations) + payments recorded by staff
-- ---------------------------------------------------------------------------

-- A bank transfer takes days, so its stock is held for two weeks (a card checkout holds 35 minutes).
local BANK_TRANSFER_HOLD_MINUTES = 14 * 24 * 60
ShopOrderQueries.BANK_TRANSFER_HOLD_MINUTES = BANK_TRANSFER_HOLD_MINUTES

local column_cache = {}
--- Does this column exist? (cached per worker once true). Used for columns another change adds.
local function has_column(tbl, col)
    local key = tbl .. "." .. col
    if column_cache[key] then return true end
    local ok, rows = pcall(db.query, [[SELECT 1 FROM information_schema.columns WHERE table_name = ? AND column_name = ?
                                       LIMIT 1]], tbl, col)
    local yes = ok and rows and #rows > 0 or false
    if yes then column_cache[key] = true end
    return yes
end
ShopOrderQueries.hasColumn = has_column

--- POST /quotes/:uuid/bank-transfer (public) — the customer of an authorised Order Authorisation chooses to
-- pay by bank transfer: creates the order (pending_payment, payment_method bank_transfer, no Stripe session),
-- holds its stock, links the quote (quote.order_id; the quote stays 'accepted' until the money arrives and
-- counts as turned into an order, so it can no longer be revised). Idempotent: a second call returns the
-- same order. Returns the public order shape (payment_methods + payment_reference = order number).
function ShopOrderQueries.bankTransfer(ns_id, uuid, token)
    local quote = Quote.getWithToken(ns_id, uuid, token)
    if not quote then return nil, U.err(404, "QUOTE_NOT_FOUND", "Quote not found") end
    Quote.maybeExpire(quote)
    return U.tx(function()
        -- Lock the quote so two clicks can't create two orders.
        local q = db.query("SELECT id, order_id, status FROM shop_quotes WHERE id = ? FOR UPDATE", quote.id)[1]
        if q and nz(q.order_id) then
            local existing = db.query("SELECT " .. ORDER_COLS .. " FROM shop_orders o WHERE o.id = ?", q.order_id)[1]
            if existing and existing.payment_method == "bank_transfer" and existing.status ~= "cancelled"
                and existing.status ~= "payment_failed" then
                return ShopOrderQueries.shape(existing)
            end
        end
        quote.status = q and q.status or quote.status
        local lines = U.dec(quote.lines, {})
        local methods = PaymentMethods.forDocuments(ns_id)
        local allowed, why = PM.bankTransferAllowed({
            kind = quote.kind, status = quote.status, is_past_validity = quote.is_past_validity,
            unpriced = #Pricing.unpriced_lines(lines), total_minor = quote.total_minor,
        }, methods)
        if not allowed then
            local messages = {
                NOT_AN_ORDER_AUTHORISATION = "Bank transfer is available for confirmed orders only",
                NOT_AUTHORISED = quote.status == "converted" and "This order has already been paid"
                    or "Please confirm the order first",
                QUOTE_EXPIRED = "This has expired — please ask us for a new one",
                QUOTE_PRICING_PENDING = "We still need to price some items before you can pay",
                NOTHING_TO_PAY = "There is nothing to pay on this order",
                NO_BANK_ACCOUNT = "Bank transfer isn't available — please pay by card or call us",
            }
            return nil, U.err(409, why == "NOT_AUTHORISED" and quote.status == "converted" and "QUOTE_NOT_PAYABLE"
                or why, messages[why] or "Bank transfer isn't available for this order")
        end
        if #lines == 0 then return nil, U.err(400, "EMPTY_QUOTE", "The quote has no lines") end

        db.query("SELECT pg_advisory_xact_lock(hashtext('shop_stock_' || ?))", tostring(ns_id))
        local demand = demand_for_lines(ns_id, lines)
        local blocking = shortages_for(demand)
        if #blocking > 0 then
            return nil, U.err(409, "OUT_OF_STOCK", "Some items are out of stock", { shortages = U.arr(blocking) })
        end
        local customer = U.dec(quote.customer, {})
        local email = U.nz(customer.email)
        local quote_discount = Quote.discountOf(quote)
        local quote_trade = tonumber(quote.trade_discount_minor) or 0
        local row = db.query([[
            INSERT INTO shop_orders (uuid, namespace_id, order_number, access_token, status, email, customer, lines,
                                     subtotal_minor, vat_minor, shipping_minor, total_minor, credit_minor,
                                     member_discount_minor, discount_minor, delivery_method, delivery_address,
                                     currency, quote_id, payment_method, internal_notes, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'pending_payment', ?, ?::jsonb, ?::jsonb, ?, ?, ?, ?, 0, ?, ?, ?, ?::jsonb, 'GBP', ?,
                    'bank_transfer', ?, NOW(), NOW())
            RETURNING id
        ]], Global.generateUUID(), ns_id, next_number(), U.token(24), email or db.NULL, U.enc(customer),
            U.enc(U.arr(lines)), tonumber(quote.subtotal_minor), tonumber(quote.vat_minor),
            tonumber(quote.shipping_minor) or 0, tonumber(quote.total_minor), quote_trade, quote_discount - quote_trade,
            U.nz(quote.delivery_method) or db.NULL, U.nz(quote.delivery_address) or db.NULL, quote.id,
            "Customer chose bank transfer for " .. tostring(quote.quote_number))[1]
        -- The quote fields every order made from a quote carries (the customer's PO number).
        ShopOrderQueries.applyQuoteFields(row.id, quote)
        Stock.hold(ns_id, row.id, demand, BANK_TRANSFER_HOLD_MINUTES)
        db.query("UPDATE shop_quotes SET order_id = ?, updated_at = NOW() WHERE id = ?", row.id, quote.id)
        if quote.crm_lead_id then
            pcall(require("queries.ShopLeadQueries").safeUpsert, ns_id, { email = email, source = "shop_quote",
                note = "Order " .. quote.quote_number .. ": customer chose to pay by bank transfer" })
        end
        return ShopOrderQueries.shape(ShopOrderQueries.getById(row.id))
    end)
end

local function valid_date(v)
    v = U.nz(v)
    if type(v) ~= "string" then return nil end
    local y, m, d = v:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 or d > 31 or y < 2000 or y > 2100 then return nil end
    return v:sub(1, 10)
end

--- POST /orders/:uuid/mark-paid — staff record a payment that arrived outside Stripe (bank transfer, cheque,
-- other) and the order goes through the same paid path as a card payment (status paid, stock committed,
-- quote converted, credits used). Only for orders awaiting payment that Stripe isn't collecting.
-- body: { method = bank_transfer|cheque|other (default bank_transfer), reference?, paid_at? (YYYY-MM-DD),
--         amount_minor? (what arrived; defaults to the order total) }
function ShopOrderQueries.markPaid(ns_id, uuid, body, actor)
    body = type(body) == "table" and body or {}
    local method = U.nz(body.method) or "bank_transfer"
    if not PM.MANUAL_PAID_METHODS[method] then
        return nil, U.err(400, "VALIDATION_ERROR", "method must be bank_transfer, cheque or other")
    end
    local reference = U.nz(body.reference) and tostring(body.reference):gsub("%c", " "):sub(1, 120) or nil
    local paid_at = U.nz(body.paid_at) and valid_date(body.paid_at) or nil
    if U.nz(body.paid_at) and not paid_at then
        return nil, U.err(400, "VALIDATION_ERROR", "paid_at must be a date (YYYY-MM-DD)")
    end
    local amount
    if body.amount_minor ~= nil and body.amount_minor ~= U.null then
        amount = math.floor(tonumber(body.amount_minor) or -1)
        if amount < 0 then return nil, U.err(400, "VALIDATION_ERROR", "amount_minor must be 0 or more (pence)") end
    end
    local _, err = U.tx(function()
        local o = db.query("SELECT " .. ORDER_COLS .. " FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE",
            ns_id, uuid)[1]
        if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
        if o.status ~= "pending_payment" then
            return nil, U.err(409, "NOT_AWAITING_PAYMENT", "This order isn't awaiting payment (status " .. o.status .. ")")
        end
        if o.payment_method ~= "bank_transfer" and nz(o.stripe_session_id) then
            return nil, U.err(409, "CARD_PAYMENT_IN_PROGRESS",
                "This order is being paid by card through Stripe — wait for it, or cancel it first")
        end
        amount = amount or tonumber(o.total_minor) or 0
        local note = string.format("[%s] Marked paid by %s: %s received%s%s%s",
            os.date("!%Y-%m-%d %H:%M UTC"), actor or "staff", U.money(amount),
            " (" .. method:gsub("_", " ") .. ")",
            reference and (", reference " .. reference) or "",
            amount ~= tonumber(o.total_minor) and (" — order total " .. U.money(o.total_minor)) or "")
        db.query([[UPDATE shop_orders SET payment_method = ?, paid_reference = ?, paid_amount_minor = ?,
                   paid_at = COALESCE(?::timestamp, NOW()),
                   internal_notes = COALESCE(internal_notes || E'\n', '') || ?, updated_at = NOW() WHERE id = ?]],
            method, reference or db.NULL, amount, paid_at or db.NULL, note, o.id)
        o.payment_method = method
        ShopOrderQueries.applyPaid(o, {})
        return true
    end)
    if err then return nil, err end
    return ShopOrderQueries.adminGet(ns_id, uuid)
end

local INVOICEABLE = { pending_payment = true, paid = true, processing = true, shipped = true, delivered = true }

--- POST /orders/:uuid/invoice — an accounting invoice (draft) from a shop order: the customer, one line per
-- order line, a discount line, delivery, VAT, the customer's PO number and the payment method. Idempotent:
-- the invoice uuid is kept on the order and a second call returns that invoice ({ existing = true }).
-- body: { payment_method_uuid?, due_date?, payment_terms_days?, notes? }
function ShopOrderQueries.createInvoice(ns_id, uuid, body, user_uuid)
    body = type(body) == "table" and body or {}
    local okIQ, IQ = pcall(require, "queries.InvoiceQueries")
    if not okIQ or not has_column("invoices", "po_number") then
        return nil, U.err(501, "INVOICING_UNAVAILABLE", "Invoicing is not available here")
    end
    if U.nz(body.payment_method_uuid) and not PaymentMethods.getRow(ns_id, body.payment_method_uuid) then
        return nil, U.err(400, "VALIDATION_ERROR", "payment_method_uuid is not one of this workspace's payment methods")
    end
    return U.tx(function()
        local o = db.query("SELECT " .. ORDER_COLS .. " FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE",
            ns_id, uuid)[1]
        if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
        if nz(o.invoice_uuid) then
            local inv = db.query([[SELECT uuid, invoice_number, status FROM invoices
                                    WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL]], ns_id, o.invoice_uuid)[1]
            if inv then
                return { existing = true, invoice_uuid = inv.uuid, invoice_number = inv.invoice_number, status = inv.status }
            end
        end
        if not INVOICEABLE[o.status] then
            return nil, U.err(409, "NOT_INVOICEABLE", "This order can't be invoiced (status " .. o.status .. ")")
        end
        local customer = U.dec(o.customer, {})
        local billing = U.nz(o.billing_address) and U.dec(o.billing_address, nil) or nil
        local delivery = U.nz(o.delivery_address) and U.dec(o.delivery_address, nil) or nil
        local address
        if type(billing) == "table" and type(billing.address) == "table" then
            local a = billing.address
            address = { line1 = a.line1, line2 = a.line2, city = a.city, state = a.state,
                        postal_code = a.postal_code, country = a.country }
        elseif type(delivery) == "table" then
            address = { line1 = delivery.line1, line2 = delivery.line2, city = delivery.city,
                        postal_code = delivery.postcode, country = delivery.country }
        end
        local name = U.nz(customer.company) or U.nz(customer.name) or (type(billing) == "table" and U.nz(billing.name))
            or U.nz(o.email) or "Customer"
        local po_number
        if has_column("shop_orders", "customer_po_number") then
            local r = db.query("SELECT customer_po_number FROM shop_orders WHERE id = ?", o.id)[1]
            po_number = r and U.nz(r.customer_po_number) or nil
        end
        local items = PM.invoiceLinesFromOrder({
            lines = U.dec(o.lines, {}), subtotal_minor = o.subtotal_minor, vat_minor = o.vat_minor,
            shipping_minor = o.shipping_minor,
        })
        local note_parts = { "Shop order " .. o.order_number }
        if U.nz(customer.name) and U.nz(customer.company) then note_parts[#note_parts + 1] = "Attn: " .. customer.name end
        if U.nz(customer.vat_number) then note_parts[#note_parts + 1] = "Customer VAT number: " .. customer.vat_number end
        if U.nz(body.notes) then note_parts[#note_parts + 1] = tostring(body.notes):sub(1, 2000) end
        local notes = table.concat(note_parts, "\n")
        local res = IQ.create({
            namespace_id = ns_id, owner_user_uuid = user_uuid,
            customer_name = tostring(name):sub(1, 255), customer_email = U.nz(customer.email) or U.nz(o.email),
            customer_address = address and U.enc(address) or nil,
            currency = o.currency or "GBP", notes = notes,
            due_date = valid_date(body.due_date), payment_terms_days = tonumber(body.payment_terms_days),
            po_number = po_number, payment_method_uuid = U.nz(body.payment_method_uuid),
            line_items = items,
        })
        local inv = res and res.data
        if not inv then return nil, U.err(500, "INVOICE_FAILED", "Could not create the invoice") end
        db.query([[UPDATE invoices SET metadata = COALESCE(metadata, '{}'::jsonb) || ?::jsonb WHERE uuid = ?]],
            U.enc({ shop_order_uuid = o.uuid, shop_order_number = o.order_number }), inv.uuid)
        db.query([[UPDATE shop_orders SET invoice_uuid = ?, internal_notes = COALESCE(internal_notes || E'\n', '') || ?,
                   updated_at = NOW() WHERE id = ?]], inv.uuid, "Invoice " .. tostring(inv.invoice_number) .. " created",
            o.id)
        local total = db.query("SELECT total_amount FROM invoices WHERE uuid = ?", inv.uuid)[1]
        return { existing = false, invoice_uuid = inv.uuid, invoice_number = inv.invoice_number, status = "draft",
                 total_amount = total and tonumber(total.total_amount) or U.null, order_total_minor = o.total_minor }
    end)
end

-- ---------------------------------------------------------------------------
-- admin
-- ---------------------------------------------------------------------------

function ShopOrderQueries.adminList(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 25), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "o.namespace_id = ?" }, { ns_id }
    if U.nz(params.status) then
        where[#where + 1] = "o.status = ?"
        vals[#vals + 1] = params.status
    end
    -- "Bank transfer due": awaiting a bank transfer, oldest first.
    local due = params.bank_transfer_due == "true" or params.bank_transfer_due == "1" or params.bank_transfer_due == true
        or params.filter == "bank_transfer_due"
    if due then
        where[#where + 1] = "o.status = 'pending_payment' AND o.payment_method = 'bank_transfer'"
    end
    if U.nz(params.payment_method) then
        where[#where + 1] = "COALESCE(o.payment_method, 'card') = ?"
        vals[#vals + 1] = params.payment_method
    end
    if params.filter == "needs_supplier_po" then
        where[#where + 1] = "(" .. Quote.needsSupplierPoSql() .. ")"
    elseif U.nz(params.filter) and params.filter ~= "bank_transfer_due" then
        return nil, U.err(400, "VALIDATION_ERROR", "filter must be needs_supplier_po or bank_transfer_due")
    end
    if U.nz(params.q) then
        local like = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(o.order_number ILIKE ? OR o.email ILIKE ? OR o.customer->>'name' ILIKE ? "
            .. "OR o.customer->>'company' ILIKE ? OR o.customer_po_number ILIKE ?)"
        for _ = 1, 5 do vals[#vals + 1] = like end
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. ORDER_COLS .. [[, q.uuid AS quote_uuid, q.quote_number, c.uuid AS cart_uuid,
               EXTRACT(DAY FROM NOW() - o.created_at)::int AS days_waiting,
               (SELECT cs.uuid FROM shop_chat_sessions cs WHERE cs.order_id = o.id OR (o.cart_id IS NOT NULL
                   AND cs.cart_id = o.cart_id) ORDER BY cs.id DESC LIMIT 1) AS chat_session_uuid,
               COUNT(*) OVER() AS total
          FROM shop_orders o LEFT JOIN shop_quotes q ON q.id = o.quote_id
          LEFT JOIN shop_carts c ON c.id = o.cart_id
         WHERE ]] .. table.concat(where, " AND ")
        .. (due and " ORDER BY o.created_at ASC, o.id ASC" or " ORDER BY o.created_at DESC, o.id DESC") .. " LIMIT ? OFFSET ?",
        unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    local out = {}
    for _, r in ipairs(rows) do
        local s = ShopOrderQueries.shape(r, { admin = true })
        s.line_count = #s.lines
        out[#out + 1] = s
    end
    -- For the "Bank transfer due" filter badge.
    local due_row = db.query([[SELECT COUNT(*)::int AS n FROM shop_orders WHERE namespace_id = ?
                                AND status = 'pending_payment' AND payment_method = 'bank_transfer']], ns_id)[1]
    return U.arr(out), { total = total, limit = limit, offset = offset,
                         bank_transfer_due_count = due_row and tonumber(due_row.n) or 0 }
end

function ShopOrderQueries.adminGet(ns_id, uuid)
    local o = ShopOrderQueries.getByUuid(ns_id, uuid)
    if not o then return nil end
    local s = ShopOrderQueries.shape(o, { admin = true })
    s.reservations = U.arr(db.query([[
        SELECT r.uuid, r.qty, r.status, r.expires_at, p.sku, p.name AS product_name, op.code AS option_code,
               op.name AS option_name
          FROM shop_stock_reservations r
          LEFT JOIN shop_products p ON p.id = r.product_id
          LEFT JOIN shop_options op ON op.id = r.option_id
         WHERE r.order_id = ? ORDER BY r.id
    ]], o.id))
    s.purchase_orders = ShopOrderQueries.purchaseOrdersFor(ns_id, o.uuid)
    return s
end

local REFUNDABLE = { paid = true, processing = true, shipped = true, delivered = true }

--- The payment intent to refund: the order's own, or (an order paid together with a Trade membership,
-- mode=subscription) the first invoice's, looked up from the Checkout session when the webhook never linked it.
local function payment_intent_for(stripe, o)
    if nz(o.stripe_payment_intent_id) then return o.stripe_payment_intent_id end
    if not nz(o.stripe_session_id) then return nil end
    local session = stripe:retrieve_checkout_session(o.stripe_session_id)
    if type(session) ~= "table" then return nil end
    local pi = session.payment_intent
    if type(pi) == "table" then pi = pi.id end
    if nz(pi) then return pi end
    local inv = session.invoice
    if type(inv) == "table" then inv = inv.id end
    if not nz(inv) then return nil end
    local invoice = stripe:_request("GET", "/invoices/" .. inv)
    pi = type(invoice) == "table" and invoice.payment_intent or nil
    if type(pi) == "table" then pi = pi.id end
    return nz(pi)
end

--- POST /orders/:uuid/refund — refund returned goods through Stripe, less the Trade discount the return
-- takes back (lib/shop-membership.lua refund_split / clawback).
-- body: { amount_net_minor? (goods ex VAT returned), full?, reason, dry_run? }
-- Returns { refund_minor, clawback_minor (ex VAT), clawback_gross_minor, returned_net_minor, stripe_refund_id, … }.
function ShopOrderQueries.adminRefund(ns_id, uuid, body, actor)
    body = type(body) == "table" and body or {}
    local R = require("lib.shop-membership")
    local full, dry = body.full == true, body.dry_run == true
    local reason = type(body.reason) == "string" and body.reason:gsub("%c", " "):match("^%s*(.-)%s*$") or ""
    if not dry and (#reason < 3 or #reason > 500) then
        return nil, U.err(400, "VALIDATION_ERROR", "reason is required (3–500 characters)")
    end
    local stripe
    if not dry then
        local serr
        stripe, serr = require("lib.payment-provider").get_stripe()
        if not stripe then
            ngx.log(ngx.ERR, "[shop] refund: ", tostring(serr))
            return nil, U.err(503, "PAYMENTS_DISABLED", "The payment provider is not available")
        end
    end
    -- One transaction with the order row locked, so two refunds of the same order can't both use the same balance.
    return U.tx(function()
        local o = db.query("SELECT " .. ORDER_COLS .. " FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE",
            ns_id, uuid)[1]
        if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
        if not REFUNDABLE[o.status] then
            return nil, U.err(409, "NOT_REFUNDABLE", "This order can't be refunded (status " .. o.status .. ")")
        end
        local vat_rate = effective_vat_rate(o.subtotal_minor, o.vat_minor)
        local split, verr = R.refund_split(require("queries.ShopMembershipQueries").settings(ns_id), o,
            body.amount_net_minor, full, vat_rate)
        if not split then return nil, U.err(400, "VALIDATION_ERROR", verr) end
        local out = {
            order_uuid = o.uuid, order_number = o.order_number, dry_run = dry, full = full,
            refund_minor = split.refund_minor, clawback_minor = split.clawback_minor,
            clawback_gross_minor = split.clawback_gross_minor, returned_net_minor = split.returned_net_minor,
            member_discount_minor = tonumber(o.member_discount_minor) or 0,
            refunded_before_minor = tonumber(o.refunded_minor) or 0, stripe_refund_id = U.null,
        }
        if dry then return out end
        if split.refund_minor <= 0 and not full then
            return nil, U.err(409, "NOTHING_TO_REFUND", "After the discount clawback there is nothing to refund")
        end
        local refund_id
        if split.refund_minor > 0 then
            local pi = payment_intent_for(stripe, o)
            if not pi then
                return nil, U.err(409, "NO_PAYMENT", "No Stripe payment is linked to this order — refund it in Stripe")
            end
            local res, rerr = stripe:_request("POST", "/refunds", {
                payment_intent = pi, amount = split.refund_minor, reason = "requested_by_customer",
                metadata = { order_uuid = o.uuid, clawback_minor = tostring(split.clawback_minor),
                             returned_net_minor = tostring(split.returned_net_minor) },
            }, "shop-refund-" .. o.uuid .. "-" .. tostring(o.refunded_minor) .. "-" .. split.refund_minor)
            if type(res) ~= "table" or not res.id then
                ngx.log(ngx.ERR, "[shop] refund failed for ", o.order_number, ": ", tostring(rerr))
                return nil, U.err(502, "PAYMENT_PROVIDER_ERROR", "Stripe did not accept the refund — nothing was changed")
            end
            refund_id = res.id
        end
        local note = string.format("[%s] Refund %s: goods returned %s ex VAT, Trade discount clawback %s ex VAT%s — %s%s",
            os.date("!%Y-%m-%d %H:%M UTC"), U.money(split.refund_minor), U.money(split.returned_net_minor),
            U.money(split.clawback_minor), refund_id and (" (Stripe " .. refund_id .. ")") or "", reason,
            actor and (" (by " .. actor .. ")") or "")
        db.query([[
            UPDATE shop_orders SET refunded_minor = refunded_minor + ?, returned_net_minor = returned_net_minor + ?,
                   refund_clawback_minor = refund_clawback_minor + ?,
                   status = CASE WHEN ? THEN 'refunded' ELSE status END,
                   internal_notes = COALESCE(internal_notes || E'\n', '') || ?, updated_at = NOW()
             WHERE id = ?
        ]], split.refund_minor, split.returned_net_minor, split.clawback_minor, full, note, o.id)
        out.stripe_refund_id = refund_id or U.null
        return out
    end)
end

function ShopOrderQueries.adminUpdate(ns_id, uuid, body)
    local o = ShopOrderQueries.getByUuid(ns_id, uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    local fields = { updated_at = db.raw("NOW()") }
    if body.status ~= nil then
        if not STATUSES[body.status] then return nil, U.err(400, "VALIDATION_ERROR", "invalid status") end
        fields.status = body.status
    end
    if body.tracking ~= nil then
        fields.tracking = (body.tracking == cjson.null) and db.NULL
            or db.raw(db.escape_literal(U.enc(body.tracking)) .. "::jsonb")
    end
    if body.internal_notes ~= nil then fields.internal_notes = U.nz(body.internal_notes) or db.NULL end
    -- The customer's PO number can still be added or corrected on the order (e.g. it arrived after payment).
    if body.customer_po_number ~= nil then
        local po, perr = Rules.clean_po_number(body.customer_po_number ~= U.null and body.customer_po_number or nil)
        if perr then return nil, U.err(400, "VALIDATION_ERROR", perr) end
        fields.customer_po_number = po or db.NULL
    end
    local _, err = U.tx(function()
        db.update("shop_orders", fields, { id = o.id })
        if fields.status and (fields.status == "cancelled" or fields.status == "payment_failed")
            and o.status == "pending_payment" then
            Stock.release(o.id)
        end
        return true
    end)
    if err then return nil, err end
    return ShopOrderQueries.adminGet(ns_id, uuid)
end

-- ---------------------------------------------------------------------------
-- supplier purchase order from a paid order
-- ---------------------------------------------------------------------------

local PO_STATUSES = { paid = true, processing = true, shipped = true, delivered = true }

--- POs raised from this order (purchase_orders.metadata.shop_order_uuid). Empty when the invoicing
-- feature (purchase orders) isn't deployed.
function ShopOrderQueries.purchaseOrdersFor(ns_id, order_uuid)
    local ok, rows = pcall(db.query, [[
        SELECT uuid, po_number, status, supplier_name, total, currency, created_at, sent_at, received_at, billed_at,
               metadata->>'shop_supplier_uuid' AS shop_supplier_uuid
          FROM purchase_orders
         WHERE namespace_id = ? AND metadata->>'shop_order_uuid' = ? AND deleted_at IS NULL
         ORDER BY created_at DESC
    ]], ns_id, order_uuid)
    return U.arr(ok and rows or {})
end

local function join_nonempty(parts, sep)
    local out = {}
    for _, p in ipairs(parts) do
        if type(p) == "string" and p:match("%S") then out[#out + 1] = p end
    end
    return table.concat(out, sep)
end

--- "Deliver directly to": the delivery address agreed on the order, else the address the customer gave
-- Stripe, with the customer's company, email and VAT number.
local function ship_to_of(o)
    local customer = U.dec(o.customer, {})
    local agreed = U.nz(o.delivery_address) and U.dec(o.delivery_address, nil) or nil
    if type(agreed) == "table" and next(agreed) then
        local out = {}
        for k, v in pairs(agreed) do out[k] = v end
        out.email = out.email or customer.email or o.email
        out.vat_number = out.vat_number or customer.vat_number
        out.company = out.company or customer.company
        return out
    end
    local ship = U.nz(o.shipping_address) and U.dec(o.shipping_address, {}) or {}
    local a = type(ship.address) == "table" and ship.address or ship
    return {
        name = ship.name or customer.name, company = customer.company,
        line1 = a.line1, line2 = a.line2, city = a.city, county = a.state,
        postcode = a.postal_code or a.postcode, country = a.country,
        email = customer.email or o.email, phone = customer.phone, vat_number = customer.vat_number,
    }
end

local function address_text(a)
    if type(a) ~= "table" then return nil end
    local lines = {
        join_nonempty({ a.name, a.company }, ", "), a.line1, a.line2,
        join_nonempty({ a.city, a.county, a.postcode }, " "), a.country,
        a.phone, a.email, a.vat_number and ("VAT " .. a.vat_number) or nil,
    }
    local s = join_nonempty(lines, "\n")
    return s ~= "" and s or nil
end
ShopOrderQueries.addressText = address_text

local function po_line_description(l)
    local parts = { tostring(l.product_name or l.label or "Item") }
    if U.nz(l.sku) then parts[#parts + 1] = "SKU " .. l.sku end
    for _, b in ipairs(type(l.breakdown) == "table" and l.breakdown or {}) do
        parts[#parts + 1] = (tonumber(b.qty) and tonumber(b.qty) > 1 and (b.qty .. "× ") or "") .. tostring(b.name or b.option or "")
    end
    return table.concat(parts, "\n")
end

--- Cost (pence ex VAT) of each product line from the supplier's price file: the supplier item the product
-- is linked to (shop_products.supplier_item_id). With a supplier chosen, only that supplier's items count.
-- Returns { [product_uuid] = cost_minor }.
local function supplier_costs(ns_id, lines, supplier_id)
    local uuids = {}
    for _, l in ipairs(lines) do
        if not l.custom and U.nz(l.product_uuid) then uuids[#uuids + 1] = l.product_uuid end
    end
    if #uuids == 0 then return {} end
    local ok, rows = pcall(db.query, [[
        SELECT p.uuid, i.cost_minor FROM shop_products p JOIN shop_supplier_items i ON i.id = p.supplier_item_id
         WHERE p.namespace_id = ? AND p.uuid IN ? AND (?::int IS NULL OR i.supplier_id = ?::int)
    ]], ns_id, db.list(uuids), supplier_id or db.NULL, supplier_id or db.NULL)
    local out = {}
    for _, r in ipairs(ok and rows or {}) do out[r.uuid] = tonumber(r.cost_minor) end
    return out
end

local function pounds(minor) return string.format("%.2f", (tonumber(minor) or 0) / 100) end

--- The shop supplier a PO goes to (body.supplier_uuid), with its PO contact details.
local function po_supplier(ns_id, supplier_uuid)
    if not U.nz(supplier_uuid) then return nil end
    return db.query([[SELECT id, uuid, name, contact_email, po_email, po_phone, po_address, account_number, po_notes
                        FROM shop_suppliers WHERE namespace_id = ? AND uuid = ?]], ns_id, supplier_uuid)[1]
end

--- The supplier last used for a shop order's PO in this workspace (the dialog's default).
local function last_supplier_uuid(ns_id)
    local ok, rows = pcall(db.query, [[
        SELECT metadata->>'shop_supplier_uuid' AS u FROM purchase_orders
         WHERE namespace_id = ? AND metadata->>'shop_supplier_uuid' IS NOT NULL AND deleted_at IS NULL
         ORDER BY created_at DESC LIMIT 1]], ns_id)
    return ok and rows[1] and rows[1].u or nil
end

--- Everything a supplier PO for this order would say, before it is raised. Shared by the preview
-- (GET /orders/:uuid/purchase-order/preview) and POST /orders/:uuid/purchase-order.
-- Returns (draft) or (nil, err).
function ShopOrderQueries.purchaseOrderDraft(ns_id, uuid, body)
    body = type(body) == "table" and body or {}
    local o = ShopOrderQueries.getByUuid(ns_id, uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    local sup
    if U.nz(body.supplier_uuid) then
        sup = po_supplier(ns_id, body.supplier_uuid)
        if not sup then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Supplier not found") end
    end
    local costs = type(body.costs) == "table" and body.costs or {}
    local file_costs = supplier_costs(ns_id, U.dec(o.lines, {}), sup and sup.id)
    local lines, missing = {}, 0
    for _, l in ipairs(U.dec(o.lines, {})) do
        local given = costs[l.uuid]
        if given == U.null or tostring(given or "") == "" then given = nil end
        local from_file = not l.custom and file_costs[l.product_uuid] or nil
        local cost = given and tostring(given) or (from_file and pounds(from_file)) or nil
        local included = not l.custom or body.include_custom == true
        if included and not cost then missing = missing + 1 end
        lines[#lines + 1] = {
            uuid = l.uuid, description = po_line_description(l), qty = tonumber(l.qty) or 1,
            vat_rate = tonumber(l.vat_rate) or 0.2, custom = l.custom == true, included = included,
            cost = cost or U.null,
            cost_source = given and "entered" or (from_file and "supplier_price_file") or U.null,
        }
    end
    local ship_to = ship_to_of(o)
    local method = U.nz(body.delivery_method) or U.nz(o.delivery_method)
    local customer_po = U.nz(o.customer_po_number)
    local supplier = {
        uuid = sup and sup.uuid or U.null,
        name = U.nz(body.supplier_name) or (sup and sup.name) or U.null,
        email = U.nz(body.supplier_email) or (sup and (U.nz(sup.po_email) or U.nz(sup.contact_email))) or U.null,
        phone = U.nz(body.supplier_phone) or (sup and U.nz(sup.po_phone)) or U.null,
        address = U.nz(body.supplier_address) or (sup and U.nz(sup.po_address)) or U.null,
        account_number = sup and U.nz(sup.account_number) or U.null,
        po_notes = sup and U.nz(sup.po_notes) or U.null,
    }
    return {
        order = o,
        order_uuid = o.uuid, order_number = o.order_number, order_status = o.status,
        can_raise = PO_STATUSES[o.status] == true,
        supplier = supplier,
        last_supplier_uuid = last_supplier_uuid(ns_id) or U.null,
        bill_to = require("queries.ShopSettingsQueries").billTo(ns_id) or U.null,
        ship_to = ship_to, ship_to_text = address_text(ship_to) or U.null,
        delivery_method = method or U.null,
        customer_po_number = customer_po or U.null,
        notes = Rules.supplier_po_notes({
            customer_po_number = customer_po, account_number = supplier.account_number ~= U.null and supplier.account_number or nil,
            delivery_method = method, supplier_notes = supplier.po_notes ~= U.null and supplier.po_notes or nil,
            notes = U.nz(body.notes),
        }),
        lines = U.arr(lines),
        missing_costs = missing,
        currency = o.currency or "GBP",
    }
end

--- GET /orders/:uuid/purchase-order/preview?supplier_uuid= — what the PO would say (no PO is created).
function ShopOrderQueries.purchaseOrderPreview(ns_id, uuid, params)
    local d, err = ShopOrderQueries.purchaseOrderDraft(ns_id, uuid, params)
    if not d then return nil, err end
    d.order = nil
    return d
end

--- POST /orders/:uuid/purchase-order — draft a supplier PO for a paid order: Bill to (shop settings),
-- Deliver directly to (the order's delivery address), delivery method, the end customer's PO number, the
-- order's product lines (free-text lines only with include_custom) at the supplier costs given (pounds ex
-- VAT, by line uuid), else the cost in the chosen supplier's price file, else 0 to fill in on the PO.
-- body: { supplier_uuid?, supplier_name (unless supplier_uuid), supplier_email?, supplier_phone?,
--         supplier_address?, expected_date?, delivery_method?, notes?, costs? = { [line_uuid] = "123.45" },
--         include_custom? }   Values in the body override the supplier's saved details.
function ShopOrderQueries.createPurchaseOrder(ns_id, uuid, body, user_uuid)
    body = type(body) == "table" and body or {}
    local d, derr = ShopOrderQueries.purchaseOrderDraft(ns_id, uuid, body)
    if not d then return nil, derr end
    local o = d.order
    if not d.can_raise then
        return nil, U.err(409, "ORDER_NOT_PAID", "Raise the supplier PO once the order is paid (status " .. o.status .. ")")
    end
    local okPO, POQ = pcall(require, "queries.PurchaseOrderQueries")
    if not okPO then return nil, U.err(501, "PURCHASE_ORDERS_UNAVAILABLE", "Purchase orders are not enabled here") end
    local sup = d.supplier
    if sup.name == U.null then return nil, U.err(400, "VALIDATION_ERROR", "Choose a supplier (or give supplier_name)") end
    local items = {}
    for _, l in ipairs(d.lines) do
        if l.included then
            items[#items + 1] = {
                description = l.description,
                quantity = l.qty,
                unit_price = l.cost ~= U.null and l.cost or "0",
                tax_rate = tostring(math.floor(l.vat_rate * 10000 + 0.5) / 100),
            }
        end
    end
    if #items == 0 then return nil, U.err(400, "VALIDATION_ERROR", "This order has no product lines to order") end
    local function v(x) return x ~= U.null and x or nil end
    local po, msg, code = POQ.create(ns_id, user_uuid, {
        supplier_name = tostring(sup.name):sub(1, 255),
        supplier_email = v(sup.email), supplier_phone = v(sup.phone), supplier_address = v(sup.address),
        reference = o.order_number,
        expected_date = U.nz(body.expected_date),
        delivery_address = v(d.ship_to_text),
        currency = d.currency,
        notes = d.notes ~= "" and d.notes or nil,
        items = items,
        metadata = {
            shop_order_uuid = o.uuid, shop_order_number = o.order_number,
            shop_supplier_uuid = v(sup.uuid), supplier_account_number = sup.account_number,
            end_customer_po = d.customer_po_number,
            bill_to = d.bill_to, ship_to = d.ship_to, delivery_method = d.delivery_method,
            drop_ship = true,
        },
    })
    if not po then
        return nil, U.err(code == "not_found" and 404 or 400, "PURCHASE_ORDER_FAILED", tostring(msg))
    end
    pcall(db.query, [[UPDATE shop_orders SET internal_notes = COALESCE(internal_notes || E'\n', '') || ?, updated_at = NOW()
                      WHERE id = ?]], "Supplier PO " .. tostring(po.po_number or po.uuid) .. " raised ("
        .. tostring(sup.name) .. ")", o.id)
    return po
end

return ShopOrderQueries
