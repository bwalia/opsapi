--[[
    Spec: Billing & Entitlements (docs/BILLING_ENTITLEMENTS.md).

    Run inside the API container (or from the repo root: luajit lapis/spec/billing-entitlements_spec.lua):
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/billing-entitlements_spec.lua

    Static/unit checks only (ES256 needs nginx's OpenSSL; the signing and
    licence lifecycle were verified live with `lapis exec`, see the PR).
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path
local cjson = require("cjson")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

ngx = setmetatable({ log = function() end, ERR = 3, time = os.time, now = os.time, ctx = {}, var = {} }, -- luacheck: ignore 111
    { __index = function() return function() end end })
package.loaded["lapis.db"] = setmetatable({}, { __index = function() return function() return {} end end })
for _, m in ipairs({ "models.BillingSubscriptionModel", "models.BillingPlanModel", "models.CustomerModel" }) do
    package.loaded[m] = {}
end

-- Paths are relative to lapis/; CI runs specs from the repo root.
local function read(path)
    local f = assert(io.open(path) or io.open("lapis/" .. path), path)
    local s = f:read("*a")
    f:close()
    return s
end

print("entitlement merge")
local Ent = require("helper.entitlement-service")
local catalog = { reports = "boolean", projects = "limit", seats = "limit" }
local out = { reports = false, projects = 0, seats = 0 }
Ent.merge(out, catalog, { reports = false, projects = 3, seats = 5 })
Ent.merge(out, catalog, { reports = true, projects = 10, unknown = true })
Ent.merge(out, catalog, { reports = false, seats = cjson.null })
Ent.merge(out, catalog, { seats = 99 })
check("on/off: on if any source turns it on", out.reports == true)
check("limits: the largest wins", out.projects == 10)
check("limits: null = unlimited beats any number", out.seats == cjson.null)
check("features outside the catalogue are dropped", out.unknown == nil)
check("non-table values are ignored", Ent.merge({ projects = 1 }, catalog, "x").projects == 1)

print("features released after the updates window")
local cat = { old = { type = "boolean", released = 100 }, new = { type = "boolean", released = 300 }, plain = "boolean" }
local got = Ent.merge({ old = false, new = false, plain = false }, cat, { old = true, new = true, plain = true }, 200)
check("released before updates_until: included", got.old == true and got.plain == true)
check("released after updates_until: left out", got.new == false)
check("no updates_until (subscription / unlimited): everything", Ent.merge({ new = false }, cat, { new = true }).new == true)

print("app settings (lib/billing-settings.lua)")
local Settings = require("lib.billing-settings")
local desk = Settings.resolve({ kind = "desktop", name = "D", settings = {} })
local web = Settings.resolve({ kind = "web", name = "W", settings = {} })
check("defaults by kind: desktop 30 days grace / 3 devices / fail_closed",
    desk.grace_days == 30 and desk.max_activations == 3 and desk.offline_policy == "fail_closed")
check("defaults by kind: web 3 days grace / unlimited devices / email required",
    web.grace_days == 3 and web.max_activations == cjson.null and web.email_collection == "required")
check("stored values win; objects merge with their defaults",
    Settings.resolve({ kind = "web", name = "W", settings = { grace_days = 9, rate_limits = { app_per_min = 5 } } }).grace_days == 9
    and Settings.resolve({ kind = "web", name = "W", settings = { rate_limits = { app_per_min = 5 } } }).rate_limits.licence_per_ip_per_min == 30)
check("unknown setting refused", select(2, Settings.merge({}, { nope = 1 })) ~= nil)
check("read-only setting refused", select(2, Settings.merge({}, { fingerprint_salt = "x" })) ~= nil)
check("out of range refused", select(2, Settings.merge({}, { grace_days = 999 })) ~= nil)
check("bad origin refused", select(2, Settings.merge({}, { allowed_origins = { "javascript:alert(1)" } })) ~= nil)
check("good origin accepted", Settings.merge({}, { allowed_origins = { "https://app.example.com" } }) ~= nil)
check("unknown rate-limit field refused", select(2, Settings.merge({}, { rate_limits = { nope = 1 } })) ~= nil)
check("public view has no secrets", Settings.public({ kind = "web", name = "W", settings = {} }).rate_limits == nil)

print("workspace email templates")
local NamespaceMail = require("helper.namespace-mail")
check("placeholders are HTML-escaped", NamespaceMail.fill("<p>{{name}}</p>", { name = "<b>x</b>" }) == "<p>&lt;b&gt;x&lt;/b&gt;</p>")
check("subjects stay plain, one line", NamespaceMail.fill("Hi {{name}}", { name = "a\nb" }, true) == "Hi a b")
check("unknown placeholders are empty", NamespaceMail.fill("{{nope}}!", {}) == "!")
check("every template names its variables and default file",
    (function() for _, t in pairs(NamespaceMail.TEMPLATES) do if not (t.file and t.subject and #t.variables > 0) then return false end end return true end)())
local PC = require("helper.project-config")
local enabled = PC.isFeatureEnabled
-- Other features add their own templates (forms, invitations): count billing's.
local function billing_listed()
    local n = 0
    for _, t in ipairs(NamespaceMail.listTemplates(1)) do
        if t.key:match("^billing%.") then n = n + 1 end
    end
    return n
end
PC.isFeatureEnabled = function(f) return f ~= "billing" end
check("billing templates are hidden where billing isn't deployed",
    billing_listed() == 0 and NamespaceMail.preview(1, "billing.access_link") == nil)
PC.isFeatureEnabled = function() return true end
check("and listed where it is", billing_listed() == 2)
PC.isFeatureEnabled = enabled

print("licence keys")
local Licenses = require("queries.BillingLicenseQueries")
check("typed keys normalise (case, dashes, spaces)",
    Licenses.normalize(" kw638-zeph5 2nuhf-exjy6-wy6nm ") == "KW638ZEPH52NUHFEXJY6WY6NM")
check("wrong length is refused", Licenses.normalize("ABCDE-FGHJK") == nil and Licenses.normalize(nil) == nil)

print("signing without a key")
local Signing = require("lib.billing-signing")
check("not configured without BILLING_SIGNING_KEY", Signing.configured() == false)
local token, err = Signing.sign("opsapi-entitlements+jwt", { sub = "x" })
check("nothing is signed (no fallback key)", token == nil and err == "not configured")
check("empty JWKS", #Signing.jwks().keys == 0)
check("empty feature map stays a JSON object", Signing.encode({}) == "{}")

print("gating")
local ProjectConfig = require("helper.project-config")
check("BILLING feature flag", ProjectConfig.FEATURES.BILLING == "billing")
local modules = {}
for _, m in ipairs(ProjectConfig.PROJECT_MODULES.billing or {}) do modules[m.machine_name] = true end
check("RBAC modules = route families", modules.billing and modules.subscriptions and modules.entitlements
    and modules.licenses and modules.customers)
local app_lua = read("app.lua")
for _, r in ipairs({ "billing-apps", "billing-subscriptions", "billing-licenses", "billing-public", "billing-privacy",
    "billing-payments" }) do
    check("routes." .. r .. " loads only under billing", app_lua:find('load_if("billing", "routes.' .. r .. '")', 1, true) ~= nil)
end
check("customers + plans also load for billing",
    app_lua:find('load_if%({ "ecommerce", "billing" }, "routes%.customers"%)') ~= nil
        and app_lua:find('load_if%({ "tax_copilot", "billing" }, "routes%.billing%-plans"%)') ~= nil)
check("tax checkout/webhook stay tax-only", app_lua:find('load_if%("tax_copilot", "routes%.billing%-webhook"%)') ~= nil)
local migrations = read("migrations.lua")
for i = 1, 8 do
    check("migration zzbe" .. i .. " gated on BILLING",
        migrations:find("%['zzbe" .. i .. "_[%w_]+'%] = conditional_array%(ProjectConfig%.FEATURES%.BILLING") ~= nil)
end
for i = 1, 6 do
    check("v2 migration zzbf" .. i .. " gated on BILLING",
        migrations:find("%['zzbf" .. i .. "_[%w_]+'%] = conditional_array%(ProjectConfig%.FEATURES%.BILLING") ~= nil)
end
check("workspace mail tables are core", migrations:find("%['zznm1_[%w_]+'%] = conditional_array%(ProjectConfig%.FEATURES%.CORE") ~= nil)

print("URL family = RBAC module (API-key scopes)")
for file, families in pairs({
    ["routes/billing-apps.lua"] = { billing = true },
    ["routes/billing-subscriptions.lua"] = { subscriptions = true, entitlements = true },
    ["routes/billing-licenses.lua"] = { licenses = true },
    ["routes/billing-public.lua"] = {},
    ["routes/billing-privacy.lua"] = { customers = true },
    ["routes/billing-payments.lua"] = { billing = true },
}) do
    local src = read(file)
    local ok, bad = true, nil
    for path in src:gmatch('app:%a+%("(/api/v2/[^"]+)"') do
        local seg = path:match("^/api/v2/([^/]+)")
        if seg ~= "public" and not families[seg] then ok, bad = false, path end
    end
    for module in src:gmatch('Http%.guard%("([%w_]+)"') do
        if not families[module] then ok, bad = false, "guard " .. module end
    end
    check(file .. ": every route's first segment is its module", ok, bad)
end

print("webhooks")
local PluginEvents = require("helper.plugin-events")
local entities = {}
for _, e in ipairs(PluginEvents.CATALOG) do entities[e.entity] = e end
check("subscription events", entities.subscription and entities.subscription.module == "subscriptions"
    and entities.subscription.verbs.activated ~= nil)
check("licence events hide the key hash", entities.license and entities.license.hide == "key_hash")
check("computed license.issued / license.reissued events", (function()
    local ev = table.concat(PluginEvents.entityEvents("license", {}), ",")
    return ev:find("license.issued", 1, true) and ev:find("license.reissued", 1, true)
end)())
check("activations hide the fingerprint", entities["license.activation"]
    and entities["license.activation"].hide == "fingerprint_hash" and entities["license.activation"].ns_sql ~= nil)
check("purchase.refunded / purchase.revoked events", entities.purchase and entities.purchase.module == "subscriptions"
    and entities.purchase.verbs.refunded ~= nil and entities.purchase.verbs.revoked ~= nil)
check("licence key emails ride the outbox", read("helper/plugin-events.lua"):find('"billing.licence_key.requested"', 1, true) ~= nil
    and require("lib.billing-jobs").handlers["billing.licence_key.requested"] ~= nil)

print("payments")
local pay_routes = read("routes/billing-payments.lua")
check("Stripe webhook dedupes in its own id space (the tax webhook sees the same platform events)",
    pay_routes:find('"billing:" .. tostring(event.id)', 1, true) ~= nil)
check("webhook payload is not stored (customer data)", pay_routes:find("payload = { id = event.id, type = event.type }", 1, true) ~= nil)
local pay = read("lib/billing-stripe.lua")
check("destination charges: money to the seller, seller is merchant of record",
    pay:find("transfer_data = { destination = acct.stripe_account_id }", 1, true) ~= nil
        and pay:find("on_behalf_of = acct.stripe_account_id", 1, true) ~= nil)
check("every Stripe write is idempotent", (function()
    for call in pay:gmatch('s:_request%("POST",.-%)\n') do
        if not call:find("opsapi%-") and not call:find("account_links") and not call:find("billing_portal") then return false end
    end
    return true
end)())
check("fulfilment runs once per checkout session", pay:find("pg_advisory_xact_lock", 1, true) ~= nil)
check("billing's Stripe calls verify TLS unless STRIPE_SSL_VERIFY=false (they carry the secret key)",
    pay:find('client.ssl_verify = os.getenv("STRIPE_SSL_VERIFY") ~= "false"', 1, true) ~= nil
        and read("nginx.conf"):find("env STRIPE_SSL_VERIFY;", 1, true) ~= nil)
local delivery = read("lib/billing-delivery.lua")
check("keys wait encrypted (AES-256-GCM, licence id as AAD) for at most 24 h",
    delivery:find('"aes-256-gcm"', 1, true) and delivery:find("tostring(license_id)", 1, true)
        and delivery:find("interval '24 hours'", 1, true) ~= nil)
check("revealed once: decrypted first, then claimed by an UPDATE ... revealed_at IS NULL",
    delivery:find("local raw, err = decrypt(row)", 1, true) and delivery:find("WHERE license_id = ? AND revealed_at IS NULL RETURNING", 1, true) ~= nil)

print("customers: email unique per workspace")
local cq = read("queries/CustomerQueries.lua")
check("findByEmail is workspace-scoped", cq:find("function CustomerQueries.findByEmail%(namespace_id, email%)") ~= nil)
check("legacy checkout lookup only sees workspace-less customers",
    read("routes/checkout_enhanced.lua"):find("namespace_id IS NULL") ~= nil)

print("review fixes (2026-10-08)")
local offers = read("queries/BillingOfferQueries.lua")
local purchases = read("queries/BillingPurchaseQueries.lua")
local stripe_lib = read("lib/billing-stripe.lua")
-- B1
check("B1 coupons: a checkout reserves a use atomically, fulfilment confirms it, expiry gives it back",
    offers:find("function Offers.reserve", 1, true) and offers:find("function Offers.confirm", 1, true)
        and offers:find("function Offers.release", 1, true) and stripe_lib:find('["checkout.session.expired"]', 1, true)
        and stripe_lib:find("Offers.release(reservation)", 1, true) ~= nil)
check("B1 no forced redemption; the Stripe coupon carries max_redemptions / redeem_by; sessions expire in 31 min",
    not purchases:find("force_coupon", 1, true) and stripe_lib:find("body.max_redemptions", 1, true)
        and stripe_lib:find("body.redeem_by", 1, true) and stripe_lib:find("SESSION_SECONDS = 31 * 60", 1, true) ~= nil)
check("B1 anonymous buyers: per-customer limits by email", offers:find("email_norm = ?", 1, true) ~= nil
    and stripe_lib:find('"email_required"', 1, true) ~= nil)
-- B2 / B3
local live = Ent.liveSubscriptionSql("s")
check("B2 active subscriptions entitle only until the period ends", live:find("s.current_period_end IS NULL", 1, true)
    and live:find("s.current_period_end + CASE WHEN s.source = 'stripe'", 1, true) ~= nil)
check("B3 past_due grace counts from past_due_since", live:find("COALESCE(s.past_due_since, s.updated_at) + make_interval(days => ?)", 1, true) ~= nil)
check("B2 the same rule in currentPlan and licence checks; lapsed manual/store subscriptions end",
    purchases:find('liveSubscriptionSql("s")', 1, true) and read("queries/BillingLicenseQueries.lua"):find("liveSubscriptionSql", 1, true)
        and read("lib/billing-jobs.lua"):find("function Jobs.lapseSubscriptions", 1, true) ~= nil)
-- B4 / B5
check("B4 webhook transactions that roll back raise (Stripe retries)",
    stripe_lib:find('if not ok then error("subscription sync failed: "', 1, true)
        and stripe_lib:find('if not ok then error("refund failed: "', 1, true) ~= nil)
check("B4 a refund seen before fulfilment is recorded and applied by fulfilment",
    stripe_lib:find("INSERT INTO billing_stripe_refunds", 1, true) and stripe_lib:find("DELETE FROM billing_stripe_refunds", 1, true) ~= nil)
check("B5 subscription events apply in order; an ended subscription never comes back",
    stripe_lib:find("created < tonumber(row.last_event_epoch)", 1, true) and stripe_lib:find('row.status == "canceled" and row.ended_at', 1, true) ~= nil)
-- B6
local lic_src = read("queries/BillingLicenseQueries.lua")
check("B6a no raw key in events: the webhook sender decrypts it", not lic_src:find("data.key = key", 1, true)
    and read("lib/outbound-webhooks.lua"):find("forWebhook(data.uuid)", 1, true) ~= nil)
package.loaded["helper.redis-client"] = package.loaded["helper.redis-client"] or { connect = function() return nil end }
local okg, Guard = pcall(require, "lib.billing-guard")
if okg then
    local r = Guard._redact({ success = true, data = { key = "AAAAA-BBBBB", license = { uuid = "x" } } })
    check("B6b stored idempotent responses never hold a key", r.data.key == nil and r.data.key_redacted == true and r.data.license.uuid == "x")
    -- B17
    local A = { kind = "web", name = "A", settings = { allowed_redirect_urls = { "https://shop.example/account" } } }
    local function allowed(u) return Guard.redirectAllowed(A, u) end
    check("B17 redirects: the allowed path and below it", allowed("https://shop.example/account") and allowed("https://shop.example/account/done?x=1"))
    check("B17 redirects: no prefix tricks, other hosts/ports, dot segments or userinfo",
        not allowed("https://shop.example/accounts") and not allowed("https://shop.example.evil.com/account")
            and not allowed("https://shop.example:8443/account") and not allowed("https://shop.example/account/../admin")
            and not allowed("https://shop.example/account/%2e%2e/admin") and not allowed("https://user@shop.example/account")
            and not allowed("http://shop.example/account"))
else
    check("lib/billing-guard loads in the spec", false, Guard)
end
-- B7
check("B7 a purchase records its licence; refunds undo exactly that", purchases:find("UPDATE billing_purchases SET license_id = ?", 1, true)
    and purchases:find("local function release_licence", 1, true) and not purchases:find("WHERE purchase_id = ? AND status <> 'revoked'\", purchase.id", 1, true))
-- B8
local Common = require("queries.FieldServiceCommon")
local ran = false
Common.transaction(function() Common.afterCommit(function() ran = true end); check("B8 after-commit work waits for the commit", ran == false); return true end)
check("B8 ... and runs after it", ran == true)
local ran2 = false
Common.transaction(function() Common.afterCommit(function() ran2 = true end); return nil, "rolled back" end)
check("B8 ... and never after a rollback", ran2 == false)
check("B8 the plan generation is bumped after the save", read("routes/billing-plans.lua"):find("After the save: bumped before it", 1, true) ~= nil)
-- B9 / B10
check("B9 Stripe switches invoice now and apply once paid", stripe_lib:find('proration_behavior = "always_invoice"', 1, true)
    and stripe_lib:find('payment_behavior = "pending_if_incomplete"', 1, true) and purchases:find("summary.pending = true", 1, true) ~= nil)
local has_promo = false
for _, sp in ipairs(Settings.SCHEMA) do has_promo = has_promo or sp.key == "allow_promotion_codes" end
check("B10 no platform promotion codes (they'd break the fee and be shared by every seller)", not has_promo
    and not stripe_lib:find("allow_promotion_codes", 1, true))
-- B11
local hold_spec
for _, sp in ipairs(Settings.SCHEMA) do if sp.key == "released_seat_hold_days" then hold_spec = sp end end
check("B11 released seats keep counting for a configurable hold (app setting)", hold_spec ~= nil and hold_spec.nullable == true
    and lic_src:find("released_by IN ('device', 'customer')", 1, true) ~= nil)
-- B12 / B13 / B14 / B15 / B16
check("B12 app plans need billing.read; another workspace's app plan is a 404", read("routes/billing-plans.lua"):find('has_perm(self, "billing", "read")', 1, true)
    and read("routes/billing-plans.lua"):find('if app_plan then return api_response(404', 1, true) ~= nil)
local mig = read("migrations/billing-entitlements.lua")
check("B13 transaction ids are unique per app", mig:find("billing_purchases (app_id, source, external_transaction_id)", 1, true)
    and purchases:find("WHERE app_id = ? AND source = ?", 1, true) ~= nil)
check("B14 fixed-term stacking is locked per (app, customer, plan)", purchases:find("opsapi.billing.stack:", 1, true) ~= nil)
local privacy = read("queries/BillingPrivacyQueries.lua")
check("B15 erase drops key deliveries and Stripe customer links; Stripe down -> 502", privacy:find("DELETE FROM billing_key_deliveries", 1, true)
    and privacy:find("stripe_customer_id = NULL", 1, true) and privacy:find("perr.status or 502", 1, true) ~= nil)
check("B16 account-page reissue / free a device stay within the session's app", lic_src:find("(?::bigint IS NULL OR l.app_id = ?::bigint)", 1, true) ~= nil)
-- B18
local signing = read("lib/billing-signing.lua")
check("B18 kid and issuer are required; old keys publish public members only", signing:find('not jwk.kid or not env("OPSAPI_PUBLIC_URL")', 1, true)
    and signing:find("kty = k.kty, crv = k.crv, x = k.x, y = k.y", 1, true) and not read("helper/entitlement-service.lua"):find("ngx.var.http_host", 1, true))
-- B19
local Lic = require("queries.BillingLicenseQueries")
check("B19 device names are cut on a UTF-8 boundary", Lic._utf8_cut("ab\xC3\xA9", 3) == "ab" and Lic._utf8_cut("abc", 3) == "abc")
check("B19 URL settings anchor the host", Settings._url_ok("https://app.example.com/x") and Settings._url_ok("http://localhost:3000/a")
    and not Settings._url_ok("http://localhost.evil.com") and not Settings._url_ok("https://example"))
check("B19 list settings must be arrays", select(2, Settings.merge({}, { allowed_origins = { a = "https://x.example" } })) ~= nil)
local CQ = require("queries.CustomerQueries")
check("B19 emails the customers table would reject are refused up front", CQ.validEmail("a.b+c@x.co") and not CQ.validEmail("o'b@x.com")
    and not CQ.validEmail("a@localhost"))
check("B19 MenuQueries uses a private cjson", read("queries/MenuQueries.lua"):find('require("cjson").new()', 1, true) ~= nil)
check("B19 idempotency is bound to the caller", read("lib/billing-guard.lua"):find('headers["x-billing-session"]', 1, true) ~= nil)
check("B19 access links: the job, not the request, looks the email up", read("routes/billing-public.lua"):find("email_norm = email", 1, true)
    and read("lib/billing-jobs.lua"):find("l.customer_id IS NULL", 1, true) ~= nil)
check("B19 the tax webhook leaves app-billing objects alone", read("routes/billing-webhook.lua"):find("belongs_to_app_billing(object)", 1, true) ~= nil)
check("B19 lost disputes follow refund_policy; webhook mode must match", stripe_lib:find('["charge.dispute.closed"]', 1, true)
    and read("routes/billing-payments.lua"):find("event mode does not match", 1, true) ~= nil)
check("B19 deleting a customer with purchases is a 409", read("routes/customers.lua"):find("error_response(409", 1, true) ~= nil)
check("B19 fixed upgrade paths use the plan's currency", offers:find("currency must be the plan's currency", 1, true) ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
