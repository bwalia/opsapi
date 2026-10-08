--[[
    Billing & Entitlements — public endpoints for apps without a back end and
    for the hosted pages (docs/BILLING_ENTITLEMENTS.md §8.3, §9). No secret key:
    the app is identified by its publishable key (or id); the credential is a
    licence key, an access-link token or a customer session.

      GET    /api/v2/public/billing/apps/:app                   public app info (id or pk_…)
      GET    /api/v2/public/billing/jwks.json                   signing keys
      POST   /api/v2/public/licenses/activate                   { pk, license_key, fingerprint_hash, app_version, name?, platform? }
      POST   /api/v2/public/licenses/validate                   { pk, license_key, fingerprint_hash, app_version }
      POST   /api/v2/public/licenses/deactivate                 { pk, license_key, fingerprint_hash }
      POST   /api/v2/public/billing/coupons/check               { pk, code, plan_key }
      POST   /api/v2/public/billing/access-link                 { pk, email, return_url? }  -> always 202
      POST   /api/v2/public/billing/sessions                    { token } -> a 30-minute session
      GET    /api/v2/public/billing/me                          X-Billing-Session
      POST   /api/v2/public/billing/me/licenses/:uuid/reissue   X-Billing-Session
      DELETE /api/v2/public/billing/me/licenses/:uuid/activations/:activation   X-Billing-Session
      POST   /api/v2/public/billing/me/logout                   X-Billing-Session

    Every call: CORS from the app's allowed_origins, rate limits from its
    settings, Idempotency-Key on mutating calls; licence calls also lock out an
    address after repeated bad keys.
]]

local db = require("lapis.db")
local Http = require("helper.field-service-http")
local Apps = require("queries.BillingAppQueries")
local Licenses = require("queries.BillingLicenseQueries")
local Offers = require("queries.BillingOfferQueries")
local Purchases = require("queries.BillingPurchaseQueries")
local Subs = require("queries.BillingSubscriptionQueries")
local Signing = require("lib.billing-signing")
local Settings = require("lib.billing-settings")
local Guard = require("lib.billing-guard")
local ApiKey = require("helper.api-key")
local Common = require("queries.FieldServiceCommon")

local SESSION_MINUTES = 30

local function body_of()
    local body, err = Http.json_body()
    if not body then return nil, Guard.fail(400, "invalid_body", err) end
    return body
end

-- Resolve the app, then apply CORS and the per-IP / per-app limits.
local function public(handler, opts)
    opts = opts or {}
    return function(self)
        local body, berr
        if self.req.method ~= "GET" then
            body, berr = body_of()
            if not body then return berr end
        end
        local ref = self.params.app or self.params.pk or (body and body.pk)
        local app = Apps.findPublic(ref)
        if not app then return Guard.fail(404, "unknown_app", "Unknown app or publishable key") end
        local blocked = Guard.cors(self, app)
        if blocked then return blocked end
        local r = Guard.rates(app)
        local ip = Guard.ip()
        local limited = Guard.limit(app, { { "ip", ip, r.public_per_ip_per_min, 60 }, { "app", "all", r.app_per_min, 60 } })
        if limited then return limited end
        return handler(self, app, body or {}, ip, r)
    end
end

local function token_hash(raw) return ApiKey.hash(raw) end

