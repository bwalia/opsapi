-- luacheck: max line length 140
--[[
    Plain-Lua unit test for queries/ShopSettingsQueries.lua (no nginx, no DB, no busted):
    lapis.db is faked as one in-memory shop_settings row.

    Run in the openresty image from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            luajit spec/shop-settings-test.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local row -- the namespace's shop_settings row (nil = never saved)
package.preload["lapis.db"] = function()
    return {
        NULL = setmetatable({}, { __tostring = function() return "NULL" end }),
        query = function(sql, a, b)
            if sql:match("^%s*SELECT") then return row and { row } or {} end
            if sql:match("INSERT INTO shop_settings") then row = row or { checkout_enabled = false, updated_at = "now" } end
            local col = sql:match("UPDATE shop_settings SET ([%w_]+) = ")
            if col and row then
                local v = a
                if type(v) == "table" then v = nil end -- db.NULL
                row[col] = v
            end
            return {}
        end,
    }
end

local S = require("queries.ShopSettingsQueries")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

check("no row: checkout is off (enquiries only)", S.checkoutEnabled(1) == false)

local res, err = S.update(1, { checkout_enabled = "true" })
check("update: a string is rejected", res == nil and err and err.status == 400 and err.code == "VALIDATION_ERROR",
    err and err.code)
check("update: rejected value saves nothing", row == nil)

res, err = S.update(1, {})
check("update: a missing value is rejected", res == nil and err and err.code == "VALIDATION_ERROR")

res = S.update(1, { checkout_enabled = true })
check("update: true switches checkout on", res and res.checkout_enabled == true and S.checkoutEnabled(1) == true)

res = S.update(1, { checkout_enabled = false })
check("update: false switches it off again", res and res.checkout_enabled == false and S.checkoutEnabled(1) == false)

check("no row: no order alert email", S.orderAlertEmail(1) == nil)
res, err = S.update(1, { order_alert_email = "not an email" })
check("alert email: an invalid address is rejected", res == nil and err and err.code == "VALIDATION_ERROR")
res, err = S.update(1, { order_alert_email = "a@x.com, b@x.com" })
check("alert email: a list is rejected (one address)", res == nil and err and err.code == "VALIDATION_ERROR")
res = S.update(1, { order_alert_email = "  sales@workstation.co.uk " })
check("alert email: saved trimmed", res and res.order_alert_email == "sales@workstation.co.uk"
    and S.orderAlertEmail(1) == "sales@workstation.co.uk", res and res.order_alert_email)
check("alert email: checkout untouched", S.checkoutEnabled(1) == false)
res = S.update(1, { order_alert_email = "" })
check("alert email: blank clears it", res and S.orderAlertEmail(1) == nil)

check("no row: customer delivery notifications are off", S.customerDeliveryNotifications(1) == false)
row = nil
check("no row at all: customer delivery notifications are off", S.customerDeliveryNotifications(1) == false
    and S.get(1).customer_delivery_notifications == false)
res, err = S.update(1, { customer_delivery_notifications = "true" })
check("customer notifications: a string is rejected", res == nil and err and err.code == "VALIDATION_ERROR")
res = S.update(1, { customer_delivery_notifications = true })
check("customer notifications: true turns them on", res and res.customer_delivery_notifications == true
    and S.customerDeliveryNotifications(1) == true)
check("customer notifications: checkout untouched", S.checkoutEnabled(1) == false)
res = S.update(1, { customer_delivery_notifications = false })
check("customer notifications: false turns them off", res and S.customerDeliveryNotifications(1) == false)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
