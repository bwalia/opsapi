--[[
    Spec: Billing & Entitlements (docs/BILLING_ENTITLEMENTS.md).

    Run inside the API container:
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

local function read(path)
    local f = assert(io.open(path))
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
PC.isFeatureEnabled = function(f) return f ~= "billing" end
check("billing templates are hidden where billing isn't deployed",
    #NamespaceMail.listTemplates(1) == 0 and NamespaceMail.preview(1, "billing.access_link") == nil)
PC.isFeatureEnabled = function() return true end
check("and listed where it is", #NamespaceMail.listTemplates(1) == 2)
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
local delivery = read("lib/billing-delivery.lua")
check("keys wait encrypted (AES-256-GCM, licence id as AAD) for at most 24 h",
    delivery:find('"aes-256-gcm"', 1, true) and delivery:find("tostring(license_id)", 1, true)
        and delivery:find("interval '24 hours'", 1, true) ~= nil)
check("revealed once: claimed by an UPDATE ... revealed_at IS NULL",
    delivery:find("revealed_at IS NULL AND expires_at > NOW() RETURNING", 1, true) ~= nil)

print("customers: email unique per workspace")
local cq = read("queries/CustomerQueries.lua")
check("findByEmail is workspace-scoped", cq:find("function CustomerQueries.findByEmail%(namespace_id, email%)") ~= nil)
check("legacy checkout lookup only sees workspace-less customers",
    read("routes/checkout_enhanced.lua"):find("namespace_id IS NULL") ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
