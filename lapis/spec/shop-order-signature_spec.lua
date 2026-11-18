--[[
    Spec: proof of delivery, the customer's signature on a shop order (queries/ShopOrderSignatureQueries.lua).

    Standalone (no busted). From the repo root:
        luajit lapis/spec/shop-order-signature_spec.lua
    Covers the image checks and names (pure) and the wiring: RBAC on the routes, the private storage, one
    signature in force per order, the delivered status and the customer's update.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, ctx = {} } -- luacheck: ignore 111
package.loaded["lapis.db"] = package.loaded["lapis.db"] or { query = function() return {} end, NULL = {} }
package.loaded["helper.global"] = package.loaded["helper.global"] or { generateUUID = function() return "u" end }

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = assert(io.open(path))
    local s = h:read("*a")
    h:close()
    return s
end

local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(s)
    return ((s:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#s % 3 + 1])
end
local function unb64(s)
    s = s:gsub("[^" .. B .. "=]", "")
    return (s:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end
local function be32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function png(w, h, pad)
    return "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. "\8\2\0\0\0" .. "CRC!" .. ("\0"):rep(pad or 400)
end

local Q = require("queries.ShopOrderSignatureQueries")

check("a PNG data URL is accepted", Q.decode_png("data:image/png;base64," .. b64(png(600, 180)), unb64) ~= nil)
check("bare base64 is accepted", Q.decode_png(b64(png(600, 180)), unb64) ~= nil)
local _, e1 = Q.decode_png("", unb64)
check("nothing signed", e1 and e1:find("sign", 1, true))
local _, e2 = Q.decode_png(b64("GIF89a" .. ("\0"):rep(400)), unb64)
check("not a PNG", e2 == "The signature isn't a PNG image")
local _, e3 = Q.decode_png("data:image/png;base64,<script>", unb64)
check("junk characters refused", e3 == "The signature isn't a PNG image")
local _, e4 = Q.decode_png(b64(png(600, 180, 10)), unb64)
check("an empty canvas (tiny file) refused", e4 and e4:find("empty", 1, true))
local _, e5 = Q.decode_png(b64(png(600, 180, Q.MAX_BYTES)), unb64)
check("too large refused", e5 == "The signature is too large")
local _, e6 = Q.decode_png(b64(png(10, 10)), unb64)
check("odd sizes refused", e6 == "The signature image has an odd size")

check("names are trimmed and one line", Q.clean("  Jane\n  Buyer\t", 120) == "Jane Buyer")
check("blank name is nil", Q.clean("   ", 120) == nil and Q.clean(nil, 120) == nil)
check("long name is cut", #Q.clean(("x"):rep(500), Q.NAME_MAX) == Q.NAME_MAX)
check("cancelled, refunded and failed orders can't be signed", Q.UNSIGNABLE.cancelled and Q.UNSIGNABLE.refunded
    and Q.UNSIGNABLE.payment_failed and not Q.UNSIGNABLE.paid and not Q.UNSIGNABLE.shipped)

local src = read("lapis/queries/ShopOrderSignatureQueries.lua")
check("stored privately in MinIO under shop/signatures", src:find('shop/signatures/%s/%s/%s.png', 1, true) ~= nil)
check("fingerprint kept", src:find("sha256hex(png)", 1, true) ~= nil)
check("marks delivered and tells the customer", src:find("SET status = 'delivered'", 1, true)
    and src:find('"Received and signed for by "', 1, true))
check("a failed save removes the stored file", src:find("pcall(c.delete, c, key)", 1, true) ~= nil)
check("voiding needs a reason and keeps the row", src:find("SET voided_at = NOW()", 1, true) and not src:find("DELETE FROM shop_order_signatures", 1, true))

local mig = read("lapis/migrations/shop-order-signatures.lua")
check("one signature in force per order", mig:find("ON shop_order_signatures (order_id) WHERE voided_at IS NULL", 1, true) ~= nil)
check("registered as zzs63 under SHOP", read("lapis/migrations.lua"):find("['zzs63_shop_order_signatures'] = conditional_array(ProjectConfig.FEATURES.SHOP", 1, true) ~= nil)

local routes = read("lapis/routes/shop-admin.lua")
check("read routes need shop read", routes:find('app:get(BASE .. "/orders/:uuid/signature", guard("read"', 1, true)
    and routes:find('app:get(BASE .. "/orders/:uuid/signature/image", guard("read"', 1, true))
check("signing and voiding need shop update", routes:find('app:post(BASE .. "/orders/:uuid/signature", guard("update"', 1, true)
    and routes:find('app:post(BASE .. "/orders/:uuid/signature/void", guard("update"', 1, true))
check("the image is never cached", routes:find('content_type = "image/png"', 1, true) and routes:find('"no-store, private"', 1, true))
check("no public signature route", not read("lapis/routes/shop-public.lua"):find("signature", 1, true))

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
