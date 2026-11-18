--[[
    Spec: staff-created orders (queries/ManualOrderQueries.lua) and Sales Orders wiring
    (queries/SalesOrderQueries.lua, routes/sales-orders.lua, routes/orders.lua).

    Standalone (no busted). From the repo root:  luajit lapis/spec/manual-order_spec.lua
    The database side runs for real in spec/shop-ops-pack-e2e/run.sh.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3 } -- luacheck: ignore 111
package.loaded["lapis.db"] = package.loaded["lapis.db"] or { NULL = {}, query = function() return {} end }
package.loaded["helper.global"] = package.loaded["helper.global"] or { generateUUID = function() return "u" end }
package.loaded["cjson"] = package.loaded["cjson"] or { null = {}, encode = function() return "{}" end }

local failures = 0
local function check(name, ok, detail)
    if ok then print("  ok   - " .. name) else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(p) local h = assert(io.open(p)); local s = h:read("*a"); h:close(); return s end

local M = require("queries.ManualOrderQueries")
local good = { store_uuid = "s", customer = { email = " Jane@Example.co.UK " }, items = { { product_uuid = "p", quantity = 2 } } }
local v = M.validate(good)
check("a good order validates", v ~= nil and v.customer.email == "jane@example.co.uk" and v.channel == "phone")
check("channel in person kept", M.validate({ store_uuid = "s", customer = { email = "a@b.co" }, items = { { product_uuid = "p", quantity = 1 } },
    channel = "in_person" }).channel == "in_person")
local function bad(body) local r, e = M.validate(body); return r == nil and e end
check("no store", bad({ customer = { email = "a@b.co" }, items = { { product_uuid = "p", quantity = 1 } } }).status == 422)
check("bad email", bad({ store_uuid = "s", customer = { email = "nope" }, items = { { product_uuid = "p", quantity = 1 } } }).status == 422)
check("no items", bad({ store_uuid = "s", customer = { email = "a@b.co" }, items = {} }).status == 422)
check("fractional quantity", bad({ store_uuid = "s", customer = { email = "a@b.co" }, items = { { product_uuid = "p", quantity = 1.5 } } }))
check("zero quantity", bad({ store_uuid = "s", customer = { email = "a@b.co" }, items = { { product_uuid = "p", quantity = 0 } } }))
check("unknown channel", bad({ store_uuid = "s", customer = { email = "a@b.co" }, items = { { product_uuid = "p", quantity = 1 } }, channel = "fax" }))
check("prices are never taken from the request", M.validate({ store_uuid = "s", customer = { email = "a@b.co" },
    items = { { product_uuid = "p", quantity = 1, price = 0.01 } } }).items[1].price == nil)
check("same product twice is one line", #M.validate({ store_uuid = "s", customer = { email = "a@b.co" },
    items = { { product_uuid = "p", quantity = 1 }, { product_uuid = "p", quantity = 2 } } }).items == 1)
check("amounts: 2 decimals at most", M.amount("12.50") == 12.5 and M.amount("") == 0 and select(2, M.amount("1.234")) == "bad"
    and select(2, M.amount("-5")) == "bad" and select(2, M.amount("abc")) == "bad")
local t = M.totals({ { price = 1999.99, quantity = 3 }, { price = 150, quantity = 1 } }, 0.2, 25, 10)
check("totals: subtotal, tax at the store's rate, shipping, discount", t.subtotal == 6149.97 and t.tax == 1229.99 and t.total == 7394.96, t.total)
check("addresses keep known fields only", M.address({ line1 = "1 High St", evil = "x" }).line1 == "1 High St"
    and M.address({ evil = "x" }) == nil)

local routes = read("lapis/routes/orders.lua")
check("create needs orders.create in the workspace", routes:find('requirePermission("orders", "create"', 1, true) ~= nil)
check("create is idempotent", routes:find('require("helper.idempotency").run', 1, true) ~= nil)
check("the old wholesale create is gone", not routes:find("OrderQueries.create(self.params)", 1, true))
local so = read("lapis/routes/sales-orders.lua")
check("sales orders need sign-in and a workspace", so:find("AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(", 1, true) ~= nil)
check("sales orders route is loaded", read("lapis/app.lua"):find('safe_load_routes("routes.sales-orders")', 1, true) ~= nil)
local sq = read("lapis/queries/SalesOrderQueries.lua")
check("each source has its permission", sq:find('key = "shop", permission = { "shop", "read" }', 1, true)
    and sq:find('key = "store", permission = { "orders", "read" }', 1, true))
check("store orders are workspace-scoped (or by their store)", sq:find("WHERE COALESCE(o.namespace_id, s.namespace_id) = ?", 1, true) ~= nil)

if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
