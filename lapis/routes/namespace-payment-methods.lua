--[[
    Payment methods ("Getting paid"), namespace level (core). queries/PaymentMethodQueries.lua.

      GET    /api/v2/namespace/payment-methods            namespace.read | invoices.read | shop.read
                                                          (?include_inactive=true for the settings page)
      POST   /api/v2/namespace/payment-methods            namespace.update
      PUT    /api/v2/namespace/payment-methods/:uuid      namespace.update
      DELETE /api/v2/namespace/payment-methods/:uuid      namespace.update (deactivated instead when an
                                                          invoice uses it)

    Namespace owners and platform admins pass every check (NamespaceMiddleware.hasPermission).
    PaymentMethod: { uuid, kind, label, account_name, bank_name, sort_code, account_number, iban, swift_bic,
                     currency, instructions, is_default, show_on_documents, is_active, sort_order }
]]

local Http = require("helper.field-service-http")
local PaymentMethods = require("queries.PaymentMethodQueries")

local READ = { { "namespace", "read" }, { "invoices", "read" }, { "shop", "read" } }

local function with_body(fn)
    return Http.guard("namespace", "update", function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return fn(self, body)
    end)
end

return function(app)
    app:get("/api/v2/namespace/payment-methods", Http.guard_any(READ, function(self)
        local inactive = self.params.include_inactive == "true" or self.params.include_inactive == "1"
        return Http.ok(setmetatable(PaymentMethods.list(self.namespace.id, { include_inactive = inactive }),
            require("cjson").array_mt))
    end))

    app:post("/api/v2/namespace/payment-methods", with_body(function(self, body)
        local row, err = PaymentMethods.create(self.namespace.id, body, Http.actor(self))
        if not row then return Http.fail(422, err) end
        return Http.ok(row, 201)
    end))

    app:put("/api/v2/namespace/payment-methods/:uuid", with_body(function(self, body)
        return Http.result(PaymentMethods.update(self.namespace.id, self.params.uuid, body))
    end))

    app:delete("/api/v2/namespace/payment-methods/:uuid", Http.guard("namespace", "update", function(self)
        return Http.result(PaymentMethods.remove(self.namespace.id, self.params.uuid))
    end))
end
