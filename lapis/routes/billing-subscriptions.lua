--[[
    Billing & Entitlements — subscriptions, purchases, grants, upgrades and
    plan history (RBAC `subscriptions`), and the runtime checks a client's
    server calls with a scoped secret key (RBAC `entitlements`).
    docs/BILLING_ENTITLEMENTS.md §8.

      GET    /api/v2/subscriptions?app=&customer=&status=           subscriptions.read
      GET    /api/v2/subscriptions/:uuid                             subscriptions.read
      GET    /api/v2/subscriptions/grants?app=&customer=             subscriptions.read
      POST   /api/v2/subscriptions/grants                            subscriptions.create
      DELETE /api/v2/subscriptions/grants/:uuid                      subscriptions.delete (revoke)
      GET    /api/v2/subscriptions/entitlements?app=&customer=       subscriptions.read (dashboard view)
      GET    /api/v2/subscriptions/purchases?app=&customer=&status=&source=   subscriptions.read
      POST   /api/v2/subscriptions/purchases                         subscriptions.create (manual sale)
      POST   /api/v2/subscriptions/purchases/:uuid/revoke            subscriptions.update
      POST   /api/v2/subscriptions/upgrade[?quote=1]                 subscriptions.update (admin upgrade)
      GET    /api/v2/subscriptions/plan-changes?app=&customer=&kind= subscriptions.read
      POST   /api/v2/subscriptions/purchases/:uuid/refund            subscriptions.update { amount? } (Stripe purchases)
      POST   /api/v2/subscriptions/checkout                          subscriptions.create -> Stripe Checkout URL
               { app, plan, customer | customer_external_id?, email?, coupon?, success_url?, cancel_url? }
      POST   /api/v2/subscriptions/portal                            subscriptions.create -> Stripe Customer Portal URL
               { app, customer | customer_external_id, return_url? }

      PUT    /api/v2/entitlements/:app/customers/:external_id        entitlements.create (upsert customer)
      GET    /api/v2/entitlements/:app/customers/:external_id        entitlements.read  (+ signed token)
      POST   /api/v2/entitlements/:app/purchases                     entitlements.create (verified store/external)
      POST   /api/v2/entitlements/:app/purchases/verify              entitlements.create (verifier; stores: 501)
]]

local cjson = require("cjson")
local Http = require("helper.field-service-http")
local Apps = require("queries.BillingAppQueries")
local Subs = require("queries.BillingSubscriptionQueries")
local Purchases = require("queries.BillingPurchaseQueries")
local CustomerQueries = require("queries.CustomerQueries")
local EntitlementService = require("helper.entitlement-service")
local Signing = require("lib.billing-signing")
local Guard = require("lib.billing-guard")
local db = require("lapis.db")
local Pay = require("lib.billing-stripe")
local Common = require("queries.FieldServiceCommon")

local function customer_view(c)
    return c and { uuid = c.uuid, external_id = c.external_id, email = c.email } or nil
end

local function body_guard(module, action, handler)
    return Http.guard(module, action, function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return handler(self, body)
    end)
end

