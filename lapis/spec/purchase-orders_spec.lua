--[[
    Spec: Purchase Orders - status workflow, receipt/bill maths, namespace
    isolation and feature wiring.

    Standalone (no busted). Run from the repo root:
        luajit lapis/spec/purchase-orders_spec.lua
    or inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/purchase-orders_spec.lua

    Pure functions (canTransition, receiptStatus, billAmounts, decimal,
    lineValues, round2, ...) run against a stubbed lapis.db; the database
    paths (receipts, bills, rounding, concurrency, isolation) are driven for
    real by spec/purchase-orders-e2e/run.sh. The tenant boundary is also guarded statically: every SQL
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
    { "billed", "received" },
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
check("cancelled is terminal", next(Q.TRANSITIONS.cancelled) == nil)
check("billed only reopens to received (a voided bill)", Q.canTransition("billed", "received")
    and not Q.canTransition("billed", "partially_received") and not Q.canTransition("billed", "cancelled"))
check("partially received can't be cancelled (close it short)", not Q.canTransition("partially_received", "cancelled"))
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

print("Bill amounts (lines already in pennies from SQL):")
local b = Q.billAmounts({ { net = 125, tax = 25, tax_rate = 20 }, { net = 300, tax = 60, tax_rate = 20 } })
check("single-rate bill: net/tax/gross", b.net == 425 and b.tax == 85 and b.gross == 510, b.net .. "/" .. b.tax)
check("single-rate bill keeps the rate", b.vat_rate == 20, b.vat_rate)
b = Q.billAmounts({ { net = 100, tax = 20, tax_rate = 20 }, { net = 100, tax = 0, tax_rate = 0 } })
check("mixed rates -> effective rate", b.vat_rate == 10 and b.gross == 220, b.vat_rate)
b = Q.billAmounts({ { net = 0.1, tax = 0.02, tax_rate = 20 }, { net = 0.2, tax = 0.04, tax_rate = 20 } })
check("sums of pennies are exact (0.1 + 0.2)", b.net == 0.3 and b.tax == 0.06 and b.gross == 0.36, b.net)

print("Rounding and input checks:")
check("round2 is half away from zero like Postgres (1.005 -> 1.01, 2.675 -> 2.68, -1.005 -> -1.01)",
    Q._round2(1.005) == 1.01 and Q._round2(2.675) == 2.68 and Q._round2(-1.005) == -1.01 and Q._round2(1.004) == 1)
check("decimal keeps what was typed", Q.decimal(1.333, 3, 12) == "1.333" and Q.decimal(0.1 + 0.2, 2, 13) == "0.3"
    and Q.decimal("12.50", 2, 13) == "12.5" and Q.decimal(5, 3, 12) == "5" and Q.decimal("007", 3, 12) == "7")
check("decimal refuses extra places, negatives, exponents and junk",
    not Q.decimal(1.333, 2, 13) and not Q.decimal("1.2345", 3, 12) and not Q.decimal(-1, 2, 13)
    and not Q.decimal("1e5", 3, 12) and not Q.decimal("abc", 2, 13) and not Q.decimal({}, 2, 13)
    and not Q.decimal(0 / 0, 2, 13) and not Q.decimal(".", 2, 13))
check("decimal refuses numbers too big for the column", not Q.decimal("12345678901234", 2, 13)
    and Q.decimal("1234567890123", 2, 13) == "1234567890123")
local v, e = Q.lineValues({ description = "Board", quantity = 3, unit_price = 1.333 })
check("a price with more than 2 decimals is refused (no silent rounding)", v == nil and e:find("2 decimals"), e)
v = Q.lineValues({ description = "Board", quantity = 3, unit_price = 1.33, tax_rate = 20 })
check("line values are exact text for NUMERIC", v and v.quantity == "3" and v.unit_price == "1.33" and v.tax_rate == "20")
v, e = Q.lineValues({ description = "Board", quantity = 1.2345, unit_price = 1 })
check("a quantity with more than 3 decimals is refused", v == nil and e:find("3 decimals"), e)
v, e = Q.lineValues({ description = "Board", quantity = 1, unit_price = 1, tax_rate = 120 })
check("tax rate above 100 refused", v == nil, e)
v = Q.lineValues({ unit_price = 2 }, { description = "Kept", quantity = 1.5, unit_price = 1, tax_rate = 20 })
check("update keeps the stored fields it isn't given", v and v.quantity == "1.5" and v.unit_price == "2"
    and v.tax_rate == "20" and v.description == "Kept")
check("dates: real YYYY-MM-DD only", not Q._badDate("2026-02-28") and Q._badDate("2026-02-30")
    and Q._badDate("2026-13-01") and Q._badDate("12/10/2026") and not Q._badDate(nil) and not Q._badDate(""))
check("currency: 3-letter ISO code, default GBP", Q._currency("eur") == "EUR" and Q._currency(nil) == "GBP"
    and Q._currency("EURO") == nil and Q._currency("£") == nil)
local meta = Q.clientMetadata({ source = "web", receipts = {}, bills = "x", bill = {}, expense_uuid = "e",
    expense_id = 1, closed = true, cancelled_reason = "x" })
check("client metadata can't set server keys", meta.source == "web" and meta.receipts == nil and meta.bills == nil
    and meta.bill == nil and meta.expense_uuid == nil and meta.expense_id == nil and meta.closed == nil
    and meta.cancelled_reason == nil)
check("metadata must be an object", select(2, Q.clientMetadata("x")) ~= nil)

print("Namespace isolation (queries):")
local q = read("lapis/queries/PurchaseOrderQueries.lua")
-- A statement built as [[ ... ]] .. FRAGMENT .. [[ ... ]] is checked as one.
local q_joined = q:gsub("%]%]%s*%.%.[^%[%]\n]-%.%.%s*%[%[", " ")
local unscoped = {}
-- Every SQL string mentioning a PO table must also mention namespace_id.
for sql in q_joined:gmatch("%[%[(.-)%]%]") do
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
check("every write locks the PO row first (update, delete, transitions, items, receive, bill, close, void)",
    select(2, q:gsub("find_row%(uuid, namespace_id, true%)", "")) >= 8 and q:find("FOR UPDATE OF po", 1, true))
check("no numeric expense id kept (uuids only)", not q:find("expense_id = expense.id", 1, true))
check("money maths in NUMERIC", q:find("ROUND(q * p, 2)", 1, true) and q:find("?::numeric AS q", 1, true))

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
check("no blanket pcall turning every error into a 400", not r:find("pcall", 1, true))
for _, path in ipairs({ '"/api/v2/purchase-orders"', '"/api/v2/purchase-orders/:uuid/email"',
    '"/api/v2/purchase-orders/:uuid/receive"', '"/api/v2/purchase-orders/:uuid/convert-to-bill"' }) do
    local at = r:find("app:post(" .. path, 1, true)
    local nxt = at and (r:find("app:%a+%(", at + 1) or #r)
    check("Idempotency-Key on POST " .. path, at and r:sub(at, nxt):find("idem(self", 1, true))
end
check("billing / voiding also need the accounting permission",
    select(2, r:gsub('ledger_denied%(self, "%a+"%)', "")) == 2)
check("email: one address, PDF magic, size cap, rate limit, workspace SMTP",
    r:find('to:match(EMAIL)', 1, true) and r:find('"%PDF-"', 1, true) and r:find("MAX_PDF_B64", 1, true)
    and r:find("RateLimit.check", 1, true) and r:find("NamespaceMail.smtp", 1, true))

print("Wiring:")
check("routes gated on invoicing in app.lua",
    read("lapis/app.lua"):find('load_if("invoicing", "routes.purchase-orders")', 1, true) ~= nil)
local m = read("lapis/migrations.lua")
check("migrations gated on invoicing",
    m:find('load_if_enabled(ProjectConfig.FEATURES.INVOICING, "migrations.purchase-orders")', 1, true) ~= nil)
for i = 1, 7 do
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
