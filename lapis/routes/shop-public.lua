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
      POST   /price
      POST   /carts
      GET    /cart
      POST   /cart/lines
      PATCH  /cart/lines/:uuid
      DELETE /cart/lines/:uuid
      POST   /cart/attach-chat
      GET    /search
      POST   /quotes
      GET    /quotes/:uuid?t=
      POST   /checkout
      GET    /orders/:uuid?t=
      POST   /chat-sessions
      POST   /chat-sessions/:uuid/messages
]]

local U = require("lib.shop-util")
local RateLimit = require("middleware.rate-limit")
local Catalog = require("queries.ShopCatalogQueries")
local Cart = require("queries.ShopCartQueries")
local Quote = require("queries.ShopQuoteQueries")
local Orders = require("queries.ShopOrderQueries")
local Search = require("queries.ShopSearchQueries")
local Chat = require("queries.ShopChatQueries")

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
end