-- A query result that may carry a machine code (coupon_* errors).
local function result(row, err, code, status)
    if row == nil then
        if code then return Guard.fail(422, code, err) end
        return Http.from_error(err)
    end
    return Http.ok(row, status)
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

    app:post("/api/v2/subscriptions/grants", body_guard("subscriptions", "create", function(self, body)
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

    app:get("/api/v2/subscriptions/purchases", Http.guard("subscriptions", "read", function(self)
        local rows, meta = Purchases.list(self.namespace.id, self.params)
        return Http.ok(rows, 200, meta)
    end))

    app:post("/api/v2/subscriptions/purchases", body_guard("subscriptions", "create", function(self, body)
        local res, err, code = Purchases.sell(self.namespace.id, Http.actor(self), body)
        return result(res, err, code, 201)
    end))

    app:post("/api/v2/subscriptions/purchases/:uuid/revoke", Http.guard("subscriptions", "update", function(self)
        return Http.result(Purchases.revoke(self.namespace.id, self.params.uuid, Http.actor(self)))
    end))

    app:post("/api/v2/subscriptions/upgrade", body_guard("subscriptions", "update", function(self, body)
        local quote = self.params.quote == "1" or self.params.quote == "true"
        local res, err, code = Purchases.upgrade(self.namespace.id, Http.actor(self), body, quote)
        return result(res, err, code)
    end))

    app:post("/api/v2/subscriptions/purchases/:uuid/refund", Http.guard("subscriptions", "update", function(self)
        local body = Http.json_body() or {}
        local res, err = Pay.refund(self.namespace.id, self.params.uuid, body.amount)
        if not res then return Guard.fail(err.status, err.code, err.message) end
        return Http.ok(res)
    end))

    -- The customer a server-side checkout / portal is for: uuid, or the app's own user id.
    local function payer(a, body, required)
        if Common.nilify(body.customer) then
            local c = Subs.customer(a.namespace_id, body.customer)
            if not c then return nil, Guard.fail(404, "not_found", "Customer not found") end
            return c
        end
        if Common.nilify(body.customer_external_id) then
            local c, cerr = CustomerQueries.upsertExternal(a.namespace_id, tostring(body.customer_external_id),
                { email = body.email })
            if not c then return nil, Guard.fail(422, "invalid_customer", cerr) end
            return c
        end
        if required then return nil, Guard.fail(422, "customer_required", "Send customer or customer_external_id") end
        return nil
    end

    local function url_ok(u)
        return u == nil or (type(u) == "string" and #u <= 2000 and u:match("^https?://[^%s]+$") ~= nil)
    end

    app:post("/api/v2/subscriptions/checkout", body_guard("subscriptions", "create", function(self, body)
        local a = Apps.find(self.namespace.id, body.app)
        if not a or a.active == false then return Http.fail(404, "App not found") end
        local plan = Subs.appPlan(a.id, tostring(body.plan or ""))
        if not plan or not plan.active then return Guard.fail(404, "unknown_plan", "Plan not found in this app") end
        local success, cancel = Common.nilify(body.success_url), Common.nilify(body.cancel_url)
        if not url_ok(success) or not url_ok(cancel) then
            return Guard.fail(422, "invalid_url", "success_url and cancel_url must be http(s) URLs")
        end
        local customer, cfail = payer(a, body, false)
        if cfail then return cfail end
        return Guard.idempotent(self, ("ns:%s:checkout"):format(self.namespace.id), body, function()
            local res, err = Pay.start(a, plan, customer, { email = Common.nilify(body.email),
                coupon = Common.nilify(body.coupon), success_url = success, cancel_url = cancel,
                idempotency_key = self.req.headers["idempotency-key"] })
            if not res then return Guard.fail(err.status, err.code, err.message) end
            return Http.ok(res, res.url and 201 or 200)
        end, true)
    end))

    app:post("/api/v2/subscriptions/portal", body_guard("subscriptions", "create", function(self, body)
        local a = Apps.find(self.namespace.id, body.app)
        if not a then return Http.fail(404, "App not found") end
        if not url_ok(Common.nilify(body.return_url)) then return Guard.fail(422, "invalid_url", "return_url must be an http(s) URL") end
        local customer, cfail = payer(a, body, true)
        if not customer then return cfail end
        local res, err = Pay.portal(a, customer.id, Common.nilify(body.return_url))
        if not res then return Guard.fail(err.status, err.code, err.message) end
        return Http.ok(res)
    end))

    app:get("/api/v2/subscriptions/plan-changes", Http.guard("subscriptions", "read", function(self)
        local rows, meta = Purchases.planChanges(self.namespace.id, self.params)
        return Http.ok(rows, 200, meta)
    end))

    app:get("/api/v2/subscriptions/:uuid", Http.guard("subscriptions", "read", function(self)
        local row = Subs.findForApps(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Subscription not found") end
        return Http.ok(row)
    end))

    -- ----------------------------------------------------------------------
    -- Runtime (the client's server)
    -- ----------------------------------------------------------------------

    local function runtime(action, handler)
        return Http.guard("entitlements", action, function(self)
            local a = Apps.find(self.namespace.id, self.params.app)
            if not a or a.active == false then return Http.fail(404, "App not found") end
            return handler(self, a)
        end)
    end

    local function external_id(self)
        local id = self.params.external_id
        if type(id) ~= "string" or #id > 255 then return nil end
        return id
    end

    app:put("/api/v2/entitlements/:app/customers/:external_id", runtime("create", function(self, a)
        local ext = external_id(self)
        if not ext then return Http.fail(422, "external_id must be at most 255 characters") end
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        local mode = require("lib.billing-settings").resolve(a).email_collection
        if mode == "none" then body.email = nil end
        local existing = db.query("SELECT 1 FROM customers WHERE namespace_id = ? AND external_id = ?",
            self.namespace.id, ext)[1]
        if mode == "required" and not existing and not body.email then
            return Http.fail(422, "email is required to create a customer")
        end
        if mode ~= "required" and not existing and not body.email then
            -- No email collected: a placeholder unique to this customer (never emailed).
            body.email = ("%s+%s@customers.invalid"):format(ngx.md5(ext):sub(1, 16), a.uuid:sub(1, 8))
        end
        local c, cerr = CustomerQueries.upsertExternal(self.namespace.id, ext, body)
        if not c then return Http.fail(422, cerr) end
        return Http.ok(customer_view(c))
    end))

    -- An unknown external_id is not an error: it gets the default plan, so an
    -- app can check before (or without) registering the customer.
    app:get("/api/v2/entitlements/:app/customers/:external_id", runtime("read", function(self, a)
        local ext = external_id(self)
        if not ext then return Http.fail(422, "external_id must be at most 255 characters") end
        local c = db.query([[SELECT id, uuid, external_id, email FROM customers
            WHERE namespace_id = ? AND external_id = ?]], self.namespace.id, ext)[1]
        local ent, token = EntitlementService.get(a, c or { external_id = ext }, self.namespace.uuid)
        return Http.ok({
            customer = customer_view(c),
            entitlements = ent,
            token = token or cjson.null,
        }, 200, not Signing.configured() and { token = "not configured: set BILLING_SIGNING_KEY" } or nil)
    end))

    app:post("/api/v2/entitlements/:app/purchases", runtime("create", function(self, a)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return Guard.idempotent(self, "ns:" .. self.namespace.id .. ":purchases", body, function()
            local res, rerr = Purchases.recordExternal(a, body)
            return Http.result(res, rerr, 201)
        end)
    end))

    app:post("/api/v2/entitlements/:app/purchases/verify", runtime("create", function(_, a)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        local purchase, verr = require("lib.billing-verifiers").verify(body.source, a, body.payload)
        if not purchase then return Guard.fail(verr.status, verr.code, verr.message) end
        purchase.source = body.source
        local res, rerr = Purchases.recordExternal(a, purchase)
        return Http.result(res, rerr, 201)
    end))
end
