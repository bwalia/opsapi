-- luacheck: max line length 140
--[[
    Global search (the dashboard's ⌘K): records, not just pages
    ============================================================
    GET /api/v2/search?q=  (routes/global-search.lua) → { query, groups = [{ key, label, items = [{ title, subtitle,
    path }] }], open? (a whole deal code: go straight there) }: customers, leads, CRM accounts/contacts/deals,
    sales and purchase invoices, shop orders, quotes,
    deals, products and stock, suppliers, purchase orders, employees, projects...

    Every kind of record is a provider in one registry, so a new module adds itself with one call and nothing
    else changes (a plugin can call it from its init too):

        Search.provider("invoices", {
            label = "Invoices", order = 40,
            permission = { "invoices", "read" },              -- or any = { {"employees","read"}, {"fs_jobs","read"} }
            needs = { "invoices" },                            -- tables (or "table.column") that must exist
            run = function(ctx) return db.query(...) end,     -- rows { title, subtitle?, path }
        })

    ctx = { self, ns_id, q (trimmed), like ("%q%" escaped), limit, user_uuid }. Each provider runs only when
    its tables exist and the person has the permission (row rules too: a member sees only their own and
    unassigned leads, project members only their projects). A provider that fails is logged and left out;
    the others still answer. Always namespace-scoped.

    Specced by spec/global-search_spec.lua.
]]

local db = require("lapis.db")

local Search = {}
local unpack_ = table.unpack or unpack -- luacheck: ignore 113 143

Search.MIN_QUERY = 2
Search.MAX_QUERY = 100
Search.PER_GROUP = 5

local providers, order = {}, {}

--- Register (or replace) a provider. def = { label, order?, permission? | any?, needs?, run }
function Search.provider(key, def)
    assert(type(key) == "string" and key ~= "", "provider key")
    assert(type(def) == "table" and type(def.run) == "function" and type(def.label) == "string", "provider needs label and run")
    if not providers[key] then order[#order + 1] = key end
    def.key = key
    providers[key] = def
end

function Search.providers()
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = providers[k] end
    table.sort(list, function(a, b) return (a.order or 100) < (b.order or 100) end)
    return list
end

--- "a%b_c" → "%a\%b\_c%" (ILIKE, default escape character).
function Search.like(q)
    return "%" .. tostring(q):gsub("[%%_\\]", "\\%0") .. "%"
end

--- The query cleaned up, or nil when too short.
function Search.clean(q)
    if type(q) ~= "string" then return nil end
    q = q:gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #q < Search.MIN_QUERY then return nil end
    return q:sub(1, Search.MAX_QUERY)
end

local function join(sep, ...)
    local out = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil and v ~= db.NULL and tostring(v):match("%S") then out[#out + 1] = tostring(v) end
    end
    return table.concat(out, sep)
end
Search.join = join

local function exists(spec)
    local t, c = spec:match("^([%w_]+)%.([%w_]+)$")
    return require("helper.table-exists")(t or spec, c)
end

local function allowed(self, def)
    local NS = require("middleware.namespace")
    if def.permission then return NS.hasPermission(self, def.permission[1], def.permission[2]) end
    if def.any then
        for _, p in ipairs(def.any) do
            if NS.hasPermission(self, p[1], p[2]) then return true end
        end
        return false
    end
    return true
end

--- Run every provider the person may use. → { query, groups }
function Search.run(self, raw_q, opts)
    opts = opts or {}
    local q = Search.clean(raw_q)
    if not q then return { query = raw_q or "", groups = {} } end
    local ctx = { self = self, ns_id = self.namespace.id, q = q, like = Search.like(q), limit = opts.limit or Search.PER_GROUP,
                  user_uuid = self.current_user and self.current_user.uuid or nil }
    local groups = {}
    for _, def in ipairs(Search.providers()) do
        local ready = true
        for _, t in ipairs(def.needs or {}) do
            if not exists(t) then ready = false break end
        end
        if ready and allowed(self, def) then
            local ok, rows = pcall(def.run, ctx)
            if not ok then
                ngx.log(ngx.ERR, "[search] ", def.key, ": ", tostring(rows))
            elseif type(rows) == "table" and #rows > 0 then
                local items = {}
                for i, r in ipairs(rows) do
                    if i > ctx.limit then break end
                    if r.title and r.path then
                        items[#items + 1] = { title = tostring(r.title), subtitle = (r.subtitle and r.subtitle ~= "") and r.subtitle or nil,
                                              path = r.path }
                    end
                end
                if #items > 0 then groups[#groups + 1] = { key = def.key, label = def.label, items = items } end
            end
        end
    end
    return { query = q, groups = groups, open = ctx.open }
end

-- ---------------------------------------------------------------------------
-- Built-in providers
-- ---------------------------------------------------------------------------

local function money(v, cur)
    local n = tonumber(v)
    if not n then return nil end
    return string.format("%s %.2f", cur or "GBP", n)
end

local function name(first, last, fallback)
    local n = join(" ", first, last)
    return n ~= "" and n or fallback
end

Search.provider("deals", {
    label = "Deals", order = 5, permission = { "shop", "read" }, needs = { "shop_deal_codes" },
    run = function(ctx)
        local res = require("queries.ShopDealQueries").search(ctx.ns_id, ctx.q)
        -- A whole deal code: the palette opens the deal straight away.
        if type(res.exact) == "string" then ctx.open = "/dashboard/shop/deals/" .. ngx.escape_uri(res.exact) end
        local out = {}
        for _, r in ipairs(res.results or {}) do
            out[#out + 1] = { title = "Deal " .. r.deal_code, path = "/dashboard/shop/deals/" .. ngx.escape_uri(r.deal_code),
                subtitle = join(" · ", r.customer ~= db.NULL and r.customer or nil,
                    tostring(r.matched_by):gsub("_", " ") .. ": " .. tostring(r.match)) }
        end
        return out
    end,
})

Search.provider("customers", {
    label = "Customers", order = 10, permission = { "customers", "read" }, needs = { "customers.namespace_id" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT uuid, first_name, last_name, email, phone FROM customers
            WHERE namespace_id = ? AND (email ILIKE ? OR first_name ILIKE ? OR last_name ILIKE ? OR phone ILIKE ?
                  OR concat_ws(' ', first_name, last_name) ILIKE ?)
            ORDER BY id DESC LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = name(r.first_name, r.last_name, r.email), subtitle = join(" · ", r.email, r.phone),
                path = "/dashboard/customers/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("leads", {
    label = "Leads", order = 15, permission = { "crm_leads", "read" }, needs = { "crm_leads" },
    run = function(ctx)
        local scope, svals = require("lib.crm.lead-access").scope(ctx.self, "l")
        local code = require("helper.table-exists")("crm_leads", "deal_code") and " OR l.deal_code ILIKE ?" or ""
        local args = { ctx.ns_id }
        for _ = 1, 6 do args[#args + 1] = ctx.like end
        if code ~= "" then args[#args + 1] = ctx.like end
        for _, v in ipairs(svals) do args[#args + 1] = v end
        args[#args + 1] = ctx.limit + 1
        local out = {}
        for _, r in ipairs(db.query([[SELECT l.uuid, l.first_name, l.last_name, l.email, l.company_name, l.status FROM crm_leads l
            WHERE l.namespace_id = ? AND l.deleted_at IS NULL
              AND (l.email ILIKE ? OR l.first_name ILIKE ? OR l.last_name ILIKE ? OR l.phone ILIKE ? OR l.company_name ILIKE ?
                   OR concat_ws(' ', l.first_name, l.last_name) ILIKE ?]] .. code .. [[)
              AND ]] .. scope .. [[
            ORDER BY l.created_at DESC LIMIT ?]], unpack_(args))) do
            out[#out + 1] = { title = name(r.first_name, r.last_name, r.company_name or r.email),
                subtitle = join(" · ", r.company_name, r.email, r.status), path = "/dashboard/leads/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("crm_accounts", {
    label = "Accounts", order = 20, permission = { "crm_accounts", "read" }, needs = { "crm_accounts" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT uuid, name, industry, email, city FROM crm_accounts
            WHERE namespace_id = ? AND deleted_at IS NULL
              AND (name ILIKE ? OR email ILIKE ? OR phone ILIKE ? OR website ILIKE ? OR postal_code ILIKE ?)
            ORDER BY name LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = r.name, subtitle = join(" · ", r.industry, r.email, r.city), path = "/dashboard/crm/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("crm_contacts", {
    label = "Contacts", order = 21, permission = { "crm_contacts", "read" }, needs = { "crm_contacts", "crm_accounts" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT c.first_name, c.last_name, c.email, c.job_title, a.uuid AS account_uuid, a.name AS account
            FROM crm_contacts c LEFT JOIN crm_accounts a ON a.id = c.account_id AND a.deleted_at IS NULL
            WHERE c.namespace_id = ? AND c.deleted_at IS NULL
              AND (c.email ILIKE ? OR c.first_name ILIKE ? OR c.last_name ILIKE ? OR c.phone ILIKE ? OR c.mobile ILIKE ?
                   OR concat_ws(' ', c.first_name, c.last_name) ILIKE ?)
            ORDER BY c.id DESC LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = name(r.first_name, r.last_name, r.email), subtitle = join(" · ", r.job_title, r.account, r.email),
                path = r.account_uuid and ("/dashboard/crm/" .. r.account_uuid) or "/dashboard/crm" }
        end
        return out
    end,
})

Search.provider("crm_deals", {
    label = "CRM deals", order = 22, permission = { "crm_deals", "read" }, needs = { "crm_deals", "crm_accounts" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT d.name, d.stage, d.value, d.currency, a.uuid AS account_uuid, a.name AS account
            FROM crm_deals d LEFT JOIN crm_accounts a ON a.id = d.account_id AND a.deleted_at IS NULL
            WHERE d.namespace_id = ? AND d.deleted_at IS NULL AND (d.name ILIKE ? OR a.name ILIKE ?)
            ORDER BY d.id DESC LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = r.name, subtitle = join(" · ", r.account, r.stage, money(r.value, r.currency)),
                path = r.account_uuid and ("/dashboard/crm/" .. r.account_uuid) or "/dashboard/crm" }
        end
        return out
    end,
})

Search.provider("invoices", {
    label = "Invoices", order = 30, permission = { "invoices", "read" }, needs = { "invoices" },
    run = function(ctx)
        local cust_no = require("helper.table-exists")("invoices", "customer_invoice_number")
        local args = { ctx.ns_id, ctx.like, ctx.like, ctx.like }
        if cust_no then args[#args + 1] = ctx.like end
        args[#args + 1] = ctx.limit + 1
        local out = {}
        for _, r in ipairs(db.query([[SELECT uuid, invoice_number, ]] .. (cust_no and "customer_invoice_number" or "NULL")
            .. [[ AS customer_invoice_number, customer_name, status, total_amount, currency FROM invoices
            WHERE namespace_id = ? AND deleted_at IS NULL
              AND (invoice_number ILIKE ? OR customer_name ILIKE ? OR customer_email ILIKE ?]]
            .. (cust_no and " OR customer_invoice_number ILIKE ?" or "") .. [[)
            ORDER BY id DESC LIMIT ?]], unpack_(args))) do
            out[#out + 1] = { title = (r.customer_invoice_number ~= db.NULL and r.customer_invoice_number) or r.invoice_number,
                subtitle = join(" · ", r.customer_name, r.status, money(r.total_amount, r.currency)),
                path = "/dashboard/invoices/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("shop_orders", {
    label = "Shop orders", order = 31, permission = { "shop", "read" },
    needs = { "shop_orders.customer_po_number", "shop_orders.deal_code" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT o.uuid, o.order_number, o.status, o.email, o.customer->>'name' AS name,
                o.customer->>'company' AS company, o.total_minor, o.currency
            FROM shop_orders o WHERE o.namespace_id = ?
              AND (o.order_number ILIKE ? OR o.email ILIKE ? OR o.customer->>'name' ILIKE ? OR o.customer->>'company' ILIKE ?
                   OR COALESCE(o.customer_po_number, '') ILIKE ? OR COALESCE(o.deal_code, '') ILIKE ?)
            ORDER BY o.created_at DESC LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = r.order_number, subtitle = join(" · ", r.company or r.name, r.email,
                tostring(r.status):gsub("_", " "), money((tonumber(r.total_minor) or 0) / 100, r.currency)),
                path = "/dashboard/shop/orders/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("shop_quotes", {
    label = "Quotes", order = 32, permission = { "shop", "read" }, needs = { "shop_quotes.deal_code", "shop_quotes.superseded_by_id" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT q.uuid, q.quote_number, q.status, q.customer->>'name' AS name,
                q.customer->>'company' AS company,
                q.customer->>'email' AS email
            FROM shop_quotes q WHERE q.namespace_id = ? AND q.superseded_by_id IS NULL
              AND (q.quote_number ILIKE ? OR q.customer->>'email' ILIKE ? OR q.customer->>'name' ILIKE ?
                   OR q.customer->>'company' ILIKE ? OR COALESCE(q.deal_code, '') ILIKE ?)
            ORDER BY q.created_at DESC LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = r.quote_number, subtitle = join(" · ", r.company or r.name, r.email, r.status),
                path = "/dashboard/shop/quotes/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("shop_products", {
    label = "Products & stock", order = 40, permission = { "shop", "read" },
    needs = { "shop_products", "shop_options", "shop_option_groups" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[
            SELECT p.uuid, p.name, p.sku, p.brand, p.status, p.stock_qty, NULL AS option_name
              FROM shop_products p
             WHERE p.namespace_id = ? AND (p.name ILIKE ? OR p.sku ILIKE ? OR p.brand ILIKE ?)
            UNION ALL
            SELECT p.uuid, p.name, o.code, p.brand, p.status, o.stock_qty, o.name
              FROM shop_options o JOIN shop_option_groups g ON g.id = o.group_id JOIN shop_products p ON p.id = g.product_id
             WHERE p.namespace_id = ? AND (o.name ILIKE ? OR o.code ILIKE ?)
            LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.like, ctx.ns_id, ctx.like, ctx.like, ctx.limit + 1)) do
            local stock = tonumber(r.stock_qty)
            out[#out + 1] = { title = r.option_name ~= db.NULL and r.option_name and (r.name .. " › " .. r.option_name) or r.name,
                subtitle = join(" · ", r.sku, stock and (stock .. " in stock") or "stock not tracked",
                    r.status ~= "active" and r.status or nil),
                path = "/dashboard/shop/products/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("shop_suppliers", {
    label = "Suppliers", order = 41, permission = { "shop", "read" }, needs = { "shop_suppliers" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT name, contact_email, is_active FROM shop_suppliers
            WHERE namespace_id = ? AND (name ILIKE ? OR contact_email ILIKE ?) ORDER BY name LIMIT ?]],
            ctx.ns_id, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = r.name, subtitle = join(" · ", r.contact_email, r.is_active == false and "not active" or nil),
                path = "/dashboard/shop/suppliers" }
        end
        return out
    end,
})

Search.provider("purchase_orders", {
    label = "Purchase orders", order = 50, permission = { "purchase_orders", "read" }, needs = { "purchase_orders" },
    run = function(ctx)
        local code = require("helper.table-exists")("purchase_orders", "deal_code")
        local args = { ctx.ns_id, ctx.like, ctx.like, ctx.like }
        if code then args[#args + 1] = ctx.like end
        args[#args + 1] = ctx.limit + 1
        local out = {}
        for _, r in ipairs(db.query([[SELECT uuid, po_number, supplier_name, status, total, currency FROM purchase_orders
            WHERE namespace_id = ? AND deleted_at IS NULL
              AND (po_number ILIKE ? OR supplier_name ILIKE ? OR COALESCE(reference, '') ILIKE ?]]
            .. (code and " OR COALESCE(deal_code, '') ILIKE ?" or "") .. [[)
            ORDER BY created_at DESC LIMIT ?]], unpack_(args))) do
            out[#out + 1] = { title = r.po_number, subtitle = join(" · ", r.supplier_name, r.status, money(r.total, r.currency)),
                path = "/dashboard/purchase-orders/" .. r.uuid }
        end
        return out
    end,
})

Search.provider("purchase_invoices", {
    label = "Purchase invoices", order = 51, permission = { "purchase_orders", "read" },
    needs = { "purchase_order_supplier_invoices", "purchase_orders" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT i.number, i.kind, i.total, i.currency, po.uuid AS po_uuid, po.po_number, po.supplier_name
            FROM purchase_order_supplier_invoices i JOIN purchase_orders po ON po.id = i.purchase_order_id AND po.deleted_at IS NULL
            WHERE i.namespace_id = ? AND i.deleted_at IS NULL AND (i.number ILIKE ? OR COALESCE(i.supplier_order_ref, '') ILIKE ?)
            ORDER BY i.created_at DESC LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = r.number, subtitle = join(" · ", r.supplier_name, tostring(r.kind):gsub("_", " "), r.po_number,
                money(r.total, r.currency)), path = "/dashboard/purchase-orders/" .. r.po_uuid }
        end
        return out
    end,
})

Search.provider("employees", {
    label = "Employees", order = 60, any = { { "employees", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" } },
    needs = { "employees.namespace_id" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT u.first_name, u.last_name, COALESCE(u.email, e.email) AS email, e.job_title
            FROM employees e LEFT JOIN users u ON u.uuid = e.user_uuid
            WHERE e.namespace_id = ? AND e.deleted_at IS NULL
              AND (u.first_name ILIKE ? OR u.last_name ILIKE ? OR u.email ILIKE ? OR e.email ILIKE ? OR e.job_title ILIKE ?
                   OR concat_ws(' ', u.first_name, u.last_name) ILIKE ?)
            ORDER BY u.first_name LIMIT ?]], ctx.ns_id, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = name(r.first_name, r.last_name, r.email), subtitle = join(" · ", r.job_title, r.email),
                path = "/dashboard/employees" }
        end
        return out
    end,
})

Search.provider("projects", {
    label = "Projects", order = 70, permission = { "projects", "read" }, needs = { "kanban_projects", "kanban_project_members" },
    run = function(ctx)
        local out = {}
        for _, r in ipairs(db.query([[SELECT p.uuid, p.name, p.status FROM kanban_projects p
            JOIN kanban_project_members pm ON pm.project_id = p.id AND pm.user_uuid = ? AND pm.left_at IS NULL
            WHERE p.namespace_id = ? AND p.deleted_at IS NULL AND (p.name ILIKE ? OR p.slug ILIKE ?)
            ORDER BY p.name LIMIT ?]], ctx.user_uuid or "", ctx.ns_id, ctx.like, ctx.like, ctx.limit + 1)) do
            out[#out + 1] = { title = r.name, subtitle = r.status, path = "/dashboard/projects/" .. r.uuid }
        end
        return out
    end,
})

return Search
