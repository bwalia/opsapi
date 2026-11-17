--[[
    Shop-wide settings (shop_settings, one row per namespace; no row = defaults).

    checkout_enabled  false → no online payment for orders: cart and quote checkout
                      answer 409 CHECKOUT_DISABLED, quotes are never payable, and
                      the shop sends enquiries (quote + CRM lead) instead.
                      Membership checkout is separate and unaffected.
    po_bill_to        the "Bill to" block on supplier purchase orders raised from paid
                      shop orders: { company, line1, line2, city, county, postcode,
                      country, phone, email, vat_number }.
    order_alert_email the staff "new order" alert (an order paid online, or a customer choosing bank
                      transfer) goes here; unset = the Leads → Notifications admin email, else the
                      workspace owner. Customers are never emailed by this alert.
    customer_delivery_notifications
                      false (default) → nothing is sent to customers when staff approve or decline a
                      delivery change request (they see the outcome on their order page), and staff can
                      only send test copies of order update emails ("Email the customer" on the order page,
                      queries/ShopOrderUpdateQueries.lua) to themselves. The dashboard calls it "Customer
                      emails from the shop". Leave it off until the shop's sending address is changed.
    deal_code_prefix  the start of every new deal code (default WS: WS-DT5Z-994X). Deal codes are private:
                      staff and suppliers see them, customers never do (queries/ShopDealQueries.lua).
    deal_code_length  random characters after the prefix (default 8 = XXXX-XXXX; 6 to 16).
    po_deliver_to     our own delivery address for supplier purchase orders (same keys as po_bill_to).
                      Unset = the Bill to address. Suppliers deliver here unless staff confirm a drop-ship.
    delivery_*        UK delivery facts the shop publishes (product page, search-engine structured data):
                      delivery_cost_minor (0 = included, as the basket shows), handling days for in-stock
                      items (min/max, default 1-2: "Ships in 1-2 days") and courier transit days (min/max,
                      default 1-3). Out-of-stock items use their own lead time instead of the handling days.
    quote_valid_days  how long a new quote holds its price (default 30); also the shop's "price valid until".
]]
local db = require("lapis.db")
local U = require("lib.shop-util")
local DealCodes = require("lib.deal-codes")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143

local Q = {}

-- Defaults until migration zzs59 adds the columns (same values as the column defaults).
Q.DELIVERY_DEFAULTS = {
    delivery_cost_minor = 0, delivery_handling_min_days = 1, delivery_handling_max_days = 2,
    delivery_transit_min_days = 1, delivery_transit_max_days = 3, quote_valid_days = 30,
}
local DELIVERY_LIMITS = {
    delivery_cost_minor = { 0, 10000000 }, delivery_handling_min_days = { 0, 60 }, delivery_handling_max_days = { 0, 60 },
    delivery_transit_min_days = { 0, 30 }, delivery_transit_max_days = { 0, 30 }, quote_valid_days = { 1, 365 },
}
local DELIVERY_KEYS = { "delivery_cost_minor", "delivery_handling_min_days", "delivery_handling_max_days",
                        "delivery_transit_min_days", "delivery_transit_max_days", "quote_valid_days" }
Q.DELIVERY_KEYS = DELIVERY_KEYS

local BILL_TO_KEYS = { "company", "line1", "line2", "city", "county", "postcode", "country", "phone", "email",
                       "vat_number" }

function Q.get(ns_id)
    local ok, rows = pcall(db.query, [[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, order_alert_email,
                                              customer_delivery_notifications, deal_code_prefix, deal_code_length,
                                              po_deliver_to::text AS po_deliver_to, updated_at
                                         FROM shop_settings WHERE namespace_id = ?]], ns_id)
    if not ok then -- before migration zzs55
        ok, rows = pcall(db.query, [[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, order_alert_email,
                                            customer_delivery_notifications, updated_at
                                       FROM shop_settings WHERE namespace_id = ?]], ns_id)
    end
    if not ok then -- before migration zzs52
        ok, rows = pcall(db.query, [[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, order_alert_email,
                                            updated_at FROM shop_settings WHERE namespace_id = ?]], ns_id)
    end
    if not ok then -- before migration zzs50
        rows = db.query([[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, updated_at
                            FROM shop_settings WHERE namespace_id = ?]], ns_id)
    end
    local row = rows[1]
    local ok2, drows = pcall(db.query, "SELECT " .. table.concat(DELIVERY_KEYS, ", ")
        .. " FROM shop_settings WHERE namespace_id = ?", ns_id)
    local d = ok2 and drows and drows[1] or {}
    local delivery = {}
    for _, k in ipairs(DELIVERY_KEYS) do delivery[k] = tonumber(d[k]) or Q.DELIVERY_DEFAULTS[k] end
    return {
        delivery_cost_minor = delivery.delivery_cost_minor,
        delivery_handling_min_days = delivery.delivery_handling_min_days,
        delivery_handling_max_days = delivery.delivery_handling_max_days,
        delivery_transit_min_days = delivery.delivery_transit_min_days,
        delivery_transit_max_days = delivery.delivery_transit_max_days,
        quote_valid_days = delivery.quote_valid_days,
        checkout_enabled = row ~= nil and row.checkout_enabled == true,
        po_bill_to = row and U.nz(row.po_bill_to) and U.dec(row.po_bill_to, U.null) or U.null,
        order_alert_email = row and U.nz(row.order_alert_email) or U.null,
        customer_delivery_notifications = row ~= nil and row.customer_delivery_notifications == true,
        deal_code_prefix = row and U.nz(row.deal_code_prefix) or DealCodes.DEFAULT_PREFIX,
        deal_code_length = row and tonumber(row.deal_code_length) or DealCodes.DEFAULT_LENGTH,
        po_deliver_to = row and U.nz(row.po_deliver_to) and U.dec(row.po_deliver_to, U.null) or U.null,
        updated_at = row and row.updated_at or U.null,
    }
