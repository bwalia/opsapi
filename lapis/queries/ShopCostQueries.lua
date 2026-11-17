-- luacheck: max line length 140
--[[
    Never price below cost — DB side (FEATURES.SHOP)
    ================================================

    The rule itself is in lib/shop-cost.lua (admin check) and lib/shop-pricing.lua (a priced line below its
    known cost is invalid: below_cost). This module:

      checkLines(ns_id, lines)      → lines (cart/quote/order snapshots) whose unit price is below the current
                                      cost of what they hold (re-priced from the catalogue; staff prices and
                                      quote_only overrides count as the line's price)
      refuse(ns_id, blocked, ctx)   → the customer-facing 409 PRICE_CHECK_REQUIRED (no cost in it) + a staff
                                      alert, at most one per product per day (shop_cost_alerts)
      alert(ns_id, info)            → that staff alert on its own
      adminError(blocked)           → the staff-facing 422 BELOW_COST (names item, price, cost)
      report(ns_id, params)         → GET /api/v2/shop/admin/pricing/below-cost

    Unknown cost never blocks.
]]

local db = require("lapis.db")
local U = require("lib.shop-util")
local Cost = require("lib.shop-cost")
local Pricing = require("lib.shop-pricing")

local Q = {}

-- ---------------------------------------------------------------------------
-- line checks
-- ---------------------------------------------------------------------------

--- Lines (priced snapshots) whose unit price is below the current known cost of their configuration.
-- Free-text (custom) lines have no catalogue cost and are skipped, as are unpriced quote_only lines.
-- Returns { { line_uuid, product_id, product_uuid, product_name, sku, qty, unit_price_minor, unit_cost_minor } }.
function Q.checkLines(ns_id, lines)
    local Catalog = require("queries.ShopCatalogQueries")
    local out = {}
    for _, l in ipairs(type(lines) == "table" and lines or {}) do
        if type(l) == "table" and not l.custom and U.nz(l.product_uuid) then
            local unpriced = l.price_mode == "quote_only" and tonumber(l.price_override_minor) == nil
            local bundle = not unpriced and Catalog.loadBundle(ns_id, { uuid = l.product_uuid })
            if bundle then
                local sel = l.selections
                if type(sel) ~= "table" then sel = nil end
                local _, _, cost = Catalog.priceBundle(bundle, sel, tonumber(l.qty) or 1)
                local unit = tonumber(l.unit_price_minor) or 0
                if Pricing.below_cost(unit, cost) then
                    out[#out + 1] = {
                        line_uuid = l.uuid, product_id = bundle.product.id, product_uuid = bundle.product.uuid,
                        product_name = bundle.product.name, sku = bundle.product.sku, qty = tonumber(l.qty) or 1,
                        unit_price_minor = unit, unit_cost_minor = cost.unit_cost_minor,
                    }
                end
            end
        end
    end
    return out
end

--- Staff-facing error for blocked lines (quote editing, Order Authorisations, revisions).
function Q.adminError(blocked)
    local parts, items = {}, {}
    for i, b in ipairs(blocked) do
        local msg = string.format("%s: price %s is below its cost %s", tostring(b.product_name or b.sku or "item"),
            Cost.money(b.unit_price_minor), Cost.money(b.unit_cost_minor))
        if i <= 5 then parts[#parts + 1] = msg end
        items[#items + 1] = {
            kind = "line", name = b.product_name, line_uuid = b.line_uuid, line_index = b.line_index,
            price_minor = b.unit_price_minor, cost_minor = b.unit_cost_minor, message = msg,
        }
    end
    if #blocked > 5 then parts[#parts + 1] = string.format("and %d more", #blocked - 5) end
    return U.err(422, "BELOW_COST", "Below cost, not saved: " .. table.concat(parts, "; "), { items = U.arr(items) })
end

-- ---------------------------------------------------------------------------
-- staff alert (at most once per product per day)
-- ---------------------------------------------------------------------------

local CONTEXT = {
    cart = "added to a basket",
    checkout = "taken to checkout",
    quote = "put on a quote",
    order = "ordered",
}

--- Tell staff a customer was stopped at a below-cost price. info = { product_id, product_uuid?, product_name,
-- sku, unit_price_minor, unit_cost_minor, context = cart|checkout|quote|order, ref? }. Never throws; must be
-- called outside a transaction that is about to roll back (the once-a-day row would roll back with it).
function Q.alert(ns_id, info)
    local ok, err = pcall(function()
        if not info or not tonumber(info.product_id) then return end
        local first = db.query([[
            INSERT INTO shop_cost_alerts (namespace_id, product_id, day) VALUES (?, ?, CURRENT_DATE)
            ON CONFLICT (product_id, day) DO NOTHING RETURNING product_id
        ]], ns_id, info.product_id)[1]
        if not first then return end -- already alerted today
        local ns = db.query("SELECT id, name FROM namespaces WHERE id = ?", ns_id)[1]
        if not ns then return end
        local name = tostring(info.product_name or info.sku or "A product")
        local base = (U.env("FRONTEND_URL") or ""):gsub("/+$", "")
        local notes = U.join("\n",
            name .. (U.nz(info.sku) and (" (" .. info.sku .. ")") or ""),
            "Unit price " .. Cost.money(info.unit_price_minor) .. " ex VAT is below its cost "
                .. Cost.money(info.unit_cost_minor) .. " ex VAT.",
            "A customer tried to have it " .. (CONTEXT[info.context] or "ordered") .. (U.nz(info.ref) and (" (" .. info.ref .. ")") or "")
                .. " and was told it needs a price check and that we will be in touch.",
            "",
            "Fix the price (or the cost) in Shop → Products; Shop → Below cost lists everything affected.",
            (base ~= "" and U.nz(info.product_uuid)) and ("Open the product: " .. base .. "/dashboard/shop/products/"
                .. info.product_uuid) or nil)
        require("queries.CrmLeadNotificationQueries").notify(ns, {
            first_name = "Price check", last_name = name, source = "shop_below_cost", notes = notes,
        }, {
            to = require("queries.ShopSettingsQueries").orderAlertEmail(ns_id),
            purpose = "shop_alerts",
            staff = {
                subject = "Price check needed: " .. name .. " is priced below cost",
                headline = "Priced below cost",
                intro = "A customer was stopped because " .. name .. " is priced below its cost. Nothing was sold. "
                    .. "Please correct the price and get back to the customer.",
                telegram_title = "⚠️ <b>Priced below cost</b> " .. name:gsub("[<>&]", ""),
            },
        })
    end)
    if not ok then
        if ngx then ngx.log(ngx.WARN, "[shop-cost] below-cost alert failed: ", tostring(err)) end
    end
end

--- The customer-facing refusal for blocked lines: alerts staff (once per product per day) and returns the
-- 409 PRICE_CHECK_REQUIRED error. The cost is never in it.
function Q.refuse(ns_id, blocked, context, ref)
    local names, lines, seen = {}, {}, {}
    for _, b in ipairs(blocked) do
        if not seen[b.product_id] then
            seen[b.product_id] = true
            names[#names + 1] = tostring(b.product_name or b.sku or "an item")
            Q.alert(ns_id, {
                product_id = b.product_id, product_uuid = b.product_uuid, product_name = b.product_name, sku = b.sku,
                unit_price_minor = b.unit_price_minor, unit_cost_minor = b.unit_cost_minor, context = context, ref = ref,
            })
        end
        lines[#lines + 1] = { line_uuid = b.line_uuid or U.null, name = b.product_name, reason = "below_cost" }
    end
    return U.err(409, "PRICE_CHECK_REQUIRED", table.concat(names, ", ") .. ": " .. Cost.PRICE_CHECK_MESSAGE,
        { lines = U.arr(lines) })
end

-- ---------------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------------

--- GET /pricing/below-cost: products and options priced below known cost, how many active products/options
-- have no known cost, and (include_quotes) draft/sent quotes with a line below current cost.
function Q.report(ns_id, params)
    params = params or {}
    local Catalog = require("queries.ShopCatalogQueries")
    local P, O = Catalog.PRODUCT_COST_SQL, Catalog.OPTION_COST_SQL
    local products = db.query([[
        SELECT p.uuid, p.sku, p.name, p.status, p.price_mode, p.base_price_minor AS price_minor,
               ]] .. P .. [[ AS cost_minor,
               CASE WHEN si.cost_minor IS NOT NULL THEN 'supplier' ELSE 'manual' END AS cost_source
          FROM shop_products p LEFT JOIN shop_supplier_items si ON si.id = p.supplier_item_id
         WHERE p.namespace_id = ? AND p.status <> 'archived' AND p.price_mode <> 'quote_only'
           AND ]] .. P .. [[ IS NOT NULL AND p.base_price_minor < ]] .. P .. [[
         ORDER BY (p.base_price_minor - ]] .. P .. [[), p.name
    ]], ns_id)
    for _, r in ipairs(products) do
        r.price_minor, r.cost_minor = tonumber(r.price_minor), tonumber(r.cost_minor)
        r.margin_minor = r.price_minor - r.cost_minor
    end
    -- options whose own price is below their cost; one that follows its component is that product's problem
    local OPRICE = [[CASE WHEN cp.id IS NOT NULL AND cp.price_mode <> 'quote_only' AND cp.base_price_minor > 0
                          THEN cp.base_price_minor ELSE o.price_delta_minor END]]
    local FOLLOWS = "(cp.id IS NOT NULL AND cp.price_mode <> 'quote_only' AND cp.base_price_minor > 0)"
    local options = db.query([[
        SELECT p.uuid AS product_uuid, p.sku AS product_sku, p.name AS product_name, g.code AS group_code,
               g.name AS group_name, o.code AS option_code, o.name AS option_name,
               ]] .. OPRICE .. [[ AS price_minor, ]] .. O .. [[ AS cost_minor,
               CASE WHEN COALESCE(csi.cost_minor, cp.cost_minor) IS NOT NULL THEN 'component' ELSE 'option' END
                   AS cost_source
          FROM shop_options o
          JOIN shop_option_groups g ON g.id = o.group_id
          JOIN shop_products p ON p.id = g.product_id
          LEFT JOIN shop_products cp ON cp.id = o.component_product_id
          LEFT JOIN shop_supplier_items csi ON csi.id = cp.supplier_item_id
         WHERE p.namespace_id = ? AND p.status <> 'archived' AND o.is_active AND g.is_active
           AND NOT ]] .. FOLLOWS .. [[
           AND ]] .. O .. [[ IS NOT NULL AND ]] .. OPRICE .. [[ < ]] .. O .. [[
         ORDER BY p.name, g.sort_order, o.sort_order
    ]], ns_id)
    for _, r in ipairs(options) do
        r.price_minor, r.cost_minor = tonumber(r.price_minor), tonumber(r.cost_minor)
        r.margin_minor = r.price_minor - r.cost_minor
    end
    local missing = db.query([[
        SELECT (SELECT COUNT(*)::int FROM shop_products p LEFT JOIN shop_supplier_items si ON si.id = p.supplier_item_id
                 WHERE p.namespace_id = ? AND p.status = 'active' AND ]] .. P .. [[ IS NULL) AS products,
               (SELECT COUNT(*)::int FROM shop_options o
                  JOIN shop_option_groups g ON g.id = o.group_id
                  JOIN shop_products p ON p.id = g.product_id
                  LEFT JOIN shop_products cp ON cp.id = o.component_product_id
                  LEFT JOIN shop_supplier_items csi ON csi.id = cp.supplier_item_id
                 WHERE p.namespace_id = ? AND p.status = 'active' AND o.is_active AND g.is_active
                   AND ]] .. O .. [[ IS NULL) AS options
    ]], ns_id, ns_id)[1] or {}
    local missing_products = db.query([[
        SELECT p.uuid, p.sku, p.name FROM shop_products p LEFT JOIN shop_supplier_items si ON si.id = p.supplier_item_id
         WHERE p.namespace_id = ? AND p.status = 'active' AND ]] .. P .. [[ IS NULL
         ORDER BY p.name LIMIT 50
    ]], ns_id)
    local out = {
        products = U.arr(products),
        options = U.arr(options),
        missing_cost = { products = tonumber(missing.products) or 0, options = tonumber(missing.options) or 0 },
        missing_cost_products = U.arr(missing_products),
    }
    local iq = params.include_quotes
    if iq == true or iq == "true" or iq == "1" then
        local quotes = {}
        local rows = db.query([[
            SELECT uuid, quote_number, status, COALESCE(kind, 'quote') AS kind, customer::text AS customer,
                   lines::text AS lines
              FROM shop_quotes
             WHERE namespace_id = ? AND status IN ('draft', 'sent')
             ORDER BY created_at DESC LIMIT 200
        ]], ns_id)
        for _, q in ipairs(rows) do
            local blocked = Q.checkLines(ns_id, U.dec(q.lines, {}))
            if #blocked > 0 then
                local ls = {}
                for _, b in ipairs(blocked) do
                    ls[#ls + 1] = { line_uuid = b.line_uuid or U.null, product_name = b.product_name, qty = b.qty,
                        unit_price_minor = b.unit_price_minor, unit_cost_minor = b.unit_cost_minor }
                end
                quotes[#quotes + 1] = { uuid = q.uuid, quote_number = q.quote_number, status = q.status, kind = q.kind,
                    customer_name = U.dec(q.customer, {}).name or U.null, lines = U.arr(ls) }
            end
        end
        out.quotes = U.arr(quotes)
    end
    return out
end

return Q
