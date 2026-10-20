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
    o.refunded_minor, o.returned_net_minor, o.refund_clawback_minor,
    o.cart_id, o.quote_id, o.stripe_session_id, o.stripe_payment_intent_id, o.paid_at,
    o.tracking::text AS tracking, o.internal_notes, o.created_at, o.updated_at
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
        currency = o.currency,
        paid_at = o.paid_at or U.null,
        created_at = o.created_at,
        tracking = U.dec(o.tracking, U.null),
        url_path = url_path(o),
    }
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
    end
    return out
end

function ShopOrderQueries.getById(id)
    return db.query("SELECT " .. ORDER_COLS .. " FROM shop_orders o WHERE o.id = ?", id)[1]
end

function ShopOrderQueries.getByUuid(ns_id, uuid)
    return db.query("SELECT " .. ORDER_COLS .. [[, q.uuid AS quote_uuid, q.quote_number, c.uuid AS cart_uuid,
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

--- POST /checkout.
-- body: {from:"cart"|"quote", quote_uuid?, quote_token?, email?, name?, company?, phone?, success_url, cancel_url}
-- Returns ({order_uuid, order_token, checkout_url}) or (nil, err)
function ShopOrderQueries.checkout(ns_id, body, cart_token)
    local PaymentProvider = require("lib.payment-provider")
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

    -- Joining Trade with this order (body.membership): reserve the spot now, give this order the
    -- Trade discount for the tier they join at, and charge the first fee in the same Stripe payment.
    local join
    if type(body.membership) == "table" then
        if from ~= "cart" then
            return nil, U.err(400, "VALIDATION_ERROR", "Trade membership can only be added to a basket order")
        end
        local Membership = require("queries.ShopMembershipQueries")
        local R = require("lib.shop-membership")
        local bm = body.membership
        local s, jemail, interval = Membership.validateJoin(ns_id, {
            email = email, interval = bm.interval, accept_terms = bm.accept_terms, terms_version = bm.terms_version,
        })
        if not s then return nil, jemail end
        join = { settings = s, m = Membership.reserve(ns_id, s, jemail, interval) }
        local vat_rate = tonumber(lines[1] and lines[1].vat_rate) or 0.2
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
        local vat_rate = tonumber(lines[1] and lines[1].vat_rate) or 0.2
        local m = member.membership
        if from == "cart" and not trade and member.active and type(m) == "table"
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
                                     member_discount_minor, member_discount_pct, currency,
                                     cart_id, quote_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'pending_payment', ?, ?::jsonb, ?::jsonb, ?, ?, ?, ?, ?, ?, ?, 'GBP', ?, ?, NOW(), NOW())
            RETURNING id, uuid, order_number, access_token
        ]], Global.generateUUID(), ns_id, next_number(), token, email or db.NULL, U.enc(customer),
            U.enc(U.arr(lines)), totals.subtotal_minor, totals.vat_minor, totals.shipping_minor,
            totals.total_minor, credit and credit.credit_minor or 0,
            trade and trade.discount_minor or 0, trade and trade.pct or db.NULL, cart and cart.id or db.NULL,
            quote and quote.id or db.NULL)[1]
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
            or "Workstation credit"
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
        db.query("UPDATE shop_quotes SET status = 'converted', order_id = ?, updated_at = NOW() WHERE id = ?",
            order.id, order.quote_id)
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
    if U.nz(params.q) then
        local like = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(o.order_number ILIKE ? OR o.email ILIKE ? OR o.customer->>'name' ILIKE ? "
            .. "OR o.customer->>'company' ILIKE ?)"
        for _ = 1, 4 do vals[#vals + 1] = like end
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. ORDER_COLS .. [[, q.uuid AS quote_uuid, q.quote_number, c.uuid AS cart_uuid,
               (SELECT cs.uuid FROM shop_chat_sessions cs WHERE cs.order_id = o.id OR (o.cart_id IS NOT NULL
                   AND cs.cart_id = o.cart_id) ORDER BY cs.id DESC LIMIT 1) AS chat_session_uuid,
               COUNT(*) OVER() AS total
          FROM shop_orders o LEFT JOIN shop_quotes q ON q.id = o.quote_id
          LEFT JOIN shop_carts c ON c.id = o.cart_id
         WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY o.created_at DESC, o.id DESC LIMIT ? OFFSET ?",
        unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    local out = {}
    for _, r in ipairs(rows) do
        local s = ShopOrderQueries.shape(r, { admin = true })
        s.line_count = #s.lines
        out[#out + 1] = s
    end
    return U.arr(out), { total = total, limit = limit, offset = offset }
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
        local lines = U.dec(o.lines, {})
        local vat_rate = tonumber(lines[1] and lines[1].vat_rate) or 0.2
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

return ShopOrderQueries