end

--- The "Bill to" block for supplier POs, or nil when not set.
function Q.billTo(ns_id)
    local b = Q.get(ns_id).po_bill_to
    return type(b) == "table" and b or nil
end

--- Where suppliers deliver unless staff confirm a drop-ship: po_deliver_to, else the Bill to address. Nil
-- when neither is set.
function Q.deliverTo(ns_id)
    local s = Q.get(ns_id)
    if type(s.po_deliver_to) == "table" then return s.po_deliver_to end
    return type(s.po_bill_to) == "table" and s.po_bill_to or nil
end

local function clean_bill_to(b)
    if b == U.null then return U.null end
    if type(b) ~= "table" then return nil, "po_bill_to must be an object" end
    local out, any = {}, false
    for _, k in ipairs(BILL_TO_KEYS) do
        local v = U.nz(b[k])
        if v ~= nil then out[k] = tostring(v):sub(1, 255); any = true end
    end
    return any and out or U.null
end

function Q.checkoutEnabled(ns_id)
    return Q.get(ns_id).checkout_enabled
end

--- Where the staff "new order" alert goes, or nil (then the lead-notification admin email is used).
function Q.orderAlertEmail(ns_id)
    local e = Q.get(ns_id).order_alert_email
    return e ~= U.null and e or nil
end

--- The name customer emails go out under: the workspace's "Name in emails", else its name.
function Q.brandName(ns_id)
    local n = db.query("SELECT * FROM namespaces WHERE id = ?", ns_id)[1] or {}
    local name = U.nz(type(n.email_name) == "string" and n.email_name:match("^%s*(.-)%s*$")) or U.nz(n.name)
    return name or U.env("APP_NAME") or "OpsAPI"
end

--- May we email the customer when staff decide on their delivery change request? Off by default.
function Q.customerDeliveryNotifications(ns_id)
    return Q.get(ns_id).customer_delivery_notifications == true
end

--- What the shop may publish (GET /public/shop/:ns/settings): no addresses, emails or deal-code settings.
function Q.public(s)
    return {
        checkout_enabled = s.checkout_enabled,
        delivery = {
            cost_minor = s.delivery_cost_minor,
            handling_min_days = s.delivery_handling_min_days, handling_max_days = s.delivery_handling_max_days,
            transit_min_days = s.delivery_transit_min_days, transit_max_days = s.delivery_transit_max_days,
        },
        quote_valid_days = s.quote_valid_days,
    }
end

--- Delivery settings from a body: (values table, nil) or (nil, message). Only keys present are returned.
function Q.cleanDelivery(body, current)
    local out, any = {}, false
    for _, k in ipairs(DELIVERY_KEYS) do
        local v = body[k]
        if v ~= nil and v ~= U.null then
            local n = tonumber(v)
            local lim = DELIVERY_LIMITS[k]
            if not n or n ~= math.floor(n) or n < lim[1] or n > lim[2] then
                return nil, ("%s must be a whole number from %d to %d"):format(k, lim[1], lim[2])
            end
            out[k] = n
            any = true
        end
    end
    local function eff(k) return out[k] or (current and current[k]) or Q.DELIVERY_DEFAULTS[k] end
    if eff("delivery_handling_min_days") > eff("delivery_handling_max_days") then
        return nil, "delivery_handling_min_days must not be more than delivery_handling_max_days"
    end
    if eff("delivery_transit_min_days") > eff("delivery_transit_max_days") then
        return nil, "delivery_transit_min_days must not be more than delivery_transit_max_days"
    end
    return any and out or nil
end

