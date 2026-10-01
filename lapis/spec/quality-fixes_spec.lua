--[[
    Regression spec for the 2026-10 quality sweep: a 5xx inventory of every
    route found input errors answered with 500, endpoints broken for every
    caller, SQL injection, SSRF, a forgeable Stripe webhook, platform roles
    deletable by workspace admins, and quoted column defaults corrupting data.

    Standalone, from the repo root (in the image, for lapis/cjson):
        docker run --rm -v "$PWD:/w" -w /w lapis-lapis luajit lapis/spec/quality-fixes_spec.lua
]]

local failures = 0
local function check(name, ok, detail)
    print((ok and "  ok   - " or "  FAIL - ") .. name .. ((not ok and detail) and ("  (" .. tostring(detail) .. ")") or ""))
    if not ok then failures = failures + 1 end
end
local function read(path)
    local f = assert(io.open(path))
    local s = f:read("*a")
    f:close()
    return s
end
local function files(dir)
    local out = {}
    local h = io.popen("ls " .. dir .. "/*.lua")
    for line in h:lines() do out[#out + 1] = line end
    h:close()
    return out
end

package.path = "lapis/?.lua;" .. package.path
_G.ngx = { log = function() end, NOTICE = 1, ERR = 2, WARN = 3, now = os.time, time = os.time }
package.loaded["lib.error_catalog"], package.loaded["lib.error_locale"], package.loaded["lib.error_occurrence"] = {}, {}, {}
package.loaded["helper.global"] = { generateUUID = function() return "u" end }
local Errors = dofile("lapis/lib/errors.lua")

-- ── input errors are 4xx, never 500 ────────────────────────────────────────
print("Errors.classify")
local function c(s)
    local r = Errors.classify(s)
    return r and (r.status .. " " .. r.context.reason) or "nil"
end
check("malformed integer id -> 400", c('q\nERROR: invalid input syntax for type integer: "abc"') == "400 invalid_format")
check("malformed uuid -> 400", c('q\nERROR: invalid input syntax for type uuid: "x"') == "400 invalid_format")
check("number out of range -> 400", c('q\nERROR: value "99999999999" is out of range for type integer') == "400 out_of_range")
check("missing required column -> 422 naming the field",
    Errors.classify('q\nERROR: null value in column "email" of relation "customers" violates not-null constraint').context.field == "email")
check("check constraint -> 422", c('q\nERROR: new row for relation "t" violates check constraint "t_status_check"') == "422 invalid_value")
check("duplicate -> 409", c('q\nERROR: duplicate key value violates unique constraint "k"') == "409 duplicate")
check("still referenced -> 409", c('q\nERROR: update or delete on table "a" violates foreign key constraint "f"') == "409 still_referenced")
check("unknown reference -> 422", c('q\nERROR: insert or update on table "b" violates foreign key constraint "f"') == "422 reference_missing")
check("lapis assert_valid -> 422", c("x.lua:1: assert_valid was not captured: name must be provided") == "422 invalid")
check("Errors.invalid -> 422 with its message",
    (function() local ok, e = pcall(Errors.invalid, "Store name is required"); return Errors.classify(e) end)().message
        == "Store name is required")
check("Errors.conflict -> 409", (function() local ok, e = pcall(Errors.conflict, "exists"); return c(e) end)() == "409 conflict")
check("only Postgres' own ERROR text counts, never the SQL echoing user data",
    c("SELECT 'violates not-null constraint'\nERROR: column r.name does not exist") == "nil")
check("genuine bugs stay 500", c("attempt to index a nil value") == "nil")

print("Errors.legacy")
local leaked = Errors.legacy(500, "Failed to create customer",
    'INSERT INTO "customers" VALUES (\'ada@example.com\')\nERROR: something else broke')
check("a 500 never echoes the raw error (SQL + user data)", leaked.status == 500 and leaked.json.details == nil
    and leaked.json.error == "Failed to create customer")
local input = Errors.legacy(500, "Failed", 'q\nERROR: null value in column "email" of relation "c" violates not-null constraint')
check("an input error becomes 4xx, error still a string", input.status == 422 and type(input.json.error) == "string")
check("4xx details written by the route are kept", Errors.legacy(400, "Bad", "name is required").json.details == "name is required")

-- ── exact role names (no substring "admin") ────────────────────────────────
print("AdminCheck.hasAnyRole")
local queried = 0
package.loaded["lapis.db"] = { query = function() queried = queried + 1; return {} end }
local AdminCheck = dofile("lapis/helper/admin-check.lua")
check("exact JWT role matches", AdminCheck.hasAnyRole({ roles = "member,tax_admin" }, { "administrative", "tax_admin" }))
check("substring doesn't ('tax_administrator' is not 'tax_admin')",
    not AdminCheck.hasAnyRole({ roles = "tax_administrator", uuid = "u" }, { "tax_admin" }))
check("table claims work", AdminCheck.hasAnyRole({ roles = { { role_name = "administrative" } } }, { "administrative" }))
queried = 0
AdminCheck.hasAnyRole({ roles = "member", uuid = "u-1" }, { "tax_admin" })
check("falls back to the database when the token doesn't say", queried == 1)
local routes_src = {}
for _, f in ipairs(files("lapis/routes")) do routes_src[f] = read(f) end
local stale = 0
for f, s in pairs(routes_src) do
    if s:find("SELECT r.name FROM roles r", 1, true) or s:find('roles:match("admin")', 1, true) then stale = stale + 1 end
end
check("no route keeps its own (broken) admin check", stale == 0, stale)

-- ── SQL injection ───────────────────────────────────────────────────────────
print("SQL injection")
local quoted_concat = {}
for _, dir in ipairs({ "lapis/queries", "lapis/routes" }) do
    for _, f in ipairs(files(dir)) do
        local s = read(f)
        if s:find("'\" %.%. params%.") or s:find("'\" %.%. self%.params%.")
            or s:find("'\" %.%. db%.escape_literal") or s:find("'%%\" %.%. db%.escape_literal") then
            quoted_concat[#quoted_concat + 1] = f
        end
    end
end
check("no request value concatenated inside SQL quotes", #quoted_concat == 0, table.concat(quoted_concat, ", "))
local sp = read("lapis/queries/StoreproductQueries.lua")
check("product list ORDER BY is whitelisted", not sp:find('params.orderBy or', 1, true) and sp:find("PRODUCT_SORT", 1, true))
check("chat channel ORDER BY is whitelisted", not read("lapis/queries/ChatChannelQueries.lua"):find('params.orderBy or "created_at"', 1, true))
check("public store product search is bound, not concatenated",
    read("lapis/routes/public-store.lua"):find('where[#where + 1] = "category = ?"', 1, true) ~= nil)
local double_select = 0
for f, s in pairs(routes_src) do
    if s:find("db%.select%(%s*%[%[%s*SELECT") then double_select = double_select + 1 end
end
check("no db.select(\"SELECT ...\") (lapis adds SELECT itself)", double_select == 0, double_select)

-- ── security fixes ──────────────────────────────────────────────────────────
print("security")
local roles = routes_src["lapis/routes/roles.lua"]
local _, admin_routes = roles:gsub('admin_only%(function', "")
check("platform roles: all five routes are platform-admin only", admin_routes == 5
    and roles:find('AuthMiddleware.requireRole("administrative"', 1, true))
check("platform roles: built-in roles can't be deleted", roles:find("Built-in roles can't be deleted", 1, true) ~= nil)
local stripe = routes_src["lapis/routes/stripe-webhook.lua"]
check("ecommerce Stripe webhook verifies the signature", stripe:find('construct_event(body', 1, true)
    and not stripe:find("-- return { json = { error = \"No signature\" }", 1, true))
check("Stripe diagnostics are platform-admin only", routes_src["lapis/routes/payments.lua"]:find("stripe_diagnostic", 1, true) ~= nil)
check("products: another workspace's store is refused",
    sp:find('Errors.invalid("Store not found in this workspace")', 1, true) ~= nil)
check("products/stores: only allow-listed columns are written",
    sp:find("PRODUCT_WRITABLE", 1, true) and read("lapis/queries/StoreQueries.lua"):find("STORE_WRITABLE", 1, true))

print("SSRF")
local W = dofile("lapis/lib/outbound-webhooks.lua")
check("https public URL ok", W.parseUrl("https://hooks.example.com/x") ~= nil)
check("http refused by default", W.parseUrl("http://hooks.example.com/x") == nil)
check("http allowed when asked (CMS webhooks), public hosts only",
    W.parseUrl("http://hooks.example.com/x", { allow_http = true }) ~= nil
    and W.parseUrl("http://169.254.169.254/latest", { allow_http = true }) == nil
    and W.parseUrl("http://redis.svc/x", { allow_http = true }) == nil)
check("private allowed only by explicit opt-in", W.parseUrl("http://10.0.0.5:8200", { allow_private = true }) ~= nil)
check("CMS webhooks deliver through the guard",
    read("lapis/lib/webhook-dispatcher.lua"):find('require("lib.outbound-webhooks").send(', 1, true) ~= nil)
local guarded = 0
for _, p in ipairs({ "hashicorp", "azure", "kubernetes" }) do
    local s = read("lapis/lib/vault-providers/" .. p .. ".lua")
    if s:find('require("lib.outbound-webhooks").request(url, params, VAULT_HTTP_OPTS)', 1, true)
        and not s:find("request_uri", 1, true) then guarded = guarded + 1 end
end
check("vault providers with user-set URLs go through the guard", guarded == 3, guarded)
check("Simpro base URL checked and requests guarded",
    read("lapis/queries/SimproSyncQueries.lua"):find('parseUrl(base_url)', 1, true)
    and not read("lapis/helper/simpro-client.lua"):find("request_uri", 1, true))

-- ── data / schema ───────────────────────────────────────────────────────────
print("schema")
check("schema repair runs on every migrate", read("lapis/migrations.lua"):find('require("helper.schema-repair").run()', 1, true) ~= nil)
local repair = read("lapis/helper/schema-repair.lua")
check("quoted defaults repaired (default + exact-value rows only)",
    repair:find("ALTER COLUMN", 1, true) and repair:find('" WHERE " .. C .. "::text = " .. db.escape_literal(bad)', 1, true))
check("columns the code expects are ensured", repair:find('{ "order_delivery_assignments", "accepted_at"', 1, true)
    and repair:find('{ "orders", "delivery_latitude"', 1, true))
check("workspace owners get namespace.manage (core module + backfill)",
    read("lapis/helper/project-config.lua"):find('machine_name = "namespace"', 1, true)
    and read("lapis/migrations/namespace-module.lua"):find('grant("owner", \'["manage"]\')', 1, true))
check("statements work without diy's dms_documents",
    read("lapis/queries/TaxStatementQueries.lua"):find('require("helper.table-exists")("dms_documents")', 1, true) ~= nil)

-- ── dark mode ───────────────────────────────────────────────────────────────
print("theme")
package.loaded["helper.theme-token-schema"] = {
    COLOR_SCALE_KEYS = { "500" },
    SCHEMA = { colors = { primary = { type = "color_scale" }, secondary = { type = "color_scale" },
        background = { type = "color" } } },
}
package.loaded["helper.css-sanitizer"] = { sanitise = function(s) return s end }
local Renderer = dofile("lapis/lib/theme-renderer.lua")
local css = Renderer.render({ tokens = { colors = { primary = { ["500"] = "#f00" }, secondary = { ["500"] = "#333" },
    background = "#fff" } } }, { theme_uuid = "t1" })
local light = css:match(':root%[data%-theme%-id="t1"%]:not%(%.dark%), :root:not%(%.dark%) {(.-)}')
local brand = css:match(':root%[data%-theme%-id="t1"%], :root {(.-)}')
check("surface colours apply in light mode only", light and light:find("--color-background", 1, true)
    and light:find("--color-secondary-500", 1, true) and not light:find("--color-primary", 1, true))
check("brand colours apply in both modes", brand and brand:find("--color-primary-500", 1, true)
    and not brand:find("--color-background", 1, true))
check("cache keys follow the renderer version", read("lapis/helper/theme-cache.lua"):find('require("lib.theme-renderer").VERSION', 1, true)
    and read("opsapi-dashboard/components/layout/ThemeStyles.tsx"):find("&f=${CSS_FORMAT}", 1, true))

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
