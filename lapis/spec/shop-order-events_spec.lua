-- luacheck: max line length 140
--[[
    Plain-Lua unit test for queries/ShopOrderEventQueries.lua (order progress + updates on the customer's order
    page). No nginx, no DB: lapis.db is a fake that answers by SQL shape.

    Run from the repo root (as CI does) or from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/shop-order-events_spec.lua
]]

package.path = "./?.lua;./lapis/?.lua;" .. package.path

local cjson = require("cjson")

local S
local function reset(over)
    S = { po = {}, invoice = nil, events = {}, emails = {}, changes = {}, inserts = {}, fail_insert = false,
          times = { created_at = "2026-11-13T14:11:11Z", paid_at = "2026-11-13T14:13:00Z" }, quote = "WSQ-2026-00015" }
    for k, v in pairs(over or {}) do S[k] = v end
end
local function has(sql, pat) return sql:find(pat, 1, true) ~= nil end

local fake_db = { NULL = setmetatable({}, { __tostring = function() return "NULL" end }) }
function fake_db.query(sql, ...)
    local a = { ... }
    if has(sql, "FROM purchase_orders") then return S.po end
    if has(sql, "FROM invoices") then return S.invoice and { S.invoice } or {} end
    if has(sql, "FROM shop_orders WHERE id") then return { S.times } end
    if has(sql, "FROM shop_quotes") then return S.quote and { { quote_number = S.quote } } or {} end
    if has(sql, "FROM shop_order_events e") and has(sql, "e.uuid = ?") then
        for _, r in ipairs(S.inserts) do if r.uuid == a[1] then return { r } end end
        return {}
    end
    if has(sql, "FROM shop_order_events e") then return S.events end
    if has(sql, "FROM shop_order_emails") then return S.emails end
    if has(sql, "FROM shop_delivery_change_requests") then return S.changes end
    if has(sql, "INSERT INTO shop_order_events") then
        if S.fail_insert then error("relation \"shop_order_events\" does not exist") end
        local row
        if has(sql, "'comment'") then
            row = { uuid = a[1], kind = "comment", message = a[4], author = a[5], at = "2026-11-17T16:00:00Z" }
        else
            row = { uuid = a[1], kind = a[4], status = a[5], message = a[6], author = a[7], at = "2026-11-17T16:00:00Z" }
        end
        S.inserts[#S.inserts + 1] = row
        return {}
    end
    if has(sql, "UPDATE shop_order_events SET deleted_at") then
        for _, r in ipairs(S.inserts) do if r.uuid == a[3] then r.deleted = true return { { uuid = r.uuid } } end end
        return {}
    end
    error("unexpected query: " .. sql)
end
package.loaded["lapis.db"] = fake_db
local n = 0
package.loaded["helper.global"] = { generateUUID = function() n = n + 1 return "uuid-" .. n end }

local ORDER = { id = 6, uuid = "ord-1", namespace_id = 3, status = "processing", quote_id = 15, payment_method = "card",
                tracking = cjson.encode({}) }
package.loaded["queries.ShopOrderQueries"] = {
    getByUuid = function(ns, uuid) if ns == 3 and uuid == "ord-1" then return ORDER end end,
}

local Q = require("queries.ShopOrderEventQueries")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1 print("ok   - " .. name)
    else failed = failed + 1 print("FAIL - " .. name .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or "")) end
end
local function step(list, key) for _, s in ipairs(list) do if s.key == key then return s end end end

-- progress ----------------------------------------------------------------------------------------
reset({ po = { { status = "cancelled", created_at = "x" },
               { status = "received", created_at = "2026-11-15T15:07:00Z", sent_at = "2026-11-17T14:51:00Z",
                 received_at = "2026-11-17T15:46:00Z" } } })
