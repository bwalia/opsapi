--[[
    Billing & Entitlements — management of apps, features, reports, upgrade
    paths and coupons (RBAC `billing`). docs/BILLING_ENTITLEMENTS.md §8.1.
    The public endpoints are in routes/billing-public.lua.

      GET    /api/v2/billing/settings-schema?kind=            billing.read
      GET    /api/v2/billing/apps                              billing.read
      POST   /api/v2/billing/apps                              billing.create
      GET    /api/v2/billing/apps/:app                         billing.read     (uuid or slug)
      PUT    /api/v2/billing/apps/:app                         billing.update   (incl. settings)
      DELETE /api/v2/billing/apps/:app                         billing.delete   (soft)
      POST   /api/v2/billing/apps/:app/rotate-key              billing.update
      GET    /api/v2/billing/apps/:app/features                billing.read
      POST   /api/v2/billing/apps/:app/features                billing.create
      PUT    /api/v2/billing/apps/:app/features/:key           billing.update
      DELETE /api/v2/billing/apps/:app/features/:key           billing.delete
      GET    /api/v2/billing/apps/:app/reports                 billing.read
      GET    /api/v2/billing/apps/:app/upgrades                billing.read
      POST   /api/v2/billing/apps/:app/upgrades                billing.create
      PUT    /api/v2/billing/apps/:app/upgrades/:uuid          billing.update
      DELETE /api/v2/billing/apps/:app/upgrades/:uuid          billing.delete
      GET    /api/v2/billing/coupons?app=&search=              billing.read
      POST   /api/v2/billing/coupons                           billing.create
      GET    /api/v2/billing/coupons/:uuid                     billing.read
      PUT    /api/v2/billing/coupons/:uuid                     billing.update
      DELETE /api/v2/billing/coupons/:uuid                     billing.delete
      GET    /api/v2/billing/coupons/:uuid/redemptions         billing.read
]]

local Http = require("helper.field-service-http")
local Apps = require("queries.BillingAppQueries")
local Offers = require("queries.BillingOfferQueries")
local Settings = require("lib.billing-settings")

local function with_app(action, handler)
    return Http.guard("billing", action, function(self)
        local app = Apps.find(self.namespace.id, self.params.app)
        if not app then return Http.fail(404, "App not found") end
        return handler(self, app)
    end)
end

local function with_body(action, handler)
    return with_app(action, function(self, app)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return handler(self, app, body)
    end)
end

local function body_guard(action, handler)
    return Http.guard("billing", action, function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return handler(self, body)
    end)
end

return function(app)
    app:get("/api/v2/billing/settings-schema", Http.guard("billing", "read", function(self)
        return Http.ok(Settings.describe(self.params.kind))
    end))

    app:get("/api/v2/billing/apps", Http.guard("billing", "read", function(self)
        return Http.ok(Apps.list(self.namespace.id))
    end))

    app:post("/api/v2/billing/apps", body_guard("create", function(self, body)
        local row, cerr = Apps.create(self.namespace.id, Http.actor(self), body)
        if not row then return Http.fail(422, cerr) end
        return Http.ok(row, 201)
    end))

    app:get("/api/v2/billing/apps/:app", with_app("read", function(_, a)
        local out = Apps.present(a)
        out.features = Apps.features(a.id)
        return Http.ok(out)
    end))

    app:put("/api/v2/billing/apps/:app", with_body("update", function(self, a, body)
        return Http.result(Apps.update(self.namespace.id, a.uuid, body))
    end))

    app:delete("/api/v2/billing/apps/:app", with_app("delete", function(self, a)
        return Http.result(Apps.delete(self.namespace.id, a.uuid))
    end))

    app:post("/api/v2/billing/apps/:app/rotate-key", with_app("update", function(self, a)
        return Http.result(Apps.rotateKey(self.namespace.id, a.uuid))
    end))

    app:get("/api/v2/billing/apps/:app/features", with_app("read", function(_, a)
        return Http.ok(Apps.features(a.id))
    end))

    app:post("/api/v2/billing/apps/:app/features", with_body("create", function(_, a, body)
        local row, err = Apps.addFeature(a, body)
        return Http.result(row, err, 201)
    end))

    app:put("/api/v2/billing/apps/:app/features/:key", with_body("update", function(self, a, body)
        return Http.result(Apps.updateFeature(a, self.params.key, body))
    end))

    app:delete("/api/v2/billing/apps/:app/features/:key", with_app("delete", function(self, a)
        return Http.result(Apps.deleteFeature(a, self.params.key))
    end))

    app:get("/api/v2/billing/apps/:app/reports", with_app("read", function(_, a)
        return Http.ok(Apps.report(a))
    end))

    -- Upgrade paths
    app:get("/api/v2/billing/apps/:app/upgrades", with_app("read", function(_, a)
        return Http.ok(Offers.listUpgrades(a))
    end))

    app:post("/api/v2/billing/apps/:app/upgrades", with_body("create", function(_, a, body)
        local row, err = Offers.createUpgrade(a, body)
        return Http.result(row, err, 201)
    end))

    app:put("/api/v2/billing/apps/:app/upgrades/:uuid", with_body("update", function(self, a, body)
        return Http.result(Offers.updateUpgrade(a, self.params.uuid, body))
    end))

    app:delete("/api/v2/billing/apps/:app/upgrades/:uuid", with_app("delete", function(self, a)
        return Http.result(Offers.deleteUpgrade(a, self.params.uuid))
    end))

    -- Coupons
    app:get("/api/v2/billing/coupons", Http.guard("billing", "read", function(self)
        local rows, meta = Offers.listCoupons(self.namespace.id, self.params)
        return Http.ok(rows, 200, meta)
    end))

    app:post("/api/v2/billing/coupons", body_guard("create", function(self, body)
        local row, err = Offers.createCoupon(self.namespace.id, Http.actor(self), body)
        return Http.result(row, err, 201)
    end))

    app:get("/api/v2/billing/coupons/:uuid", Http.guard("billing", "read", function(self)
        local row = Offers.getCoupon(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Coupon not found") end
        return Http.ok(row)
    end))

    app:put("/api/v2/billing/coupons/:uuid", body_guard("update", function(self, body)
        return Http.result(Offers.updateCoupon(self.namespace.id, self.params.uuid, body))
    end))

    app:delete("/api/v2/billing/coupons/:uuid", Http.guard("billing", "delete", function(self)
        return Http.result(Offers.deleteCoupon(self.namespace.id, self.params.uuid))
    end))

    app:get("/api/v2/billing/coupons/:uuid/redemptions", Http.guard("billing", "read", function(self)
        local rows, meta = Offers.redemptions(self.namespace.id, self.params.uuid, self.params)
        if not rows then return Http.fail(404, meta) end
        return Http.ok(rows, 200, meta)
    end))
end
