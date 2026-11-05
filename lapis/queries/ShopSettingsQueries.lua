--[[
    Shop-wide settings (shop_settings, one row per namespace; no row = defaults).

    checkout_enabled  false → no online payment for orders: cart and quote checkout
                      answer 409 CHECKOUT_DISABLED, quotes are never payable, and
                      the shop sends enquiries (quote + CRM lead) instead.
                      Membership checkout is separate and unaffected.
]]
local db = require("lapis.db")
local U = require("lib.shop-util")

local Q = {}

function Q.get(ns_id)
    local row = db.query("SELECT checkout_enabled, updated_at FROM shop_settings WHERE namespace_id = ?", ns_id)[1]
    return {
        checkout_enabled = row ~= nil and row.checkout_enabled == true,
        updated_at = row and row.updated_at or U.null,
    }
end

function Q.checkoutEnabled(ns_id)
    return Q.get(ns_id).checkout_enabled
end

function Q.update(ns_id, body)
    if type(body.checkout_enabled) ~= "boolean" then
        return nil, U.err(400, "VALIDATION_ERROR", "checkout_enabled must be true or false")
    end
    db.query([[
        INSERT INTO shop_settings (namespace_id, checkout_enabled, updated_at) VALUES (?, ?, NOW())
        ON CONFLICT (namespace_id) DO UPDATE SET checkout_enabled = EXCLUDED.checkout_enabled, updated_at = NOW()
    ]], ns_id, body.checkout_enabled)
    return Q.get(ns_id)
end

return Q
