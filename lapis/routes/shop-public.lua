--[[
    Shop public API (BUILD.prompt.md §3)
    =====================================
    Base /api/v2/public/shop/:ns   (:ns = namespace slug; JWT-exempt via /api/v2/public/)

    Called server-to-server by the shop BFF. Rate limited 120 req / 60 s per
    client IP (prefix shop_public) unless the request carries X-Shop-Key equal
    to env SHOP_BFF_KEY (constant-time compare). Carts are addressed by the
    X-Cart-Token header. Envelope { success, data, meta? } /
    { success:false, error, code }.

      GET    /categories
      GET    /products
      GET    /products/:slug
      GET    /products/:slug/insights   (real trust signals: price history, baskets in 24 h)
      POST   /price
      POST   /carts
      GET    /cart
      POST   /cart/lines
      PATCH  /cart/lines/:uuid
      DELETE /cart/lines/:uuid
      POST   /cart/attach-chat
      GET    /search
      GET    /market?product_slug=|q=&limit=3   (market-price reference, MARKET.prompt.md §A)
      POST   /quotes
      GET    /quotes/:uuid?t=
      POST   /checkout                           { …, membership?: { interval, accept_terms, terms_version } } joins Trade in the same payment
      GET    /orders/:uuid?t=
      POST   /chat-sessions
      POST   /chat-sessions/:uuid/messages
      POST   /chat-sessions/:uuid/requirements   { requirements: {goal, models, budget_gbp, …} } (AI advisor)
      POST   /chat-sessions/:uuid/contact        { email, name?, company?, phone?, improve_consent } → CRM lead

    VIP membership (X-Member-Token = a signed-in member's session; resolved for every route below,
    so quotes lock, checkout applies credit and members see early-access products):
      GET    /membership                         offer: real prices, founding spots left, settings
      POST   /membership/checkout                { email, interval, accept_terms, terms_version, success_url, cancel_url }
      POST   /member/login                       { email } → emails a one-time link (same answer either way)
      POST   /member/verify                      { token } → { session_token, email }
      GET    /member                             membership, credits, deactivation (X-Member-Token)
      POST   /member/cancel                      cancel at period end (X-Member-Token)
      POST   /member/deactivate                  schedule auto-close in 90 days (X-Member-Token)
      POST   /member/reactivate                  cancel a pending auto-close (X-Member-Token)
      POST   /member/logout
      GET    /member/early-access                products in the members-only window (X-Member-Token)
      POST   /products/:slug/waitlist            { email } (members first)

    Customer sign-in (Google / Apple; any shopper, not only VIP members — ends in the same session):
      POST   /auth/start                         { provider: google|apple|facebook, nonce, next } → { authorize_url } (BFF only)
      POST   /auth/password                      { email, password } → { session_token, email } + emails a code (BFF only)
      POST   /auth/password/verify               { session_token, code } → { session_token, email, expires_in_days } (BFF only)
      GET    /customer/quotes                    the signed-in customer's quotes, matched on email (X-Member-Token)
]]

local U = require("lib.shop-util")
local RateLimit = require("middleware.rate-limit")
local Catalog = require("queries.ShopCatalogQueries")
local Cart = require("queries.ShopCartQueries")
local Quote = require("queries.ShopQuoteQueries")
local Orders = require("queries.ShopOrderQueries")
local Search = require("queries.ShopSearchQueries")
local Chat = require("queries.ShopChatQueries")
local Market = require("queries.ShopMarketQueries")
local Insights = require("queries.ShopInsightsQueries")
local Membership = require("queries.ShopMembershipQueries")
local CustomerAuth = require("queries.ShopCustomerAuthQueries")

local BASE = "/api/v2/public/shop/:ns"

--- Is this a trusted BFF call?
local function is_bff(self)
    local key = U.env("SHOP_BFF_KEY")
    if not key then return false end
    return U.secure_equals(self.req.headers["x-shop-key"], key)
end

