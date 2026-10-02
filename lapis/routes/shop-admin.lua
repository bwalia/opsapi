-- luacheck: max line length 140
--[[
    Shop admin API (BUILD.prompt.md §5)
    ====================================
    Base /api/v2/shop/admin — JWT (global before_filter + requireAuth) +
    namespace (X-Namespace-Id / X-Namespace-Slug / JWT) + RBAC module "shop".
    Lists return { success, data:[…], meta:{ total, limit, offset } }.

      GET/POST          /categories            PUT/DELETE /categories/:uuid
      GET/POST          /products              GET/PUT/DELETE /products/:uuid
      POST              /products/:uuid/stock  POST /options/:uuid/stock
      GET               /stock                 GET /stock/movements
      POST              /import
      GET               /orders                GET/PUT /orders/:uuid
      GET/POST          /quotes                GET/PUT /quotes/:uuid
      GET               /chats                 GET /chats/:uuid
      GET/POST          /knowledge             DELETE /knowledge/:source_ref   POST /knowledge/reindex
      GET               /dashboard
      POST              /reconcile
]]

local U = require("lib.shop-util")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local Catalog = require("queries.ShopCatalogQueries")
local Stock = require("queries.ShopStockQueries")
local Orders = require("queries.ShopOrderQueries")
local Quote = require("queries.ShopQuoteQueries")
local Chat = require("queries.ShopChatQueries")
local Search = require("queries.ShopSearchQueries")
local Dashboard = require("queries.ShopDashboardQueries")
local ShopStripe = require("queries.ShopStripeQueries")

local BASE = "/api/v2/shop/admin"

--- auth + namespace + RBAC("shop", action) + error envelope
local function guard(action, handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("shop", action, U.safe(function(self)
        return handler(self, self.namespace.id)
    end)))
end

local function body_or_400()
    local body, err = U.read_json()
    if not body then return nil, U.fail(400, "INVALID_JSON", err) end
    return body
end

local function user_id(self)
    local u = self.current_user or {}
    local id = tonumber(u.id)
    if id then return id end
    if u.uuid then
        local db = require("lapis.db")
        local r = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", u.uuid)[1]
        return r and r.id or nil
    end
    return nil
end

local function method_router(handlers)
    return function(self, ns_id)
        local h = handlers[ngx.req.get_method()]
        if not h then return U.fail(405, "METHOD_NOT_ALLOWED", "Method not allowed") end
        return h(self, ns_id)
    end
end

local function result(res, err)
    if res == nil then return U.from_err(err) end
    return U.ok(res)
end

local function created(res, err)
    if res == nil then return U.from_err(err) end
    return U.ok(res, 201)
end

