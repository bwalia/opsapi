--[[
    Billing & Entitlements — apps, feature catalogue, reports (RBAC `billing`)
    and the public pricing + JWKS endpoints. docs/BILLING_ENTITLEMENTS.md §7.

      GET    /api/v2/billing/apps                          billing.read
      POST   /api/v2/billing/apps                          billing.create
      GET    /api/v2/billing/apps/:app                     billing.read     (uuid or slug)
      PUT    /api/v2/billing/apps/:app                     billing.update
      DELETE /api/v2/billing/apps/:app                     billing.delete   (soft)
      POST   /api/v2/billing/apps/:app/rotate-key          billing.update   (new publishable key)
      GET    /api/v2/billing/apps/:app/features            billing.read
      POST   /api/v2/billing/apps/:app/features            billing.create
      PUT    /api/v2/billing/apps/:app/features/:key       billing.update
      DELETE /api/v2/billing/apps/:app/features/:key       billing.delete
      GET    /api/v2/billing/apps/:app/reports             billing.read

      GET    /api/v2/public/billing/pricing?pk=            public: an app's public plans
      GET    /api/v2/public/billing/jwks.json              public: keys that verify tokens/licences
]]

local Http = require("helper.field-service-http")
local RateLimit = require("middleware.rate-limit")
local Apps = require("queries.BillingAppQueries")
local Signing = require("lib.billing-signing")
local db = require("lapis.db")

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

-- Public GETs: readable from any origin (no credentials), 60/min per IP.
local function public_get(prefix, handler)
    return function(self)
        local allowed, _, retry = RateLimit.check("billing_pub:" .. prefix .. ":" .. RateLimit.getClientIP(), 60, 60)
        if not allowed then
            return { status = 429, json = { success = false, error = "Too many requests", retry_after = retry } }
        end
        if not ngx.header["Access-Control-Allow-Origin"] then ngx.header["Access-Control-Allow-Origin"] = "*" end
        return handler(self)
    end
end

return function(app)
    app:get("/api/v2/billing/apps", Http.guard("billing", "read", function(self)
        return Http.ok(Apps.list(self.namespace.id))
    end))

    app:post("/api/v2/billing/apps", Http.guard("billing", "create", function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
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

    -- ----------------------------------------------------------------------
    -- Public
    -- ----------------------------------------------------------------------

    app:get("/api/v2/public/billing/pricing", public_get("pricing", function(self)
        local a = Apps.byPublishableKey(self.params.pk)
        if not a then return Http.fail(404, "Unknown publishable key") end
        local plans = db.query([[
            SELECT uuid, plan_key, name, description, plan_type, amount, currency, billing_interval, interval_count,
                   trial_days, features, is_default, sort_order
            FROM billing_plans WHERE app_id = ? AND active AND is_public AND deleted_at IS NULL
            ORDER BY sort_order, amount]], a.id)
        for _, p in ipairs(plans) do p.amount = tonumber(p.amount) end
        return Http.ok({
            app = { uuid = a.uuid, name = a.name, kind = a.kind, mode = a.mode },
            features = Apps.features(a.id),
            plans = require("queries.FieldServiceCommon").arr(plans),
        })
    end))

    app:get("/api/v2/public/billing/jwks.json", public_get("jwks", function()
        ngx.header["Cache-Control"] = "public, max-age=300"
        return { status = 200, json = Signing.jwks() }
    end))
end
