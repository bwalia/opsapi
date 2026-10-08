--[[
    Billing & Entitlements — licence keys (RBAC `licenses`) and the public
    endpoints desktop / self-hosted apps call. docs/BILLING_ENTITLEMENTS.md §7.

      GET    /api/v2/licenses?app=&customer=&status=          licenses.read
      POST   /api/v2/licenses                                  licenses.create  (key returned ONCE)
      GET    /api/v2/licenses/:uuid                            licenses.read    (+ activations)
      PUT    /api/v2/licenses/:uuid                            licenses.update  (suspend/resume, limits, expiry)
      POST   /api/v2/licenses/:uuid/revoke                     licenses.update
      DELETE /api/v2/licenses/:uuid/activations/:activation    licenses.delete  (free a seat)

      POST   /api/v2/public/licenses/activate     { pk, license_key, fingerprint, name?, platform?, app_version? }
      POST   /api/v2/public/licenses/validate     { pk, license_key, fingerprint, app_version? }
      POST   /api/v2/public/licenses/deactivate   { pk, license_key, fingerprint }

    Public calls are limited per IP and per licence key; errors carry a stable
    `code` (invalid_license, license_revoked, activation_limit, …).
]]

local Http = require("helper.field-service-http")
local RateLimit = require("middleware.rate-limit")
local Apps = require("queries.BillingAppQueries")
local Licenses = require("queries.BillingLicenseQueries")

local function public_post(name, fn)
    return function()
        local body = Http.json_body() or {}
        local checks = { { "ip:" .. RateLimit.getClientIP(), 30 } }
        local key = Licenses.normalize(body.license_key)
        if key then checks[2] = { "key:" .. ngx.md5(key), 20 } end
        for _, c in ipairs(checks) do
            local allowed, _, retry = RateLimit.check("billing_lic:" .. c[1], c[2], 60)
            if not allowed then
                return { status = 429, json = { success = false, code = "rate_limited",
                    error = "Too many requests", retry_after = retry } }
            end
        end
        local a = Apps.byPublishableKey(body.pk)
        if not a then
            return { status = 404, json = { success = false, code = "unknown_app", error = "Unknown publishable key" } }
        end
        local result, err = Licenses[name](a, body)
        if not result then
            return { status = err.status, json = { success = false, code = err.code, error = err.message } }
        end
        return Http.ok(result)
    end
end

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

    app:delete("/api/v2/licenses/:uuid/activations/:activation", Http.guard("licenses", "delete", function(self)
        return Http.result(Licenses.removeActivation(self.namespace.id, self.params.uuid, self.params.activation))
    end))

    app:post("/api/v2/public/licenses/activate", public_post("activate"))
    app:post("/api/v2/public/licenses/validate", public_post("validate"))
    app:post("/api/v2/public/licenses/deactivate", public_post("deactivate"))
end
