-- luacheck: max line length 140
-- luacheck: globals ngx
--[[
    Plain-Lua test for "never price below cost": lib/shop-cost.lua, the pricing engine's below_cost check,
    the admin product save (queries/ShopCatalogQueries.lua), the supplier sync (queries/ShopSupplierQueries.lua),
    quote lines (queries/ShopQuoteQueries.lua priceLines) and the public product shape — with the DB and the
    notifier stubbed (no nginx, no DB, nothing is sent).

    Run from the repo root (as CI does) or from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/shop-cost-floor_spec.lua
]]

package.path = "./?.lua;./lapis/?.lua;/usr/local/openresty/lualib/?.lua;" .. package.path
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath -- cjson

local cjson = require("cjson")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

ngx = { -- luacheck: ignore 111
    log = function() end, ERR = 1, WARN = 2, NOTICE = 3, ctx = {}, now = os.time,
    encode_base64 = function(s) return s end,
    timer = { at = function() return true end },
}

-- ---------------------------------------------------------------------------
-- stubs
-- ---------------------------------------------------------------------------

local S
local function reset()
    S = {
        sql = {}, updates = {}, inserts = {}, notifies = {}, alerted = {},
        product = { id = 1, uuid = "p-1", sku = "WS-1", slug = "ws-1", name = "Workstation", price_mode = "fixed",
                    base_price_minor = 100000, stock_qty = 0, specs = "{}", attributes = "{}", images = "[]", tags = "[]",
                    vat_rate = 0.2, status = "active", lead_time_days = 10, allow_backorder = true },
        manual_cost = nil, supplier_cost = nil,
        groups = {},
        options = {},       -- id -> { id, group_id, code, name, delta, manual_cost, component_price, component_cost }
        reprice_rows = {},  -- supplier reprice candidates
        last_change = nil,  -- latest shop_price_changes row
    }
end
reset()

local function has(sql, s) return sql:find(s, 1, true) ~= nil end

local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
local function val(v) if v == NULL then return nil end return v end

local function option_rows()
    local out = {}
    local ids = {}
    for id in pairs(S.options) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local o = S.options[id]
        local follows = o.component_price ~= nil and o.component_price > 0
        out[#out + 1] = {
            id = o.id, uuid = "o-" .. o.id, group_id = o.group_id, code = o.code, name = o.name,
            price_delta_minor = follows and o.component_price or o.delta, stored_price_delta_minor = o.delta,
            price_follows_component = follows, component_product_id = o.component_price and 99 or nil,
            max_qty = o.max_qty or 1, is_default = o.is_default or false, is_active = true, sort_order = 10,
            attributes = "{}",
            cost_minor = o.component_cost or o.manual_cost, manual_cost_minor = o.manual_cost,
            component_cost_minor = o.component_cost,
        }
    end
    return out
end

