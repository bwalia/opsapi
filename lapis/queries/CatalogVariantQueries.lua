-- luacheck: max line length 160
--[[
    Product variations (sizes, colours, …) for staff — workspace-scoped
    =====================================================================
    A product of Stores & Products can have variations (product_variants): each its own name ("M / Blue"),
    up to three options, SKU, price (empty = the product's price), stock and on/off. The till (Point of Sale)
    and staff orders sell a variation; the product's own stock is used when it has none.

    Routes: routes/catalog-variants.lua (RBAC products: read / create / update / delete). The product must
    belong to this workspace (its own namespace_id, or its store's).

      list(ns_id, product_uuid)                 → { product = { uuid, name, price, track_inventory }, variants = [...] }
      create(ns_id, product_uuid, body)         body { title?, option1?, option2?, option3?, sku?, price?, stock?, is_active? }
      update(ns_id, variant_uuid, body)         the same fields; only those sent change
      remove(ns_id, variant_uuid)               deletes it (old orders keep its name: orderitems.variant_title)

    Functions return (value) or (nil, err { status, code, message, fields? }).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local Q = {}

local function err(status, code, message, fields)
    return nil, { status = status, code = code, message = message, fields = fields }
end

local function text(v, max)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" then return nil end
    v = v:gsub("%c", " "):match("^%s*(.-)%s*$")
    if v == "" then return nil end
    return v:sub(1, max)
end

local function product_of(ns_id, product_uuid)
    if type(product_uuid) ~= "string" or product_uuid == "" then return nil end
    return db.query([[SELECT p.id, p.uuid, p.name, p.price, p.track_inventory FROM storeproducts p JOIN stores s ON s.id = p.store_id
        WHERE p.uuid = ? AND COALESCE(p.namespace_id, s.namespace_id) = ?]], product_uuid, ns_id)[1]
end

local function variant_of(ns_id, variant_uuid)
    if type(variant_uuid) ~= "string" or variant_uuid == "" then return nil end
    return db.query([[SELECT v.*, p.uuid AS product_uuid FROM product_variants v JOIN storeproducts p ON p.id = v.product_id
        JOIN stores s ON s.id = p.store_id WHERE v.uuid = ? AND COALESCE(p.namespace_id, s.namespace_id) = ?]], variant_uuid, ns_id)[1]
end

local function shape(v, product_price)
    local own = tonumber(v.price)
    return {
        uuid = v.uuid, title = v.title, option1 = v.option1 or cjson.null, option2 = v.option2 or cjson.null,
        option3 = v.option3 or cjson.null, sku = v.sku or cjson.null,
        price = own and string.format("%.2f", own) or cjson.null,
        effective_price = string.format("%.2f", own or tonumber(product_price) or 0),
        stock = tonumber(v.inventory_quantity) or 0, is_active = v.is_active ~= false, position = tonumber(v.position) or 0,
    }
end

--- Validate the fields sent. partial = only those present. → fields | nil, err
local function fields(body, partial)
    body = type(body) == "table" and body or {}
    local f = {}
    local options = {}
    for _, k in ipairs({ "option1", "option2", "option3" }) do
        if body[k] ~= nil then
            f[k] = text(body[k], 100) or db.NULL
            if f[k] ~= db.NULL then options[#options + 1] = f[k] end
        end
    end
    if body.title ~= nil or not partial then
        f.title = text(body.title, 200) or (#options > 0 and table.concat(options, " / ")) or nil
        if not f.title then return err(422, "VALIDATION_ERROR", "Name the variation, e.g. Medium / Blue", { title = "required" }) end
    end
    if body.sku ~= nil then f.sku = text(body.sku, 100) or db.NULL end
    if body.price ~= nil then
        if body.price == cjson.null or body.price == "" then
            f.price = db.NULL
        else
            local s = tostring(body.price):match("^%s*(.-)%s*$")
            if not s:match("^%d+%.?%d?%d?$") or tonumber(s) > 1e9 then
                return err(422, "VALIDATION_ERROR", "The price must be an amount like 12.50 (or empty to use the product's)", { price = "amount" })
            end
            f.price = tonumber(s)
        end
    end
    if body.stock ~= nil then
        local n = tonumber(body.stock)
        if not n or n ~= math.floor(n) or n < 0 or n > 1e9 then
            return err(422, "VALIDATION_ERROR", "Stock must be a whole number from 0", { stock = "whole number" })
        end
        f.inventory_quantity = n
    end
    if body.is_active ~= nil then f.is_active = body.is_active == true or body.is_active == "true" end
    return f
end

local function sku_taken(ns_id, sku, except_id)
    if not sku or sku == db.NULL then return false end
    return db.query([[SELECT 1 AS x FROM product_variants v JOIN storeproducts p ON p.id = v.product_id JOIN stores s ON s.id = p.store_id
        WHERE COALESCE(p.namespace_id, s.namespace_id) = ? AND lower(v.sku) = lower(?) AND v.id <> ? LIMIT 1]],
        ns_id, sku, except_id or 0)[1] ~= nil
end

function Q.list(ns_id, product_uuid)
    local p = product_of(ns_id, product_uuid)
    if not p then return err(404, "NOT_FOUND", "Product not found") end
    local out = {}
    for _, v in ipairs(db.query("SELECT * FROM product_variants WHERE product_id = ? ORDER BY position, id", p.id)) do
        out[#out + 1] = shape(v, p.price)
    end
    return { product = { uuid = p.uuid, name = p.name, price = string.format("%.2f", tonumber(p.price) or 0),
        track_inventory = p.track_inventory == true }, variants = setmetatable(out, cjson.array_mt) }
end

function Q.create(ns_id, product_uuid, body)
    local p = product_of(ns_id, product_uuid)
    if not p then return err(404, "NOT_FOUND", "Product not found") end
    local f, ferr = fields(body, false)
    if not f then return nil, ferr end
    if sku_taken(ns_id, f.sku) then return err(409, "SKU_TAKEN", "Another variation already has the SKU " .. f.sku, { sku = "taken" }) end
    f.uuid = Global.generateUUID()
    f.product_id = p.id
    f.inventory_quantity = f.inventory_quantity or 0
    f.position = (tonumber((db.query("SELECT COALESCE(MAX(position), 0) AS m FROM product_variants WHERE product_id = ?", p.id)[1] or {}).m) or 0) + 1
    f.created_at, f.updated_at = db.raw("NOW()"), db.raw("NOW()")
    local row = db.insert("product_variants", f, { returning = "*" })
    row = type(row) == "table" and (row[1] or row) or nil
    return shape(row or db.query("SELECT * FROM product_variants WHERE uuid = ?", f.uuid)[1], p.price)
end

function Q.update(ns_id, variant_uuid, body)
    local v = variant_of(ns_id, variant_uuid)
    if not v then return err(404, "NOT_FOUND", "Variation not found") end
    local f, ferr = fields(body, true)
    if not f then return nil, ferr end
    if f.sku and sku_taken(ns_id, f.sku, v.id) then
        return err(409, "SKU_TAKEN", "Another variation already has the SKU " .. f.sku, { sku = "taken" })
    end
    if next(f) then
        f.updated_at = db.raw("NOW()")
        db.update("product_variants", f, { id = v.id })
    end
    local p = db.query("SELECT price FROM storeproducts WHERE id = ?", v.product_id)[1] or {}
    return shape(db.query("SELECT * FROM product_variants WHERE id = ?", v.id)[1], p.price)
end

function Q.remove(ns_id, variant_uuid)
    local v = variant_of(ns_id, variant_uuid)
    if not v then return err(404, "NOT_FOUND", "Variation not found") end
    db.query("DELETE FROM product_variants WHERE id = ?", v.id)
    return { deleted = true }
end

return Q
