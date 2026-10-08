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
for _, r in ipairs({ "billing-apps", "billing-subscriptions", "billing-licenses" }) do
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

print("URL family = RBAC module (API-key scopes)")
for file, families in pairs({
    ["routes/billing-apps.lua"] = { billing = true },
    ["routes/billing-subscriptions.lua"] = { subscriptions = true, entitlements = true },
    ["routes/billing-licenses.lua"] = { licenses = true },
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
check("activations hide the fingerprint", entities["license.activation"]
    and entities["license.activation"].hide == "fingerprint_hash" and entities["license.activation"].ns_sql ~= nil)

print("customers: email unique per workspace")
local cq = read("queries/CustomerQueries.lua")
check("findByEmail is workspace-scoped", cq:find("function CustomerQueries.findByEmail%(namespace_id, email%)") ~= nil)
check("legacy checkout lookup only sees workspace-less customers",
    read("routes/checkout_enhanced.lua"):find("namespace_id IS NULL") ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