--- body: { checkout_enabled?, po_bill_to?, order_alert_email?, customer_delivery_notifications?, deal_code_prefix?,
-- deal_code_length?, po_deliver_to?, delivery_*?, quote_valid_days? } (at least one).
function Q.update(ns_id, body)
    local has_checkout, has_bill = body.checkout_enabled ~= nil, body.po_bill_to ~= nil
    local has_alert = body.order_alert_email ~= nil
    local has_notify = body.customer_delivery_notifications ~= nil
    local has_prefix, has_length = body.deal_code_prefix ~= nil, body.deal_code_length ~= nil
    local has_deliver = body.po_deliver_to ~= nil
    local delivery, delivery_err = Q.cleanDelivery(body, Q.get(ns_id))
    if delivery_err then return nil, U.err(400, "VALIDATION_ERROR", delivery_err) end
    if not has_checkout and not has_bill and not has_alert and not has_notify and not has_prefix and not has_length
        and not has_deliver and not delivery then
        return nil, U.err(400, "VALIDATION_ERROR", "Nothing to update (checkout_enabled, po_bill_to, "
            .. "order_alert_email, customer_delivery_notifications, deal_code_prefix, deal_code_length, po_deliver_to, "
            .. "delivery settings or quote_valid_days)")
    end
    local prefix, length, deliver
    if has_prefix then
        local perr
        prefix, perr = DealCodes.clean_prefix(body.deal_code_prefix ~= U.null and body.deal_code_prefix or nil)
        if not prefix then return nil, U.err(400, "VALIDATION_ERROR", perr) end
    end
    if has_length then
        local lerr
        length, lerr = DealCodes.clean_length(body.deal_code_length ~= U.null and body.deal_code_length or nil)
        if not length then return nil, U.err(400, "VALIDATION_ERROR", lerr) end
    end
    if has_deliver then
        local derr
        deliver, derr = clean_bill_to(body.po_deliver_to)
        if not deliver then
            return nil, U.err(400, "VALIDATION_ERROR", ((derr or ""):gsub("po_bill_to", "po_deliver_to")))
        end
    end
    if has_notify and type(body.customer_delivery_notifications) ~= "boolean" then
        return nil, U.err(400, "VALIDATION_ERROR", "customer_delivery_notifications must be true or false")
    end
    local alert
    if has_alert then
        alert = U.nz(body.order_alert_email ~= U.null and body.order_alert_email or nil)
        if alert ~= nil then
            alert = tostring(alert):gsub("^%s+", ""):gsub("%s+$", "")
            if #alert > 254 or not alert:match("^[^@%s,;]+@[^@%s,;]+%.[^@%s,;]+$") then
                return nil, U.err(400, "VALIDATION_ERROR", "order_alert_email must be one email address")
            end
        end
    end
    if has_checkout and type(body.checkout_enabled) ~= "boolean" then
        return nil, U.err(400, "VALIDATION_ERROR", "checkout_enabled must be true or false")
    end
    local bill
    if has_bill then
        local berr
        bill, berr = clean_bill_to(body.po_bill_to)
        if not bill then return nil, U.err(400, "VALIDATION_ERROR", berr) end
    end
    db.query("INSERT INTO shop_settings (namespace_id) VALUES (?) ON CONFLICT (namespace_id) DO NOTHING", ns_id)
    if has_checkout then
        db.query("UPDATE shop_settings SET checkout_enabled = ?, updated_at = NOW() WHERE namespace_id = ?",
            body.checkout_enabled, ns_id)
    end
    if has_notify then
        db.query([[UPDATE shop_settings SET customer_delivery_notifications = ?, updated_at = NOW()
                    WHERE namespace_id = ?]], body.customer_delivery_notifications, ns_id)
    end
    if has_alert then
        db.query("UPDATE shop_settings SET order_alert_email = ?, updated_at = NOW() WHERE namespace_id = ?",
            alert or db.NULL, ns_id)
    end
    if has_bill then
        db.query("UPDATE shop_settings SET po_bill_to = ?::jsonb, updated_at = NOW() WHERE namespace_id = ?",
            bill == U.null and db.NULL or U.enc(bill), ns_id)
    end
    if has_prefix or has_length then
        db.query([[UPDATE shop_settings SET deal_code_prefix = COALESCE(?, deal_code_prefix),
                   deal_code_length = COALESCE(?, deal_code_length), updated_at = NOW() WHERE namespace_id = ?]],
            prefix or db.NULL, length or db.NULL, ns_id)
    end
    if has_deliver then
        db.query("UPDATE shop_settings SET po_deliver_to = ?::jsonb, updated_at = NOW() WHERE namespace_id = ?",
            deliver == U.null and db.NULL or U.enc(deliver), ns_id)
    end
    if delivery then
        local sets, vals = {}, {}
        for _, k in ipairs(DELIVERY_KEYS) do
            if delivery[k] ~= nil then
                sets[#sets + 1] = k .. " = ?"
                vals[#vals + 1] = delivery[k]
            end
        end
        vals[#vals + 1] = ns_id
        db.query("UPDATE shop_settings SET " .. table.concat(sets, ", ") .. ", updated_at = NOW() WHERE namespace_id = ?",
            unpack(vals))
    end
    return Q.get(ns_id)
end

--- How long a new quote holds its price, in days.
function Q.quoteValidDays(ns_id)
    local ok, s = pcall(Q.get, ns_id)
    return ok and s and s.quote_valid_days or Q.DELIVERY_DEFAULTS.quote_valid_days
end

return Q
