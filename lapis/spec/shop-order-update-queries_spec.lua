-- luacheck: max line length 140
-- luacheck: globals ngx
--[[
    Plain-Lua test for queries/ShopOrderUpdateQueries.lua with the DB, the order queries, the shop
    settings and the mailer stubbed (no nginx, no DB, nothing is sent).

    Run from the repo root (as CI does) or from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/shop-order-update-queries_spec.lua
]]

package.path = "./?.lua;./lapis/?.lua;/usr/local/openresty/lualib/?.lua;" .. package.path
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath -- cjson

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

ngx = { log = function() end, ERR = 1, WARN = 2 } -- luacheck: ignore 111

-- state the stubs read and write
local S
local function reset()
    S = {
        enabled = false, sends = {}, inserts = {}, notes = {}, real_count = 0, test_count = 0, dup = false,
        events = {}, deleted = {}, send_ok = true, headline_subject = nil,
        user = { first_name = "Sam", last_name = "Taylor", email = "sam@ws.example" },
        order = { id = 7, uuid = "o-1", namespace_id = 3, order_number = "WS-10042", access_token = "tok", status = "paid",
                  email = "ann@example.com", customer = '{"name":"Ann Lee","email":"ann@example.com"}',
                  tracking = '{"carrier":"DPD","tracking_number":"123"}', delivery_date = "2026-11-18", delivery_window = "am" },
    }
end
reset()

