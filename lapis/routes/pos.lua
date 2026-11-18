-- luacheck: max line length 140
--[[
    Point of Sale (queries/PosQueries.lua): selling in person from a store of this workspace.

      GET  /api/v2/pos/products?store_uuid=&q=&limit=   orders.create  the till's products (q: name, SKU, barcode)
      POST /api/v2/pos/sales                            orders.create  { store_uuid, items, discount_amount?, customer?,
                                                                       payment { method, tendered?, reference? }, note? }
                                                                       → 201 the receipt; Idempotency-Key honoured
      GET  /api/v2/pos/sales/:uuid/receipt              orders.read    the receipt again
      POST /api/v2/pos/sales/:uuid/email-receipt        orders.create  { email } (20 a minute per person)
      GET  /api/v2/pos/summary?store_uuid=&date=        orders.read    the till's day by payment method
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RateLimit = require("middleware.rate-limit")
local cjson = require("cjson")

local function guard(action, handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("orders", action, function(self)
        local ok, res = pcall(handler, self)
        if not ok then
            ngx.log(ngx.ERR, "[pos] ", tostring(res))
            return { status = 500,
                json = { success = false, error = "Something went wrong at the till. Try again." } }
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

local function json_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local path = ngx.req.get_body_file()
        local f = path and io.open(path, "rb")
        if f then raw = f:read("*a"); f:close() end
    end
    local ok, body = pcall(cjson.decode, raw or "")
    if not ok or type(body) ~= "table" then return nil end
    return body
end

return function(app)
    local Pos = require("queries.PosQueries")

    app:get("/api/v2/pos/products", guard("create", function(self)
        return reply(Pos.products(self.namespace.id, self.params.store_uuid, self.params.q, self.params.limit))
    end))

    app:post("/api/v2/pos/sales", guard("create", function(self)
        local body = json_body()
        if not body then
            return { status = 400, json = { success = false, error = "Send the sale as JSON", code = "INVALID_JSON" } }
        end
        return require("helper.idempotency").run(self, self.namespace.id, self.current_user.uuid, function()
            local data, err = Pos.sale(self.namespace.id, body)
            return reply(data, err, 201)
        end)
    end))

    app:get("/api/v2/pos/sales/:uuid/receipt", guard("read", function(self)
        return reply(Pos.receipt(self.namespace.id, self.params.uuid))
    end))

    app:post("/api/v2/pos/sales/:uuid/email-receipt", guard("create", function(self)
        local who = self.current_user and self.current_user.uuid or "anon"
        local allowed = RateLimit.check("pos_receipt:" .. who, 20, 60)
        if not allowed then
            return { status = 429,
                json = { success = false, error = "That's a lot of receipts. Try again in a minute." } }
        end
        local body = json_body() or {}
        return reply(Pos.email_receipt(self.namespace.id, self.params.uuid, body.email))
    end))

    app:get("/api/v2/pos/summary", guard("read", function(self)
        return reply(Pos.summary(self.namespace.id, self.params.store_uuid, self.params.date))
    end))
end
