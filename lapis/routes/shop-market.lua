-- luacheck: max line length 140
--[[
    Shop market-price admin API (workstation-website shop/MARKET.prompt.md §A)
    ==========================================================================
    Base /api/v2/shop/admin/market — JWT or opsk_ API key (scoped "shop") +
    namespace + RBAC module "shop". Envelope { success, data, meta? }.

      GET    /market/sources?product_uuid=&active=     POST /market/sources
      PUT    /market/sources/:uuid                      DELETE /market/sources/:uuid
      POST   /market/sources/upsert                     (idempotent by product + url)
      GET    /market/due?limit=50                       (worker queue; ?source_uuid= forces one)
      POST   /market/observations                       (worker results)
      POST   /market/observations/:uuid/accept          (accept an anomaly)
      GET    /market/products/:uuid                     (sources + latest obs + summary + history)
      GET    /market/overview?stale=&diff_gt=&q=&anomalies=
      POST   /market/products/:uuid/apply-price         { strategy: median|min|value, value_minor? }

    The public read (GET /api/v2/public/shop/:ns/market) lives in shop-public.lua.
]]

local U = require("lib.shop-util")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local Market = require("queries.ShopMarketQueries")

local BASE = "/api/v2/shop/admin/market"
local MAX_BATCH = 500

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

--- Array from body[key]; 400 unless a non-empty array within MAX_BATCH.
local function batch_or_400(body, key)
    local list = body[key]
    if type(list) ~= "table" or #list == 0 then
        return nil, U.fail(400, "VALIDATION_ERROR", key .. " must be a non-empty array")
    end
    if #list > MAX_BATCH then
        return nil, U.fail(400, "VALIDATION_ERROR", key .. " may contain at most " .. MAX_BATCH .. " items")
    end
    return list
end

local function user_id(self)
    local u = self.current_user or {}
    if u.api_key and not u.user_bound then return nil end
    local id = tonumber(u.id)
    if id then return id end
    if u.uuid then
        local db = require("lapis.db")
        local r = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", u.uuid)[1]
        return r and r.id or nil
    end
    return nil
end

local function result(res, err, status)
    if res == nil then return U.from_err(err) end
    return U.ok(res, status)
end

return function(app)
    -- sources -------------------------------------------------------------------
    app:post(BASE .. "/sources/upsert", guard("update", function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local list, bad2 = batch_or_400(body, "sources")
        if not list then return bad2 end
        return U.ok(Market.upsertSources(ns_id, list))
    end))

    app:match(BASE .. "/sources", function(self)
        local m = ngx.req.get_method()
        if m == "GET" then
            return guard("read", function(s, ns_id)
                local data, meta = Market.listSources(ns_id, s.params)
                return U.ok(data, 200, meta)
            end)(self)
        elseif m == "POST" then
            return guard("create", function(_, ns_id)
                local body, bad = body_or_400()
                if not body then return bad end
                local res, err = Market.createSource(ns_id, body)
                return result(res, err, 201)
            end)(self)
        end
        return U.fail(405, "METHOD_NOT_ALLOWED", "Method not allowed")
    end)

    app:match(BASE .. "/sources/:uuid", function(self)
        local m = ngx.req.get_method()
        if m == "GET" then
            return guard("read", function(s, ns_id)
                local src = Market.getSource(ns_id, s.params.uuid)
                if not src then return U.fail(404, "NOT_FOUND", "Market source not found") end
                return U.ok(src)
            end)(self)
        elseif m == "PUT" or m == "PATCH" then
            return guard("update", function(s, ns_id)
                local body, bad = body_or_400()
                if not body then return bad end
                return result(Market.updateSource(ns_id, s.params.uuid, body))
            end)(self)
        elseif m == "DELETE" then
            return guard("delete", function(s, ns_id)
                return result(Market.deleteSource(ns_id, s.params.uuid))
            end)(self)
        end
        return U.fail(405, "METHOD_NOT_ALLOWED", "Method not allowed")
    end)

    -- worker queue + results ------------------------------------------------------
    app:get(BASE .. "/due", guard("read", function(self, ns_id)
        local data, meta = Market.due(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:post(BASE .. "/observations", guard("update", function(_, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        local list, bad2 = batch_or_400(body, "observations")
        if not list then return bad2 end
        return U.ok(Market.recordObservations(ns_id, list))
    end))

    app:post(BASE .. "/observations/:uuid/accept", guard("update", function(self, ns_id)
        return result(Market.acceptObservation(ns_id, self.params.uuid, user_id(self)))
    end))

    -- products ------------------------------------------------------------------------
    app:get(BASE .. "/overview", guard("read", function(self, ns_id)
        local data, meta = Market.overview(ns_id, self.params)
        return U.ok(data, 200, meta)
    end))

    app:get(BASE .. "/products/:uuid", guard("read", function(self, ns_id)
        local doc = Market.productDetail(ns_id, self.params.uuid, self.params)
        if not doc then return U.fail(404, "NOT_FOUND", "Product not found") end
        return U.ok(doc)
    end))

    app:post(BASE .. "/products/:uuid/apply-price", guard("update", function(self, ns_id)
        local body, bad = body_or_400()
        if not body then return bad end
        return result(Market.applyPrice(ns_id, self.params.uuid, body))
    end))
end
