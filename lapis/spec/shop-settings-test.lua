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
        query = function(sql, ns_id, value)
            if sql:match("^%s*SELECT") then return row and { row } or {} end
            if sql:match("INSERT INTO shop_settings") then row = { checkout_enabled = value, updated_at = "now" } end
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

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
