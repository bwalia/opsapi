-- luacheck: max line length 140
--[[
    Plain-Lua unit test for ShopDeliveryChangeQueries.adminSetAddress (staff edit the delivery address in the
    back office) and the supplier PO "Deliver directly to" it writes. No nginx, no DB: lapis.db is a fake that
    answers the few queries the function makes and records the writes.

    Run from the repo root (as CI does) or from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/shop-admin-delivery-address_spec.lua
]]

package.path = "./?.lua;./lapis/?.lua;" .. package.path

local cjson = require("cjson")

-- fake database ----------------------------------------------------------------------------------------
local state
local function reset(order, pos)
    state = { order = order, pos = pos or {}, writes = {}, notes = {}, rolled_back = false }
end

local function has(sql, pat) return sql:find(pat, 1, true) ~= nil end

local fake_db = {
    NULL = setmetatable({}, { __tostring = function() return "NULL" end }),
    raw = function(s) return s end,
    escape_literal = function(s) return "'" .. tostring(s) .. "'" end,
}
function fake_db.query(sql, ...)
    local args = { ... }
    if sql == "BEGIN" or sql == "COMMIT" then return {} end
    if sql == "ROLLBACK" then state.rolled_back = true return {} end
    if has(sql, "to_char(NOW()") then return { { t = "2026-11-17 18:00" } } end
    if has(sql, "FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE") then
        local o = state.order
        if o and args[1] == o.namespace_id and args[2] == o.uuid then return { o } end
        return {}
    end
    if has(sql, "FROM purchase_orders") and has(sql, "FOR UPDATE") then
        state.po_query = sql
        return state.pos
    end
    if has(sql, "UPDATE shop_orders SET delivery_address") then
        state.writes[#state.writes + 1] = { kind = "order", address = cjson.decode(args[1]), id = args[2] }
        return {}
    end
    if has(sql, "UPDATE purchase_orders SET delivery_address") then
        state.writes[#state.writes + 1] = { kind = "po", text = args[1], ship_to = cjson.decode(args[2]), id = args[3] }
        return {}
    end
    if has(sql, "UPDATE shop_orders SET internal_notes") then
        state.notes[#state.notes + 1] = args[1]
        return {}
    end
    error("unexpected query: " .. sql)
end
package.loaded["lapis.db"] = fake_db

-- Everything else ShopOrderQueries pulls in is out of scope here: an inert stub.
local function stub()
    return setmetatable({}, { __index = function() return function() end end })
end
for _, m in ipairs({ "helper.global", "lib.shop-pricing", "queries.ShopCatalogQueries", "queries.ShopCartQueries",
                     "queries.ShopQuoteQueries", "queries.ShopStockQueries", "queries.PaymentMethodQueries",
                     "lib.payment-methods", "lib.shop-quote-rules", "queries.ShopDealQueries", "lib.deal-codes",
                     "queries.ShopCostQueries" }) do
    package.loaded[m] = stub()
end

local Orders = require("queries.ShopOrderQueries")
Orders.adminGet = function(_, uuid) return { uuid = uuid, reloaded = true } end
local Q = require("queries.ShopDeliveryChangeQueries")

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

local function order(over)
    local o = {
        id = 6, uuid = "ord-1", namespace_id = 3, status = "processing", email = "k@example.com",
        customer = cjson.encode({ name = "Kate", email = "k@example.com", company = "IQ Ltd", vat_number = "GB1" }),
        delivery_address = cjson.encode({ name = "Kate", company = "IQ Ltd", line1 = "Vine House", line2 = "143 London Road",
                                          city = "Kingston upon Thames", postcode = "KT2 6NH", country = "United Kingdom",
                                          phone = "02081668770", email = "k@example.com", vat_number = "GB1" }),
    }
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end

local HOME = { name = "Kate", line1 = "15 Gadesden Road", line2 = "West Ewell", city = "Epsom", postcode = "kt199lb",
               phone = "+447833229206" }

-- the happy path: order and an already-sent drop-ship PO --------------------------------------------------
reset(order(), { { id = 1, po_number = "PO-000001", status = "sent", supplier_name = "Boston", sent_at = "2026-11-17" } })
local res, err = Q.adminSetAddress(3, "ord-1", { address = HOME, staff_note = "Customer phoned" }, "staff@example.com")
check("returns the reloaded order", res and res.order and res.order.reloaded == true, err and err.message)
local ow = state.writes[1]
check("order address written", ow and ow.kind == "order" and ow.id == 6)
check("postcode normalised", ow and ow.address.postcode == "KT19 9LB", ow and ow.address.postcode)
check("country is GB", ow and ow.address.country == "GB")
check("keeps the agreed email and VAT number", ow and ow.address.email == "k@example.com" and ow.address.vat_number == "GB1")
check("blank company stored as empty, not dropped", ow and ow.address.company == "")
local pw = state.writes[2]
check("drop-ship PO updated", pw and pw.kind == "po" and pw.id == 1)
check("PO text has the postcode", pw and pw.text:find("Epsom KT19 9LB", 1, true) ~= nil, pw and pw.text)
check("PO text has no customer company for a home address", pw and not pw.text:find("IQ Ltd", 1, true), pw and pw.text)
check("PO ship_to has the new line1", pw and pw.ship_to.line1 == "15 Gadesden Road")
check("only open drop-ship POs are selected", state.po_query and state.po_query:find("drop_ship", 1, true)
    and state.po_query:find("NOT IN ('received', 'billed', 'cancelled')", 1, true))
check("result flags the PO as already sent", res and res.purchase_orders[1] and res.purchase_orders[1].already_sent == true)
local note = state.notes[1] or ""
check("note names who changed it", note:find("changed by staff@example.com", 1, true) ~= nil, note)
check("note keeps the old address", note:find("Was: Kate, IQ Ltd, Vine House", 1, true) ~= nil, note)
check("note has the staff note", note:find("Note: Customer phoned", 1, true) ~= nil, note)
check("note tells staff to tell the supplier", note:find("already sent to Boston: tell them", 1, true) ~= nil, note)

-- update_purchase_orders = false leaves POs alone -------------------------------------------------------
reset(order(), { { id = 1, po_number = "PO-000001", status = "sent", supplier_name = "Boston", sent_at = "2026-11-17" } })
res = Q.adminSetAddress(3, "ord-1", { address = HOME, update_purchase_orders = false }, "staff")
check("POs untouched when asked", #state.writes == 1 and state.po_query == nil and #res.purchase_orders == 0)

-- refusals ---------------------------------------------------------------------------------------------
reset(order({ status = "shipped" }))
res, err = Q.adminSetAddress(3, "ord-1", { address = HOME }, "staff")
check("shipped order refused with 409", res == nil and err and err.status == 409 and #state.writes == 0, err and err.status)
check("refusal rolls back", state.rolled_back)

reset(order())
res, err = Q.adminSetAddress(3, "ord-1", { address = { name = "Kate", line1 = "1 Rue", city = "Paris", postcode = "75001" } }, "s")
check("non-UK postcode refused with 400", res == nil and err and err.status == 400 and #state.writes == 0, err and err.status)

reset(order())
res, err = Q.adminSetAddress(4, "ord-1", { address = HOME }, "staff")
check("another workspace's order is not found", res == nil and err and err.status == 404, err and err.status)

reset(order({ delivery_address = cjson.encode({ name = "Kate", company = "", line1 = "15 Gadesden Road", line2 = "West Ewell",
    city = "Epsom", postcode = "KT19 9LB", country = "GB", phone = "+447833229206", email = "k@example.com" }) }))
res, err = Q.adminSetAddress(3, "ord-1", { address = HOME }, "staff")
check("same address refused (NO_CHANGE)", res == nil and err and err.code == "NO_CHANGE", err and (err.code or err.message))

-- agreed address without an email: the customer's email mustn't make an unchanged address look changed
reset(order({ delivery_address = cjson.encode({ name = "Kate", company = "", line1 = "15 Gadesden Road", line2 = "West Ewell",
    city = "Epsom", postcode = "KT19 9LB", country = "GB", phone = "+447833229206" }) }))
res, err = Q.adminSetAddress(3, "ord-1", { address = HOME }, "staff")
check("same address, no agreed email: still NO_CHANGE", res == nil and err and err.code == "NO_CHANGE",
    err and (err.code or err.message))

reset(order({ delivery_address = cjson.encode({ name = "Kate", company = "", line1 = "15 Gadesden Road", line2 = "West Ewell",
    city = "Epsom", postcode = "KT19 9LB", country = "GB", phone = "+447833229206" }) }))
local with_email = {}
for k, v in pairs(HOME) do with_email[k] = v end
with_email.email = "new@example.com"
res, err = Q.adminSetAddress(3, "ord-1", { address = with_email }, "staff")
check("a newly typed email is a change", res ~= nil and state.writes[1] and state.writes[1].address.email == "new@example.com",
    err and (err.code or err.message))

-- the PO prints the country name, not the ISO code
check("PO text says United Kingdom, not GB", Orders.addressText({ name = "A", line1 = "1 St", city = "Epsom", postcode = "KT19 9LB",
    country = "GB" }):find("\nUnited Kingdom", 1, true) ~= nil)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
