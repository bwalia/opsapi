-- luacheck: max line length 160
--[[
    Staff create an order (Stores & Products → Sales Orders → Create order)
    =======================================================================
    POST /api/v2/orders (routes/orders.lua; RBAC orders.create, in the caller's workspace). Replaces the old
    handler that saved whatever fields it was sent.

    body {
      store_uuid            a store of this workspace
      customer              { email (required), first_name?, last_name?, phone? }: found by email in this
                            workspace, else created
      items                 [{ product_uuid, quantity }] (1..100 lines): active products of that store; prices come
                            from the product, never from the request
      shipping_amount?, discount_amount?   pounds (≥ 0, at most 2 decimals)
      shipping_address?, billing_address?  { name?, line1?, line2?, city?, postcode?, country?, phone? }
      customer_notes?, internal_notes?
      paid?                 true when the customer has already paid (financial_status paid)
      channel?              how they ordered: phone (default) | in_person | email — kept as orders.source, so Sales
                            Orders can tell a phone order from a counter sale (a POS screen would write 'pos')
    }

    orders.source = the channel (migrations/sales-orders.lua); online checkout leaves it empty.
    Tax = subtotal × the store's tax_rate (a fraction, as at checkout). Stock: a product that tracks inventory
    must have enough, and it is taken off in the same transaction (a row lock, so two orders can't both take
    the last one). → the order { uuid, order_number, totals, items } | nil, err { status, code, message, fields? }

    Specced by spec/manual-order_spec.lua (rules) and the INT check (database).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local Q = {}

Q.MAX_LINES = 100
Q.CHANNELS = { phone = true, in_person = true, email = true }
Q.MAX_QTY = 100000

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
Q.text = text

--- Pounds with at most 2 decimals, ≥ 0 → number | nil, "bad"
function Q.amount(v)
    if v == nil or v == cjson.null or v == "" then return 0 end
    local s = type(v) == "number" and string.format("%.10g", v) or (type(v) == "string" and v:match("^%s*(.-)%s*$")) or nil
    if not s or not s:match("^%d+%.?%d?%d?$") then return nil, "bad" end
    local n = tonumber(s)
    if not n or n > 1e9 then return nil, "bad" end
    return n
end

local function r2(n) return math.floor(n * 100 + 0.5) / 100 end
Q.r2 = r2

function Q.email(v)
    v = text(v, 254)
    if not v then return nil end
    v = v:lower()
    return v:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") and v or nil
end

local ADDRESS_KEYS = { "name", "company", "line1", "line2", "city", "county", "postcode", "country", "phone" }
function Q.address(v)
    if type(v) ~= "table" then return nil end
    local out, any = {}, false
    for _, k in ipairs(ADDRESS_KEYS) do
        local s = text(v[k], 200)
        if s then out[k] = s; any = true end
    end
    return any and out or nil
end

--- Validate the request (no database). → clean | nil, err
function Q.validate(body)
    if type(body) ~= "table" then return err(400, "INVALID_BODY", "Send the order as JSON") end
    local store_uuid = text(body.store_uuid, 64)
    if not store_uuid then return err(422, "VALIDATION_ERROR", "Choose the store", { store_uuid = "required" }) end
    local c = type(body.customer) == "table" and body.customer or {}
    local email = Q.email(c.email)
    if not email then
        return err(422, "VALIDATION_ERROR", "Enter the customer's email address", { ["customer.email"] = "a valid email" })
    end
    if type(body.items) ~= "table" or #body.items == 0 then
        return err(422, "VALIDATION_ERROR", "Add at least one product", { items = "at least one" })
    end
    if #body.items > Q.MAX_LINES then return err(422, "VALIDATION_ERROR", "At most " .. Q.MAX_LINES .. " lines", { items = "too many" }) end
    local items, seen = {}, {}
    for i, it in ipairs(body.items) do
        local p = type(it) == "table" and text(it.product_uuid, 64)
        local qty = type(it) == "table" and tonumber(it.quantity)
        if not p then return err(422, "VALIDATION_ERROR", "Line " .. i .. ": choose a product", { ["items." .. i] = "product" }) end
        if not qty or qty ~= math.floor(qty) or qty < 1 or qty > Q.MAX_QTY then
            return err(422, "VALIDATION_ERROR", "Line " .. i .. ": the quantity must be a whole number from 1",
                { ["items." .. i] = "quantity" })
        end
        if seen[p] then
            items[seen[p]].quantity = items[seen[p]].quantity + qty -- the same product twice is one line
        else
            items[#items + 1] = { product_uuid = p, quantity = qty }
            seen[p] = #items
        end
    end
    local shipping, s_bad = Q.amount(body.shipping_amount)
    if s_bad then return err(422, "VALIDATION_ERROR", "Shipping must be an amount like 12.50", { shipping_amount = "amount" }) end
    local discount, d_bad = Q.amount(body.discount_amount)
    if d_bad then return err(422, "VALIDATION_ERROR", "Discount must be an amount like 5.00", { discount_amount = "amount" }) end
    local channel = body.channel == nil and "phone" or body.channel
    if not Q.CHANNELS[channel] then
        return err(422, "VALIDATION_ERROR", "How did they order? phone, in_person or email", { channel = "phone | in_person | email" })
    end
    return {
        store_uuid = store_uuid, items = items, shipping = shipping, discount = discount, paid = body.paid == true, channel = channel,
        customer = { email = email, first_name = text(c.first_name, 100), last_name = text(c.last_name, 100), phone = text(c.phone, 40) },
        shipping_address = Q.address(body.shipping_address), billing_address = Q.address(body.billing_address),
        customer_notes = text(body.customer_notes, 2000), internal_notes = text(body.internal_notes, 2000),
    }
end

--- Totals from the products' prices. lines = {{ price, quantity }}; tax_rate a fraction.
function Q.totals(lines, tax_rate, shipping, discount)
    local subtotal = 0
    for _, l in ipairs(lines) do
        l.total = r2(l.price * l.quantity)
        subtotal = subtotal + l.total
    end
    subtotal = r2(subtotal)
    local tax = r2(subtotal * (tonumber(tax_rate) or 0))
    local total = r2(subtotal + tax + (shipping or 0) - (discount or 0))
    return { subtotal = subtotal, tax = tax, shipping = shipping or 0, discount = discount or 0, total = total }
end

local function nz(v) return v ~= nil and v ~= db.NULL and v ~= "" and v or nil end

function Q.create(ns_id, body)
    local o, verr = Q.validate(body)
    if not o then return nil, verr end
    local store = db.query([[SELECT id, uuid, name, tax_rate, currency FROM stores WHERE uuid = ? AND namespace_id = ?]],
        o.store_uuid, ns_id)[1]
    if not store then return err(404, "STORE_NOT_FOUND", "That store isn't in this workspace") end

    local ok, res, cerr = pcall(function()
        db.query("BEGIN")
        local lines = {}
        for i, it in ipairs(o.items) do
            local p = db.query([[SELECT id, uuid, name, sku, price, track_inventory, inventory_quantity, is_active
                FROM storeproducts WHERE uuid = ? AND store_id = ? FOR UPDATE]], it.product_uuid, store.id)[1]
            if not p or p.is_active == false then
                db.query("ROLLBACK")
                return nil, { status = 422, code = "PRODUCT_NOT_AVAILABLE", message = "Line " .. i .. ": that product isn't sold in "
                    .. store.name, fields = { ["items." .. i] = "product" } }
            end
            local price = tonumber(p.price)
            if not price or price < 0 then
                db.query("ROLLBACK")
                return nil, { status = 422, code = "PRODUCT_HAS_NO_PRICE", message = p.name .. " has no price. Set one on the product first." }
            end
            if p.track_inventory == true and (tonumber(p.inventory_quantity) or 0) < it.quantity then
                db.query("ROLLBACK")
                return nil, { status = 409, code = "NOT_ENOUGH_STOCK", message = ("Only %d of %s in stock"):format(
                    math.max(0, tonumber(p.inventory_quantity) or 0), p.name), fields = { ["items." .. i] = "quantity" } }
            end
            lines[#lines + 1] = { product = p, price = price, quantity = it.quantity }
        end
        local t = Q.totals(lines, store.tax_rate, o.shipping, o.discount)
        if t.total < 0 then
            db.query("ROLLBACK")
            return nil, { status = 422, code = "VALIDATION_ERROR", message = "The discount is more than the order", fields = { discount_amount = "too big" } }
        end

        -- The customer: this workspace's, by email; otherwise a new one.
        local customer = db.query([[SELECT id, uuid FROM customers WHERE namespace_id = ? AND lower(email) = ? ORDER BY id LIMIT 1]],
            ns_id, o.customer.email)[1]
        if not customer then
            customer = db.query([[INSERT INTO customers (uuid, namespace_id, email, first_name, last_name, phone, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, NOW(), NOW()) RETURNING id, uuid]], Global.generateUUID(), ns_id, o.customer.email,
                o.customer.first_name or db.NULL, o.customer.last_name or db.NULL, o.customer.phone or db.NULL)[1]
        end

        local uuid = Global.generateUUID()
        local number = "ORD-" .. os.date("!%Y%m%d") .. "-" .. uuid:gsub("%-", ""):sub(1, 8):upper()
        local billing = o.billing_address or o.shipping_address
        local order = db.query([[
            INSERT INTO orders (]] .. (require("helper.table-exists")("orders", "source") and "source, " or "") .. [[uuid, namespace_id,
                store_id, customer_id, order_number, status, financial_status, fulfillment_status,
                subtotal, tax_amount, shipping_amount, discount_amount, total_amount, currency, billing_address, shipping_address,
                customer_notes, internal_notes, processed_at, created_at, updated_at)
            VALUES (]] .. (require("helper.table-exists")("orders", "source") and (db.escape_literal(o.channel) .. ", ") or "") .. [[?, ?, ?, ?, ?, ?, ?,
                'unfulfilled', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW(), NOW())
            RETURNING id, uuid, order_number]], uuid, ns_id, store.id, customer.id, number,
            o.paid and "confirmed" or "pending", o.paid and "paid" or "pending",
            t.subtotal, t.tax, t.shipping, t.discount, t.total, nz(store.currency) or "GBP",
            billing and cjson.encode(billing) or db.NULL, o.shipping_address and cjson.encode(o.shipping_address) or db.NULL,
            o.customer_notes or db.NULL, o.internal_notes or db.NULL)[1]
        local items = {}
        for _, l in ipairs(lines) do
            db.query([[INSERT INTO orderitems (uuid, order_id, product_id, quantity, price, total, product_title, sku, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())]], Global.generateUUID(), order.id, l.product.id, l.quantity, l.price,
                l.total, l.product.name, nz(l.product.sku) or db.NULL)
            if l.product.track_inventory == true then
                db.query("UPDATE storeproducts SET inventory_quantity = inventory_quantity - ?, updated_at = NOW() WHERE id = ?",
                    l.quantity, l.product.id)
            end
            items[#items + 1] = { product_uuid = l.product.uuid, name = l.product.name, quantity = l.quantity, price = l.price, total = l.total }
        end
        db.query("COMMIT")
        return { uuid = order.uuid, order_number = order.order_number, store = { uuid = store.uuid, name = store.name },
                 customer = { uuid = customer.uuid, email = o.customer.email }, status = o.paid and "confirmed" or "pending",
                 financial_status = o.paid and "paid" or "pending", channel = o.channel, currency = nz(store.currency) or "GBP",
                 subtotal = t.subtotal, tax_amount = t.tax, shipping_amount = t.shipping, discount_amount = t.discount,
                 total_amount = t.total, items = items }
    end)
    if not ok then
        pcall(db.query, "ROLLBACK")
        ngx.log(ngx.ERR, "[orders] create failed: ", tostring(res))
        return err(500, "ORDER_FAILED", "The order couldn't be saved. Try again.")
    end
    if not res then return nil, cerr end
    return res
end

return Q