--- Wrap a public handler: rate limit (unless BFF), resolve namespace, catch errors.
local function public(handler)
    return U.safe(function(self)
        if not is_bff(self) then
            local allowed, remaining, retry = RateLimit.check("shop_public:" .. RateLimit.getClientIP(), 120, 60)
            ngx.header["X-RateLimit-Limit"] = "120"
            ngx.header["X-RateLimit-Remaining"] = tostring(remaining or 0)
            if not allowed then
                ngx.header["Retry-After"] = tostring(retry)
                return U.fail(429, "RATE_LIMITED", "Too many requests", { retry_after = retry })
            end
        end
        local ns = Catalog.namespaceBySlug(self.params.ns)
        if not ns then return U.fail(404, "NAMESPACE_NOT_FOUND", "Shop not found") end
        self.shop_ns = ns
        -- Signed-in VIP member (BFF forwards the httpOnly ws_member cookie as X-Member-Token).
        local mt = self.req.headers["x-member-token"]
        if mt then ngx.ctx.shop_member = Membership.memberFromSession(ns.id, mt) end
        return handler(self, ns.id)
    end)
end

local function body_or_400()
    local body, err = U.read_json()
    if not body then return nil, U.fail(400, "INVALID_JSON", err) end
    return body
end

local function cart_token(self)
    return self.req.headers["x-cart-token"]
end

local function require_cart(self, ns_id)
    local cart = Cart.byToken(ns_id, cart_token(self))
    if not cart then return nil, U.fail(404, "CART_NOT_FOUND", "Cart not found or expired") end
    return cart
end

--- (cart, notices) | (nil, err) → response
local function cart_response(view, notices_or_err, status)
    if not view then return U.from_err(notices_or_err) end
    local meta
    if notices_or_err and #notices_or_err > 0 then meta = { notices = notices_or_err } end
    return U.ok(view, type(status) == "number" and status or 200, meta)
end

