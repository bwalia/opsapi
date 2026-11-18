-- luacheck: max line length 160
--[[
    Point of Sale: selling in person, paid on the spot
    ==================================================
    The till (dashboard /dashboard/pos) sells a store's products (Stores & Products: any goods or services, any
    merchant). A sale is an order like any other (queries/ManualOrderQueries.lua) with channel 'pos': paid and
    handed over at once (status delivered, financial_status paid, fulfillment fulfilled), stock taken, and the
    payment kept on the order (orders.payment_method / payment_details). It shows in Sales Orders as
    "Point of sale". Routes: routes/pos.lua (RBAC orders: create to sell, read for receipts and totals).

      products(ns_id, store_uuid, q, limit)    the store's active products for the till: name, SKU, barcode,
                                               price, first image, stock (a scanned barcode or SKU is exact)
      sale(ns_id, body)                        body { store_uuid, items [{ product_uuid, quantity }], discount_amount?,
                                               customer? { email?, first_name?, last_name? } (a walk-in needs none),
                                               payment { method cash|card|other, tendered? (cash), reference? },
                                               note? } → the receipt
      receipt(ns_id, order_uuid)               a sale's receipt (to print again)
      email_receipt(ns_id, order_uuid, email)  emails the receipt (the workspace's "Receipts" email account)
      summary(ns_id, store_uuid, date?)        the till's day in the store's time zone: sales, total, by payment method

    Functions return (value) or (nil, err { status, code, message, fields? }).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Orders = require("queries.ManualOrderQueries")

local Q = {}

Q.METHODS = { cash = "Cash", card = "Card", other = "Other" }

local function err(status, code, message, fields)
    return nil, { status = status, code = code, message = message, fields = fields }
end

local function nz(v) return v ~= nil and v ~= db.NULL and v ~= "" and v or nil end

local function money(n, currency)
    n = tonumber(n) or 0
    local sym = ({ GBP = "£", EUR = "€", USD = "$" })[tostring(currency or "GBP"):upper()]
    local s = string.format("%.2f", n)
    return sym and (sym .. s) or (s .. " " .. tostring(currency))
end
Q.money = money

local function store_of(ns_id, store_uuid)
    if type(store_uuid) ~= "string" or store_uuid == "" then return nil end
    return db.query([[SELECT id, uuid, name, currency, tax_rate, timezone, address, city, postal_code, contact_email, contact_phone
        FROM stores WHERE uuid = ? AND namespace_id = ?]], store_uuid, ns_id)[1]
end

local function first_image(images)
    if type(images) ~= "string" or images == "" then return nil end
    local ok, list = pcall(cjson.decode, images)
    if not ok or type(list) ~= "table" then return nil end
    local f = list[1]
    if type(f) == "table" then f = f.url or f.src end
    return type(f) == "string" and f:match("^https?://") and f or nil
end

function Q.products(ns_id, store_uuid, q, limit)
    local store = store_of(ns_id, store_uuid)
    if not store then return err(404, "STORE_NOT_FOUND", "That store isn't in this workspace") end
    limit = math.min(500, math.max(1, math.floor(tonumber(limit) or 300)))
    local where, vals = { "p.store_id = ?", "p.is_active" }, { store.id }
    q = type(q) == "string" and q:match("^%s*(.-)%s*$") or ""
    if q ~= "" then
        local like = "%" .. q:sub(1, 100):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = [[(p.name ILIKE ? OR p.sku ILIKE ? OR p.barcode ILIKE ? OR EXISTS (SELECT 1 FROM product_variants v
            WHERE v.product_id = p.id AND v.is_active AND v.sku ILIKE ?))]]
        for _ = 1, 4 do vals[#vals + 1] = like end
    end
    vals[#vals + 1] = limit
    local unpack_ = table.unpack or unpack -- luacheck: ignore 113 143
    local rows = db.query([[SELECT p.id, p.uuid, p.name, p.sku, p.barcode, p.price, p.images, p.track_inventory, p.inventory_quantity,
            c.uuid AS category_uuid, c.name AS category
        FROM storeproducts p LEFT JOIN categories c ON c.id = p.category_id
        WHERE ]] .. table.concat(where, " AND ") .. [[ ORDER BY c.name NULLS LAST, p.sort_order NULLS LAST, p.name LIMIT ?]], unpack_(vals))

    -- Their variations (sizes, colours, …), each with its own price and stock.
    local by_product, ids = {}, {}
    for _, r in ipairs(rows) do ids[#ids + 1] = r.id end
    if #ids > 0 then
        for _, v in ipairs(db.query([[SELECT product_id, uuid, title, sku, price, inventory_quantity FROM product_variants
            WHERE product_id IN ? AND is_active ORDER BY position, id]], db.list(ids))) do
            by_product[v.product_id] = by_product[v.product_id] or {}
            table.insert(by_product[v.product_id], v)
        end
    end

    local out, categories, cat_seen = {}, {}, {}
    for _, r in ipairs(rows) do
        local tracked = r.track_inventory == true
        local variants = {}
        for _, v in ipairs(by_product[r.id] or {}) do
            local vstock = tracked and (tonumber(v.inventory_quantity) or 0) or cjson.null
            variants[#variants + 1] = { uuid = v.uuid, title = v.title, sku = nz(v.sku) or cjson.null,
                price = string.format("%.2f", tonumber(v.price) or tonumber(r.price) or 0), stock = vstock,
                available = vstock == cjson.null or vstock > 0 }
        end
        local stock, available
        if #variants > 0 then
            available, stock = false, tracked and 0 or cjson.null
            for _, v in ipairs(variants) do
                if v.available then available = true end
                if tracked then stock = stock + v.stock end
            end
        else
            stock = tracked and (tonumber(r.inventory_quantity) or 0) or cjson.null
            available = stock == cjson.null or stock > 0
        end
        local cat = nz(r.category)
        if cat and not cat_seen[cat] then
            cat_seen[cat] = true
            categories[#categories + 1] = { uuid = r.category_uuid, name = cat }
        end
        out[#out + 1] = { uuid = r.uuid, name = r.name, sku = nz(r.sku) or cjson.null, barcode = nz(r.barcode) or cjson.null,
            price = string.format("%.2f", tonumber(r.price) or 0), image = first_image(r.images) or cjson.null, stock = stock,
            tracked = tracked, available = available, category = cat or cjson.null,
            variants = setmetatable(variants, cjson.array_mt) }
    end
    return { store = { uuid = store.uuid, name = store.name, currency = nz(store.currency) or "GBP",
        tax_rate = tonumber(store.tax_rate) or 0 }, products = setmetatable(out, cjson.array_mt),
        categories = setmetatable(categories, cjson.array_mt) }
end

--- Payment from the till. → { method, details } | nil, err
function Q.payment(p, total)
    p = type(p) == "table" and p or {}
    if not Q.METHODS[p.method] then
        return err(422, "VALIDATION_ERROR", "How did they pay? cash, card or other", { ["payment.method"] = "cash | card | other" })
    end
    local details = {}
    local ref = type(p.reference) == "string" and p.reference:gsub("%c", " "):match("^%s*(.-)%s*$"):sub(1, 100) or ""
    if ref ~= "" then details.reference = ref end
    if p.method == "cash" then
        local tendered, bad = Orders.amount(p.tendered)
        if bad then return err(422, "VALIDATION_ERROR", "Cash given must be an amount like 20.00", { ["payment.tendered"] = "amount" }) end
        if p.tendered == nil or p.tendered == "" or p.tendered == cjson.null then tendered = total end
        if tendered + 1e-9 < total then
            return err(422, "VALIDATION_ERROR", "The cash given is less than the total (" .. string.format("%.2f", total) .. ")",
                { ["payment.tendered"] = "too little" })
        end
        details.tendered = Orders.r2(tendered)
        details.change = Orders.r2(tendered - total)
    end
    return { method = p.method, details = details }
end

function Q.sale(ns_id, body)
    body = type(body) == "table" and body or {}
    local clean, verr = Orders.validate({ store_uuid = body.store_uuid, items = body.items, discount_amount = body.discount_amount,
        customer = body.customer }, { channel = "pos", walk_in = true })
    if not clean then return nil, verr end
    -- The method is checked now; the cash given against the total once the order has locked its prices.
    local probe = type(body.payment) == "table" and body.payment or {}
    if not Q.METHODS[probe.method] then
        return err(422, "VALIDATION_ERROR", "How did they pay? cash, card or other", { ["payment.method"] = "cash | card | other" })
    end
    local note = type(body.note) == "string" and body.note:sub(1, 2000) or nil
    local order, oerr = Orders.create(ns_id, {
        store_uuid = clean.store_uuid, items = clean.items, discount_amount = body.discount_amount, customer = body.customer,
        internal_notes = note,
    }, { channel = "pos", walk_in = true, completed = true,
        payment = function(total) return Q.payment(body.payment, total) end })
    if not order then return nil, oerr end
    return Q.receipt(ns_id, order.uuid)
end

function Q.receipt(ns_id, order_uuid)
    local o = db.query([[SELECT o.id, o.uuid, o.order_number, o.subtotal, o.tax_amount, o.discount_amount, o.total_amount, o.currency,
            o.payment_method, o.payment_details::text AS payment_details, o.source,
            to_char(o.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS sold_at,
            s.uuid AS store_uuid, s.name AS store_name, s.address, s.city, s.postal_code, s.contact_email, s.contact_phone,
            c.email AS customer_email
        FROM orders o JOIN stores s ON s.id = o.store_id LEFT JOIN customers c ON c.id = o.customer_id
        WHERE o.uuid = ? AND COALESCE(o.namespace_id, s.namespace_id) = ?]], tostring(order_uuid or ""), ns_id)[1]
    if not o then return err(404, "NOT_FOUND", "Sale not found") end
    local items = {}
    for _, i in ipairs(db.query("SELECT product_title, variant_title, sku, quantity, price, total FROM orderitems WHERE order_id = ? ORDER BY id",
        o.id)) do
        items[#items + 1] = { name = nz(i.variant_title) and (i.product_title .. " — " .. i.variant_title) or i.product_title,
            sku = nz(i.sku) or cjson.null, quantity = tonumber(i.quantity),
            price = string.format("%.2f", tonumber(i.price) or 0), total = string.format("%.2f", tonumber(i.total) or 0) }
    end
    local details = {}
    if nz(o.payment_details) then
        local ok, d = pcall(cjson.decode, o.payment_details)
        if ok and type(d) == "table" then details = d end
    end
    local function f(v) return v and string.format("%.2f", tonumber(v) or 0) or cjson.null end
    return {
        uuid = o.uuid, order_number = o.order_number, sold_at = o.sold_at, channel = nz(o.source) or "online",
        store = { uuid = o.store_uuid, name = o.store_name,
            address = table.concat((function()
                local parts = {}
                for _, v in ipairs({ nz(o.address), nz(o.city), nz(o.postal_code) }) do parts[#parts + 1] = v end
                return parts
            end)(), ", "),
            contact = table.concat((function()
                local parts = {}
                for _, v in ipairs({ nz(o.contact_phone), nz(o.contact_email) }) do parts[#parts + 1] = v end
                return parts
            end)(), " · ") },
        items = setmetatable(items, cjson.array_mt), currency = nz(o.currency) or "GBP",
        subtotal = f(o.subtotal), tax = f(o.tax_amount), discount = f(o.discount_amount), total = f(o.total_amount),
        payment = { method = nz(o.payment_method) or cjson.null, label = Q.METHODS[o.payment_method] or cjson.null,
            tendered = details.tendered and f(details.tendered) or cjson.null, change = details.change and f(details.change) or cjson.null,
            reference = details.reference or cjson.null },
        customer_email = nz(o.customer_email) or cjson.null,
    }
end

--- Email the receipt (in a timer: the till never waits on SMTP). → { sent = true } | nil, err
function Q.email_receipt(ns_id, order_uuid, email)
    local to = Orders.email(email)
    if not to then return err(422, "VALIDATION_ERROR", "Enter the customer's email address", { email = "a valid email" }) end
    local r, rerr = Q.receipt(ns_id, order_uuid)
    if not r then return nil, rerr end
    local Mail = require("helper.mail")
    local smtp = require("helper.namespace-mail").smtp(ns_id, "receipts")
    if not smtp and not Mail.isConfigured() then return err(503, "EMAIL_NOT_SET_UP", "Email isn't set up for this workspace") end
    local cur = r.currency
    local lines = {}
    for _, l in ipairs(r.items) do lines[#lines + 1] = { quantity = l.quantity, name = l.name, total = money(l.total, cur) } end
    local data = {
        store_name = r.store.name, order_number = r.order_number, sold_at = r.sold_at:gsub("T", " "):gsub("Z$", " UTC"),
        lines = lines, subtotal = money(r.subtotal, cur), total = money(r.total, cur),
        discount = tonumber(r.discount) and tonumber(r.discount) > 0 and money(r.discount, cur) or nil,
        tax = tonumber(r.tax) and tonumber(r.tax) > 0 and money(r.tax, cur) or nil,
        payment_method = r.payment.label ~= cjson.null and r.payment.label or "—",
        tendered = r.payment.tendered ~= cjson.null and money(r.payment.tendered, cur) or nil,
        change = r.payment.change ~= cjson.null and money(r.payment.change, cur) or nil,
        reference = r.payment.reference ~= cjson.null and r.payment.reference or nil,
        store_contact = r.store.contact, app_name = r.store.name,
    }
    local msg = { to = to, subject = "Your receipt from " .. tostring(r.store.name) .. " (" .. r.order_number .. ")",
        template = "order_receipt", data = data }
    if smtp then
        msg.smtp, msg.from_email, msg.from_name, msg.reply_to = smtp, smtp.from_email, smtp.from_name or r.store.name, smtp.reply_to
    end
    local ok, terr = ngx.timer.at(0, function(premature)
        if premature then return end
        local sok, serr = pcall(Mail.send, msg)
        if not sok then ngx.log(ngx.ERR, "[pos] receipt email: ", tostring(serr)) end
    end)
    if not ok then return err(503, "EMAIL_FAILED", "The receipt couldn't be sent. Try again: " .. tostring(terr)) end
    return { sent = true, to = to }
end

--- The till's day: sales and money by payment method, in the store's time zone. date = YYYY-MM-DD (default today).
function Q.summary(ns_id, store_uuid, date)
    local store = store_of(ns_id, store_uuid)
    if not store then return err(404, "STORE_NOT_FOUND", "That store isn't in this workspace") end
    if date ~= nil and date ~= "" and not (type(date) == "string" and date:match("^%d%d%d%d%-%d%d%-%d%d$")) then
        return err(400, "VALIDATION_ERROR", "date must be YYYY-MM-DD")
    end
    local tz = nz(store.timezone) or "UTC"
    if not db.query("SELECT 1 AS ok FROM pg_timezone_names WHERE name = ?", tz)[1] then tz = "UTC" end
    local day = (date and date ~= "") and date
        or db.query("SELECT to_char(NOW() AT TIME ZONE ?, 'YYYY-MM-DD') AS d", tz)[1].d
    local rows = db.query([[SELECT COALESCE(payment_method, 'other') AS method, COUNT(*) AS sales, COALESCE(SUM(total_amount), 0) AS total
        FROM orders WHERE store_id = ? AND source = 'pos' AND financial_status = 'paid'
          AND created_at >= (?::date)::timestamp AT TIME ZONE ? AT TIME ZONE 'UTC'
          AND created_at < (?::date + 1)::timestamp AT TIME ZONE ? AT TIME ZONE 'UTC'
        GROUP BY 1 ORDER BY 1]], store.id, day, tz, day, tz)
    local by, sales, total = {}, 0, 0
    for _, r in ipairs(rows) do
        by[#by + 1] = { method = r.method, label = Q.METHODS[r.method] or r.method, sales = tonumber(r.sales) or 0,
            total = string.format("%.2f", tonumber(r.total) or 0) }
        sales = sales + (tonumber(r.sales) or 0)
        total = total + (tonumber(r.total) or 0)
    end
    -- The day's latest sales, to print a receipt again.
    local recent = {}
    for _, r in ipairs(db.query([[SELECT o.uuid, o.order_number, o.total_amount, o.payment_method,
            to_char(o.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS sold_at,
            (SELECT COALESCE(SUM(quantity), 0) FROM orderitems WHERE order_id = o.id) AS items
        FROM orders o WHERE o.store_id = ? AND o.source = 'pos'
          AND o.created_at >= (?::date)::timestamp AT TIME ZONE ? AT TIME ZONE 'UTC'
          AND o.created_at < (?::date + 1)::timestamp AT TIME ZONE ? AT TIME ZONE 'UTC'
        ORDER BY o.created_at DESC LIMIT 8]], store.id, day, tz, day, tz)) do
        recent[#recent + 1] = { uuid = r.uuid, order_number = r.order_number, sold_at = r.sold_at, items = tonumber(r.items) or 0,
            total = string.format("%.2f", tonumber(r.total_amount) or 0), method = Q.METHODS[r.payment_method] or cjson.null }
    end
    return { date = day, timezone = tz, currency = nz(store.currency) or "GBP", sales = sales,
        total = string.format("%.2f", total), by_method = setmetatable(by, cjson.array_mt),
        recent = setmetatable(recent, cjson.array_mt) }
end

return Q
