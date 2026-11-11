--[[
    Shop-wide settings (shop_settings, one row per namespace; no row = defaults).

    checkout_enabled  false → no online payment for orders: cart and quote checkout
                      answer 409 CHECKOUT_DISABLED, quotes are never payable, and
                      the shop sends enquiries (quote + CRM lead) instead.
                      Membership checkout is separate and unaffected.
    po_bill_to        the "Bill to" block on supplier purchase orders raised from paid
                      shop orders: { company, line1, line2, city, county, postcode,
                      country, phone, email, vat_number }.
]]
local db = require("lapis.db")
local U = require("lib.shop-util")

local Q = {}

local BILL_TO_KEYS = { "company", "line1", "line2", "city", "county", "postcode", "country", "phone", "email",
                       "vat_number" }

function Q.get(ns_id)
    local row = db.query([[SELECT checkout_enabled, po_bill_to::text AS po_bill_to, updated_at
                             FROM shop_settings WHERE namespace_id = ?]], ns_id)[1]
    return {
        checkout_enabled = row ~= nil and row.checkout_enabled == true,
        po_bill_to = row and U.nz(row.po_bill_to) and U.dec(row.po_bill_to, U.null) or U.null,
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

--- body: { checkout_enabled?, po_bill_to? } (at least one).
function Q.update(ns_id, body)
    local has_checkout, has_bill = body.checkout_enabled ~= nil, body.po_bill_to ~= nil
    if not has_checkout and not has_bill then
        return nil, U.err(400, "VALIDATION_ERROR", "Nothing to update (checkout_enabled or po_bill_to)")
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
    if has_bill then
        db.query("UPDATE shop_settings SET po_bill_to = ?::jsonb, updated_at = NOW() WHERE namespace_id = ?",
            bill == U.null and db.NULL or U.enc(bill), ns_id)
    end
    return Q.get(ns_id)
end

return Q