return function(app)
    -- catalogue ---------------------------------------------------------------
    app:get(BASE .. "/categories", public(function(_, ns_id)
        return U.ok(Catalog.listCategories(ns_id))
    end))

    app:get(BASE .. "/products", public(function(self, ns_id)
        local data, meta = Catalog.listPublic(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:get(BASE .. "/products/:slug", public(function(self, ns_id)
        local bundle = Catalog.loadBundle(ns_id, { slug = self.params.slug }, { public = true })
        if not bundle then return U.fail(404, "PRODUCT_NOT_FOUND", "Product not found") end
        return U.ok(Catalog.fullProduct(bundle))
    end))

    app:get(BASE .. "/products/:slug/insights", public(function(self, ns_id)
        local data = Insights.forProduct(ns_id, self.params.slug)
        if not data then return U.fail(404, "PRODUCT_NOT_FOUND", "Product not found") end
        return U.ok(data)
    end))

    app:post(BASE .. "/price", public(function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local priced, err = Catalog.priceRequest(ns_id, body)
        if not priced then return U.from_err(err) end
        return U.ok(priced)
    end))

    -- carts ---------------------------------------------------------------------
    app:post(BASE .. "/carts", public(function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local cart, token = Cart.create(ns_id, body)
        local view = Cart.view(ns_id, cart, { token = token })
        return U.ok(view, 201)
    end))

    app:get(BASE .. "/cart", public(function(self, ns_id)
        local cart, bad = require_cart(self, ns_id)
        if not cart then return bad end
        return cart_response(Cart.view(ns_id, cart))
    end))

    app:post(BASE .. "/cart/lines", public(function(self, ns_id)
        local cart, bad = require_cart(self, ns_id)
        if not cart then return bad end
        local body, bad2 = body_or_400()
        if not body then return bad2 end
        local view, notices_or_err = Cart.addLine(ns_id, cart, body)
        return cart_response(view, notices_or_err, 201)
    end))

    app:match(BASE .. "/cart/lines/:uuid", public(function(self, ns_id)
        local method = ngx.req.get_method()
        local cart, bad = require_cart(self, ns_id)
        if not cart then return bad end
        if method == "PATCH" or method == "PUT" then
            local body, bad2 = body_or_400()
            if not body then return bad2 end
            return cart_response(Cart.updateLine(ns_id, cart, self.params.uuid, body))
        elseif method == "DELETE" then
            return cart_response(Cart.removeLine(ns_id, cart, self.params.uuid))
        end
        return U.fail(405, "METHOD_NOT_ALLOWED", "Use PATCH or DELETE")
    end))

    app:post(BASE .. "/cart/attach-chat", public(function(self, ns_id)
        local cart, bad = require_cart(self, ns_id)
        if not cart then return bad end
        local body, bad2 = body_or_400()
        if not body then return bad2 end
        if not U.nz(body.chat_session_uuid) then
            return U.fail(400, "VALIDATION_ERROR", "chat_session_uuid is required")
        end
        local ok, err = Cart.attachChat(ns_id, cart, body.chat_session_uuid)
        if not ok then return U.from_err(err) end
        return cart_response(Cart.view(ns_id, cart))
    end))

    -- search --------------------------------------------------------------------
    app:get(BASE .. "/search", public(function(self, ns_id)
        local data, meta = Search.search(ns_id, self.params.q, self.params.limit)
        return U.ok(data, 200, meta)
    end))

    -- market prices (third-party reference; accepted + fresh observations only) ----
    app:get(BASE .. "/market", public(function(self, ns_id)
        local slug = U.nz(self.params.product_slug)
        if slug then
            local data = Market.publicBySlug(ns_id, slug)
            if not data then return U.fail(404, "PRODUCT_NOT_FOUND", "Product not found") end
            return U.ok(data, 200, { fresh_days = Market.FRESH_DAYS })
        end
        local q = U.nz(self.params.q)
        if not q then return U.fail(400, "VALIDATION_ERROR", "product_slug or q is required") end
        local limit = U.clamp(U.int(self.params.limit, 3), 1, 10)
        -- Search a wider pool, then prefer hits that have fresh market data
        -- (stable: search rank is kept within each group).
        local hits = Search.search(ns_id, q, math.min(limit * 4, 30))
        local uuids = {}
        for _, p in ipairs(hits.products or {}) do uuids[#uuids + 1] = p.uuid end
        local with, without = {}, {}
        for _, e in ipairs(Market.publicByUuids(ns_id, uuids)) do
            if #e.observations > 0 then with[#with + 1] = e else without[#without + 1] = e end
        end
        local data = {}
        for _, e in ipairs(with) do if #data < limit then data[#data + 1] = e end end
        for _, e in ipairs(without) do if #data < limit then data[#data + 1] = e end end
        return U.ok(U.arr(data), 200, { fresh_days = Market.FRESH_DAYS, q = q })
    end))

    -- quotes ----------------------------------------------------------------------
    app:post(BASE .. "/quotes", public(function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local quote, err = Quote.createPublic(ns_id, body, cart_token(self))
        if not quote then return U.from_err(err) end
        return U.ok(quote, 201)
    end))

    app:get(BASE .. "/quotes/:uuid", public(function(self, ns_id)
        local quote = Quote.publicView(ns_id, self.params.uuid, self.params.t)
        if not quote then return U.fail(404, "QUOTE_NOT_FOUND", "Quote not found") end
        return U.ok(quote)
    end))

    -- checkout + orders -----------------------------------------------------------
    app:post(BASE .. "/checkout", public(function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Orders.checkout(ns_id, body, cart_token(self))
        if not res then return U.from_err(err) end
        return U.ok(res, 201)
    end))

    app:get(BASE .. "/orders/:uuid", public(function(self, ns_id)
        local order = Orders.publicView(ns_id, self.params.uuid, self.params.t)
        if not order then return U.fail(404, "ORDER_NOT_FOUND", "Order not found") end
        return U.ok(order)
    end))

    -- chat transcripts --------------------------------------------------------------
    app:post(BASE .. "/chat-sessions", public(function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        return U.ok(Chat.create(ns_id, body), 201)
    end))

    app:post(BASE .. "/chat-sessions/:uuid/messages", public(function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Chat.append(ns_id, self.params.uuid, body)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    app:post(BASE .. "/chat-sessions/:uuid/requirements", public(function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Chat.recordRequirements(ns_id, self.params.uuid, body)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    app:post(BASE .. "/chat-sessions/:uuid/contact", public(function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Chat.saveContact(ns_id, self.params.uuid, body)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    -- VIP membership ------------------------------------------------------------------
    app:get(BASE .. "/membership", public(function(_, ns_id)
        return U.ok(Membership.offer(ns_id))
    end))

    app:post(BASE .. "/membership/checkout", public(function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Membership.startCheckout(ns_id, body)
        if not res then return U.from_err(err) end
        return U.ok(res, 201)
    end))

    app:post(BASE .. "/member/login", public(function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Membership.requestLogin(ns_id, body)
        if not res then return U.from_err(err) end
        -- Same answer whether or not the email is a member.
        return U.ok({ message = "If that email has a membership, we've sent a sign-in link. It expires in 15 minutes." })
    end))

    app:post(BASE .. "/member/verify", public(function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Membership.verifyLink(ns_id, body)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    local function member_or_401()
        local m = ngx.ctx.shop_member
        if not m then return nil, U.fail(401, "NOT_SIGNED_IN", "Please sign in to your membership") end
        return m
    end

    app:get(BASE .. "/member", public(function(_, ns_id)
        local m, bad = member_or_401()
        if not m then return bad end
        return U.ok(Membership.me(ns_id, m))
    end))

    app:post(BASE .. "/member/cancel", public(function(_, ns_id)
        local m, bad = member_or_401()
        if not m then return bad end
        local res, err = Membership.cancel(ns_id, m)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    app:post(BASE .. "/member/deactivate", public(function(self, ns_id)
        local m, bad = member_or_401()
        if not m then return bad end
        local res, err = Membership.deactivate(ns_id, m, self.req.headers["x-member-token"])
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    app:post(BASE .. "/member/reactivate", public(function(_, ns_id)
        local m, bad = member_or_401()
        if not m then return bad end
        local res, err = Membership.reactivate(ns_id, m)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    app:post(BASE .. "/member/logout", public(function(self, ns_id)
        return U.ok(Membership.logout(ns_id, self.req.headers["x-member-token"]))
    end))

    -- Customer sign-in (Google / Apple) ------------------------------------------------
    -- BFF only: the shop sets the nonce cookie it will check when the browser comes back.
    app:post(BASE .. "/auth/start", public(function(self)
        if not is_bff(self) then return U.fail(403, "FORBIDDEN", "Not allowed") end
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = CustomerAuth.start(self.shop_ns, body)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    -- Existing OpsAPI account: password, then the emailed 6-digit code (as every OpsAPI password sign-in).
    app:post(BASE .. "/auth/password", public(function(self)
        if not is_bff(self) then return U.fail(403, "FORBIDDEN", "Not allowed") end
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = CustomerAuth.passwordStart(self.shop_ns, body)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    app:post(BASE .. "/auth/password/verify", public(function(self)
        if not is_bff(self) then return U.fail(403, "FORBIDDEN", "Not allowed") end
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = CustomerAuth.passwordVerify(self.shop_ns, body)
        if not res then return U.from_err(err) end
        return U.ok(res)
    end))

    app:get(BASE .. "/customer/quotes", public(function(self, ns_id)
        local m, bad = member_or_401()
        if not m then return bad end
        local data, meta = Quote.forCustomer(ns_id, m.email, self.params)
        return U.ok(data, 200, meta)
    end))

    app:get(BASE .. "/member/early-access", public(function(_, ns_id)
        local m, bad = member_or_401()
        if not m then return bad end
        return U.ok(Membership.earlyAccess(ns_id, m))
    end))

    app:post(BASE .. "/products/:slug/waitlist", public(function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local res, err = Membership.joinWaitlist(ns_id, self.params.slug, body, ngx.ctx.shop_member)
        if not res then return U.from_err(err) end
        return U.ok(res, 201)
    end))
end
