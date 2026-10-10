--[[
    Spec: Purchase Orders - status workflow, receipt/bill maths, namespace
    isolation and feature wiring.

    Standalone (no busted). Run from the repo root:
        luajit lapis/spec/purchase-orders_spec.lua
    or inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/purchase-orders_spec.lua

    Pure functions (canTransition, receiptStatus, billAmounts) run against a
    stubbed lapis.db; the tenant boundary is guarded statically: every SQL
    statement that touches purchase_orders / purchase_order_items filters on
    namespace_id, and every route goes through requirePermission("purchase_orders").
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, INFO = 7 } -- luacheck: ignore 111

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end

-- Stubs: the pure helpers must not touch the database.
package.loaded["lapis.db"] = setmetatable({ NULL = {} }, {
    __index = function() return function() error("database must not be used by pure helpers") end end,
})
package.loaded["helper.global"] = { generateUUID = function() return "uuid" end }

local Q = require("queries.PurchaseOrderQueries")

print("Status transitions:")
local allowed = {
    { "draft", "sent" }, { "draft", "cancelled" },
    { "sent", "acknowledged" }, { "sent", "partially_received" }, { "sent", "received" }, { "sent", "cancelled" },
    { "acknowledged", "partially_received" }, { "acknowledged", "received" }, { "acknowledged", "cancelled" },
    { "partially_received", "partially_received" }, { "partially_received", "received" },
    { "partially_received", "billed" },
    { "received", "billed" },
}
local allowed_set = {}
for _, t in ipairs(allowed) do
    allowed_set[t[1] .. ">" .. t[2]] = true
    check(t[1] .. " -> " .. t[2] .. " allowed", Q.canTransition(t[1], t[2]))
end
-- Everything else is refused (exhaustive over the status set).
local refused_ok, refused_bad = 0, {}
for _, from in ipairs(Q.STATUSES) do
    for _, to in ipairs(Q.STATUSES) do
        if not allowed_set[from .. ">" .. to] then
            if Q.canTransition(from, to) then refused_bad[#refused_bad + 1] = from .. ">" .. to
            else refused_ok = refused_ok + 1 end
        end
    end
end
check("every other transition is refused", #refused_bad == 0, table.concat(refused_bad, ", "))
check("billed and cancelled are terminal", next(Q.TRANSITIONS.billed) == nil and next(Q.TRANSITIONS.cancelled) == nil)
check("draft cannot skip to received", not Q.canTransition("draft", "received"))
check("received cannot be cancelled", not Q.canTransition("received", "cancelled"))
check("unknown status refused", not Q.canTransition("bogus", "sent") and not Q.canTransition("draft", "bogus"))
check("seven statuses", #Q.STATUSES == 7 and refused_ok == 49 - #allowed, refused_ok)

print("Receipt status:")
check("nothing received -> nil", Q.receiptStatus({ { quantity = 5, received_quantity = 0 } }) == nil)
check("some received -> partially_received",
    Q.receiptStatus({ { quantity = 5, received_quantity = 2 }, { quantity = 1, received_quantity = 0 } })
        == "partially_received")
check("all received -> received",
    Q.receiptStatus({ { quantity = 5, received_quantity = 5 }, { quantity = "1.5", received_quantity = "1.5" } })
        == "received")
check("no lines -> nil", Q.receiptStatus({}) == nil)

print("Bill amounts:")
local b = Q.billAmounts({
    { quantity = 10, received_quantity = 10, unit_price = 12.5, tax_rate = 20 },
    { quantity = 2, received_quantity = 2, unit_price = 150, tax_rate = 20 },
})
check("single-rate bill: net/tax/gross", b.net == 425 and b.tax == 85 and b.gross == 510, b.net .. "/" .. b.tax)
check("single-rate bill keeps the rate", b.vat_rate == 20, b.vat_rate)
b = Q.billAmounts({
    { quantity = 10, received_quantity = 4, unit_price = 12.5, tax_rate = 20 },
    { quantity = 2, received_quantity = 0, unit_price = 150, tax_rate = 0 },
})
check("partial bill counts only received quantity", b.net == 50 and b.tax == 10 and b.gross == 60, b.gross)
b = Q.billAmounts({
    { received_quantity = 1, unit_price = 100, tax_rate = 20 },
    { received_quantity = 1, unit_price = 100, tax_rate = 0 },
})
check("mixed rates -> effective rate", b.vat_rate == 10 and b.gross == 220, b.vat_rate)

print("Namespace isolation (queries):")
local q = read("lapis/queries/PurchaseOrderQueries.lua")
local unscoped = {}
-- Every SQL string mentioning a PO table must also mention namespace_id.
for sql in q:gmatch("%[%[(.-)%]%]") do
    if sql:find("purchase_order", 1, true) and not sql:find("namespace_id", 1, true) then
        unscoped[#unscoped + 1] = (sql:gsub("%s+", " ")):sub(1, 80)
    end
end
-- One-line statements may be concatenated over a continuation line: check the
-- call plus the next line. `.. where` is list()'s namespace-scoped WHERE (below).
for sql in q:gmatch('db%.query%(("[^\n]*\n[^\n]*)') do
    if sql:match('^"[^"]*purchase_order') and not sql:find("namespace_id", 1, true)
        and not sql:find(" .. where", 1, true) then
        unscoped[#unscoped + 1] = sql:sub(1, 80)
    end
end
check("every PO SQL statement filters on namespace_id", #unscoped == 0, table.concat(unscoped, " | "))
check("list() scopes on po.namespace_id", q:find('"po.namespace_id = " .. db.escape_literal(namespace_id)', 1, true))
check("items are joined to their PO within the namespace",
    q:find("po.id = i.purchase_order_id AND po.namespace_id = i.namespace_id", 1, true))
check("CRM company link is namespace-scoped",
    q:find("FROM crm_accounts WHERE uuid = ? AND namespace_id = ?", 1, true))
check("project link is namespace-scoped",
    q:find("FROM kanban_projects WHERE uuid = ? AND namespace_id = ?", 1, true))
check("no numeric ids in responses",
    q:find("row.internal_id = nil", 1, true) and q:find("row.namespace_id = nil", 1, true))
check("PO number is an atomic per-namespace upsert", q:find("ON CONFLICT (namespace_id) DO UPDATE", 1, true))
check("receive and bill lock the PO row", select(2, q:gsub("find_row%(uuid, namespace_id, true%)", "")) >= 3)

print("Routes:")
local r = read("lapis/routes/purchase-orders.lua")
local routes = select(2, r:gsub('app:%a+%("/api/v2/purchase%-orders', ""))
local guarded = select(2, r:gsub('app:%a+%("/api/v2/purchase%-orders[^"]*", guard%("%a+"', ""))
check("every route is guarded", routes > 0 and routes == guarded, guarded .. "/" .. routes)
check("guard = auth + requirePermission(purchase_orders)",
    r:find('AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("purchase_orders", action, handler))',
        1, true))
check("routes pass self.namespace.id", not r:find("PurchaseOrderQueries%.%a+%(self%.params%.uuid%)"))
check("static paths registered before :uuid",
    r:find('"/api/v2/purchase-orders/stats"', 1, true) < r:find('"/api/v2/purchase-orders/:uuid"', 1, true)
    and r:find('"/api/v2/purchase-orders/items/:item_uuid"', 1, true)
        < r:find('"/api/v2/purchase-orders/:uuid"', 1, true))
check("email escapes HTML", r:find("html_escape(it.description)", 1, true) ~= nil)

print("Wiring:")
check("routes gated on invoicing in app.lua",
    read("lapis/app.lua"):find('load_if("invoicing", "routes.purchase-orders")', 1, true) ~= nil)
local m = read("lapis/migrations.lua")
check("migrations gated on invoicing",
    m:find('load_if_enabled(ProjectConfig.FEATURES.INVOICING, "migrations.purchase-orders")', 1, true) ~= nil)
for i = 1, 5 do
    check("migration step " .. i .. " registered",
        m:find("conditional_array%(ProjectConfig%.FEATURES%.INVOICING, purchase_order_migrations, "
            .. i .. "%)") ~= nil)
end
local mig = read("lapis/migrations/purchase-orders.lua")
check("migration is idempotent", select(2, mig:gsub("IF NOT EXISTS", "")) >= 8)
check("menu item key + path", mig:find('key = "purchase_orders"', 1, true) and
    mig:find('path = "/dashboard/purchase-orders"', 1, true))
local pc = read("lapis/helper/project-config.lua")
check("RBAC module in PROJECT_MODULES (Finance)",
    pc:find('machine_name = "purchase_orders".-category = "Finance"') ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