local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
package.loaded["lapis.db"] = {
    NULL = NULL,
    query = function(sql, ...)
        local a = { ... }
        if sql:find("FROM users", 1, true) then return { S.user } end
        if sql:find("COUNT(*)", 1, true) then return { { n = a[2] and S.test_count or S.real_count } } end
        if sql:find("SELECT 1 FROM shop_order_emails", 1, true) then return S.dup and { { ["?column?"] = 1 } } or {} end
        if sql:find("INSERT INTO shop_order_emails", 1, true) then
            S.inserts[#S.inserts + 1] = a
            S.events[#S.events + 1] = "log"
            return {}
        end
        if sql:find("DELETE FROM shop_order_emails", 1, true) then S.deleted[#S.deleted + 1] = a[1] return {} end
        if sql:find("FOR UPDATE", 1, true) then S.events[#S.events + 1] = "lock" return {} end
        if sql:find("to_char", 1, true) then return { { t = "2026-11-15 10:30" } } end
        if sql:find("UPDATE shop_orders", 1, true) then S.notes[#S.notes + 1] = a[1] return {} end
        if sql:find("FROM shop_order_emails", 1, true) then return {} end
        return {}
    end,
}
package.loaded["helper.global"] = { generateUUID = function() return "uuid-1" end }
package.loaded["queries.ShopOrderQueries"] = {
    getByUuid = function(_, uuid) return uuid == S.order.uuid and S.order or nil end,
    adminGet = function() return { uuid = S.order.uuid } end,
}
package.loaded["queries.ShopSettingsQueries"] = { customerDeliveryNotifications = function() return S.enabled end,
                                                  brandName = function() return "Acme Ltd" end }
package.loaded["helper.mail"] = { isConfigured = function() return true end }
package.loaded["helper.namespace-mail"] = {
    smtp = function() return nil end,
    render = function(_, key, data) return { subject = S.headline_subject or (data.headline .. ": order " .. data.order_number),
                                             html = "<p>x</p>", customised = false, key = key } end,
    send = function(ns, key, to, data, brand, extra)
        S.sends[#S.sends + 1] = { ns = ns, key = key, to = to, data = data, brand = brand, extra = extra }
        S.events[#S.events + 1] = "send"
        if not S.send_ok then return nil, "535 5.7.8 smtp.example.com: bad credentials for user@x" end
        return true
    end,
}

local Q = require("queries.ShopOrderUpdateQueries")

-- presets ---------------------------------------------------------------------------------------
local info = Q.presets(3, "o-1", 11)
check("presets: all five", info and #info.presets == 5)
check("presets: order number filled in", info.presets[1].message:find("WS-10042", 1, true) ~= nil)
check("presets: dispatched carries the tracking", info.presets[3].message:find("Tracking: DPD 123", 1, true) ~= nil,
    info.presets[3].message)
check("presets: recipient is the order email", info.to == "ann@example.com")
check("presets: switch reported off", info.customer_emails_enabled == false)
check("presets: tests go to the staff member", info.test_to == "sam@ws.example" and info.signature == "Sam Taylor")
local _, nf = Q.presets(3, "nope", 11)
check("presets: unknown order is 404", nf and nf.status == 404)

-- preview ---------------------------------------------------------------------------------------
local pv = Q.preview(3, "o-1", { preset = "delayed" }, 11)
check("preview: preset used when no text given", pv and pv.headline == "Update on your order" and pv.kind == "delayed")
check("preview: warns about [NEW DATE]", pv and pv.warnings[1] and pv.warnings[1]:find("[NEW DATE]", 1, true) ~= nil)
local _, perr = Q.preview(3, "o-1", { headline = "", message = "x" }, 11)
check("preview: validation error", perr and perr.status == 400 and perr.field == "headline")

-- test send: always allowed, to staff only, no order note --------------------------------------------
reset()
local t = Q.send(3, "o-1", { preset = "received_reserved", headline = "Order received", message = "Hello", test = true }, 11)
check("test: sent", t and t.sent and t.test)
check("test: goes to the staff member, never the customer", #S.sends == 1 and S.sends[1].to == "sam@ws.example")
check("test: subject prefix", S.sends[1].extra.subject_prefix == "[TEST] " and t.subject:sub(1, 7) == "[TEST] ")
check("test: template data marks the test", S.sends[1].data.test == true and S.sends[1].data.test_customer == "ann@example.com")
check("test: logged as a test", #S.inserts == 1 and S.inserts[1][11] == true)
check("test: no order note", #S.notes == 0)

reset()
S.user.email = nil
local _, noe = Q.send(3, "o-1", { headline = "H", message = "M", test = true }, 11)
check("test: refused without a staff email", noe and noe.status == 400 and #S.sends == 0)

reset()
S.test_count = 20
local _, trl = Q.send(3, "o-1", { headline = "H", message = "M", test = true }, 11)
check("test: rate limited", trl and trl.status == 429)

-- real send ---------------------------------------------------------------------------------------
reset()
local _, off = Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
check("real: 409 CUSTOMER_EMAILS_OFF when the switch is off", off and off.status == 409 and off.code == "CUSTOMER_EMAILS_OFF")
check("real: nothing sent while off", #S.sends == 0)

reset()
S.enabled = true
S.order.email = nil
S.order.customer = '{"name":"Ann Lee"}'
local _, noc = Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
check("real: refused without a customer email", noc and noc.code == "NO_CUSTOMER_EMAIL" and #S.sends == 0)

reset()
S.enabled = true
S.order.email = nil -- falls back to customer.email
local r = Q.send(3, "o-1", { preset = "received_reserved", headline = "Order received", message = "Thank you" }, 11)
check("real: sent to the customer", r and r.sent and not r.test and S.sends[1].to == "ann@example.com")
check("real: no test prefix", S.sends[1].extra.subject_prefix == nil and r.subject == "Order received: order WS-10042")
check("real: signature is the staff member", S.sends[1].data.signature == "Sam Taylor" and S.sends[1].data.signature_is_person)
check("real: delivery summary", S.sends[1].data.delivery_summary == "Wed 18 Nov 2026, morning", S.sends[1].data.delivery_summary)
check("real: template key", S.sends[1].key == "shop.order_update")
check("real: logged", #S.inserts == 1 and S.inserts[1][4] == "received_reserved" and S.inserts[1][11] == false)
check("real: order note", S.notes[1] == "[2026-11-15 10:30] Update emailed to ann@example.com by Sam Taylor: Order received",
    S.notes[1])

reset()
S.enabled = true
local _, mk = Q.send(3, "o-1", { preset = "delayed" }, 11)
check("real: refused while [NEW DATE] is left in", mk and mk.status == 400 and #S.sends == 0)

reset()
S.enabled = true
S.real_count = 5
local _, rl = Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
check("real: at most 5 per order per day", rl and rl.status == 429 and #S.sends == 0)

reset()
S.enabled = true
S.dup = true
local _, dup = Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
check("real: the same update twice in 10 minutes is refused", dup and dup.code == "DUPLICATE_SEND" and #S.sends == 0)

reset()
S.enabled = true
S.user = nil
local anon = Q.send(3, "o-1", { headline = "H", message = "M" }, nil)
check("real: no staff name signs as the workspace's team", anon and S.sends[1].data.signature == "The Acme Ltd team"
    and not S.sends[1].data.signature_is_person)

-- the workspace's brand, no made-up phone number ------------------------------------------------------
reset()
S.enabled = true
Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
check("brand: the workspace's name, never a hard-coded one", S.sends[1].data.app_name == "Acme Ltd"
    and S.sends[1].brand.app_name == "Acme Ltd")
check("brand: no phone line unless SHOP_CALL_PHONE is set", S.sends[1].data.call_phone == nil)

-- the log row is the reservation: written (under the order's lock) before the email goes ------------------
reset()
S.enabled = true
Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
check("cap: lock, then log, then send", table.concat(S.events, ",") == "lock,log,send", table.concat(S.events, ","))

reset()
S.enabled = true
S.send_ok = false
local _, fail = Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
check("failed send: 502 without the SMTP server's words", fail and fail.status == 502
    and not fail.message:find("535", 1, true) and not fail.message:find("smtp.example.com", 1, true), fail and fail.message)
check("failed send: its log row is removed again (it doesn't count)", #S.deleted == 1 and S.deleted[1] == S.inserts[1][1])
check("failed send: no order note", #S.notes == 0)

-- a subject longer than the column is cut on a character, not inside one ---------------------------------
reset()
S.enabled = true
S.headline_subject = string.rep("é", 200) -- 400 bytes
local long = Q.send(3, "o-1", { headline = "H", message = "M" }, 11)
local logged = S.inserts[1] and S.inserts[1][7]
check("subject: at most 255 bytes, whole characters", long and logged and #logged <= 255 and #logged == 254
    and not logged:find("[\xC0-\xFF]$"), logged and #logged)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
