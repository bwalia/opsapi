--[[
    The shop ops pack's SQL against a real Postgres (run.sh starts one). Calls the real modules:
      queries/PurchaseInvoiceQueries.lua   list(): paid / owed / overdue, oldest invoice first, filters, totals
      lib/global-search.lua                run(): every built-in provider, namespace-scoped, permissions, lead rows
      queries/ShopDealQueries.lua          recent()
    through a small lapis.db shim over pgmoon (`?` placeholders, db.NULL, db.list, db.raw).
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

-- Connect before the ngx stub exists (pgmoon picks its socket and helpers from ngx when it sees it).
local pgmoon = require("pgmoon")
local pg = pgmoon.new({ host = os.getenv("PGHOST"), port = 5432, database = "test", user = "postgres", password = "test",
    socket_type = "luasocket" })
assert(pg:connect())

ngx = { -- luacheck: ignore 111
    log = function(_, ...) io.stderr:write("[log] ", table.concat({ ... }), "\n") end, ERR = 3, WARN = 4, INFO = 7, DEBUG = 8,
    ctx = {}, var = {}, time = os.time, now = os.time, null = nil,
    escape_uri = function(s) return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end,
}

-- ---------------------------------------------------------------------------
-- lapis.db over pgmoon
-- ---------------------------------------------------------------------------

local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
local db = { NULL = NULL }
local function raw(s) return setmetatable({ s }, { __raw = true }) end
db.raw = raw
function db.list(t) return setmetatable({ t }, { __list = true }) end
function db.escape_literal(v)
    if v == nil or v == NULL then return "NULL" end
    if type(v) == "number" then return tostring(v) end
    if type(v) == "boolean" then return v and "TRUE" or "FALSE" end
    if type(v) == "table" then
        local mt = getmetatable(v) or {}
        if mt.__raw then return v[1] end
        if mt.__list then
            local parts = {}
            for i, x in ipairs(v[1]) do parts[i] = db.escape_literal(x) end
            return "(" .. table.concat(parts, ", ") .. ")"
        end
    end
    return pg:escape_literal(tostring(v))
end
function db.interpolate(sql, ...)
    local args, n, i = { ... }, select("#", ...), 0
    local out = sql:gsub("%?", function()
        i = i + 1
        if i > n then error("too few values for the query's placeholders: " .. sql:sub(1, 200)) end
        return db.escape_literal(args[i])
    end)
    if i ~= n then error(("query has %d placeholders, %d values: %s"):format(i, n, sql:sub(1, 300))) end
    return out
end
function db.query(sql, ...)
    local q = select("#", ...) > 0 and db.interpolate(sql, ...) or sql
    local res, err = pg:query(q)
    if not res then error(tostring(err) .. "\nSQL: " .. q, 2) end
    if res == true then return {} end
    return res
end
function db.select(sql, ...) return db.query("SELECT " .. sql, ...) end
function db.insert(tbl, vals, opts)
    local cols, marks, args = {}, {}, {}
    for k, v in pairs(vals) do cols[#cols + 1] = k; marks[#marks + 1] = "?"; args[#args + 1] = v end
    local ret = opts and opts.returning and (" RETURNING " .. (opts.returning == "*" and "*" or table.concat(opts.returning, ", "))) or ""
    return db.query("INSERT INTO " .. tbl .. " (" .. table.concat(cols, ", ") .. ") VALUES (" .. table.concat(marks, ", ") .. ")" .. ret,
        unpack(args))
end
function db.update(tbl, vals, cond)
    local sets, args, wh = {}, {}, {}
    for k, v in pairs(vals) do sets[#sets + 1] = k .. " = ?"; args[#args + 1] = v end
    for k, v in pairs(cond) do wh[#wh + 1] = k .. " = ?"; args[#args + 1] = v end
    return db.query("UPDATE " .. tbl .. " SET " .. table.concat(sets, ", ") .. " WHERE " .. table.concat(wh, " AND "), unpack(args))
end
package.loaded["lapis.db"] = db

-- Permission stub: per test, the permissions of "the person".
local perms = {}
package.loaded["middleware.namespace"] = {
    hasPermission = function(_, module, action) return perms[module .. "." .. action] == true or perms[module .. ".manage"] == true end,
}
package.loaded["helper.global"] = { generateUUID = function() return "uuid-" .. tostring(math.random(1e9)) end }

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- ---------------------------------------------------------------------------
-- schema (the columns these queries use, with the real types) + fixtures
-- ---------------------------------------------------------------------------
db.query([[
CREATE TABLE namespaces (id serial PRIMARY KEY, uuid text, name text);
INSERT INTO namespaces (id, uuid, name) VALUES (1, 'ns-1', 'Workstation'), (2, 'ns-2', 'Other');

CREATE TABLE purchase_orders (id bigserial PRIMARY KEY, uuid text UNIQUE NOT NULL, namespace_id bigint NOT NULL, po_number text,
  supplier_name text, reference text, status text, total numeric(15,2), currency text DEFAULT 'GBP', deal_code text,
  metadata jsonb DEFAULT '{}', created_at timestamp DEFAULT NOW(), deleted_at timestamp);
CREATE TABLE purchase_order_supplier_invoices (id bigserial PRIMARY KEY, uuid text UNIQUE NOT NULL, namespace_id bigint NOT NULL,
  purchase_order_id bigint NOT NULL REFERENCES purchase_orders(id), kind text NOT NULL, number text NOT NULL, invoice_date date NOT NULL,
  due_date date, supplier_order_ref text, net numeric(15,2) NOT NULL, vat numeric(15,2) NOT NULL, total numeric(15,2) NOT NULL,
  currency text NOT NULL DEFAULT 'GBP', payment_terms text, document_id bigint, created_by_kind text NOT NULL DEFAULT 'staff',
  created_at timestamp NOT NULL DEFAULT NOW(), deleted_at timestamp);
CREATE TABLE purchase_order_payments (id bigserial PRIMARY KEY, uuid text, namespace_id bigint NOT NULL, purchase_order_id bigint NOT NULL,
  supplier_invoice_id bigint, amount numeric(15,2) NOT NULL, currency text DEFAULT 'GBP', voided_at timestamp);
]])

-- PO-1 (ns 1): invoices A (old, £600, overdue), B (£400, due later), proforma P (£1000), credit note C (£100);
-- payments £300 against the proforma + £100 unlinked (one £50 voided). Pool = 400 + 100 credit = 500:
-- A gets 500 of 600 (part paid → overdue as its due date passed), B gets 0.
-- PO-2 (ns 1): invoice D £200 fully paid. PO-3 (ns 2): another workspace's invoice, never visible.
db.query([[
INSERT INTO purchase_orders (id, uuid, namespace_id, po_number, supplier_name, reference, status, total, deal_code) VALUES
  (1, 'po-1', 1, 'PO-000001', 'Boston Limited', 'WSO-2026-00006', 'received', 1000, 'WS-6VBE-MKFV'),
  (2, 'po-2', 1, 'PO-000002', 'Acme Parts', NULL, 'billed', 200, NULL),
  (3, 'po-3', 2, 'PO-000001', 'Boston Limited', NULL, 'sent', 999, NULL),
  (4, 'po-4', 1, 'PO-000004', 'Deleted Ltd', NULL, 'sent', 50, NULL);
UPDATE purchase_orders SET deleted_at = NOW() WHERE id = 4;
INSERT INTO purchase_order_supplier_invoices (uuid, namespace_id, purchase_order_id, kind, number, invoice_date, due_date, net, vat, total, supplier_order_ref) VALUES
  ('inv-a', 1, 1, 'invoice', 'INV-A', CURRENT_DATE - 40, CURRENT_DATE - 10, 500, 100, 600, 'SO-77'),
  ('inv-b', 1, 1, 'invoice', 'INV-B', CURRENT_DATE - 5, CURRENT_DATE + 25, 333.33, 66.67, 400, NULL),
  ('pro-p', 1, 1, 'proforma', 'PF-1', CURRENT_DATE - 50, NULL, 833.33, 166.67, 1000, NULL),
  ('cn-c', 1, 1, 'credit_note', 'CN-1', CURRENT_DATE - 3, NULL, 83.33, 16.67, 100, NULL),
  ('inv-d', 1, 2, 'invoice', 'ACME-9', CURRENT_DATE - 20, CURRENT_DATE - 1, 166.67, 33.33, 200, NULL),
  ('inv-x', 2, 3, 'invoice', 'OTHER-1', CURRENT_DATE - 20, CURRENT_DATE - 1, 1, 1, 2, NULL),
  ('inv-del', 1, 4, 'invoice', 'GONE-1', CURRENT_DATE, NULL, 1, 1, 2, NULL);
INSERT INTO purchase_order_payments (namespace_id, purchase_order_id, supplier_invoice_id, amount, voided_at) VALUES
  (1, 1, (SELECT id FROM purchase_order_supplier_invoices WHERE uuid = 'pro-p'), 300, NULL),
  (1, 1, NULL, 100, NULL),
  (1, 1, NULL, 50, NOW()),
  (1, 2, NULL, 200, NULL);
]])

print("purchase invoices")
local PI = require("queries.PurchaseInvoiceQueries")
local rows, meta = PI.list(1, {})
local by = {}
for _, r in ipairs(rows) do by[r.number] = r end
check("lists this workspace's live invoices only", #rows == 5 and not by["OTHER-1"] and not by["GONE-1"], #rows)
check("oldest invoice paid first from payments + credit notes", by["INV-A"].paid == "500.00" and by["INV-A"].outstanding == "100.00",
    by["INV-A"].paid)
check("past its due date with money owed → overdue", by["INV-A"].state == "overdue" and by["INV-A"].days_late == 10, by["INV-A"].state)
check("the next invoice gets what is left (nothing)", by["INV-B"].paid == "0.00" and by["INV-B"].state == "unpaid")
check("voided payments don't count", meta.summary.GBP.owed == "500.00", meta.summary.GBP and meta.summary.GBP.owed)
check("fully paid", by["ACME-9"].state == "paid" and by["ACME-9"].outstanding == "0.00")
check("proforma and credit note listed, never owed", by["PF-1"].state == "proforma" and by["CN-1"].state == "credit"
    and by["PF-1"].outstanding == "0.00")
check("overdue first", rows[1].number == "INV-A", rows[1].number)
check("totals", meta.summary.GBP.overdue == "100.00" and meta.summary.GBP.owed_count == 2 and meta.summary.GBP.overdue_count == 1
    and meta.summary.GBP.paid == "700.00", meta.summary.GBP.paid)
check("PO link and supplier", by["INV-A"].purchase_order.uuid == "po-1" and by["INV-A"].supplier_name == "Boston Limited")
local owed = PI.list(1, { state = "owed" })
check("state=owed: unpaid, part paid and overdue", #owed == 2)
check("state=paid", #PI.list(1, { state = "paid" }) == 1)
check("search by supplier order ref", #PI.list(1, { q = "so-77" }) == 1)
check("search by PO reference", #PI.list(1, { q = "WSO-2026" }) == 4)
check("search escapes wildcards", #PI.list(1, { q = "%" }) == 0)
check("date range", #PI.list(1, { from = os.date("!%Y-%m-%d", os.time() - 10 * 86400) }) == 2)
local bad, err = PI.list(1, { state = "everything" })
check("a bad state is a 400", bad == nil and err.status == 400)
local bad2, err2 = PI.list(1, { from = "yesterday" })
check("a bad date is a 400", bad2 == nil and err2.status == 400)
local _, m2 = PI.list(1, { limit = 2, offset = 0 })
check("paging keeps the total", m2.total == 5 and m2.limit == 2)

-- ---------------------------------------------------------------------------
-- global search
-- ---------------------------------------------------------------------------
db.query([[
CREATE TABLE users (id serial PRIMARY KEY, uuid text, first_name text, last_name text, email text);
INSERT INTO users (uuid, first_name, last_name, email) VALUES ('me', 'Sam', 'Staff', 'sam@ws.test'), ('other', 'Olive', 'Other', 'olive@ws.test');
CREATE TABLE customers (id serial PRIMARY KEY, uuid text, namespace_id integer, email text, first_name text, last_name text, phone text,
  created_at timestamp, updated_at timestamp);
INSERT INTO customers (uuid, namespace_id, email, first_name, last_name, phone) VALUES
  ('c-1', 1, 'katerina@iqinit.uk', 'Katerina', 'Damec-Whitelock', '+447833229206'), ('c-2', 2, 'katerina@else.uk', 'Katerina', 'Else', NULL);
CREATE TABLE crm_leads (id serial PRIMARY KEY, uuid text, namespace_id integer, first_name text, last_name text, email text, phone text,
  company_name text, status text, owner_user_uuid text, deal_code text, created_at timestamp DEFAULT NOW(), deleted_at timestamp);
INSERT INTO crm_leads (uuid, namespace_id, first_name, last_name, email, company_name, status, owner_user_uuid, deal_code) VALUES
  ('l-mine', 1, 'Katerina', 'Mine', 'k1@x.uk', 'IQ in IT LTD', 'new', 'me', 'WS-6VBE-MKFV'),
  ('l-free', 1, 'Katerina', 'Free', 'k2@x.uk', NULL, 'new', NULL, NULL),
  ('l-theirs', 1, 'Katerina', 'Theirs', 'k3@x.uk', NULL, 'new', 'other', NULL);
CREATE TABLE crm_accounts (id serial PRIMARY KEY, uuid text, namespace_id integer, name text, industry text, email text, phone text,
  website text, city text, postal_code text, deleted_at timestamp);
INSERT INTO crm_accounts (uuid, namespace_id, name, industry, city) VALUES ('a-1', 1, 'IQ in IT LTD', 'IT', 'Epsom');
CREATE TABLE crm_contacts (id serial PRIMARY KEY, uuid text, namespace_id integer, account_id integer, first_name text, last_name text,
  email text, phone text, mobile text, job_title text, deleted_at timestamp);
INSERT INTO crm_contacts (uuid, namespace_id, account_id, first_name, last_name, email) VALUES ('ct-1', 1, 1, 'Katerina', 'Contact', 'kc@iqinit.uk');
CREATE TABLE crm_deals (id serial PRIMARY KEY, uuid text, namespace_id integer, account_id integer, name text, stage text, value numeric,
  currency text, deleted_at timestamp);
INSERT INTO crm_deals (uuid, namespace_id, account_id, name, stage, value, currency) VALUES ('d-1', 1, 1, 'IQ in IT DGX Spark', 'won', 6307.98, 'GBP');
CREATE TABLE invoices (id serial PRIMARY KEY, uuid text, namespace_id integer, invoice_number text, customer_invoice_number text,
  customer_name text, customer_email text, status text, total_amount numeric, currency text, deleted_at timestamp);
INSERT INTO invoices (uuid, namespace_id, invoice_number, customer_invoice_number, customer_name, customer_email, status, total_amount, currency)
  VALUES ('i-1', 1, 'INV-0007', 'WS-INV-1007', 'IQ in IT LTD', 'katerina@iqinit.uk', 'paid', 6307.98, 'GBP');
CREATE TABLE shop_settings (namespace_id integer, deal_code_prefix text, deal_code_length integer);
CREATE TABLE shop_deal_codes (namespace_id integer, code text UNIQUE, created_by_user_id integer, created_at timestamp DEFAULT NOW());
INSERT INTO shop_deal_codes (namespace_id, code) VALUES (1, 'WS-6VBE-MKFV');
CREATE TABLE shop_orders (id serial PRIMARY KEY, uuid text, namespace_id integer, order_number text, status text, email text,
  customer jsonb, customer_po_number text, deal_code text, total_minor bigint, currency text, quote_id integer, created_at timestamp DEFAULT NOW());
INSERT INTO shop_orders (uuid, namespace_id, order_number, status, email, customer, deal_code, total_minor, currency) VALUES
  ('o-1', 1, 'WSO-2026-00006', 'delivered', 'katerina@iqinit.uk', '{"name":"Katerina Damec-Whitelock","company":"IQ in IT LTD"}', 'WS-6VBE-MKFV', 630798, 'GBP');
CREATE TABLE shop_quotes (id serial PRIMARY KEY, uuid text, namespace_id integer, quote_number text, status text, customer jsonb,
  customer_po_number text, deal_code text, superseded_by_id integer, order_id integer, kind text DEFAULT 'quote',
  created_at timestamp DEFAULT NOW());
INSERT INTO shop_quotes (uuid, namespace_id, quote_number, status, customer, deal_code) VALUES
  ('q-1', 1, 'WSQ-2026-00021', 'converted', '{"name":"Katerina Damec-Whitelock","company":"IQ in IT LTD","email":"katerina@iqinit.uk"}', 'WS-6VBE-MKFV');
CREATE TABLE shop_supplier_requests (namespace_id integer, deal_code text, supplier_quote_ref text, created_at timestamp DEFAULT NOW());
CREATE TABLE shop_products (id serial PRIMARY KEY, uuid text, namespace_id integer, name text, sku text, brand text, status text, stock_qty integer);
INSERT INTO shop_products (uuid, namespace_id, name, sku, brand, status, stock_qty) VALUES
  ('p-1', 1, 'NVIDIA DGX Spark Founders Edition', 'NV-DGX-SPARK', 'NVIDIA', 'active', 3);
CREATE TABLE shop_option_groups (id serial PRIMARY KEY, product_id integer, name text);
INSERT INTO shop_option_groups (product_id, name) VALUES (1, 'Storage');
CREATE TABLE shop_options (id serial PRIMARY KEY, group_id integer, code text, name text, stock_qty integer);
INSERT INTO shop_options (group_id, code, name, stock_qty) VALUES (1, 'SSD-4TB', '4TB DGX SSD', 2);
CREATE TABLE shop_suppliers (id serial PRIMARY KEY, uuid text, namespace_id integer, name text, contact_email text, is_active boolean);
INSERT INTO shop_suppliers (uuid, namespace_id, name, contact_email, is_active) VALUES ('s-1', 1, 'Boston Limited', 'sam.rogers@boston.co.uk', true);
CREATE TABLE employees (id serial PRIMARY KEY, uuid text, namespace_id integer, user_uuid text, email text, job_title text, deleted_at timestamp);
INSERT INTO employees (uuid, namespace_id, user_uuid, job_title) VALUES ('e-1', 1, 'me', 'Delivery driver');
CREATE TABLE kanban_projects (id serial PRIMARY KEY, uuid text, namespace_id integer, name text, slug text, status text, deleted_at timestamp);
INSERT INTO kanban_projects (uuid, namespace_id, name, slug, status) VALUES ('k-1', 1, 'DGX rollout', 'dgx-rollout', 'active'),
  ('k-2', 1, 'DGX secret', 'dgx-secret', 'active');
CREATE TABLE kanban_project_members (project_id integer, user_uuid text, left_at timestamp);
INSERT INTO kanban_project_members (project_id, user_uuid) VALUES (1, 'me'), (2, 'other');
]])

print("global search")
local Search = require("lib.global-search")
local self = { namespace = { id = 1 }, current_user = { uuid = "me" } }
local function run(q)
    local res = Search.run(self, q)
    local g = {}
    for _, x in ipairs(res.groups) do g[x.key] = x.items end
    return g, res
end

local g = run("katerina")
check("no permission → no records", next(g) == nil)

for _, p in ipairs({ "customers.read", "crm_leads.read", "crm_accounts.read", "crm_contacts.read", "crm_deals.read", "invoices.read",
    "shop.read", "purchase_orders.read", "employees.read", "projects.read" }) do perms[p] = true end
g = run("katerina")
check("customers: this workspace only", g.customers and #g.customers == 1 and g.customers[1].path == "/dashboard/customers/c-1")
check("leads: a member sees own + unassigned only", g.leads and #g.leads == 2, g.leads and #g.leads)
check("contacts link to their account", g.crm_contacts and g.crm_contacts[1].path == "/dashboard/crm/a-1")
check("invoices by customer email", g.invoices and g.invoices[1].title == "WS-INV-1007")
check("shop orders by customer", g.shop_orders and g.shop_orders[1].path == "/dashboard/shop/orders/o-1")
check("quotes by customer", g.shop_quotes and g.shop_quotes[1].title == "WSQ-2026-00021")
perms["crm_leads.manage"] = true
g = run("katerina")
check("leads: a manager sees all", g.leads and #g.leads == 3)

g = run("iq in it")
check("accounts by name", g.crm_accounts and g.crm_accounts[1].path == "/dashboard/crm/a-1")
check("CRM deals by account name", g.crm_deals and g.crm_deals[1].subtitle:find("GBP 6307.98", 1, true) ~= nil, g.crm_deals and g.crm_deals[1].subtitle)

g = run("DGX")
check("products and their options (stock)", g.shop_products and #g.shop_products == 2
    and g.shop_products[1].subtitle:find("in stock", 1, true) ~= nil)
check("projects: only ones I'm in", g.projects and #g.projects == 1 and g.projects[1].path == "/dashboard/projects/k-1")

g = run("PO-000001")
check("purchase orders: this workspace only", g.purchase_orders and #g.purchase_orders == 1 and g.purchase_orders[1].path == "/dashboard/purchase-orders/po-1")
g = run("INV-A")
check("purchase invoices link to their PO", g.purchase_invoices and g.purchase_invoices[1].path == "/dashboard/purchase-orders/po-1")
g = run("boston")
check("suppliers", g.shop_suppliers and g.shop_suppliers[1].title == "Boston Limited")
g = run("delivery driver")
check("employees by job title", g.employees and g.employees[1].title == "Sam Staff")

local _, res = run("ws 6vbe mkfv")
check("a whole deal code opens the deal", res.open == "/dashboard/shop/deals/WS-6VBE-MKFV", res.open)
g = run("WS-6VBE")
check("part of a deal code lists the deal", g.deals and g.deals[1].title == "Deal WS-6VBE-MKFV")
check("…and the order, quote and lead that carry it", g.shop_orders and g.shop_quotes and g.leads)
g = run("50%")
check("wildcards are literal", next(g) == nil)

-- ---------------------------------------------------------------------------
-- latest deals
-- ---------------------------------------------------------------------------
print("latest deals")
local D = require("queries.ShopDealQueries")
local recent = D.recent(1, 10)
check("the workspace's deals with counts and customer", #recent.results == 1 and recent.results[1].deal_code == "WS-6VBE-MKFV"
    and recent.results[1].orders == 1 and recent.results[1].quotes == 1 and recent.results[1].purchase_orders == 1
    and recent.results[1].customer == "Katerina Damec-Whitelock, IQ in IT LTD", recent.results[1] and recent.results[1].customer)
check("another workspace sees none of them", #D.recent(2, 10).results == 0)

-- ---------------------------------------------------------------------------
-- staff-created store orders + Sales Orders (shop and store orders together)
-- ---------------------------------------------------------------------------
print("create order (stores)")
db.query([[
CREATE TABLE stores (id serial PRIMARY KEY, uuid text, namespace_id integer, user_id integer, name text, tax_rate numeric DEFAULT 0,
  currency varchar DEFAULT 'USD', timezone varchar DEFAULT 'UTC', address text, city varchar, postal_code varchar, contact_email varchar,
  contact_phone varchar);
INSERT INTO stores (uuid, namespace_id, name, tax_rate, currency) VALUES ('st-1', 1, 'Workstation Store', 0.2, 'GBP'),
  ('st-2', 2, 'Other Store', 0, 'GBP');
CREATE TABLE storeproducts (id serial PRIMARY KEY, uuid text, store_id integer, name text, sku text, barcode varchar, price numeric,
  track_inventory boolean DEFAULT true, inventory_quantity integer DEFAULT 0, is_active boolean DEFAULT true, images text DEFAULT '[]',
  sort_order integer, category_id integer, namespace_id integer, updated_at timestamp);
CREATE TABLE categories (id serial PRIMARY KEY, uuid text, store_id integer, name text);
CREATE TABLE product_variants (id serial PRIMARY KEY, uuid text UNIQUE, product_id integer, title text, option1 text, option2 text,
  option3 text, sku text, price numeric, compare_price numeric, inventory_quantity integer DEFAULT 0, is_active boolean DEFAULT true,
  position integer DEFAULT 0, created_at timestamp, updated_at timestamp);
INSERT INTO storeproducts (uuid, store_id, name, sku, price, track_inventory, inventory_quantity, is_active) VALUES
  ('sp-1', 1, 'GPU Workstation', 'GW-1', 1999.99, true, 3, true),
  ('sp-2', 1, 'Setup service', 'SET', 150, false, 0, true),
  ('sp-off', 1, 'Old model', 'OLD', 10, false, 0, false),
  ('sp-x', 2, 'Other store item', 'X', 5, false, 0, true);
CREATE TABLE orders (id serial PRIMARY KEY, uuid text, namespace_id integer, store_id integer, customer_id integer, order_number text,
  status varchar DEFAULT 'pending', financial_status varchar DEFAULT 'pending', fulfillment_status varchar, subtotal numeric, tax_amount numeric,
  shipping_amount numeric, discount_amount numeric, total_amount numeric, currency varchar DEFAULT 'USD', billing_address text,
  shipping_address text, customer_notes text, internal_notes text, processed_at timestamp, created_at timestamp, updated_at timestamp,
  source varchar(30), payment_method varchar(30), payment_details jsonb);
CREATE TABLE orderitems (id serial PRIMARY KEY, uuid text, order_id integer, product_id integer, variant_id text, quantity integer,
  price numeric, total numeric, product_title text, variant_title text, sku text, created_at timestamp, updated_at timestamp);
-- an online checkout order from before orders had a workspace (its store's counts)
INSERT INTO orders (uuid, namespace_id, store_id, order_number, status, financial_status, total_amount, currency, created_at)
  VALUES ('so-old', NULL, 1, 'ORD-OLD-1', 'delivered', 'paid', 99.50, 'GBP', NOW() - interval '2 days');
]])
-- helper.table-exists remembers a missing table for a minute: forget what the search checks saw before these existed.
package.loaded["helper.table-exists"] = nil
local M = require("queries.ManualOrderQueries")
local ord, oerr = M.create(1, { store_uuid = "st-1", customer = { email = "Buyer@Example.co.uk", first_name = "Bea" },
    items = { { product_uuid = "sp-1", quantity = 2 }, { product_uuid = "sp-2", quantity = 1 }, { product_uuid = "sp-1", quantity = 1 } },
    shipping_amount = "25.00", discount_amount = "10", paid = true, internal_notes = "Counter sale", channel = "in_person" })
check("an order is created", ord ~= nil, oerr and oerr.message)
if ord then
    check("prices from the products, the same product merged", #ord.items == 2 and ord.items[1].quantity == 3 and ord.subtotal == 6149.97,
        ord.subtotal)
    check("tax from the store's rate (a fraction)", ord.tax_amount == 1229.99, ord.tax_amount)
    check("total = subtotal + tax + shipping - discount", ord.total_amount == 7394.96, ord.total_amount)
    check("paid → confirmed and paid", ord.status == "confirmed" and ord.financial_status == "paid")
    local row = db.query("SELECT namespace_id, source, total_amount, currency FROM orders WHERE uuid = ?", ord.uuid)[1]
    check("saved in this workspace with its channel", row.namespace_id == 1 and row.source == "in_person" and row.currency == "GBP")
    check("stock taken (tracked products only)", db.query("SELECT inventory_quantity FROM storeproducts WHERE uuid = 'sp-1'")[1].inventory_quantity == 0)
    check("the customer is created once, in the workspace, lower-cased",
        #db.query("SELECT 1 FROM customers WHERE namespace_id = 1 AND email = 'buyer@example.co.uk'") == 1)
    check("two order lines saved", #db.query("SELECT 1 FROM orderitems oi JOIN orders o ON o.id = oi.order_id WHERE o.uuid = ?", ord.uuid) == 2)
end
local _, e1 = M.create(1, { store_uuid = "st-1", customer = { email = "buyer@example.co.uk" }, items = { { product_uuid = "sp-1", quantity = 1 } } })
check("not enough stock → 409, nothing saved", e1 and e1.status == 409 and e1.code == "NOT_ENOUGH_STOCK"
    and #db.query("SELECT 1 FROM orders WHERE source IS NOT NULL") == 1, e1 and e1.message)
local _, e6 = M.create(1, { store_uuid = "st-1", customer = { email = "a@b.co" }, items = { { product_uuid = "sp-2", quantity = 1 } },
    channel = "telepathy" })
check("an unknown channel → 422", e6 and e6.status == 422)
local _, e2 = M.create(1, { store_uuid = "st-2", customer = { email = "a@b.co" }, items = { { product_uuid = "sp-x", quantity = 1 } } })
check("another workspace's store → 404", e2 and e2.status == 404)
local _, e3 = M.create(1, { store_uuid = "st-1", customer = { email = "a@b.co" }, items = { { product_uuid = "sp-off", quantity = 1 } } })
check("an inactive product → 422", e3 and e3.status == 422 and e3.code == "PRODUCT_NOT_AVAILABLE")
local _, e4 = M.create(1, { store_uuid = "st-1", customer = { email = "a@b.co" }, items = { { product_uuid = "sp-x", quantity = 1 } } })
check("a product of another store → 422", e4 and e4.status == 422)
local _, e5 = M.create(1, { store_uuid = "st-1", customer = { email = "a@b.co" }, items = { { product_uuid = "sp-2", quantity = 1 } },
    discount_amount = "500" })
check("a discount bigger than the order → 422", e5 and e5.status == 422)
check("no transaction left open", pcall(db.query, "SELECT 1"))

print("point of sale")
db.query("UPDATE storeproducts SET inventory_quantity = 5, barcode = '5012345678900' WHERE uuid = 'sp-1'")
db.query("UPDATE stores SET timezone = 'Europe/London', address = '1 High St', city = 'Hemel', contact_phone = '01234' WHERE uuid = 'st-1'")
local Pos = require("queries.PosQueries")
local catalogue = Pos.products(1, "st-1", "5012345678900")
check("a scanned barcode finds the product", #catalogue.products == 1 and catalogue.products[1].uuid == "sp-1"
    and catalogue.products[1].stock == 5 and catalogue.products[1].available == true)
check("inactive products never at the till", #Pos.products(1, "st-1", "Old model").products == 0)
local _, perr = Pos.products(1, "st-2", "")
check("another workspace's store → 404", perr and perr.status == 404)
local r, serr = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-2", quantity = 2 } },
    payment = { method = "cash", tendered = "400" } })
check("a walk-in cash sale", r ~= nil and r.channel == "pos", serr and serr.message)
if r then
    check("tax at the store's rate and the total", r.subtotal == "300.00" and r.tax == "60.00" and r.total == "360.00", r.total)
    check("change given", r.payment.method == "cash" and r.payment.tendered == "400.00" and r.payment.change == "40.00")
    check("store details on the receipt", r.store.address == "1 High St, Hemel" and r.store.contact == "01234")
    local row = db.query("SELECT status, financial_status, fulfillment_status, customer_id FROM orders WHERE uuid = ?", r.uuid)[1]
    check("paid and handed over, no customer needed", row.status == "delivered" and row.financial_status == "paid"
        and row.fulfillment_status == "fulfilled" and row.customer_id == nil)
end
local _, e7 = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-2", quantity = 1 } }, payment = { method = "cash", tendered = "5" } })
check("too little cash → 422, nothing saved", e7 and e7.status == 422 and #db.query("SELECT 1 FROM orders WHERE source = 'pos'") == 1)
local _, e8 = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-2", quantity = 1 } }, payment = { method = "iou" } })
check("an unknown payment method → 422", e8 and e8.status == 422)
local card = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-1", quantity = 1 } }, payment = { method = "card", reference = "AUTH 1234" },
    customer = { email = "till@example.co.uk" } })
check("a card sale with a customer", card and card.payment.reference == "AUTH 1234" and card.customer_email == "till@example.co.uk")
check("stock taken at the till", db.query("SELECT inventory_quantity FROM storeproducts WHERE uuid = 'sp-1'")[1].inventory_quantity == 4)
local sum = Pos.summary(1, "st-1")
check("the till's day: 2 sales, by method", sum.sales == 2 and #sum.by_method == 2 and sum.timezone == "Europe/London", sum.total)
check("the till's total", sum.total == string.format("%.2f", 360 + 2399.99), sum.total)
check("another day is empty", Pos.summary(1, "st-1", "2001-01-01").sales == 0)
local again = Pos.receipt(1, r and r.uuid)
check("the receipt prints again", again and again.order_number == (r and r.order_number))
check("not another workspace's receipt", Pos.receipt(2, r and r.uuid) == nil)

print("variations at the till")
db.query([[INSERT INTO categories (uuid, store_id, name) VALUES ('cat-1', 1, 'Clothing');
INSERT INTO storeproducts (uuid, store_id, name, sku, price, track_inventory, inventory_quantity, is_active, category_id)
  VALUES ('sp-tee', 1, 'Tee', 'TEE', 10, true, 0, true, (SELECT id FROM categories WHERE uuid = 'cat-1'));
INSERT INTO product_variants (uuid, product_id, title, sku, price, inventory_quantity, is_active, position) VALUES
  ('v-s', (SELECT id FROM storeproducts WHERE uuid = 'sp-tee'), 'Small', 'TEE-S', NULL, 2, true, 1),
  ('v-l', (SELECT id FROM storeproducts WHERE uuid = 'sp-tee'), 'Large', 'TEE-L', 12, 0, true, 2),
  ('v-off', (SELECT id FROM storeproducts WHERE uuid = 'sp-tee'), 'Old', 'TEE-O', 1, 9, false, 3);]])
local cat = Pos.products(1, "st-1", "")
local tee
for _, p in ipairs(cat.products) do if p.uuid == "sp-tee" then tee = p end end
check("the till lists variations (active only) with their own price and stock", tee and #tee.variants == 2
    and tee.variants[1].price == "10.00" and tee.variants[2].price == "12.00" and tee.variants[2].available == false)
check("a product with variations is in stock while one is", tee and tee.available == true and tee.stock == 2)
check("categories for the till's tabs", #cat.categories == 1 and cat.categories[1].name == "Clothing" and tee.category == "Clothing")
check("a variation's SKU finds its product", #Pos.products(1, "st-1", "TEE-L").products == 1)
local _, ev = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-tee", quantity = 1 } }, payment = { method = "card" } })
check("a product with variations needs one chosen", ev and ev.code == "CHOOSE_VARIANT", ev and ev.message)
local _, ev2 = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-tee", variant_uuid = "v-l", quantity = 1 } }, payment = { method = "card" } })
check("an out-of-stock variation is refused", ev2 and ev2.code == "NOT_ENOUGH_STOCK", ev2 and ev2.message)
local _, ev3 = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-tee", variant_uuid = "v-off", quantity = 1 } }, payment = { method = "card" } })
check("an inactive variation is refused", ev3 and ev3.code == "VARIANT_NOT_AVAILABLE")
local vs = Pos.sale(1, { store_uuid = "st-1", items = { { product_uuid = "sp-tee", variant_uuid = "v-s", quantity = 2 } }, payment = { method = "card" } })
check("a variation sells at its price", vs and vs.subtotal == "20.00" and vs.items[1].name == "Tee — Small", vs and vs.items[1].name)
check("the variation's stock is taken, not the product's",
    db.query("SELECT inventory_quantity FROM product_variants WHERE uuid = 'v-s'")[1].inventory_quantity == 0
    and db.query("SELECT inventory_quantity FROM storeproducts WHERE uuid = 'sp-tee'")[1].inventory_quantity == 0)
check("the order line keeps the variation", db.query("SELECT variant_title FROM orderitems WHERE variant_id = 'v-s'")[1].variant_title == "Small")
local sum2 = Pos.summary(1, "st-1")
check("recent sales for reprinting", #sum2.recent == 3 and sum2.recent[1].order_number == vs.order_number)

print("variations (staff)")
local CV = require("queries.CatalogVariantQueries")
local made = CV.create(1, "sp-tee", { option1 = "Medium", option2 = "Blue", sku = "TEE-MB", price = "11.50", stock = 4 })
check("a variation is named from its options", made and made.title == "Medium / Blue" and made.price == "11.50" and made.stock == 4)
local _, dup = CV.create(1, "sp-tee", { title = "Again", sku = "tee-mb" })
check("a SKU is unique within the workspace", dup and dup.status == 409)
local _, other = CV.create(2, "sp-tee", { title = "X" })
check("another workspace's product → 404", other and other.status == 404)
local up = CV.update(1, made.uuid, { price = "", stock = 7, is_active = false })
check("price cleared falls back to the product's; stock and on/off change", up.price == require("cjson").null
    and up.effective_price == "10.00" and up.stock == 7 and up.is_active == false)
local _, bad = CV.update(1, made.uuid, { stock = -1 })
check("negative stock refused", bad and bad.status == 422)
check("listed for staff (inactive too)", #CV.list(1, "sp-tee").variants == 4)
check("removed", CV.remove(1, made.uuid).deleted == true and #CV.list(1, "sp-tee").variants == 3)

print("sales orders (shop + stores)")
local SO = require("queries.SalesOrderQueries")
perms = { ["shop.read"] = true, ["orders.read"] = true }
local list, lm = SO.list(self, 1, {})
local bysrc = {}
for _, r in ipairs(list) do bysrc[r.source] = (bysrc[r.source] or 0) + 1 end
check("shop and store orders together", bysrc.shop == 1 and bysrc.store == 5 and lm.total == 6, (bysrc.shop or 0) .. "/" .. (bysrc.store or 0))
check("point of sale channel", #SO.list(self, 1, { channel = "pos" }) == 3)
check("both sources used", #lm.sources == 2)
check("newest first", list[1].order_number:find("^ORD%-%d") ~= nil, list[1].order_number)
local staff = SO.list(self, 1, { channel = "in_person" })
check("channel filter (in person)", #staff == 1 and staff[1].source == "store" and staff[1].channel == "in_person")
local shopo = SO.list(self, 1, { source = "shop" })
check("shop orders link to the shop order page", #shopo == 1 and shopo[1].path == "/dashboard/shop/orders/o-1" and shopo[1].stage == "delivered")
check("totals in pounds", shopo[1].total == "6307.98")
check("another workspace's orders never show", #SO.list(self, 2, {}) == 0)
check("stats: delivered and revenue", lm.stats.delivered == 5 and lm.stats.revenue.GBP == string.format("%.2f", 13802.44 + 360 + 2399.99 + 24),
    lm.stats.revenue.GBP)
check("stage in_progress", #SO.list(self, 1, { stage = "in_progress" }) == 1)
check("search by customer email", #SO.list(self, 1, { q = "buyer@" }) == 1)
check("date filter", #SO.list(self, 1, { from = os.date("!%Y-%m-%d") }) == 5)
perms = { ["orders.read"] = true }
local only, om = SO.list(self, 1, {})
check("without shop access: store orders only", #only == 5 and #om.sources == 1)
local bad, berr = SO.list(self, 1, { stage = "nonsense" })
check("a bad stage → 400", bad == nil and berr.status == 400)

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
