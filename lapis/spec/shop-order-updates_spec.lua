-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-order-updates.lua and the shop.order_update template registration
    (no nginx, no DB, no busted).

    Run from the repo root (as CI does) or from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/shop-order-updates_spec.lua
]]

package.path = "./?.lua;./lapis/?.lua;" .. package.path

local Upd = require("lib.shop-order-updates")

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

-- presets ---------------------------------------------------------------------------------------
local keys = {}
for i, p in ipairs(Upd.PRESETS) do keys[p.key] = i end
for _, k in ipairs({ "received_reserved", "in_stock_book_delivery", "dispatched", "delayed", "custom" }) do
    check("preset " .. k .. " exists", keys[k] ~= nil and Upd.preset(k) ~= nil)
end
check("custom is last", keys.custom == #Upd.PRESETS)
check("unknown preset is nil", Upd.preset("nope") == nil and Upd.preset(nil) == nil and Upd.preset({}) == nil)
check("custom preset is blank", Upd.preset("custom").headline == "" and Upd.preset("custom").message == "")

local rr = Upd.preset("received_reserved")
check("received_reserved headline", rr.headline == "Order received")
check("received_reserved text is the owner's wording", rr.message == "Thank you, we've received your order {order_number}. "
    .. "We've placed the order with our supplier and your item is reserved for you. We'll collect it in the next day or two, "
    .. "and as soon as it's with us we'll be in touch to agree a delivery time that suits you.")
check("in_stock headline", Upd.preset("in_stock_book_delivery").headline == "Ready to deliver")
check("dispatched headline", Upd.preset("dispatched").headline == "On its way")
check("delayed headline", Upd.preset("delayed").headline == "Update on your order")

-- Wording rules: no supplier / distributor brand, no round-the-clock promises, UK English, Mon–Fri 9–6.
local BANNED = { "ingram", "tech data", "td synnex", "synnex", "westcoast", "exertis", "24/7", "24 hours a day",
                 "round the clock", "color", "organize", "realize", "center" }
for _, p in ipairs(Upd.PRESETS) do
    local text = (p.headline .. " " .. p.message .. " " .. p.label):lower()
    for _, b in ipairs(BANNED) do
        check("preset " .. p.key .. " does not say '" .. b .. "'", not text:find(b, 1, true))
    end
    check("preset " .. p.key .. " headline fits", #p.headline <= Upd.HEADLINE_MAX)
    check("preset " .. p.key .. " message fits", #p.message <= Upd.MESSAGE_MAX)
    if p.message:lower():find("9am", 1, true) then
        check("preset " .. p.key .. " hours are Monday to Friday, 9am to 6pm", p.message:find("Monday to Friday, 9am to 6pm", 1, true))
    end
end

-- placeholders -----------------------------------------------------------------------------------
check("fill replaces known names", Upd.fill("Hi {first_name}, order {order_number}.", { first_name = "Ann", order_number = "WS-1" })
    == "Hi Ann, order WS-1.")
check("fill leaves unknown names", Upd.fill("x {nope} y", {}) == "x {nope} y")
check("fill of a non-string is empty", Upd.fill(nil, {}) == "")
check("fill does not treat % in values as patterns", Upd.fill("{a}", { a = "100%" }) == "100%")
check("first_name", Upd.first_name("  Sam Taylor ") == "Sam" and Upd.first_name("") == nil and Upd.first_name(nil) == nil)

local r = Upd.render(rr, { order_number = "WS-10042" })
check("render fills the order number", r.message:find("WS-10042", 1, true) ~= nil and not r.message:find("{", 1, true))
check("render keeps key and label", r.key == "received_reserved" and r.label == rr.label)

check("tracking_line: none", Upd.tracking_line(nil) == "" and Upd.tracking_line({}) == "")
check("tracking_line: carrier + number + url", Upd.tracking_line({ carrier = "DPD", tracking_number = "123 456",
    url = "https://track.example.com/123" }) == "\n\nTracking: DPD 123 456 (https://track.example.com/123)",
    Upd.tracking_line({ carrier = "DPD", tracking_number = "123 456", url = "https://track.example.com/123" }))
check("tracking_line: url only", Upd.tracking_line({ url = "https://t.example.com/x" }) == "\n\nTracking: https://t.example.com/x")
check("tracking_line: ignores a non-http url", Upd.tracking_line({ tracking_number = "9", url = "javascript:alert(1)" })
    == "\n\nTracking: 9")
local d = Upd.render(Upd.preset("dispatched"), { order_number = "WS-2", tracking_line = "" })
check("dispatched without tracking reads cleanly", d.message:find("on its way to you.\n\nIf anything", 1, true) ~= nil, d.message)

check("unfilled finds [NEW DATE]", Upd.unfilled(Upd.preset("delayed").message) == "[NEW DATE]")
check("unfilled ignores ordinary brackets", Upd.unfilled("Order (ref [a1]) is fine") == nil)
check("unfilled of nil", Upd.unfilled(nil) == nil)

-- validation -------------------------------------------------------------------------------------
local v = Upd.validate({ headline = "  Order   received ", message = "Line one\r\n\n\n\nLine\0 two\t ok \27" })
check("validate cleans the headline", v and v.headline == "Order received", v and v.headline)
check("validate keeps line breaks, strips control characters", v and v.message == "Line one\n\nLine two ok", v and v.message)
local _, e1 = Upd.validate({ headline = "", message = "x" })
check("headline required", e1 and e1.field == "headline")
local _, e2 = Upd.validate({ headline = string.rep("a", 121), message = "x" })
check("headline max 120", e2 and e2.field == "headline")
check("headline of exactly 120 is fine", Upd.validate({ headline = string.rep("é", 120), message = "x" }) ~= nil)
local _, e3 = Upd.validate({ headline = "Hi", message = "  \n\t " })
check("message required", e3 and e3.field == "message")
local _, e4 = Upd.validate({ headline = "Hi", message = string.rep("a", 4001) })
check("message max 4000", e4 and e4.field == "message")
check("message of exactly 4000 characters is fine", Upd.validate({ headline = "Hi", message = string.rep("é", 4000) }) ~= nil)
check("message must be a string", select(2, Upd.validate({ headline = "Hi", message = {} })).field == "message")
check("body must be a table", select(2, Upd.validate(nil)).field == "body")
local v2 = Upd.validate({ headline = "Hi", message = "<b>bold</b> & co" })
check("validate leaves HTML for the template to escape", v2.message == "<b>bold</b> & co")
check("validate drops bidi overrides", Upd.validate({ headline = "a\226\128\174b", message = "x" }).headline == "a b")

-- delivery summary + note ------------------------------------------------------------------------
check("delivery_summary: nothing agreed", Upd.delivery_summary({}) == nil and Upd.delivery_summary(nil) == nil)
check("delivery_summary: date and window", Upd.delivery_summary({ delivery_date = "2026-11-18", delivery_window = "am" })
    == "Wed 18 Nov 2026, morning", Upd.delivery_summary({ delivery_date = "2026-11-18", delivery_window = "am" }))
check("delivery_summary: any time is not repeated", Upd.delivery_summary({ delivery_date = "2026-11-18", delivery_window = "all_day" })
    == "Wed 18 Nov 2026")
local ds = Upd.delivery_summary({ delivery_date = "2026-11-18", delivery_address = { line1 = "1 High St", city = "London",
    postcode = "SW1A 1AA", country = "GB", phone = "0700" } })
check("delivery_summary: address without phone", ds == "Wed 18 Nov 2026, to 1 High St, London, SW1A 1AA", ds)
check("delivery_summary: address only", Upd.delivery_summary({ delivery_address = { line1 = "1 High St" } }) == "To 1 High St")
check("note_line", Upd.note_line("2026-11-15 10:30", "ann@example.com", "Sam Taylor", "Order received")
    == "[2026-11-15 10:30] Update emailed to ann@example.com by Sam Taylor: Order received")

-- template registration (helper/namespace-mail.lua with its DB/mail dependencies stubbed) ---------
package.loaded["lapis.db"] = { query = function() return {} end, NULL = {} }
package.loaded["helper.global"] = {}
package.loaded["helper.mail"] = {}
package.loaded["helper.project-config"] = { isFeatureEnabled = function() return true end }
local NamespaceMail = require("helper.namespace-mail")
local t = NamespaceMail.TEMPLATES[Upd.TEMPLATE_KEY]
check("shop.order_update is registered", t ~= nil)
check("shop.order_update belongs to the shop feature", t and t.feature == "shop")
local f = t and (io.open("views/emails/" .. t.file .. ".etlua") or io.open("lapis/views/emails/" .. t.file .. ".etlua"))
check("its etlua body exists", f ~= nil)
local src = f and f:read("*a") or ""
if f then f:close() end
check("the body never outputs raw HTML (<%- …%>)", not src:find("<%-", 1, true))
check("the body has no unsubscribe link or tracking pixel", not src:lower():find("unsubscribe", 1, true)
    and not src:lower():find("<img", 1, true))
for _, var in ipairs({ "customer_name", "order_number", "headline", "message", "order_link", "delivery_summary", "signature",
                       "app_name", "call_phone" }) do
    local listed = false
    for _, x in ipairs(t and t.variables or {}) do if x == var then listed = true end end
    check("variable " .. var .. " is listed", listed)
    check("sample has " .. var, t and t.sample[var] ~= nil)
end
check("subject default", t and NamespaceMail.fill(t.subject, { headline = "Order received", order_number = "WS-1" }, true)
    == "Order received: order WS-1")
check("subject keeps headline on one line", NamespaceMail.fill(t.subject, { headline = "a\nb", order_number = "1" }, true)
    == "a b: order 1")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