local function random_token()
    local random = require("resty.random")
    local bytes = random.bytes(32, true) or random.bytes(32)
    return (ngx.encode_base64(bytes):gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- The customer behind X-Billing-Session (for this app).
local function session(self, app)
    local raw = self.req.headers["x-billing-session"]
    if type(raw) ~= "string" or #raw < 20 or #raw > 200 then return nil end
    return db.query([[SELECT s.id, s.customer_id, s.expires_at, c.uuid, c.email, c.external_id
        FROM billing_customer_sessions s JOIN customers c ON c.id = s.customer_id
        WHERE s.token_hash = ? AND s.app_id = ? AND s.expires_at > NOW()]], token_hash(raw), app.id)[1]
end

local function with_session(handler)
    return public(function(self, app, body, ip, r)
        local s = session(self, app)
        if not s then return Guard.fail(401, "session_expired", "Your session has expired: request a new link") end
        return handler(self, app, body, s)
    end)
end

local function public_plans(app)
    local plans = db.query([[
        SELECT uuid, plan_key, name, description, purchase_type, amount, currency, billing_interval, interval_count,
               trial_days, term_days, term_covers, updates_days, features, is_default, sort_order
        FROM billing_plans WHERE app_id = ? AND active AND is_public AND deleted_at IS NULL
        ORDER BY sort_order, amount]], app.id)
    for _, p in ipairs(plans) do p.amount = tonumber(p.amount) end
    return Common.arr(plans)
end

return function(app)
    app:get("/api/v2/public/billing/apps/:app", public(function(self, app)
        local etag = ('"%s-%s"'):format(app.uuid:sub(1, 8), app.cache_generation or 1)
        ngx.header["Cache-Control"] = "public, max-age=300"
        ngx.header["ETag"] = etag
        if self.req.headers["if-none-match"] == etag then return { status = 304, layout = false, "" } end
        local info = Settings.public(app)
        info.uuid, info.name, info.kind, info.mode = app.uuid, app.name, app.kind, app.mode
        info.publishable_key = app.publishable_key
        info.features = Apps.features(app.id)
        info.plans = public_plans(app)
        return Http.ok(info)
    end))

    app:get("/api/v2/public/billing/jwks.json", function()
        local allowed, _, retry = require("middleware.rate-limit").check("billing_jwks:" .. Guard.ip(), 120, 60)
        if not allowed then return Guard.fail(429, "rate_limited", "Too many requests", { retry_after = retry }) end
        ngx.header["Access-Control-Allow-Origin"] = "*"
        ngx.header["Cache-Control"] = "public, max-age=300"
        return { status = 200, json = Signing.jwks() }
    end)

    -- Licences -------------------------------------------------------------

    local function licence_call(name)
        return public(function(self, app, body, ip, r)
            local locked = Guard.lockedOut(app, ip)
            if locked then return locked end
            local key = Licenses.normalize(body.license_key)
            local limited = Guard.limit(app, {
                { "lic_ip", ip, r.licence_per_ip_per_min, 60 },
                key and { "lic_key", key, r.licence_per_key_per_min, 60 } or nil,
            })
            if limited then return limited end
            return Guard.idempotent(self, ("app:%s:licenses:%s"):format(app.id, name), body, function()
                local result, err = Licenses[name](app, body)
                if not result then
                    if err.code == "invalid_license" then Guard.badKey(app, ip) end
                    return Guard.fail(err.status, err.code, err.message)
                end
                return Http.ok(result)
            end)
        end)
    end
    app:post("/api/v2/public/licenses/activate", licence_call("activate"))
    app:post("/api/v2/public/licenses/validate", licence_call("validate"))
    app:post("/api/v2/public/licenses/deactivate", licence_call("deactivate"))

    -- Coupons ----------------------------------------------------------------

    app:post("/api/v2/public/billing/coupons/check", public(function(_, app, body, ip, r)
        local limited = Guard.limit(app, { { "coupon_ip", ip, r.checkout_per_ip_per_hour * 3, 3600 } })
        if limited then return limited end
        local plan = Subs.appPlan(app.id, tostring(body.plan_key or ""))
        if not plan or not plan.is_public then return Guard.fail(404, "unknown_plan", "Unknown plan") end
        local res, code, msg = Offers.checkCoupon(app.namespace_id, app, body.code, plan, plan.amount, plan.currency, nil)
        if not res then return Guard.fail(422, code, msg) end
        return Http.ok({ valid = true, code = res.coupon.code, amount = tonumber(plan.amount), discount = res.discount,
            total = res.total, currency = plan.currency, duration = res.duration, duration_months = res.duration_months })
    end))

    -- Access links + sessions ------------------------------------------------

    app:post("/api/v2/public/billing/access-link", public(function(self, app, body, ip, r)
        if Settings.resolve(app).email_collection == "none" then
            return Guard.fail(400, "access_links_disabled", "This app doesn't collect email addresses")
        end
        local email = type(body.email) == "string" and body.email:lower():match("^%s*(.-)%s*$") or ""
        if not email:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") or #email > 254 then
            return Guard.fail(422, "invalid_email", "Enter a valid email address")
        end
        local return_url = Common.nilify(body.return_url)
        if return_url and not Guard.redirectAllowed(app, return_url) then
            return Guard.fail(422, "redirect_not_allowed", "return_url isn't one of this app's allowed redirect URLs")
        end
        local limited = Guard.limit(app, { { "link_ip", ip, r.access_link_per_ip_per_hour, 3600 },
            { "link_email", email, r.access_link_per_email_per_hour, 3600 } })
        if limited then return limited end
        return Guard.idempotent(self, ("app:%s:access-link"):format(app.id), body, function()
            -- Only customers with billing records in this app get a link; the
            -- answer is the same either way, so emails can't be enumerated.
            local c = db.query([[
                SELECT c.id FROM customers c WHERE c.namespace_id = ? AND lower(c.email) = ?
                  AND (EXISTS (SELECT 1 FROM billing_licenses WHERE customer_id = c.id AND app_id = ?)
                    OR EXISTS (SELECT 1 FROM billing_purchases WHERE customer_id = c.id AND app_id = ?)
                    OR EXISTS (SELECT 1 FROM billing_subscriptions WHERE customer_id = c.id AND app_id = ?)
                    OR EXISTS (SELECT 1 FROM billing_grants WHERE customer_id = c.id AND app_id = ?))
                LIMIT 1]], app.namespace_id, email, app.id, app.id, app.id, app.id)[1]
            if c then
                local uuid = Common.uuid()
                db.insert("billing_access_links", { uuid = uuid, namespace_id = app.namespace_id, app_id = app.id,
                    customer_id = c.id, return_url = return_url or db.NULL,
                    expires_at = db.raw(("NOW() + interval '%d minutes'"):format(require("lib.billing-jobs").LINK_MINUTES)) })
                require("helper.plugin-events").emit(app.namespace_id, "billing.access_link.requested", { link = uuid })
            end
            return { status = 202, json = { success = true,
                data = { message = "If that email has a licence or purchase, a link is on its way." } } }
        end)
    end))

    app:post("/api/v2/public/billing/sessions", public(function(_, app, body, ip)
        local limited = Guard.limit(app, { { "session_ip", ip, 30, 600 } })
        if limited then return limited end
        if type(body.token) ~= "string" or #body.token < 20 or #body.token > 200 then
            return Guard.fail(401, "invalid_link", "This link is invalid or has expired")
        end
        -- Single use: claimed atomically.
        local link = db.query([[UPDATE billing_access_links SET used_at = NOW()
            WHERE token_hash = ? AND app_id = ? AND used_at IS NULL AND expires_at > NOW()
            RETURNING customer_id]], token_hash(body.token), app.id)[1]
        if not link then return Guard.fail(401, "invalid_link", "This link is invalid or has expired") end
        local raw = random_token()
        db.insert("billing_customer_sessions", { app_id = app.id, customer_id = link.customer_id,
            token_hash = token_hash(raw), expires_at = db.raw(("NOW() + interval '%d minutes'"):format(SESSION_MINUTES)) })
        return Http.ok({ session = raw, expires_in = SESSION_MINUTES * 60 }, 201)
    end))

    app:get("/api/v2/public/billing/me", with_session(function(_, app, _, s)
        local purchases, subscriptions = Purchases.forCustomer(app, s.customer_id)
        return Http.ok({
            customer = { email = s.email },
            app = { uuid = app.uuid, name = app.name, kind = app.kind, branding = Settings.public(app) },
            licences = Licenses.forCustomer(app, s.customer_id),
            purchases = purchases,
            subscriptions = subscriptions,
        })
    end))

    app:post("/api/v2/public/billing/me/licenses/:uuid/reissue", with_session(function(self, app, body, s)
        return Guard.idempotent(self, ("app:%s:reissue:%s"):format(app.id, s.customer_id), body, function()
            local res, err = Licenses.reissue(app.namespace_id, self.params.uuid, s.customer_id)
            if not res then return Guard.fail(404, "not_found", err) end
            res.license.customer_email, res.license.customer_external_id = nil, nil
            return Http.ok(res)
        end)
    end))

    app:delete("/api/v2/public/billing/me/licenses/:uuid/activations/:activation", with_session(
        function(self, app, _, s)
            local ok, err = Licenses.removeActivation(app.namespace_id, self.params.uuid, self.params.activation,
                s.customer_id)
            if not ok then return Guard.fail(404, "not_found", err) end
            return Http.ok({ freed = true })
        end))

    app:post("/api/v2/public/billing/me/logout", with_session(function(_, _, _, s)
        db.query("DELETE FROM billing_customer_sessions WHERE id = ?", s.id)
        return Http.ok({ signed_out = true })
    end))
end
