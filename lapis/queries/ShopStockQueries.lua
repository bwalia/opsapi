--[[
    Shop stock: availability, reservations, movements, stock sheet
    ===============================================================

    Availability of a product/option = stock_qty − Σ(held, unexpired reservations).
    Options with component_product_id take stock from that product; options with
    stock_qty NULL and no component are untracked (always available).
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local Global = require("helper.global")
local U = require("lib.shop-util")

local ShopStockQueries = {}

local function id_list(ids)
    local out, seen = {}, {}
    for _, id in ipairs(ids or {}) do
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

--- { [product_id] = { stock_qty, held, available } }
function ShopStockQueries.forProducts(ids)
    ids = id_list(ids)
    local map = {}
    if #ids == 0 then return map end
    local rows = db.query([[
        SELECT p.id, p.stock_qty,
               COALESCE((SELECT SUM(r.qty) FROM shop_stock_reservations r
                          WHERE r.product_id = p.id AND r.status = 'held' AND r.expires_at > NOW()), 0)::int AS held
          FROM shop_products p WHERE p.id = ANY(?)
    ]], db.array(ids))
    for _, r in ipairs(rows) do
        local stock = tonumber(r.stock_qty) or 0
        local held = tonumber(r.held) or 0
        map[r.id] = { stock_qty = stock, held = held, available = stock - held }
    end
    return map
end

--- { [option_id] = { stock_qty, held, available } } (only options with own stock)
function ShopStockQueries.forOptions(ids)
    ids = id_list(ids)
    local map = {}
    if #ids == 0 then return map end
    local rows = db.query([[
        SELECT o.id, o.stock_qty,
               COALESCE((SELECT SUM(r.qty) FROM shop_stock_reservations r
                          WHERE r.option_id = o.id AND r.status = 'held' AND r.expires_at > NOW()), 0)::int AS held
          FROM shop_options o WHERE o.id = ANY(?) AND o.stock_qty IS NOT NULL
    ]], db.array(ids))
    for _, r in ipairs(rows) do
        local stock = tonumber(r.stock_qty) or 0
        local held = tonumber(r.held) or 0
        map[r.id] = { stock_qty = stock, held = held, available = stock - held }
    end
    return map
end

--- Public availability object for an available-count (nil = untracked).
function ShopStockQueries.availability(available, lead_time_days)
    if available == nil then
        return { in_stock = true, qty_available = U.null, lead_time_days = lead_time_days }
    end
    return {
        in_stock = available > 0,
        qty_available = math.max(0, available),
        lead_time_days = lead_time_days,
    }
end

-- ---------------------------------------------------------------------------
-- movements / adjustments
-- ---------------------------------------------------------------------------

local REASONS = { adjustment = true, sale = true, release = true, restock = true, import = true }
ShopStockQueries.REASONS = REASONS

function ShopStockQueries.recordMovement(ns_id, fields)
    db.query([[
        INSERT INTO shop_stock_movements (uuid, namespace_id, product_id, option_id, delta, reason, ref, user_id,
                                          created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
    ]], Global.generateUUID(), ns_id, fields.product_id or db.NULL, fields.option_id or db.NULL,
        fields.delta, fields.reason, fields.ref or db.NULL, fields.user_id or db.NULL)
end

--- Adjust a product's stock by delta; returns the updated availability row.
function ShopStockQueries.adjustProduct(ns_id, product_uuid, delta, reason, note, user_id)
    delta = U.int(delta, nil)
    if not delta or delta == 0 then return nil, U.err(400, "VALIDATION_ERROR", "delta must be a non-zero integer") end
    reason = reason or "adjustment"
    if not REASONS[reason] then return nil, U.err(400, "VALIDATION_ERROR", "invalid reason") end
    return U.tx(function()
        local rows = db.query([[
            UPDATE shop_products SET stock_qty = stock_qty + ?, updated_at = NOW()
             WHERE namespace_id = ? AND uuid = ? RETURNING id, uuid, sku, name, stock_qty
        ]], delta, ns_id, product_uuid)
        local p = rows[1]
        if not p then return nil, U.err(404, "NOT_FOUND", "Product not found") end
        ShopStockQueries.recordMovement(ns_id, { product_id = p.id, delta = delta, reason = reason,
            ref = note, user_id = user_id })
        local a = ShopStockQueries.forProducts({ p.id })[p.id]
        return { kind = "product", uuid = p.uuid, sku = p.sku, name = p.name,
                 qty = a.stock_qty, held = a.held, available = a.available }
    end)
end

--- Adjust an option's stock. Options backed by a component product adjust
-- that product instead; untracked options (NULL) start tracking from 0.
function ShopStockQueries.adjustOption(ns_id, option_uuid, delta, reason, note, user_id)
    delta = U.int(delta, nil)
    if not delta or delta == 0 then return nil, U.err(400, "VALIDATION_ERROR", "delta must be a non-zero integer") end
    reason = reason or "adjustment"
    if not REASONS[reason] then return nil, U.err(400, "VALIDATION_ERROR", "invalid reason") end
    local rows = db.query([[
        SELECT o.id, o.uuid, o.code, o.name, o.component_product_id, cp.uuid AS component_uuid
          FROM shop_options o
          JOIN shop_option_groups g ON g.id = o.group_id
          JOIN shop_products p ON p.id = g.product_id
          LEFT JOIN shop_products cp ON cp.id = o.component_product_id
         WHERE p.namespace_id = ? AND o.uuid = ?
    ]], ns_id, option_uuid)
    local o = rows[1]
    if not o then return nil, U.err(404, "NOT_FOUND", "Option not found") end
    if U.nz(o.component_product_id) then
        return ShopStockQueries.adjustProduct(ns_id, o.component_uuid, delta, reason, note, user_id)
    end
    return U.tx(function()
        db.query("UPDATE shop_options SET stock_qty = COALESCE(stock_qty, 0) + ?, updated_at = NOW() WHERE id = ?",
            delta, o.id)
        ShopStockQueries.recordMovement(ns_id, { option_id = o.id, delta = delta, reason = reason,
            ref = note, user_id = user_id })
        local a = ShopStockQueries.forOptions({ o.id })[o.id]
        return { kind = "option", uuid = o.uuid, code = o.code, name = o.name,
                 qty = a.stock_qty, held = a.held, available = a.available }
    end)
end

-- ---------------------------------------------------------------------------
-- reservations
-- ---------------------------------------------------------------------------

--- Hold stock for an order. `demand` = engine demand rows ({stock_key, qty}).
function ShopStockQueries.hold(ns_id, order_id, demand, minutes)
    for _, d in ipairs(demand or {}) do
        local kind, id = tostring(d.stock_key or ""):match("^(%a):(%d+)$")
        if kind and d.qty and d.qty > 0 then
            db.query([[
                INSERT INTO shop_stock_reservations (uuid, namespace_id, product_id, option_id, qty, order_id,
                                                     status, expires_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'held', NOW() + (? || ' minutes')::interval, NOW(), NOW())
            ]], Global.generateUUID(), ns_id,
                kind == "p" and tonumber(id) or db.NULL,
                kind == "o" and tonumber(id) or db.NULL,
                d.qty, order_id, tostring(minutes or 35))
        end
    end
end

--- Release an order's held reservations.
function ShopStockQueries.release(order_id)
    db.query([[
        UPDATE shop_stock_reservations SET status = 'released', updated_at = NOW()
         WHERE order_id = ? AND status = 'held'
    ]], order_id)
end

--- Commit an order's reservations (held OR released-by-expiry — the money was
-- taken, so the stock goes) and decrement stock with sale movements. Idempotent:
-- rows already 'committed' are skipped.
function ShopStockQueries.commit(ns_id, order_id, order_number)
    local rows = db.query([[
        UPDATE shop_stock_reservations SET status = 'committed', updated_at = NOW()
         WHERE order_id = ? AND status <> 'committed'
        RETURNING product_id, option_id, qty
    ]], order_id)
    for _, r in ipairs(rows) do
        local pid, oid = U.nz(r.product_id), U.nz(r.option_id)
        if pid then
            db.query("UPDATE shop_products SET stock_qty = stock_qty - ?, updated_at = NOW() WHERE id = ?", r.qty, pid)
        elseif oid then
            db.query([[UPDATE shop_options SET stock_qty = COALESCE(stock_qty, 0) - ?, updated_at = NOW()
                        WHERE id = ?]], r.qty, oid)
        end
        ShopStockQueries.recordMovement(ns_id, { product_id = pid, option_id = oid, delta = -r.qty,
            reason = "sale", ref = order_number })
    end
    return #rows
end

--- Housekeeping: release held reservations past expiry whose order is no longer
-- awaiting payment (pending orders are handled by the reconciler, which asks
-- Stripe first).
function ShopStockQueries.releaseStale(ns_id)
    local sql = [[
        UPDATE shop_stock_reservations r SET status = 'released', updated_at = NOW()
          FROM shop_orders o
         WHERE o.id = r.order_id AND r.status = 'held' AND r.expires_at < NOW()
           AND o.status <> 'pending_payment'
    ]]
    if ns_id then
        return db.query(sql .. " AND r.namespace_id = ?", ns_id)
    end
    return db.query(sql)
end

-- ---------------------------------------------------------------------------
-- admin stock sheet + movements
-- ---------------------------------------------------------------------------

function ShopStockQueries.sheet(ns_id, params)
    params = params or {}
    local rows = db.query([[
        WITH held AS (
            SELECT product_id, option_id, SUM(qty)::int AS held
              FROM shop_stock_reservations
             WHERE namespace_id = ? AND status = 'held' AND expires_at > NOW()
             GROUP BY product_id, option_id
        )
        SELECT 'product' AS kind, p.uuid, p.sku, NULL AS code, p.name, p.name AS product_name, p.uuid AS product_uuid,
               NULL AS group_name, NULL AS option_name,
               p.stock_qty AS qty, COALESCE(h.held, 0) AS held, p.stock_qty - COALESCE(h.held, 0) AS available,
               p.low_stock_threshold AS threshold, p.status, p.allow_backorder, p.lead_time_days, p.product_type
          FROM shop_products p
          LEFT JOIN held h ON h.product_id = p.id AND h.option_id IS NULL
         WHERE p.namespace_id = ? AND p.status <> 'archived'
        UNION ALL
        SELECT 'option' AS kind, o.uuid, p.sku, o.code, o.name, p.name AS product_name, p.uuid AS product_uuid,
               g.name AS group_name, o.name AS option_name,
               o.stock_qty AS qty, COALESCE(h.held, 0) AS held, o.stock_qty - COALESCE(h.held, 0) AS available,
               p.low_stock_threshold AS threshold, p.status, p.allow_backorder, p.lead_time_days, NULL AS product_type
          FROM shop_options o
          JOIN shop_option_groups g ON g.id = o.group_id
          JOIN shop_products p ON p.id = g.product_id
          LEFT JOIN held h ON h.option_id = o.id
         WHERE p.namespace_id = ? AND o.stock_qty IS NOT NULL AND o.component_product_id IS NULL
           AND o.is_active AND p.status <> 'archived'
         ORDER BY kind DESC, name
    ]], ns_id, ns_id, ns_id)
    local out = {}
    local low_only = U.bool(params.low_only, false)
    for _, r in ipairs(rows) do
        r.low = (tonumber(r.available) or 0) <= (tonumber(r.threshold) or 0)
        r.is_low = r.low
        r.stock_qty = r.qty
        r.low_stock_threshold = r.threshold
        for _, k in ipairs({ "sku", "code", "product_name", "product_uuid", "product_type", "group_name",
                             "option_name" }) do
            if r[k] == nil then r[k] = U.null end
        end
        if not low_only or r.low then out[#out + 1] = r end
    end
    return U.arr(out)
end

function ShopStockQueries.lowStockCount(ns_id)
    return #ShopStockQueries.sheet(ns_id, { low_only = true })
end

function ShopStockQueries.movements(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 50), 1, 500)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "m.namespace_id = ?" }, { ns_id }
    if U.nz(params.product_uuid) then
        where[#where + 1] = "p.uuid = ?"
        vals[#vals + 1] = params.product_uuid
    end
    if U.nz(params.option_uuid) then
        where[#where + 1] = "o.uuid = ?"
        vals[#vals + 1] = params.option_uuid
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query([[
        SELECT m.uuid, m.delta, m.reason, m.ref, m.user_id, m.created_at,
               p.uuid AS product_uuid, p.sku, p.name AS product_name, o.uuid AS option_uuid, o.name AS option_name,
               COUNT(*) OVER() AS total
          FROM shop_stock_movements m
          LEFT JOIN shop_products p ON p.id = m.product_id
          LEFT JOIN shop_options o ON o.id = m.option_id
         WHERE ]] .. table.concat(where, " AND ") .. [[
         ORDER BY m.created_at DESC, m.id DESC LIMIT ? OFFSET ?
    ]], unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        r.total = nil
        r.note = r.ref or U.null
        for _, k in ipairs({ "ref", "user_id", "product_uuid", "sku", "product_name", "option_uuid", "option_name" }) do
            if r[k] == nil then r[k] = U.null end
        end
    end
    return U.arr(rows), { total = total, limit = limit, offset = offset }
end

return ShopStockQueries
