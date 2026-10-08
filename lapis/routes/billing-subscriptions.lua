--[[
    Billing & Entitlements — subscriptions + grants (RBAC `subscriptions`) and
    the runtime entitlement checks (RBAC `entitlements`) a client's server
    calls with a scoped secret key. docs/BILLING_ENTITLEMENTS.md §5 / §7.

      GET    /api/v2/subscriptions?app=&customer=&status=            subscriptions.read
      GET    /api/v2/subscriptions/:uuid                              subscriptions.read
      GET    /api/v2/subscriptions/grants?app=&customer=&include_revoked=   subscriptions.read
      POST   /api/v2/subscriptions/grants                             subscriptions.create
      DELETE /api/v2/subscriptions/grants/:uuid                       subscriptions.delete (revoke)
      GET    /api/v2/subscriptions/entitlements?app=&customer=        subscriptions.read (dashboard view)

      PUT    /api/v2/entitlements/:app/customers/:external_id         entitlements.create (upsert customer)
      GET    /api/v2/entitlements/:app/customers/:external_id         entitlements.read  (+ signed token)

    Subscriptions are created by checkout (Phase 2); until then access comes
    from the app's default plan and grants.
]]

local cjson = require("cjson")
local Http = require("helper.field-service-http")
local Apps = require("queries.BillingAppQueries")
local Subs = require("queries.BillingSubscriptionQueries")
local CustomerQueries = require("queries.CustomerQueries")
local EntitlementService = require("helper.entitlement-service")
local Signing = require("lib.billing-signing")
local db = require("lapis.db")

local function customer_view(c)
    return c and { uuid = c.uuid, external_id = c.external_id, email = c.email } or nil
end

return function(app)
    app:get("/api/v2/subscriptions", Http.guard("subscriptions", "read", function(self)
        local rows, meta = Subs.listForApps(self.namespace.id, self.params)
        return Http.ok(rows, 200, meta)
    end))

    app:get("/api/v2/subscriptions/grants", Http.guard("subscriptions", "read", function(self)
        local rows, meta = Subs.listGrants(self.namespace.id, self.params)
        return Http.ok(rows, 200, meta)
    end))

    app:post("/api/v2/subscriptions/grants", Http.guard("subscriptions", "create", function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        local row, gerr = Subs.createGrant(self.namespace.id, Http.actor(self), body)
        return Http.result(row, gerr, 201)
    end))

    app:delete("/api/v2/subscriptions/grants/:uuid", Http.guard("subscriptions", "delete", function(self)
        return Http.result(Subs.revokeGrant(self.namespace.id, self.params.uuid))
    end))

    app:get("/api/v2/subscriptions/entitlements", Http.guard("subscriptions", "read", function(self)
        local a = Apps.find(self.namespace.id, self.params.app)
        if not a then return Http.fail(404, "App not found") end
        local c = Subs.customer(self.namespace.id, self.params.customer)
        if not c then return Http.fail(404, "Customer not found") end
        return Http.ok(EntitlementService.resolve(a, c))
    end))

    app:get("/api/v2/subscriptions/:uuid", Http.guard("subscriptions", "read", function(self)
        local row = Subs.findForApps(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Subscription not found") end
        return Http.ok(row)
    end))

    -- ----------------------------------------------------------------------
    -- Runtime
    -- ----------------------------------------------------------------------

    local function runtime(action, handler)
        return Http.guard("entitlements", action, function(self)
            local a = Apps.find(self.namespace.id, self.params.app)
            if not a or a.active == false then return Http.fail(404, "App not found") end
            local external_id = self.params.external_id
            if type(external_id) ~= "string" or #external_id > 255 then
                return Http.fail(422, "external_id must be at most 255 characters")
            end
            return handler(self, a, external_id)
        end)
    end

    app:put("/api/v2/entitlements/:app/customers/:external_id", runtime("create", function(self, a, external_id)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        local c, cerr = CustomerQueries.upsertExternal(self.namespace.id, external_id, body)
        if not c then return Http.fail(422, cerr) end
        return Http.ok(customer_view(c))
    end))

    -- An unknown external_id is not an error: it gets the default plan, so an
    -- app can check before (or without) registering the customer.
    app:get("/api/v2/entitlements/:app/customers/:external_id", runtime("read", function(self, a, external_id)
        local c = db.query([[SELECT id, uuid, external_id, email FROM customers
            WHERE namespace_id = ? AND external_id = ?]], self.namespace.id, external_id)[1]
        local ent = EntitlementService.resolve(a, c or { id = 0, external_id = external_id })
        local token = EntitlementService.token(a, c or { external_id = external_id }, ent, self.namespace.uuid)
        return Http.ok({
            customer = customer_view(c),
            entitlements = ent,
            token = token or cjson.null,
        }, 200, not Signing.configured() and { token = "not configured: set BILLING_SIGNING_KEY" } or nil)
    end))
end