local p = Q.progress(ORDER)
check("eight steps, in order", #p == 8 and p[1].key == "placed" and p[8].key == "invoiced")
check("placed shows the quote number", step(p, "placed").detail == "WSQ-2026-00015")
check("paid with method", step(p, "paid").done and step(p, "paid").detail == "card")
check("cancelled PO skipped, active one used", step(p, "supplier_order").at == "2026-11-15T15:07:00Z")
check("ordered from supplier = PO sent", step(p, "ordered_from_supplier").done)
check("goods received", step(p, "goods_received").done and step(p, "goods_received").at == "2026-11-17T15:46:00Z")
check("not shipped yet", not step(p, "shipped").done and not step(p, "delivered").done)
local blob = cjson.encode(p)
check("never the supplier name or PO number", not blob:find("PO%-") and not blob:find("Boston"))

reset({ times = { created_at = "2026-11-13T14:11:11Z" } })
p = Q.progress({ id = 7, uuid = "o2", namespace_id = 3, status = "pending_payment", tracking = "{}" })
check("unpaid: paid not done, no PO", not step(p, "paid").done and not step(p, "supplier_order").done)

reset({ invoice = { invoice_number = "INV-0042", created_at = "2026-11-18T09:00:00Z" } })
p = Q.progress({ id = 8, uuid = "o3", namespace_id = 3, status = "delivered", invoice_uuid = "inv-1",
                 tracking = cjson.encode({ carrier = "DPD", tracking_number = "123", shipped_at = "2026-11-17T17:00:00Z" }) })
check("shipped with tracking", step(p, "shipped").done and step(p, "shipped").detail == "DPD 123")
check("delivered", step(p, "delivered").done)
check("invoiced with number", step(p, "invoiced").done and step(p, "invoiced").detail == "INV-0042")

-- updates -------------------------------------------------------------------------------------------
reset({ events = { { uuid = "e1", kind = "comment", message = "Booked for 6pm", author = "staff@x", at = "2026-11-17T16:00:00Z" } },
        emails = { { uuid = "m1", headline = "Ready to deliver", body = "Hi", at = "2026-11-17T15:00:00Z" } },
        changes = { { uuid = "c1", requested_address = cjson.encode({ name = "K", line1 = "15 Gadesden Road", city = "Epsom",
                       postcode = "KT19 9LB", country = "GB" }), at = "2026-11-17T17:00:00Z" } } })
local u = Q.updates(ORDER)
check("three updates, newest first", #u == 3 and u[1].kind == "delivery_change" and u[3].kind == "email", cjson.encode(u))
check("email shows headline and body", u[3].title == "Ready to deliver" and u[3].message == "Hi")
check("delivery change describes the address", u[1].message:find("15 Gadesden Road", 1, true) ~= nil)
check("customer view hides the author", u[2].author == nil)
u = Q.updates(ORDER, { admin = true })
check("admin view shows the author", u[2].author == "staff@x" and u[2].removable == true)

-- comments --------------------------------------------------------------------------------------------
reset()
local c, err = Q.addComment(3, "ord-1", { message = "  We can deliver today between 6 and 7pm.  " }, "staff@x", 9)
check("comment added", c and c.kind == "comment" and c.message == "We can deliver today between 6 and 7pm.", err and err.message)
c, err = Q.addComment(3, "ord-1", { message = " " }, "staff@x")
check("blank comment refused", c == nil and err.status == 400)
c, err = Q.addComment(3, "ord-1", { message = string.rep("x", 9000) }, "staff@x")
check("huge comment refused", c == nil and err.status == 400)
c, err = Q.addComment(4, "ord-1", { message = "hello" }, "staff@x")
check("another workspace's order: 404", c == nil and err.status == 404)
c = Q.addComment(3, "ord-1", { message = "<script>alert(1)</script>" }, "staff@x")
check("stored as text (rendered as text by the shop)", c and c.message == "<script>alert(1)</script>")

reset()
Q.addComment(3, "ord-1", { message = "oops" }, "staff@x")
local r = Q.remove(3, "ord-1", S.inserts[1].uuid, "staff@x")
check("comment removed", r and r.removed and S.inserts[1].deleted)
r, err = Q.remove(3, "ord-1", "nope", "staff@x")
check("unknown update: 404", r == nil and err.status == 404)

-- record ----------------------------------------------------------------------------------------------
reset()
check("record stores a status event", Q.record(ORDER, "status", { status = "shipped", author = "s" })
    and S.inserts[1].kind == "status" and S.inserts[1].status == "shipped")
reset({ fail_insert = true })
check("record never raises (table missing before migration)", Q.record(ORDER, "status", { status = "shipped" }) == false)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
