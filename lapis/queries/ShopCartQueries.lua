-- luacheck: max line length 140
--[[
    Shop carts (server-priced)
    ==========================
    A cart is addressed by an opaque random token (X-Cart-Token); only
    sha256(token) is stored. Every read re-prices each line through the
    pricing engine — stored unit_price_minor is informational only.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Pricing = require("lib.shop-pricing")
local Catalog = require("queries.ShopCatalogQueries")

local ShopCartQueries = {}

local CART_DAYS = 30

function ShopCartQueries.create(ns_id, params)
    params = params or {}
    local token = U.token(32)
    local row = db.query([[
        INSERT INTO shop_carts (uuid, namespace_id, token_hash, status, email, currency, expires_at, last_seen_at,
                                created_at, updated_at)
        VALUES (?, ?, ?, 'active', ?, 'GBP', NOW() + (? || ' days')::interval, NOW(), NOW(), NOW())
        RETURNING *
    ]], Global.generateUUID(), ns_id, U.sha256_hex(token), U.nz(params.email) or db.NULL, tostring(CART_DAYS))[1]
    if U.nz(params.chat_session_uuid) then
        ShopCartQueries.attachChat(ns_id, row, params.chat_session_uuid)
    end
    return row, token
end

--- Active cart for a token (nil when missing / expired / converted).
function ShopCartQueries.byToken(ns_id, token, opts)
    opts = opts or {}
    if not U.nz(token) or #token < 20 or #token > 200 then return nil end
    local rows = db.query([[
        SELECT * FROM shop_carts WHERE namespace_id = ? AND token_hash = ? AND expires_at > NOW()
    ]], ns_id, U.sha256_hex(token))
    local cart = rows[1]
    if not cart then return nil end
    if not opts.any_status and cart.status ~= "active" then return nil end
    db.query("UPDATE shop_carts SET last_seen_at = NOW() WHERE id = ?", cart.id)
    return cart
end

--- Re-price all lines. Returns (Cart, notices).
-- opts.token adds the token (create only); opts.persist updates stored prices.
function ShopCartQueries.view(ns_id, cart, opts)
    opts = opts or {}
    local rows = db.query([[
        SELECT l.id, l.uuid, l.product_id, l.qty, l.selections::text AS selections, l.unit_price_minor, l.label,
               p.status AS product_status, p.name AS product_name, p.uuid AS product_uuid
          FROM shop_cart_lines l JOIN shop_products p ON p.id = l.product_id
         WHERE l.cart_id = ? ORDER BY l.sort_order, l.id
    ]], cart.id)
    local lines, notices, demand_lines = {}, {}, {}
    local has_quote_only = false
    for _, r in ipairs(rows) do
        if r.product_status ~= "active" then
            db.query("DELETE FROM shop_cart_lines WHERE id = ?", r.id)
            notices[#notices + 1] = {
                code = "LINE_REMOVED",
                message = (r.product_name or "A product") .. " is no longer available and was removed from your cart",
                line_uuid = r.uuid,
            }
        else
            local bundle = Catalog.loadBundle(ns_id, { id = r.product_id }, { public = true })
            local priced, demand = Catalog.priceBundle(bundle, U.dec(r.selections, {}), r.qty)
            local line = Catalog.lineSnapshot(bundle, priced, r.uuid)
            if bundle.product.price_mode == "quote_only" then has_quote_only = true end
            if tonumber(r.unit_price_minor) ~= line.unit_price_minor then
                if opts.persist ~= false then
                    db.query("UPDATE shop_cart_lines SET unit_price_minor = ?, label = ?, updated_at = NOW() WHERE id = ?",
                        line.unit_price_minor, line.label, r.id)
                end
                if tonumber(r.unit_price_minor) and tonumber(r.unit_price_minor) > 0 then
                    notices[#notices + 1] = { code = "PRICE_CHANGED", line_uuid = r.uuid,
                        message = "The price of " .. bundle.product.name .. " has changed" }
                end
            end
            lines[#lines + 1] = line
            demand_lines[#demand_lines + 1] = { line = line, demand = demand, bundle = bundle }
        end
    end
    local t = Pricing.totals(lines, 0)
    local out = {
        uuid = cart.uuid,
        status = cart.status,
        currency = cart.currency or "GBP",
        email = cart.email or U.null,
        lines = U.arr(lines),
        subtotal_minor = t.subtotal_minor,
        vat_minor = t.vat_minor,
        shipping_minor = t.shipping_minor,
        total_minor = t.total_minor,
        item_count = t.item_count,
        has_quote_only = has_quote_only,
        expires_at = cart.expires_at,
    }
    if opts.token then out.token = opts.token end
    return out, U.arr(notices), demand_lines
end

local function find_line(cart_id, line_uuid)
    return db.query([[
        SELECT l.*, l.selections::text AS selections_text, p.slug AS product_slug
          FROM shop_cart_lines l JOIN shop_products p ON p.id = l.product_id
         WHERE l.cart_id = ? AND l.uuid = ?
    ]], cart_id, line_uuid)[1]
end

--- Add a line. Returns (Cart, notices) or (nil, err) — err has `violations`
-- (422) when the configuration is invalid. Identical configurations merge.
function ShopCartQueries.addLine(ns_id, cart, body)
    local priced, bundle_or_err = Catalog.priceRequest(ns_id, body)
    if not priced then return nil, bundle_or_err end
    local bundle = bundle_or_err
    if not priced.valid then
        return nil, U.err(422, "INVALID_CONFIGURATION", "This configuration is not valid",
            { violations = priced.violations, data = priced })
    end
    local key = Pricing.selection_key(priced.selections)
    local existing = db.query([[
        SELECT id, qty, selections::text AS selections FROM shop_cart_lines WHERE cart_id = ? AND product_id = ?
    ]], cart.id, bundle.product.id)
    local merged
    for _, r in ipairs(existing) do
        if Pricing.selection_key(U.dec(r.selections, {})) == key then merged = r break end
    end
    if merged then
        local new_qty = merged.qty + priced.qty
        local repriced = Catalog.priceBundle(bundle, priced.selections, new_qty)
        if not repriced.valid then
            return nil, U.err(422, "INVALID_CONFIGURATION", "This configuration is not valid",
                { violations = repriced.violations, data = repriced })
        end
        db.query("UPDATE shop_cart_lines SET qty = ?, unit_price_minor = ?, label = ?, updated_at = NOW() WHERE id = ?",
            new_qty, repriced.unit_price_minor, repriced.label, merged.id)
    else
        local n = db.query("SELECT COUNT(*)::int AS n FROM shop_cart_lines WHERE cart_id = ?", cart.id)[1].n
        if n >= 50 then return nil, U.err(400, "CART_FULL", "A cart can hold at most 50 lines") end
        db.query([[
            INSERT INTO shop_cart_lines (uuid, cart_id, product_id, qty, selections, unit_price_minor, label, sort_order,
                                         created_at, updated_at)
            VALUES (?, ?, ?, ?, ?::jsonb, ?, ?, ?, NOW(), NOW())
        ]], Global.generateUUID(), cart.id, bundle.product.id, priced.qty, U.enc(priced.selections),
            priced.unit_price_minor, priced.label, n)
    end
    db.query("UPDATE shop_carts SET updated_at = NOW() WHERE id = ?", cart.id)
    return ShopCartQueries.view(ns_id, cart)
end

function ShopCartQueries.updateLine(ns_id, cart, line_uuid, body)
    local line = find_line(cart.id, line_uuid)
    if not line then return nil, U.err(404, "LINE_NOT_FOUND", "Cart line not found") end
    local qty = body.qty ~= nil and U.int(body.qty, nil) or line.qty
    if not qty then return nil, U.err(400, "VALIDATION_ERROR", "qty must be an integer") end
    if qty <= 0 then return ShopCartQueries.removeLine(ns_id, cart, line_uuid) end
    local selections = body.selections
    if selections == nil or selections == cjson.null then selections = U.dec(line.selections_text, {}) end
    local priced, bundle_or_err = Catalog.priceRequest(ns_id,
        { product_slug = line.product_slug, qty = qty, selections = selections })
    if not priced then return nil, bundle_or_err end
    if not priced.valid then
        return nil, U.err(422, "INVALID_CONFIGURATION", "This configuration is not valid",
            { violations = priced.violations, data = priced })
    end
    db.query([[UPDATE shop_cart_lines SET qty = ?, selections = ?::jsonb, unit_price_minor = ?, label = ?,
               updated_at = NOW() WHERE id = ?]],
        priced.qty, U.enc(priced.selections), priced.unit_price_minor, priced.label, line.id)
    db.query("UPDATE shop_carts SET updated_at = NOW() WHERE id = ?", cart.id)
    return ShopCartQueries.view(ns_id, cart)
end

function ShopCartQueries.removeLine(ns_id, cart, line_uuid)
    local line = find_line(cart.id, line_uuid)
    if not line then return nil, U.err(404, "LINE_NOT_FOUND", "Cart line not found") end
    db.query("DELETE FROM shop_cart_lines WHERE id = ?", line.id)
    db.query("UPDATE shop_carts SET updated_at = NOW() WHERE id = ?", cart.id)
    return ShopCartQueries.view(ns_id, cart)
end

function ShopCartQueries.attachChat(ns_id, cart, chat_session_uuid)
    local s = db.query("SELECT id FROM shop_chat_sessions WHERE namespace_id = ? AND uuid = ?", ns_id,
        chat_session_uuid)[1]
    if not s then return nil, U.err(404, "CHAT_SESSION_NOT_FOUND", "Chat session not found") end
    db.query("UPDATE shop_carts SET chat_session_id = ?, updated_at = NOW() WHERE id = ?", s.id, cart.id)
    db.query("UPDATE shop_chat_sessions SET cart_id = ?, updated_at = NOW() WHERE id = ?", cart.id, s.id)
    return true
end

function ShopCartQueries.markConverted(cart_id)
    if not U.nz(cart_id) then return end
    db.query("UPDATE shop_carts SET status = 'converted', updated_at = NOW() WHERE id = ? AND status <> 'converted'",
        cart_id)
end

return ShopCartQueries
