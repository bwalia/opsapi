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
                      delivery change request (they see the outcome on their order page). Leave it off
                      until the shop's sending address is changed.
]]
local db = require("lapis.db")
local U = require("lib.shop-util")

local Q = {}

local BILL_TO_KEYS = { "company", "line1", "line2", "city", "county", "postcode", "country", "phone", "email",
                       "vat_number" }

function Q.get(ns_id)
    local ok, rows = pcall(db.query, [[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, order_alert_email,
                                              customer_delivery_notifications, updated_at
                                         FROM shop_settings WHERE namespace_id = ?]], ns_id)
    if not ok then -- before migration zzs52
        ok, rows = pcall(db.query, [[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, order_alert_email,
                                            updated_at FROM shop_settings WHERE namespace_id = ?]], ns_id)
    end
    if not ok then -- before migration zzs50
        rows = db.query([[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, updated_at
                            FROM shop_settings WHERE namespace_id = ?]], ns_id)
    end
    local row = rows[1]
    return {
        checkout_enabled = row ~= nil and row.checkout_enabled == true,
        po_bill_to = row and U.nz(row.po_bill_to) and U.dec(row.po_bill_to, U.null) or U.null,
        order_alert_email = row and U.nz(row.order_alert_email) or U.null,
        customer_delivery_notifications = row ~= nil and row.customer_delivery_notifications == true,
        updated_at = row and row.updated_at or U.null,
    }
end

--- The "Bill to" block for supplier POs, or nil when not set.
function Q.billTo(ns_id)
    local b = Q.get(ns_id).po_bill_to
    return type(b) == "table" and b or nil
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

--- May we email the customer when staff decide on their delivery change request? Off by default.
function Q.customerDeliveryNotifications(ns_id)
    return Q.get(ns_id).customer_delivery_notifications == true
end

--- body: { checkout_enabled?, po_bill_to?, order_alert_email?, customer_delivery_notifications? } (at least one).
function Q.update(ns_id, body)
    local has_checkout, has_bill = body.checkout_enabled ~= nil, body.po_bill_to ~= nil
    local has_alert = body.order_alert_email ~= nil
    local has_notify = body.customer_delivery_notifications ~= nil
    if not has_checkout and not has_bill and not has_alert and not has_notify then
        return nil, U.err(400, "VALIDATION_ERROR", "Nothing to update (checkout_enabled, po_bill_to, order_alert_email "
            .. "or customer_delivery_notifications)")
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
    return Q.get(ns_id)
end

return Q
