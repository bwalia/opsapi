-- luacheck: max line length 140
--[[
    Stock enquiries to suppliers (shop)
    ===================================
    "Have you got this in stock?" from a product, before there is a customer or a deal: pick a supplier and
    a quantity and the message is ready ("Hello Sam", what and how many, their code and the part number when
    we know them, then: how many in stock or the lead time? trade price ex VAT? when could you deliver? how
    long is the price valid?), subject "Stock enquiry: <product>". Staff can edit it, then
      email     sent from here, through the workspace's "Price requests to suppliers" email account, with
                replies going to the person who sent it;
      whatsapp  / sms   opens WhatsApp or the phone's text messages with the message ready (nothing here
                sends those: the person presses send on their own phone).
    Each enquiry is kept on the product (shop_supplier_requests, kind = 'stock', no deal code; migration
    zzs66), where the supplier's answer goes: stock or lead time, price ex VAT, valid until, their reference.
    Our prices are never in the message. Deal screens (queries/ShopDealQueries.lua) never show these.

      draft(ns_id, product_uuid, { supplier, qty, note }, user)  → { product, supplier, qty, subject, body }
      send(ns_id, product_uuid, body, user)   body { supplier_uuid, channel, qty?, subject?, message }
                                              → { channel, enquiry, sent_to?, link? }
      list(ns_id, { product_uuid?, supplier_uuid?, limit? })     → enquiries, newest first
      update(ns_id, uuid, body, user_id)      the answer: stock, lead_time, unit_price_minor, valid_until,
                                              supplier_quote_ref, notes
      delete(ns_id, uuid, user_id)
    user: { id, first_name, last_name, email }. Errors are (nil, { status, code, message }).
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local U = require("lib.shop-util")
local Codes = require("lib.deal-codes")
local Global = require("helper.global")

local E = {}

E.CHANNELS = { email = "email", whatsapp = "WhatsApp", sms = "text message" }
E.MAX_QTY = 100000

local function text(v, max)
    if v == nil or v == U.null then return nil end
    if type(v) ~= "string" and type(v) ~= "number" then return nil end
    local s = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return U.cut(s, max)
end

local function whole(v, lo, hi)
    local n = tonumber(v)
    if not n or n ~= math.floor(n) or n < lo or n > hi then return nil end
    return n
end

local function supplier_of(ns_id, supplier_uuid)
    if type(supplier_uuid) ~= "string" or supplier_uuid == "" then return nil end
    return db.query([[SELECT id, uuid, name, contact_name, COALESCE(NULLIF(po_email, ''), NULLIF(contact_email, '')) AS email,
                             NULLIF(po_phone, '') AS phone
                        FROM shop_suppliers WHERE namespace_id = ? AND uuid = ?]], ns_id, supplier_uuid)[1]
end

--- The product, with the supplier item it is linked to (their code, the part number) when there is one.
local function product_of(ns_id, product_uuid)
    if type(product_uuid) ~= "string" or product_uuid == "" then return nil end
    return db.query([[SELECT p.id, p.uuid, p.name, p.brand, p.sku, p.slug,
                             i.supplier_id AS item_supplier_id, i.supplier_sku, i.mpn
                        FROM shop_products p
                        LEFT JOIN shop_supplier_items i ON i.id = p.supplier_item_id
                       WHERE p.namespace_id = ? AND p.uuid = ?]], ns_id, product_uuid)[1]
end

--- "Juno Computers Neptune 18"" unless the name already starts with the brand.
function E.title(p)
    local name, brand = text(p.name, 300) or "", text(p.brand, 120)
    if not brand then return name end
    local first = brand:match("^(%S+)"):lower() -- "Juno Computers" + "Juno Neptune 18"" → the name as it is
    if name:lower():sub(1, #first) == first then return name end
    return brand .. " " .. name
end

--- The message. p: product row; s: supplier row; t: { qty, note, company, sender }.
-- Their own code only when the product is linked to this supplier's price file; the part number always.
function E.message(p, s, t)
    t = t or {}
    local title = E.title(p)
    local qty = whole(t.qty, 1, E.MAX_QTY) or 1
    local out = {}
    out[#out + 1] = "Hello " .. (text(s.contact_name, 160) or s.name) .. ","
    out[#out + 1] = ""
    out[#out + 1] = "Do you have the following in stock?"
    out[#out + 1] = ""
    out[#out + 1] = qty .. " x " .. title
    if s.id and p.item_supplier_id and tonumber(p.item_supplier_id) == tonumber(s.id) and text(p.supplier_sku, 120) then
        out[#out + 1] = "   - Your code: " .. p.supplier_sku
    end
    if text(p.mpn, 120) then out[#out + 1] = "   - Part number: " .. p.mpn end
    local note = text(t.note, 2000)
    if note then
        for line in (note .. "\n"):gmatch("([^\n]*)\n") do
            if line:match("%S") then out[#out + 1] = "   - " .. line:gsub("^%s*%-?%s*", "") end
        end
    end
    out[#out + 1] = ""
    out[#out + 1] = "Please let us know how many you have in stock (or the lead time), your trade price ex VAT, "
        .. "when you could deliver, and how long the price is valid."
    out[#out + 1] = ""
    out[#out + 1] = "Thank you,"
    if text(t.sender, 200) then out[#out + 1] = t.sender end
    if text(t.company, 200) then out[#out + 1] = t.company end
    return { subject = "Stock enquiry: " .. title, body = table.concat(out, "\n") }
end

local function public_supplier(s)
    return { uuid = s.uuid, name = s.name, contact_name = s.contact_name or U.null, email = s.email or U.null,
             phone = s.phone or U.null, phone_intl = Codes.intl_phone(s.phone) or U.null }
end

local function sender_of(user)
    user = user or {}
    return U.nz(U.join(" ", U.nz(user.first_name), U.nz(user.last_name)))
end

local function brand_of(ns_id)
    return require("queries.ShopSettingsQueries").brandName(ns_id)
end

function E.draft(ns_id, product_uuid, opts, user)
    opts = type(opts) == "table" and opts or {}
    local p = product_of(ns_id, product_uuid)
    if not p then return nil, U.err(404, "NOT_FOUND", "Product not found") end
    local s = supplier_of(ns_id, opts.supplier)
    if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Choose a supplier") end
    local qty = whole(opts.qty or 1, 1, E.MAX_QTY)
    if not qty then return nil, U.err(400, "VALIDATION_ERROR", "Quantity must be a whole number from 1") end
    local mail = E.message(p, s, { qty = qty, note = opts.note, company = brand_of(ns_id), sender = sender_of(user) })
    return { product = { uuid = p.uuid, name = p.name, title = E.title(p) }, supplier = public_supplier(s), qty = qty,
             subject = mail.subject, body = mail.body }
end

local function send_email(ns_id, s, subject, message, user)
    local NamespaceMail = require("helper.namespace-mail")
    local esc = message:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local html = "<div style=\"font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5\">"
        .. esc:gsub("\n", "<br>\n") .. "</div>"
    local msg, smtp_or_err = NamespaceMail.prepare(ns_id, "supplier_requests", {
        to = s.email, subject = subject, html = html, text = message, from_name = brand_of(ns_id),
        reply_to = U.nz(user.email), sync = true,
    })
    if not msg then
        return nil, U.err(503, "EMAIL_NOT_CONFIGURED", "No email account can send this: " .. tostring(smtp_or_err))
    end
    local sent, err = require("helper.mail").send(msg)
    if not sent then
        ngx.log(ngx.ERR, "[shop-stock-enquiry] email to supplier ", s.uuid, " failed: ", tostring(err))
        return nil, U.err(502, "EMAIL_FAILED", "The email could not be sent. Check the workspace's email settings "
            .. "(Workspace → Email) and try again")
    end
    return true
end

local COLS = [[r.uuid, r.kind, r.supplier_name, r.contact_name, r.contact_email, r.sent_at::text AS sent_at,
    r.lines::text AS lines, r.supplier_quote_ref, r.lead_time, r.valid_until::text AS valid_until, r.notes, r.channel,
    r.message, r.created_at, r.updated_at, s.uuid AS supplier_uuid, p.uuid AS product_uuid, p.name AS product_name]]

local FROM = [[ FROM shop_supplier_requests r
    LEFT JOIN shop_suppliers s ON s.id = r.supplier_id
    LEFT JOIN shop_products p ON p.id = r.product_id ]]

local function shape(r)
    if not r then return nil end
    local lines = U.dec(r.lines, {})
    local l = lines[1] or {}
    return {
        uuid = r.uuid, supplier_uuid = r.supplier_uuid or U.null, supplier_name = r.supplier_name,
        contact_name = r.contact_name or U.null, contact_email = r.contact_email or U.null,
        product_uuid = r.product_uuid or U.null, product_name = r.product_name or l.description or U.null,
        qty = tonumber(l.qty) or 1, unit_price_minor = tonumber(l.unit_price_minor) or U.null,
        stock_qty = tonumber(l.stock_qty) or U.null,
        sent_at = r.sent_at or U.null, channel = r.channel or U.null, message = r.message or U.null,
        lead_time = r.lead_time or U.null, valid_until = r.valid_until or U.null,
        supplier_quote_ref = r.supplier_quote_ref or U.null, notes = r.notes or U.null,
        answered = (l.unit_price_minor ~= nil or l.stock_qty ~= nil or r.lead_time ~= nil) and true or false,
        created_at = r.created_at, updated_at = r.updated_at,
    }
end

local function get(ns_id, uuid)
    if type(uuid) ~= "string" or uuid == "" then return nil end
    return db.query("SELECT r.id, " .. COLS .. FROM .. " WHERE r.namespace_id = ? AND r.uuid = ? AND r.kind = 'stock'",
        ns_id, uuid)[1]
end

function E.send(ns_id, product_uuid, body, user)
    body, user = type(body) == "table" and body or {}, user or {}
    local channel = body.channel
    if not E.CHANNELS[channel] then
        return nil, U.err(400, "VALIDATION_ERROR", "Choose how to send it: email, WhatsApp or a text message")
    end
    local p = product_of(ns_id, product_uuid)
    if not p then return nil, U.err(404, "NOT_FOUND", "Product not found") end
    local s = supplier_of(ns_id, body.supplier_uuid)
    if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Choose a supplier") end
    local qty = whole(body.qty or 1, 1, E.MAX_QTY)
    if not qty then return nil, U.err(400, "VALIDATION_ERROR", "Quantity must be a whole number from 1") end
    local subject = text(body.subject, 200) or ("Stock enquiry: " .. E.title(p))
    local message = text(body.message, 8000)
    if not message then return nil, U.err(400, "VALIDATION_ERROR", "Write the message to the supplier") end

    local out = { channel = channel }
    if channel == "email" then
        if not s.email then
            return nil, U.err(400, "SUPPLIER_NO_EMAIL", "Add an email address to " .. s.name .. " first (Shop → Suppliers)")
        end
        local ok, err = send_email(ns_id, s, subject, message, user)
        if not ok then return nil, err end
        out.sent_to = s.email
    else
        local links = Codes.message_links(s.phone, subject .. "\n\n" .. message)
        if not links then
            return nil, U.err(400, "SUPPLIER_NO_PHONE", "Add a phone number to " .. s.name .. " first (Shop → Suppliers)")
        end
        out.link = links[channel]
    end

    local uuid = Global.generateUUID()
    local ok, err = pcall(db.query, [[
        INSERT INTO shop_supplier_requests (uuid, namespace_id, kind, deal_code, product_id, supplier_id, supplier_name,
                                            contact_name, contact_email, sent_at, lines, channel, message,
                                            created_by_user_id, created_at, updated_at)
        VALUES (?, ?, 'stock', NULL, ?, ?, ?, ?, ?, ?::date, ?::jsonb, ?, ?, ?, NOW(), NOW())
    ]], uuid, ns_id, p.id, s.id, s.name, s.contact_name or db.NULL, s.email or db.NULL, os.date("!%Y-%m-%d"),
        U.enc(U.arr({ { description = E.title(p), qty = qty } })), channel, U.cut(subject .. "\n\n" .. message, 8000),
        tonumber(user.id) or db.NULL)
    if not ok then
        -- The email has gone (or the link is ready): say so rather than fail the whole thing.
        ngx.log(ngx.ERR, "[shop-stock-enquiry] not recorded for product ", p.uuid, ": ", tostring(err))
        out.enquiry, out.not_recorded = U.null, "not recorded"
        return out
    end
    out.enquiry = shape(get(ns_id, uuid))
    return out
end

function E.list(ns_id, opts)
    opts = type(opts) == "table" and opts or {}
    local where, vals = { "r.namespace_id = ?", "r.kind = 'stock'" }, { ns_id }
    if U.nz(opts.product_uuid) then where[#where + 1] = "p.uuid = ?"; vals[#vals + 1] = opts.product_uuid end
    if U.nz(opts.supplier_uuid) then where[#where + 1] = "s.uuid = ?"; vals[#vals + 1] = opts.supplier_uuid end
    local limit = whole(opts.limit or 50, 1, 200) or 50
    vals[#vals + 1] = limit
    local out = {}
    for i, r in ipairs(db.query("SELECT " .. COLS .. FROM .. " WHERE " .. table.concat(where, " AND ")
            .. " ORDER BY r.created_at DESC, r.id DESC LIMIT ?", unpack(vals))) do
        out[i] = shape(r)
    end
    return U.arr(out)
end

--- The supplier's answer. body: { stock_qty?, lead_time?, unit_price_minor? (pence ex VAT), valid_until?,
-- supplier_quote_ref?, notes? }; null clears a field.
function E.update(ns_id, uuid, body, user_id) -- luacheck: ignore 212
    body = type(body) == "table" and body or {}
    local r = get(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Stock enquiry not found") end
    local set = { updated_at = db.raw("NOW()") }
    for k, max in pairs({ lead_time = 160, supplier_quote_ref = 120, notes = 4000 }) do
        if body[k] ~= nil then set[k] = text(body[k], max) or db.NULL end
    end
    if body.valid_until ~= nil then
        if U.nz(body.valid_until) and body.valid_until ~= U.null then
            local d = U.date(body.valid_until)
            if not d then return nil, U.err(400, "VALIDATION_ERROR", "valid_until must be a date (YYYY-MM-DD)") end
            set.valid_until = d
        else
            set.valid_until = db.NULL
        end
    end
    local lines = U.dec(r.lines, {})
    local l = lines[1] or { qty = 1 }
    local changed = false
    for k, hi in pairs({ unit_price_minor = 2147483647, stock_qty = E.MAX_QTY }) do
        if body[k] ~= nil then
            if body[k] == U.null or body[k] == "" then
                l[k] = nil
            else
                local n = whole(body[k], 0, hi)
                if not n then
                    return nil, U.err(400, "VALIDATION_ERROR", k == "unit_price_minor" and "Price must be pence ex VAT (0 or more)"
                        or "Stock must be a whole number (0 or more)")
                end
                l[k] = n
            end
            changed = true
        end
    end
    if changed then
        lines[1] = l
        set.lines = db.raw(db.escape_literal(U.enc(U.arr(lines))) .. "::jsonb")
    end
    db.update("shop_supplier_requests", set, { id = r.id })
    return shape(get(ns_id, uuid))
end

function E.delete(ns_id, uuid, user_id) -- luacheck: ignore 212
    local r = get(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Stock enquiry not found") end
    db.query("DELETE FROM shop_supplier_requests WHERE id = ?", r.id)
    return { deleted = true }
end

return E
