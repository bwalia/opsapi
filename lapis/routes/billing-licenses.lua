--[[
    Billing & Entitlements — licence keys (RBAC `licenses`).
    docs/BILLING_ENTITLEMENTS.md §8.1. The public activate / validate /
    deactivate endpoints are in routes/billing-public.lua.

      GET    /api/v2/licenses?app=&customer=&status=          licenses.read
      POST   /api/v2/licenses                                  licenses.create  (key returned ONCE)
      GET    /api/v2/licenses/:uuid                            licenses.read    (+ devices)
      PUT    /api/v2/licenses/:uuid                            licenses.update  (suspend/resume, limits, windows)
      POST   /api/v2/licenses/:uuid/revoke                     licenses.update
      POST   /api/v2/licenses/:uuid/reissue                    licenses.update  (new key ONCE; devices kept)
      DELETE /api/v2/licenses/:uuid/activations/:activation    licenses.delete  (free a seat)
]]

local Http = require("helper.field-service-http")
local Licenses = require("queries.BillingLicenseQueries")

return function(app)
    app:get("/api/v2/licenses", Http.guard("licenses", "read", function(self)
        local rows, meta = Licenses.list(self.namespace.id, self.params)
        return Http.ok(rows, 200, meta)
    end))

    app:post("/api/v2/licenses", Http.guard("licenses", "create", function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        local row, cerr = Licenses.create(self.namespace.id, Http.actor(self), body)
        return Http.result(row, cerr, 201)
    end))

    app:get("/api/v2/licenses/:uuid", Http.guard("licenses", "read", function(self)
        local row = Licenses.get(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Licence not found") end
        return Http.ok(row)
    end))

    app:put("/api/v2/licenses/:uuid", Http.guard("licenses", "update", function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return Http.result(Licenses.update(self.namespace.id, self.params.uuid, body))
    end))

    app:post("/api/v2/licenses/:uuid/revoke", Http.guard("licenses", "update", function(self)
        return Http.result(Licenses.revoke(self.namespace.id, self.params.uuid))
    end))

    app:post("/api/v2/licenses/:uuid/reissue", Http.guard("licenses", "update", function(self)
        return Http.result(Licenses.reissue(self.namespace.id, self.params.uuid))
    end))

    app:delete("/api/v2/licenses/:uuid/activations/:activation", Http.guard("licenses", "delete", function(self)
        return Http.result(Licenses.removeActivation(self.namespace.id, self.params.uuid, self.params.activation))
    end))
end
