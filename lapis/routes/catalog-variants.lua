-- luacheck: max line length 140
--[[
    Product variations for staff (queries/CatalogVariantQueries.lua), RBAC products, this workspace's products only:
      GET    /api/v2/catalog/products/:uuid/variants      products.read
      POST   /api/v2/catalog/products/:uuid/variants      products.update  { title?, option1-3?, sku?, price?, stock?, is_active? }
      PUT    /api/v2/catalog/variants/:uuid               products.update  (the fields sent)
      DELETE /api/v2/catalog/variants/:uuid               products.update
    (The older /api/v2/products/:id/variants routes stay for the storefront.)
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local cjson = require("cjson")

local function guard(action, handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("products", action, function(self)
        local ok, res = pcall(handler, self)
        if not ok then
            ngx.log(ngx.ERR, "[variants] ", tostring(res))
            return { status = 500, json = { success = false, error = "The variation couldn't be saved. Try again." } }
        end
        return res
    end))
end

local function reply(data, err, status)
    if not data then
        return { status = err.status or 400, json = { success = false, error = err.message, code = err.code, fields = err.fields } }
    end
    return { status = status or 200, json = { success = true, data = data } }
end

local function body()
    ngx.req.read_body()
    local ok, b = pcall(cjson.decode, ngx.req.get_body_data() or "")
    return ok and type(b) == "table" and b or nil
end

return function(app)
    local V = require("queries.CatalogVariantQueries")

    app:get("/api/v2/catalog/products/:uuid/variants", guard("read", function(self)
        return reply(V.list(self.namespace.id, self.params.uuid))
    end))

    app:post("/api/v2/catalog/products/:uuid/variants", guard("update", function(self)
        local b = body()
        if not b then return { status = 400, json = { success = false, error = "Send the variation as JSON" } } end
        return reply(V.create(self.namespace.id, self.params.uuid, b), nil, 201)
    end))

    app:match("/api/v2/catalog/variants/:uuid", function(self)
        local m = ngx.req.get_method()
        if m == "PUT" or m == "PATCH" then
            return guard("update", function(s)
                local b = body()
                if not b then return { status = 400, json = { success = false, error = "Send the variation as JSON" } } end
                return reply(V.update(s.namespace.id, s.params.uuid, b))
            end)(self)
        elseif m == "DELETE" then
            return guard("update", function(s) return reply(V.remove(s.namespace.id, s.params.uuid)) end)(self)
        end
        return { status = 405, json = { success = false, error = "Method not allowed" } }
    end)
end