package.loaded["lapis.db"] = {
    NULL = NULL,
    raw = function(s) return s end,
    escape_literal = function(s) return "'" .. tostring(s) .. "'" end,
    array = function(t) return t end,
    list = function(t) return t end,
    query = function(sql, ...)
        local a = { ... }
        S.sql[#S.sql + 1] = sql
        if sql == "BEGIN" or sql == "COMMIT" or sql == "ROLLBACK" then return {} end
        -- catalogue
        if has(sql, "SELECT id, uuid, sku, slug, name, stock_qty FROM shop_products") then
            local p = S.product
            return { { id = p.id, uuid = p.uuid, sku = p.sku, slug = p.slug, name = p.name, stock_qty = p.stock_qty } }
        end
        if has(sql, "SELECT sku FROM shop_products WHERE namespace_id = ? AND slug") then return {} end
        if has(sql, "FROM shop_products p LEFT JOIN shop_categories c") then
            local r = {}
            for k, v in pairs(S.product) do r[k] = v end
            return { r }
        end
        if has(sql, "AS manual_cost_minor, si.cost_minor AS supplier_cost_minor") then
            return { { manual_cost_minor = S.manual_cost, supplier_cost_minor = S.supplier_cost } }
        end
        if has(sql, "FROM shop_option_groups WHERE product_id") then return S.groups end
        if has(sql, "SELECT id FROM shop_option_groups WHERE product_id = ? AND code = ?") then
            for _, g in ipairs(S.groups) do if g.code == a[2] then return { { id = g.id } } end end
            return {}
        end
        if has(sql, "SELECT id FROM shop_options WHERE group_id = ? AND code = ?") then
            for id, o in pairs(S.options) do if o.group_id == a[1] and o.code == a[2] then return { { id = id } } end end
            return {}
        end
        if has(sql, "FROM shop_options o") and has(sql, "WHERE g.product_id = ?") then return option_rows() end
        if has(sql, "FROM shop_rules WHERE product_id") then return {} end
        if has(sql, "SELECT uuid FROM shop_products WHERE id = ?") then return { { uuid = S.product.uuid } } end
        -- supplier sync
        if has(sql, "JOIN shop_supplier_items i ON i.id = p.supplier_item_id") then return S.reprice_rows end
        if has(sql, "FROM shop_price_changes") and has(sql, "ORDER BY id DESC LIMIT 1") then
            return S.last_change and { S.last_change } or {}
        end
        if has(sql, "INSERT INTO shop_price_changes") then
            S.inserts[#S.inserts + 1] = { sql = sql, args = a }
            if has(sql, "'blocked_below_cost'") then
                S.last_change = { status = "blocked_below_cost", new_price_minor = a[6], cost_minor = a[7] }
            end
            return {}
        end
        if has(sql, "UPDATE shop_products SET base_price_minor") then S.updates[#S.updates + 1] = sql return {} end
        -- staff alerts
        if has(sql, "INSERT INTO shop_cost_alerts") then
            local key = tostring(a[2])
            if S.alerted[key] then return {} end
            S.alerted[key] = true
            return { { product_id = a[2] } }
        end
        if has(sql, "SELECT id, name FROM namespaces") then return { { id = 3, name = "Workstation" } } end
        return {}
    end,
    update = function(tbl, fields, where)
        S.updates[#S.updates + 1] = { tbl = tbl, fields = fields }
        if tbl == "shop_products" then
            if fields.base_price_minor ~= nil then S.product.base_price_minor = fields.base_price_minor end
            if fields.cost_minor ~= nil then S.manual_cost = val(fields.cost_minor) end
        elseif tbl == "shop_options" then
            local o = S.options[where.id]
            if o then
                if fields.price_delta_minor ~= nil then o.delta = fields.price_delta_minor end
                if fields.cost_minor ~= nil then o.manual_cost = val(fields.cost_minor) end
            end
        end
    end,
    insert = function() return { { id = 1000 } } end,
}
package.loaded["helper.global"] = { generateUUID = function() return "uuid-" .. tostring(#S.sql) end }
package.loaded["queries.ShopStockQueries"] = {
    forProducts = function() return {} end, forOptions = function() return {} end,
    availability = function(a, l) return { available = a, lead_time_days = l } end, recordMovement = function() end,
}
package.loaded["queries.ShopInsightsQueries"] = { snapshotPrices = function() end, recordCartAdd = function() end }
package.loaded["queries.CrmLeadNotificationQueries"] = {
    notify = function(ns, lead, opts) S.notifies[#S.notifies + 1] = { ns = ns, lead = lead, opts = opts } end,
}
package.loaded["queries.ShopSettingsQueries"] = { orderAlertEmail = function() return "orders@ws.example" end }
package.loaded["queries.ShopLeadQueries"] = {}
package.loaded["queries.PaymentMethodQueries"] = {}

local Cost = require("lib.shop-cost")
local Pricing = require("lib.shop-pricing")
local Catalog = require("queries.ShopCatalogQueries")
local Suppliers = require("queries.ShopSupplierQueries")
local CostQ = require("queries.ShopCostQueries")
local Quote = require("queries.ShopQuoteQueries")

local function rolled_back()
    for _, q in ipairs(S.sql) do if q == "ROLLBACK" then return true end end
    return false
end

-- ---------------------------------------------------------------------------
-- lib/shop-cost.lua
-- ---------------------------------------------------------------------------

check("effective: supplier cost wins over manual", Cost.effective(12000, 9000) == 12000)
check("effective: manual when no supplier cost", Cost.effective(nil, 9000) == 9000)
check("effective: unknown when neither", Cost.effective(nil, nil) == nil)
check("parse: absent = unset", Cost.parse(nil, cjson.null) == "unset")
check("parse: null clears", Cost.parse(cjson.null, cjson.null) == "clear")
do
    local k, v = Cost.parse(4250, cjson.null)
    check("parse: integer sets", k == "set" and v == 4250)
    local _, _, err = Cost.parse(-1, cjson.null)
    check("parse: negative refused", err ~= nil)
    _, _, err = Cost.parse(12.5, cjson.null)
    check("parse: fraction refused", err ~= nil)
    _, _, err = Cost.parse("abc", cjson.null)
    check("parse: text refused", err ~= nil)
end
check("below: unknown cost never blocks", Cost.below(100, nil) == false)
do
    local v = Cost.check_product({ name = "WS", base_price_minor = 70900, cost_minor = 76000 }, {})
    check("check_product: product below cost", #v == 1 and v[1].kind == "product" and v[1].message:find("£709.00", 1, true)
        and v[1].message:find("£760.00", 1, true), v[1] and v[1].message)
    v = Cost.check_product({ name = "WS", price_mode = "quote_only", base_price_minor = 0, cost_minor = 76000 }, {})
    check("check_product: quote_only has no list price to check", #v == 0)
    v = Cost.check_product({ name = "WS", base_price_minor = 100000 }, { { code = "psu", options = {
        { code = "1200w", name = "1200 W 80 PLUS Platinum", price_delta_minor = 8900, cost_minor = 14500 },
        { code = "1000w", name = "1000 W", price_delta_minor = 0 },
        { code = "gpu", name = "RTX", price_delta_minor = 100, cost_minor = 500000, price_follows_component = true },
        { code = "old", name = "Old", price_delta_minor = 1, cost_minor = 500, is_active = false },
    } } })
    check("check_product: option below cost blocked; unknown, follows-component and inactive pass",
        #v == 1 and v[1].kind == "option" and v[1].option_code == "1200w", #v)
    check("summary names item, price and cost", Cost.summary(v):find("1200 W 80 PLUS Platinum", 1, true)
        and Cost.summary(v):find("£89.00", 1, true) and Cost.summary(v):find("£145.00", 1, true))
end

-- ---------------------------------------------------------------------------
-- pricing engine
-- ---------------------------------------------------------------------------

local function groups_psu(opt_cost)
    return { { code = "psu", name = "PSU", selection = "single", required = true, min_qty = 1, max_qty = 1, options = {
        { code = "850w", name = "850 W", price_delta_minor = 0, is_default = true, cost_minor = 9000 },
        { code = "1200w", name = "1200 W 80 PLUS Platinum", price_delta_minor = 8900, cost_minor = opt_cost },
    } } }
end
do
    local product = { slug = "ws", name = "WS", base_price_minor = 200000, price_mode = "configurable", cost_minor = 150000 }
    local priced, _, cost = Pricing.price(product, groups_psu(14500), {}, { psu = "850w" }, 1)
    check("engine: priced above cost is valid", priced.valid and cost.known and cost.unit_cost_minor == 159000)
    -- 1200 W option sold at +£89 while the base margin is thin: unit 208,900 < cost 150,000 + 60,000
    product.cost_minor = 195000
    priced, _, cost = Pricing.price(product, groups_psu(14500), {}, { psu = "1200w" }, 2)
    check("engine: configured line below cost is invalid (below_cost)", priced.valid == false and cost.below_cost
        and cost.unit_cost_minor == 209500, cost.unit_cost_minor)
    local v = priced.violations[1]
    check("engine: customer message has no cost", v and v.rule == "below_cost" and v.message == Pricing.PRICE_CHECK_MESSAGE
        and not v.message:find("%d"))
    local enc = cjson.encode(priced)
    -- (the violation's rule name "below_cost" is the only mention; no cost field, no cost figure)
    check("engine: priced output carries no cost", not enc:find("cost_minor", 1, true) and not enc:find("209500", 1, true)
        and not enc:find('"cost"', 1, true), enc)
    check("below_cost helper honours a staff price", Pricing.below_cost(209500, cost) == false
        and Pricing.below_cost(209499, cost) == true)
    -- option qty multiplies the option cost like its price
    local g = groups_psu(14500)
    g[1].selection, g[1].max_qty, g[1].options[2].max_qty = "multi", 4, 4
    priced, _, cost = Pricing.price({ base_price_minor = 0, cost_minor = 0 }, g, {}, { psu = { { option = "1200w", qty = 3 } } }, 1)
    check("engine: option cost × qty", cost.unit_cost_minor == 43500 and priced.unit_price_minor == 26700 and cost.below_cost)
end
do
    -- fixed product, SSD sold at £709 with a known cost of £760
    local priced, _, cost = Pricing.price({ name = "4 TB SSD", base_price_minor = 70900, price_mode = "fixed",
        cost_minor = 76000 }, {}, {}, nil, 1)
    check("engine: fixed line below cost is invalid", not priced.valid and cost.below_cost)
    priced, _, cost = Pricing.price({ name = "4 TB SSD", base_price_minor = 70900, price_mode = "fixed" }, {}, {}, nil, 1)
    check("engine: unknown cost passes", priced.valid and cost.known == false and not cost.below_cost)
    priced, _, cost = Pricing.price({ name = "X", base_price_minor = 0, price_mode = "quote_only", cost_minor = 500 }, {}, {}, nil, 1)
    check("engine: unpriced quote_only is not blocked", priced.valid and not cost.below_cost)
    -- only the known parts count: base cost unknown, option cost known and covered
    priced, _, cost = Pricing.price({ base_price_minor = 100000, price_mode = "configurable" }, groups_psu(nil), {},
        { psu = "850w" }, 1)
    check("engine: partial cost (known parts only)", priced.valid and cost.known and cost.unit_cost_minor == 9000)
end

-- ---------------------------------------------------------------------------
-- admin save (ShopCatalogQueries.saveProduct)
-- ---------------------------------------------------------------------------

do
    reset()
    S.product.name, S.product.base_price_minor = "4 TB SSD", 80000
    local res, err = Catalog.saveProduct(3, { base_price_minor = 70900, cost_minor = 76000 }, { uuid = "p-1", ignore_stock = true })
    check("admin save: product below cost refused with 422 BELOW_COST", res == nil and err and err.status == 422
        and err.code == "BELOW_COST", err and err.code)
    check("admin save: message names item, price and cost", err and err.message:find("4 TB SSD", 1, true)
        and err.message:find("£709.00", 1, true) and err.message:find("£760.00", 1, true), err and err.message)
    check("admin save: rolled back", rolled_back())
    check("admin save: items listed", err and err.items and err.items[1].kind == "product" and err.items[1].cost_minor == 76000)

    reset()
    S.supplier_cost = 76000
    S.product.base_price_minor = 80000
    res, err = Catalog.saveProduct(3, { base_price_minor = 70900, cost_minor = 10000 }, { uuid = "p-1", ignore_stock = true })
    check("admin save: supplier cost wins over a lower manual cost", res == nil and err and err.code == "BELOW_COST")

    reset()
    res, err = Catalog.saveProduct(3, { cost_minor = -5 }, { uuid = "p-1" })
    check("admin save: negative cost is a 400", res == nil and err and err.status == 400, err and err.message)

    reset()
    res, err = Catalog.saveProduct(3, { base_price_minor = 90000, cost_minor = 76000 }, { uuid = "p-1", ignore_stock = true })
    check("admin save: above cost saves", res ~= nil and err == nil and S.manual_cost == 76000, err and err.message)

    reset()
    res = Catalog.saveProduct(3, { base_price_minor = 50000 }, { uuid = "p-1", ignore_stock = true })
    check("admin save: unknown cost never blocks", res ~= nil)
end

do
    -- option: the 1200 W PSU upgrade at +£89 with a cost of £145
    reset()
    S.product.price_mode = "configurable"
    S.groups = { { id = 10, uuid = "g-10", code = "psu", name = "PSU", selection = "single", required = true, min_qty = 1,
                   max_qty = 1, sort_order = 10, is_active = true } }
    S.options[100] = { id = 100, group_id = 10, code = "1200w", name = "1200 W 80 PLUS Platinum", delta = 8900 }
    local doc = { option_groups = { { code = "psu", name = "PSU", options = {
        { code = "1200w", name = "1200 W 80 PLUS Platinum", price_delta_minor = 8900, cost_minor = 14500 } } } } }
    local res, err = Catalog.saveProduct(3, doc, { uuid = "p-1", ignore_stock = true })
    check("admin save: option below cost refused", res == nil and err and err.code == "BELOW_COST"
        and err.items[1].kind == "option" and err.items[1].option_code == "1200w", err and err.message)
    check("admin save: option message names option, price and cost", err and err.message:find("1200 W 80 PLUS Platinum", 1, true)
        and err.message:find("£89.00", 1, true) and err.message:find("£145.00", 1, true), err and err.message)

    doc.option_groups[1].options[1].price_delta_minor = 17900
    res, err = Catalog.saveProduct(3, doc, { uuid = "p-1", ignore_stock = true })
    check("admin save: option above cost saves", res ~= nil, err and err.message)

    -- follows-component: the option's own check is skipped (the component product's save covers it)
    reset()
    S.product.price_mode = "configurable"
    S.groups = { { id = 10, uuid = "g-10", code = "gpu", name = "GPU", selection = "single", min_qty = 0, max_qty = 1,
                   sort_order = 10, is_active = true } }
    S.options[200] = { id = 200, group_id = 10, code = "rtx", name = "RTX PRO 6000", delta = 0,
                       component_price = 700000, component_cost = 650000 }
    res, err = Catalog.saveProduct(3, { option_groups = { { code = "gpu", options = { { code = "rtx", price_delta_minor = 0 } } } } },
        { uuid = "p-1", ignore_stock = true })
    check("admin save: follows-component option not blocked by its stored delta", res ~= nil, err and err.message)
    -- …but a component option whose component is unpriced is checked against the component's cost
    S.options[200].component_price = 0
    res, err = Catalog.saveProduct(3, { option_groups = { { code = "gpu", options = { { code = "rtx", price_delta_minor = 0 } } } } },
        { uuid = "p-1", ignore_stock = true })
    check("admin save: unpriced component option checked against component cost", res == nil and err
        and err.code == "BELOW_COST", err and err.code)
end

-- ---------------------------------------------------------------------------
-- public shapes never carry cost
-- ---------------------------------------------------------------------------

do
    reset()
    S.product.price_mode = "configurable"
    S.manual_cost, S.supplier_cost = 61234, 61234
    S.groups = { { id = 10, uuid = "g-10", code = "psu", name = "PSU", selection = "single", required = true, min_qty = 1,
                   max_qty = 1, sort_order = 10, is_active = true } }
    S.options[100] = { id = 100, group_id = 10, code = "1200w", name = "1200 W", delta = 8900, manual_cost = 4321,
                       is_default = true }
    local bundle = Catalog.loadBundle(3, { slug = "ws-1" }, { public = true })
    check("loadBundle: effective costs loaded", bundle.product.cost_minor == 61234 and bundle.groups[1].options[1].cost_minor == 4321)
    local full = cjson.encode(Catalog.fullProduct(bundle))
    check("public product: no cost field or value", not full:find("cost", 1, true) and not full:find("61234", 1, true)
        and not full:find("4321", 1, true), full:match('"[%w_]*cost[%w_]*"'))
    local card = cjson.encode(Catalog.card(bundle.product))
    check("public card: no cost", not card:find("cost", 1, true) and not card:find("61234", 1, true))
    local priced = Catalog.priceBundle(bundle, nil, 1)
    local line = cjson.encode(Catalog.lineSnapshot(bundle, priced))
    check("cart/quote line snapshot: no cost", not line:find("cost", 1, true) and not line:find("61234", 1, true), line)
    local admin = Catalog.adminDocument(3, "p-1")
    check("admin document: exposes cost fields", admin.cost_minor == 61234 and admin.effective_cost_minor == 61234
        and admin.cost_source == "supplier" and admin.option_groups[1].options[1].cost_minor == 4321
        and admin.option_groups[1].options[1].cost_source == "option")
end

-- ---------------------------------------------------------------------------
-- supplier sync
-- ---------------------------------------------------------------------------

do
    reset()
    S.reprice_rows = { { id = 5, uuid = "p-5", sku = "SSD-4TB", name = "4 TB SSD", base_price_minor = 80000, margin_pct = -10,
        supplier_item_id = 7, price_mode = "fixed", pricing_source = "supplier", cost_minor = 76000, item_active = true,
        threshold_pct = 10, update_lead_times = false } }
    local out = Suppliers.repriceProduct(3, 5)
    local applied = false
    for _, u in ipairs(S.updates) do if type(u) == "string" and has(u, "base_price_minor") then applied = true end end
    check("sync: below-cost price not applied (not clamped)", not applied)
    check("sync: counted and listed in the result", out.blocked_below_cost == 1 and out.blocked[1].sku == "SSD-4TB"
        and out.blocked[1].new_price_minor == 68400 and out.applied == 0 and out.pending == 0)
    check("sync: recorded as blocked_below_cost", #S.inserts == 1 and has(S.inserts[1].sql, "'blocked_below_cost'"))
    Suppliers.repriceProduct(3, 5)
    check("sync: the same blocked move is recorded once", #S.inserts == 1, #S.inserts)

    reset()
    S.reprice_rows = { { id = 5, sku = "SSD-4TB", name = "4 TB SSD", base_price_minor = 80000, margin_pct = 15,
        supplier_item_id = 7, price_mode = "fixed", pricing_source = "supplier", cost_minor = 76000, item_active = true,
        threshold_pct = 10, update_lead_times = false } }
    out = Suppliers.repriceProduct(3, 5)
    check("sync: a price above cost still applies", out.applied == 1 and out.blocked_below_cost == 0)
end

-- ---------------------------------------------------------------------------
-- quotes / orders: lines below cost
-- ---------------------------------------------------------------------------

do
    reset()
    S.product.name, S.product.base_price_minor, S.manual_cost = "4 TB SSD", 70900, 76000
    -- customer quote: 409, no cost in the message, one staff alert per product per day
    local lines, err = Quote.priceLines(3, { { product_slug = "ws-1", qty = 1 } })
    check("quote (customer): refused with PRICE_CHECK_REQUIRED", lines == nil and err and err.status == 409
        and err.code == "PRICE_CHECK_REQUIRED", err and err.code)
    check("quote (customer): message has no cost", err and not err.message:find("760", 1, true)
        and not err.message:find("709", 1, true) and err.message:find("price check", 1, true), err and err.message)
    check("quote (customer): staff alerted with price and cost", #S.notifies == 1
        and S.notifies[1].lead.notes:find("£760.00", 1, true) and S.notifies[1].opts.staff ~= nil)
    Quote.priceLines(3, { { product_slug = "ws-1", qty = 1 } })
    check("staff alert at most once per product per day", #S.notifies == 1, #S.notifies)

    -- staff quote: 422 BELOW_COST naming the cost; a staff price above cost is fine
    lines, err = Quote.priceLines(3, { { product_slug = "ws-1", qty = 1 } }, { admin = true })
    check("quote (staff): list price below cost refused with BELOW_COST", lines == nil and err and err.code == "BELOW_COST"
        and err.message:find("£760.00", 1, true), err and err.message)
    lines, err = Quote.priceLines(3, { { product_slug = "ws-1", qty = 1, price_override_minor = 70000 } }, { admin = true })
    check("quote (staff): override below cost refused", lines == nil and err and err.code == "BELOW_COST")
    lines, err = Quote.priceLines(3, { { product_slug = "ws-1", qty = 1, price_override_minor = 80000 } }, { admin = true })
    check("quote (staff): override above cost accepted, line valid", lines ~= nil and lines[1].unit_price_minor == 80000
        and lines[1].valid == true, err and err.message)

    -- a snapshot whose price has fallen below today's cost (quote checkout / bank transfer / basket checkout)
    local blocked = CostQ.checkLines(3, { { uuid = "l-1", product_uuid = "p-1", qty = 2, unit_price_minor = 70900 },
        { uuid = "l-2", custom = true, unit_price_minor = 1 } })
    check("checkLines: snapshot below current cost found, custom lines skipped", #blocked == 1 and blocked[1].line_uuid == "l-1"
        and blocked[1].unit_cost_minor == 76000)
    blocked = CostQ.checkLines(3, { { uuid = "l-1", product_uuid = "p-1", qty = 1, unit_price_minor = 76000 } })
    check("checkLines: at cost passes", #blocked == 0)

    reset()
    S.product.base_price_minor = 70900
    blocked = CostQ.checkLines(3, { { uuid = "l-1", product_uuid = "p-1", qty = 1, unit_price_minor = 70900 } })
    check("checkLines: unknown cost passes", #blocked == 0)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