return function(app)
    -- categories --------------------------------------------------------------
    app:get(BASE .. "/categories", guard("read", function(_, ns_id)
        local rows = Catalog.listCategories(ns_id, { admin = true })
        return U.ok(rows, 200, { total = #rows, limit = #rows, offset = 0 })
    end))

    app:post(BASE .. "/categories", guard("create", function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        if not U.nz(body.name) then return U.fail(400, "VALIDATION_ERROR", "name is required") end
        local slug = U.nz(body.slug) or U.slugify(body.name)
        local db = require("lapis.db")
        if db.query("SELECT 1 FROM shop_categories WHERE namespace_id = ? AND slug = ?", ns_id, slug)[1] then
            return U.fail(409, "SLUG_TAKEN", "Category slug already in use")
        end
        local row, err = Catalog.saveCategory(ns_id, body)
        if not row then return U.from_err(err) end
        return U.ok(row, 201)
    end))

    app:match(BASE .. "/categories/:uuid", function(self)
        local m = ngx.req.get_method()
        local action = (m == "DELETE") and "delete" or "update"
        return guard(action, method_router({
            PUT = function(s, ns_id)
                local body, bad = body_or_400()
                if not body then return bad end
                local row, err = Catalog.saveCategory(ns_id, body, s.params.uuid)
                if not row then return U.from_err(err) end
                return U.ok(row)
            end,
            DELETE = function(s, ns_id)
                local ok, err = Catalog.deleteCategory(ns_id, s.params.uuid)
                if not ok then return U.from_err(err) end
                return U.ok({ deleted = true })
            end,
        }))(self)
    end)

    -- products ------------------------------------------------------------------
    app:get(BASE .. "/products", guard("read", function(self, ns_id)
        local data, meta = Catalog.adminList(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:post(BASE .. "/products", guard("create", function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local db = require("lapis.db")
        if U.nz(body.sku) and db.query("SELECT 1 FROM shop_products WHERE namespace_id = ? AND sku = ?",
            ns_id, body.sku)[1] then
            return U.fail(409, "SKU_TAKEN", "SKU already in use: " .. tostring(body.sku))
        end
        local res, err = Catalog.saveProduct(ns_id, body, { user_id = user_id(self), ref = "product created" })
        if not res then return U.from_err(err) end
        local doc = Catalog.adminDocument(ns_id, res.uuid)
        if #res.unresolved > 0 then
            local missing = {}
            for _, u in ipairs(res.unresolved) do missing[#missing + 1] = u.sku end
            return U.ok(doc, 201, { warnings = U.arr({ "component_product_sku not found: " .. table.concat(missing, ", ") }) })
        end
        return U.ok(doc, 201)
    end))

    app:match(BASE .. "/products/:uuid", function(self)
        local m = ngx.req.get_method()
        local action = (m == "GET" and "read") or (m == "DELETE" and "delete") or "update"
        return guard(action, method_router({
            GET = function(s, ns_id)
                local doc = Catalog.adminDocument(ns_id, s.params.uuid)
                if not doc then return U.fail(404, "NOT_FOUND", "Product not found") end
                return U.ok(doc)
            end,
            PUT = function(s, ns_id)
                local body, bad = body_or_400()
                if not body then return bad end
                local res, err = Catalog.saveProduct(ns_id, body, { uuid = s.params.uuid, user_id = user_id(s),
                    ref = "product edit", ignore_stock = true })
                if not res then return U.from_err(err) end
                local doc = Catalog.adminDocument(ns_id, res.uuid)
                if #res.unresolved > 0 then
                    local missing = {}
                    for _, u in ipairs(res.unresolved) do missing[#missing + 1] = u.sku end
                    return U.ok(doc, 200, { warnings = U.arr({ "component_product_sku not found: "
                        .. table.concat(missing, ", ") }) })
                end
                return U.ok(doc)
            end,
            DELETE = function(s, ns_id)
                return result(Catalog.deleteProduct(ns_id, s.params.uuid))
            end,
        }))(self)
    end)

    app:post(BASE .. "/products/:uuid/stock", guard("update", function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        return result(Stock.adjustProduct(ns_id, self.params.uuid, body.delta, body.reason, U.nz(body.note),
            user_id(self)))
    end))

    app:post(BASE .. "/options/:uuid/stock", guard("update", function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        return result(Stock.adjustOption(ns_id, self.params.uuid, body.delta, body.reason, U.nz(body.note),
            user_id(self)))
    end))

    app:get(BASE .. "/stock", guard("read", function(self, ns_id)
        local rows = Stock.sheet(ns_id, { low_only = self.params.low_only })
        return U.ok(rows, 200, { total = #rows, limit = #rows, offset = 0 })
    end))

    app:get(BASE .. "/stock/movements", guard("read", function(self, ns_id)
        local data, meta = Stock.movements(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:post(BASE .. "/import", guard("create", function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        if type(body.products) ~= "table" and type(body.categories) ~= "table" then
            return U.fail(400, "VALIDATION_ERROR", "categories and/or products arrays are required")
        end
        return U.ok(Catalog.import(ns_id, body, user_id(self)))
    end))

    -- orders ----------------------------------------------------------------------
    app:get(BASE .. "/orders", guard("read", function(self, ns_id)
        local data, meta = Orders.adminList(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:match(BASE .. "/orders/:uuid", function(self)
        local action = ngx.req.get_method() == "GET" and "read" or "update"
        return guard(action, method_router({
            GET = function(s, ns_id)
                local o = Orders.adminGet(ns_id, s.params.uuid)
                if not o then return U.fail(404, "NOT_FOUND", "Order not found") end
                return U.ok(o)
            end,
            PUT = function(s, ns_id)
                local body, bad = body_or_400()
                if not body then return bad end
                return result(Orders.adminUpdate(ns_id, s.params.uuid, body))
            end,
        }))(self)
    end)

    -- quotes ----------------------------------------------------------------------
    app:get(BASE .. "/quotes", guard("read", function(self, ns_id)
        local data, meta = Quote.adminList(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:post(BASE .. "/quotes", guard("create", function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        return created(Quote.adminCreate(ns_id, body, user_id(self)))
    end))

    app:match(BASE .. "/quotes/:uuid", function(self)
        local action = ngx.req.get_method() == "GET" and "read" or "update"
        return guard(action, method_router({
            GET = function(s, ns_id)
                local q = Quote.adminGet(ns_id, s.params.uuid)
                if not q then return U.fail(404, "NOT_FOUND", "Quote not found") end
                return U.ok(q)
            end,
            PUT = function(s, ns_id)
                local body, bad = body_or_400()
                if not body then return bad end
                return result(Quote.adminUpdate(ns_id, s.params.uuid, body))
            end,
        }))(self)
    end)

    -- chats -----------------------------------------------------------------------
    app:get(BASE .. "/chats", guard("read", function(self, ns_id)
        local data, meta = Chat.adminList(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:get(BASE .. "/chats/:uuid", guard("read", function(self, ns_id)
        local s = Chat.adminGet(ns_id, self.params.uuid)
        if not s then return U.fail(404, "NOT_FOUND", "Chat session not found") end
        return U.ok(s)
    end))

    -- knowledge ---------------------------------------------------------------------
    app:get(BASE .. "/knowledge", guard("read", function(self, ns_id)
        local data, meta = Search.listKnowledge(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:post(BASE .. "/knowledge/reindex", guard("update", function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        return U.ok(Search.reindex(ns_id, body))
    end))

    app:post(BASE .. "/knowledge", guard("create", function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        return created(Search.addDocument(ns_id, body))
    end))

    app:delete(BASE .. "/knowledge/:source_ref", guard("delete", function(self, ns_id)
        local n = Search.deleteSource(ns_id, self.params.source_ref, self.params.source_type)
        if n == 0 then return U.fail(404, "NOT_FOUND", "No knowledge chunks for that source_ref") end
        return U.ok({ deleted_chunks = n })
    end))

    -- dashboard + reconcile ---------------------------------------------------------
    app:get(BASE .. "/dashboard", guard("read", function(_, ns_id)
        return U.ok(Dashboard.kpis(ns_id))
    end))

    app:post(BASE .. "/reconcile", guard("update", function(_, ns_id)
        return U.ok(ShopStripe.reconcile(ns_id, {}))
    end))
end
