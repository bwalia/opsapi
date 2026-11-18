--[[
    Spec: the ⌘K record search (lib/global-search.lua).

    Standalone (no busted). From the repo root:
        luajit lapis/spec/global-search_spec.lua
    Covers the registry, query cleaning and LIKE escaping, permission and table gating, a failing provider
    left out without breaking the others, the per-group limit, and that every built-in provider is
    namespace-scoped. The SQL itself runs against a real database in the INT check.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
local logged = {}
ngx = ngx or { log = function(_, ...) logged[#logged + 1] = table.concat({ ... }) end, ERR = 3, -- luacheck: ignore 111
    escape_uri = function(s) return s end }

local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
local missing = {}
package.loaded["lapis.db"] = { NULL = NULL, query = function() return {} end }
package.loaded["helper.table-exists"] = function(t, c) return not missing[c and (t .. "." .. c) or t] end
local perms = {}
package.loaded["middleware.namespace"] = {
    hasPermission = function(_, module, action) return perms[module .. "." .. action] == true end,
}

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local Search = require("lib.global-search")

check("query is trimmed and squashed", Search.clean("  acme \n  ltd ") == "acme ltd")
check("too short → nil", Search.clean("a") == nil and Search.clean("  ") == nil and Search.clean(nil) == nil)
check("long query is cut", #Search.clean(("x"):rep(500)) == Search.MAX_QUERY)
check("LIKE wildcards escaped", Search.like("50%_off\\") == "%50\\%\\_off\\\\%")
check("join skips blanks and NULL", Search.join(" · ", "a", nil, "", NULL, "b") == "a · b")

-- built-ins registered, every one namespace-scoped
local keys = {}
for _, p in ipairs(Search.providers()) do keys[p.key] = p end
for _, k in ipairs({ "deals", "customers", "leads", "crm_accounts", "crm_contacts", "crm_deals", "invoices", "shop_orders",
    "shop_quotes", "shop_products", "shop_suppliers", "purchase_orders", "purchase_invoices", "employees", "projects" }) do
    check("provider " .. k .. " is registered with a permission", keys[k] ~= nil and (keys[k].permission or keys[k].any) ~= nil)
end
local src = assert(io.open("lapis/lib/global-search.lua")):read("*a")
local scoped = true
for body in src:gmatch('Search%.provider%("[%w_]+", {(.-)\n}%)') do
    if not body:find("namespace_id = ?", 1, true) and not body:find("ShopDealQueries", 1, true) then scoped = false end
end
check("every built-in query filters by namespace", scoped)
check("leads use the row rule (own + unassigned for members)", src:find('require("lib.crm.lead-access").scope(ctx.self, "l")', 1, true) ~= nil)
check("projects only where the person is a member", src:find("pm.user_uuid = ? AND pm.left_at IS NULL", 1, true) ~= nil)

-- run(): only what the person may see, failures isolated, limit per group
local self = { namespace = { id = 7 }, current_user = { uuid = "me" } }
Search.provider("zz_test_ok", { label = "Things", order = 1, permission = { "things", "read" },
    run = function(ctx)
        local rows = {}
        for i = 1, 9 do rows[i] = { title = "T" .. i .. " " .. ctx.q, path = "/t/" .. i, subtitle = "" } end
        return rows
    end })
Search.provider("zz_test_boom", { label = "Boom", order = 2, permission = { "things", "read" },
    run = function() error("db down") end })
Search.provider("zz_test_hidden", { label = "Hidden", order = 3, permission = { "secret", "read" },
    run = function() return { { title = "x", path = "/x" } } end })
Search.provider("zz_test_any", { label = "Any", order = 4, any = { { "nope", "read" }, { "things", "read" } },
    run = function() return { { title = "y", path = "/y" } } end })
Search.provider("zz_test_table", { label = "Needs", order = 5, permission = { "things", "read" }, needs = { "gone_table" },
    run = function() return { { title = "z", path = "/z" } } end })
missing.gone_table = true
perms["things.read"] = true

local res = Search.run(self, "  acme ")
local by = {}
for _, g in ipairs(res.groups) do by[g.key] = g end
check("query echoed clean", res.query == "acme")
check("allowed provider answers", by.zz_test_ok ~= nil and by.zz_test_ok.items[1].title == "T1 acme")
check("at most PER_GROUP per group", by.zz_test_ok and #by.zz_test_ok.items == Search.PER_GROUP)
check("blank subtitle dropped", by.zz_test_ok and by.zz_test_ok.items[1].subtitle == nil)
check("a failing provider is left out and logged", by.zz_test_boom == nil and #logged > 0)
check("no permission → nothing", by.zz_test_hidden == nil)
check("any-of permission works", by.zz_test_any ~= nil)
check("missing table → skipped", by.zz_test_table == nil)
check("built-ins without permission stay quiet", by.invoices == nil and by.leads == nil and by.shop_orders == nil)
check("groups in provider order", res.groups[1].key == "zz_test_ok")
check("a short query runs nothing", #Search.run(self, "a").groups == 0)

local route = assert(io.open("lapis/routes/global-search.lua")):read("*a")
check("route needs sign-in and a workspace", route:find("AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(", 1, true) ~= nil)
check("route is rate limited", route:find('prefix = "global_search"', 1, true) ~= nil)
check("route is loaded", assert(io.open("lapis/app.lua")):read("*a"):find('safe_load_routes("routes.global-search")', 1, true) ~= nil)

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
