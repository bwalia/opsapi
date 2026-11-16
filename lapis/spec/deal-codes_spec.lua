--[[
    Spec: private deal codes (lib/deal-codes.lua, queries/ShopDealQueries.lua) and who sees what.

    Standalone (no busted). From the repo root:
        luajit lapis/spec/deal-codes_spec.lua
    (CI runs it in bwalia/opsapi-base.) The database paths (codes on new leads / quotes / revisions / orders,
    the deal page, search, drop-ship confirmation, the backfill run twice, customer pages and emails) are
    driven for real by spec/deal-codes-e2e/run.sh.

    Covers:
      - format WS-XXXX-XXXX, the allowed characters only, settings for prefix and length
      - rejection sampling (no modulo bias), a CSPRNG source, uniqueness, a forced clash is retried
      - customer-facing shapes never carry the code (or the internal notes); staff shapes do
      - customer-facing templates, routes and email/invoice builders never reference it
      - supplier-facing purchase orders, price requests and their emails never carry the customer's name,
        email, phone, organisation or WSQ number; a drop-ship needs the tick box and is logged
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, INFO = 7, ctx = {}, var = {} } -- luacheck: ignore 111
ngx.escape_uri = ngx.escape_uri or function(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

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
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end

-- A scriptable lapis.db stub: `handler(sql, ...)` answers each query (default: no rows).
local handler = function() return {} end
local db = { NULL = setmetatable({}, { __tostring = function() return "NULL" end }) }
db.query = function(sql, ...) return handler(sql, ...) end
db.raw = function(s) return s end
db.escape_literal = function(s) return "'" .. tostring(s) .. "'" end
db.list = function(t) return t end
db.update = function() return {} end
db.interpolate_query = function(s) return s end
package.loaded["lapis.db"] = db
-- helper.global needs bcrypt (not in the plain OpenResty image); only generateUUID is used here.
package.loaded["helper.global"] = package.loaded["helper.global"] or setmetatable({
    generateUUID = function() return "00000000-0000-4000-8000-000000000000" end,
    getCurrentTimestamp = function() return os.date("!%Y-%m-%d %H:%M:%S") end,
}, { __index = function() return function() end end })

local Codes = require("lib.deal-codes")
local U = require("lib.shop-util")
local cjson = require("cjson")

-- A deterministic "random" source for the pure tests: cycles through the given bytes.
local function source(bytes)
    local i = 0
    return function(n)
        local out = {}
        for _ = 1, n do
            i = i % #bytes + 1
            out[#out + 1] = string.char(bytes[i])
        end
        return table.concat(out)
    end
end
local function urandom(n)
    local f = assert(io.open("/dev/urandom", "rb"))
    local s = f:read(n)
    f:close()
    return s
end

-- ---------------------------------------------------------------------------
print("Format and characters:")
local ALLOWED = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
check("alphabet has no 0 O 1 I L", Codes.ALPHABET == ALLOWED and not Codes.ALPHABET:find("[0O1IL]"))
local code = Codes.generate({ bytes = urandom })
check("default code looks like WS-XXXX-XXXX", code:match("^WS%-[" .. ALLOWED .. "][" .. ALLOWED .. "][" .. ALLOWED .. "]["
    .. ALLOWED .. "]%-[" .. ALLOWED .. "][" .. ALLOWED .. "][" .. ALLOWED .. "][" .. ALLOWED .. "]$") ~= nil, code)
check("the example WS-DT5Z-994X is valid", Codes.valid("WS-DT5Z-994X"))
local all_ok, bad = true, nil
for _ = 1, 2000 do
    local c = Codes.generate({ bytes = urandom })
    local body = c:sub(4):gsub("%-", "")
    if #body ~= 8 or body:find("[^" .. ALLOWED .. "]") or not Codes.valid(c) then all_ok, bad = false, c end
end
check("2000 codes: only allowed characters, all valid", all_ok, bad)
check("prefix setting", Codes.generate({ prefix = "ACME", bytes = urandom }):match("^ACME%-") ~= nil)
check("length setting: 12 = XXXX-XXXX-XXXX", Codes.generate({ length = 12, bytes = urandom }):match("^WS%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w$") ~= nil)
check("length setting: 10 = XXXX-XXXX-XX", Codes.generate({ length = 10, bytes = urandom }):match("^WS%-%w%w%w%w%-%w%w%w%w%-%w%w$") ~= nil)
check("prefix 'ws ' is cleaned to WS", Codes.clean_prefix("ws ") == "WS")
check("prefix too long refused", Codes.clean_prefix("ABCDEFG") == nil)
check("prefix with a hyphen refused", Codes.clean_prefix("W-S") == nil)
check("length 5 refused", Codes.clean_length(5) == nil)
check("length 17 refused", Codes.clean_length(17) == nil)
check("length 8.5 refused", Codes.clean_length(8.5) == nil)
check("defaults WS / 8", Codes.clean_prefix(nil) == "WS" and Codes.clean_length(nil) == 8)
check("ambiguous characters are not valid", not Codes.valid("WS-DT5Z-994O") and not Codes.valid("WS-DT5Z-9941")
    and not Codes.valid("WS-DT5Z-994L") and not Codes.valid("WS-DT5Z-994I") and not Codes.valid("WS-DT5Z-9940"))
check("lower case is not a stored code", not Codes.valid("ws-dt5z-994x"))
check("a WSQ quote number is not a deal code", not Codes.valid("WSQ-2026-00021") and Codes.normalize("WSQ-2026-00021") == nil)
check("normalize: lower case and spaces", Codes.normalize("  ws dt5z 994x ") == "WS-DT5Z-994X", Codes.normalize("  ws dt5z 994x "))
check("normalize: missing inner hyphen", Codes.normalize("WS-DT5Z994X") == "WS-DT5Z-994X")
check("normalize: no hyphens with the prefix known", Codes.normalize("wsdt5z994x", "WS") == "WS-DT5Z-994X")
check("normalize: rubbish", Codes.normalize("hello") == nil and Codes.normalize("") == nil and Codes.normalize(nil) == nil)

print("Secure random source and no modulo bias:")
check("bytes 248..255 are thrown away (31 symbols: 248 = 8 x 31)", Codes.REJECT_FROM == 248)
-- Only rejected bytes, then byte 0 ('A'): the code must be all A's (the rejected ones never map to a symbol).
check("rejected bytes never become characters",
    Codes.generate({ bytes = source({ 248, 249, 250, 251, 252, 253, 254, 255, 0 }) }) == "WS-AAAA-AAAA")
-- Every accepted byte value maps to a character, each character from exactly 8 byte values.
local counts, rejected = {}, 0
for b = 0, 255 do
    local ch = Codes.symbol(b)
    if ch then counts[ch] = (counts[ch] or 0) + 1 else rejected = rejected + 1 end
end
local lo, hi = math.huge, 0
for i = 1, #ALLOWED do
    local n = counts[ALLOWED:sub(i, i)] or 0
    lo, hi = math.min(lo, n), math.max(hi, n)
end
check("every character comes from exactly 8 byte values (uniform)", lo == 8 and hi == 8, lo .. ".." .. hi)
check("8 byte values rejected", rejected == 8)
check("no random source: refused", not pcall(Codes.generate, {}))
local gen_src = read("lapis/lib/deal-codes.lua") .. read("lapis/queries/ShopDealQueries.lua")
check("math.random is never used for codes", not gen_src:find("math%.random"))
check("the database layer draws from resty.random / OpenSSL, else /dev/urandom",
    gen_src:find("U.random_bytes", 1, true) ~= nil and gen_src:find("/dev/urandom", 1, true) ~= nil)
-- Never built from customer data: generate() takes only the prefix, the length and the random source.
check("generate() reads only prefix, length and bytes", (function()
    local seen = {}
    local opts = setmetatable({}, { __index = function(_, k) seen[k] = true; if k == "bytes" then return urandom end end })
    Codes.generate(opts)
    for k in pairs(seen) do if k ~= "prefix" and k ~= "length" and k ~= "bytes" then return false end end
    return true
end)())

print("Uniqueness:")
local seen, dup = {}, false
for _ = 1, 20000 do
    local c = Codes.generate({ bytes = urandom })
    if seen[c] then dup = true end
    seen[c] = true
end
check("20000 codes, no duplicates (31^8 ≈ 8.5e11 possible)", not dup)
local mig = read("lapis/migrations/shop-deal-codes.lua")
check("UNIQUE index on shop_deal_codes(code)", mig:find("CREATE UNIQUE INDEX IF NOT EXISTS shop_deal_codes_code_uidx ON shop_deal_codes %(code%)") ~= nil)

-- newCode() against a stubbed database: the first two draws clash (INSERT … ON CONFLICT DO NOTHING returns no row).
local D = require("queries.ShopDealQueries")
D.random_bytes = urandom
local inserts, tried = 0, {}
handler = function(sql, ...)
    if sql:find("INSERT INTO shop_deal_codes", 1, true) then
        inserts = inserts + 1
        local _, c = ...
        tried[#tried + 1] = c
        if inserts <= 2 then return {} end -- clash
        return { { code = c } }
    end
    return {}
end
local got = D.newCode(7, 1)
check("forced clash: retried until a free code (3 inserts)", inserts == 3 and got == tried[3], inserts)
check("each retry draws a new code", tried[1] ~= tried[2] and tried[2] ~= tried[3])
check("the insert uses ON CONFLICT (code) DO NOTHING (a clash never aborts the transaction)",
    gen_src:find("ON CONFLICT (code) DO NOTHING", 1, true) ~= nil)
inserts = 0
handler = function(sql)
    if sql:find("INSERT INTO shop_deal_codes", 1, true) then inserts = inserts + 1; return {} end
    return {}
end
local ok_all = pcall(D.newCode, 7, 1)
check("gives up with an error after " .. D.MAX_ATTEMPTS .. " clashes", not ok_all and inserts == D.MAX_ATTEMPTS, inserts)
handler = function() return {} end

-- ---------------------------------------------------------------------------
print("Customers never see the deal code (or internal notes):")
local Quotes = require("queries.ShopQuoteQueries")
local Orders = require("queries.ShopOrderQueries")
local CODE = "WS-DT5Z-994X"
local quote_row = {
    id = 1, uuid = "q-uuid", namespace_id = 7, quote_number = "WSQ-2026-00021", access_token = "tok", status = "sent",
    source = "admin", customer = '{"name":"Jane Buyer","email":"jane@buyer.test","company":"Buyer Ltd","phone":"07700 900123"}',
    notes = "Thanks", internal_notes = "Boston quoted 9,000 (SECRET-NOTE)", lines = "[]", subtotal_minor = 100, vat_minor = 20,
    shipping_minor = 0, total_minor = 120, currency = "GBP", valid_until = "2099-01-01", kind = "quote",
    deal_code = CODE, revision_no = 0, is_past_validity = false,
}
local function json(t) return U.enc(t) end
local public_quote = json(Quotes.shape(quote_row, { contact = true }))
check("public quote shape: no deal code", not public_quote:find(CODE, 1, true) and not public_quote:find("deal_code", 1, true))
check("public quote shape: no internal notes", not public_quote:find("SECRET-NOTE", 1, true)
    and not public_quote:find("internal_notes", 1, true))
local list_quote = json(Quotes.shape(quote_row))
check("customer quote list shape: no deal code", not list_quote:find(CODE, 1, true))
local admin_quote = Quotes.shape(quote_row, { admin = true })
check("staff quote shape: has the deal code", admin_quote.deal_code == CODE)
local order_row = {
    id = 2, uuid = "o-uuid", namespace_id = 7, order_number = "WSO-2026-00009", access_token = "otok", status = "paid",
    email = "jane@buyer.test", customer = quote_row.customer, lines = "[]", subtotal_minor = 100, vat_minor = 20,
    shipping_minor = 0, total_minor = 120, currency = "GBP", internal_notes = "Supplier PO raised (SECRET-NOTE)",
    deal_code = CODE, created_at = "2026-11-16",
}
local public_order = json(Orders.shape(order_row))
check("public order shape: no deal code", not public_order:find(CODE, 1, true) and not public_order:find("deal_code", 1, true))
check("public order shape: no internal notes", not public_order:find("SECRET-NOTE", 1, true))
check("staff order shape: has the deal code", Orders.shape(order_row, { admin = true }).deal_code == CODE)

-- Every customer-facing source: the deal code is never referenced. (The shop renders the quote page, the
-- customer link and the quote PDF from the public shapes above.)
local customer_facing = {
    "lapis/routes/shop-public.lua", "lapis/views/emails/shop_order_update.etlua",
    "lapis/views/emails/shop_order_authorisation.etlua", "lapis/views/emails/lead_confirmation.etlua",
    "lapis/views/emails/_base.etlua", "lapis/lib/shop-order-updates.lua", "lapis/queries/ShopOrderUpdateQueries.lua",
    "lapis/queries/ShopDeliveryChangeQueries.lua", "lapis/queries/ShopCustomerAuthQueries.lua",
    "lapis/queries/ShopStripeQueries.lua", "lapis/lib/crm/lead-confirmation.lua", "lapis/queries/PaymentMethodQueries.lua",
}
for _, f in ipairs(customer_facing) do
    local ok, s = pcall(read, f)
    if ok then check(f:gsub("^lapis/", "") .. " never mentions deal_code", not s:find("deal_code", 1, true)) end
end
-- The customer's emails and invoice are built from whitelisted data: the code is never in it.
local qsrc = read("lapis/queries/ShopQuoteQueries.lua")
local send_block = qsrc:match("function ShopQuoteQueries%.sendToCustomer.-\nend\n")
check("quote/OA email data has no deal code", send_block and not send_block:find("deal_code", 1, true))
local osrc = read("lapis/queries/ShopOrderQueries.lua")
local invoice_block = osrc:match("function ShopOrderQueries%.createInvoice.-\nend\n")
check("invoice from an order has no deal code", invoice_block and not invoice_block:find("deal_code", 1, true))
local shape_q = qsrc:match("function ShopQuoteQueries%.shape.-\nend\n")
check("quote shape: deal_code only inside the staff (opts.admin) block",
    shape_q and (shape_q:find("deal_code", 1, true) or 0) > (shape_q:find("if opts.admin then", 1, true) or math.huge))
local shape_o = osrc:match("function ShopOrderQueries%.shape.-\nend\n")
check("order shape: deal_code only inside the staff (opts.admin) block",
    shape_o and (shape_o:find("deal_code", 1, true) or 0) > (shape_o:find("if opts.admin then", 1, true) or math.huge))

-- ---------------------------------------------------------------------------
print("Suppliers never see the customer:")
local customer = { name = "Jane Buyer", email = "jane@buyer.test", phone = "07700 900123", company = "Buyer Ltd" }
local markers = Codes.markers(customer, { "WSQ-2026-00021", "WSQ-2026-00021-R1" })
check("markers: name, email, phone, organisation, quote numbers", #markers == 6, #markers)
-- Positive controls: the check finds each of them.
check("leak check finds the email", Codes.leaks("Contact jane@BUYER.test", markers)[1] == "email")
check("leak check finds the phone however it is written", Codes.leaks("+44 7700 900123", markers)[1] == "phone")
check("leak check finds the organisation in a nested table", Codes.leaks({ a = { "for buyer ltd" } }, markers)[1] == "organisation")
check("leak check finds the WSQ number", Codes.leaks("ref WSQ-2026-00021", markers)[1] == "quote_number")
check("leak check: a clean text", #Codes.leaks("2 x RTX PRO 6000, deal " .. CODE, markers) == 0)

local base = {
    deal_code = CODE, order_uuid = "o-uuid", order_number = "WSO-2026-00009",
    supplier = { uuid = "s-uuid", name = "Boston Ltd", email = "sales@boston.test", phone = "01234 567890",
                 address = "Boston House", account_number = "ACC-1", notes = "Deliver 9-5" },
    items = { { description = "RTX PRO 6000 Blackwell\nSKU 900-5G144", quantity = 2, unit_price = "6500.00", tax_rate = "20" } },
    bill_to = { company = "Workstation Ltd", line1 = "1 Our Street", postcode = "AB1 2CD" },
    our_address = { company = "Workstation Ltd", line1 = "Unit 5 Goods In", postcode = "AB1 2CD" },
    our_address_text = "Workstation Ltd\nUnit 5 Goods In\nAB1 2CD",
    ship_to = { name = "Jane Buyer", company = "Buyer Ltd", line1 = "9 Customer Road", postcode = "ZZ9 9ZZ",
                email = "jane@buyer.test", phone = "07700 900123" },
    ship_to_text = "Jane Buyer, Buyer Ltd\n9 Customer Road\nZZ9 9ZZ\n07700 900123\njane@buyer.test",
    customer_po_number = "BUYER-PO-77", delivery_method = "Courier", notes = "Please ship together", currency = "GBP",
}
local po = Codes.supplier_po(base)
local visible = Codes.supplier_visible(po)
check("PO: the reference is the deal code", po.reference == CODE)
check("PO: delivers to our address by default", po.delivery_address == base.our_address_text)
check("PO: the deal code is printed", po.notes:find(CODE, 1, true) ~= nil)
check("PO (supplier-visible fields): no customer name, email, phone, organisation or WSQ number",
    #Codes.leaks(visible, markers) == 0, table.concat(Codes.leaks(visible, markers), ","))
check("PO (everything stored, metadata included): nothing about the customer", #Codes.leaks(po, markers) == 0,
    table.concat(Codes.leaks(po, markers), ","))
check("PO: not a drop-ship, no customer address in the metadata", po.metadata.drop_ship == false and po.metadata.ship_to == nil)
check("PO: the customer's own PO number is not printed", not cjson.encode(visible):find("BUYER-PO-77", 1, true))

local drop = {}
for k, v in pairs(base) do drop[k] = v end
drop.drop_ship = true
local dpo = Codes.supplier_po(drop)
check("drop-ship PO: delivers to the customer's address", dpo.delivery_address == base.ship_to_text)
check("drop-ship PO: marked as confirmed in the metadata", dpo.metadata.drop_ship == true and dpo.metadata.drop_ship_confirmed == true)
check("drop-ship PO: still no WSQ number", not cjson.encode(dpo):find("WSQ-", 1, true))

local mail = Codes.request_email({ deal_code = CODE, contact_name = "Sam at Boston", spec = "2 x RTX PRO 6000, 1TB RAM",
    lines = { { description = "RTX PRO 6000 Blackwell", qty = 2 }, { description = "1TB DDR5", qty = 1 } } },
    { company = "Workstation Ltd", sender = "Bal" })
check("supplier request email: subject 'Price request: <code>'", mail.subject == "Price request: " .. CODE, mail.subject)
check("supplier request email: has the spec and the lines", mail.body:find("1TB RAM", 1, true) and mail.body:find("2 x RTX PRO 6000 Blackwell", 1, true))
check("supplier request email: no customer details", #Codes.leaks(mail, markers) == 0)

-- The database layer refuses to put the customer in front of a supplier, and the drop-ship needs the tick box.
local create_po = osrc:match("function ShopOrderQueries%.createPurchaseOrder.-\nend\n") or ""
check("createPurchaseOrder: drop-ship refused without confirm_drop_ship",
    create_po:find('drop and body.confirm_drop_ship ~= true', 1, true) and create_po:find("DROP_SHIP_NOT_CONFIRMED", 1, true))
check("createPurchaseOrder: a confirmed drop-ship is logged on the deal", create_po:find('"drop_ship.confirmed"', 1, true) ~= nil)
check("createPurchaseOrder: leak check before the PO is created",
    (create_po:find("DealCodes.leaks", 1, true) or math.huge) < (create_po:find("POQ.create", 1, true) or 0))
check("createPurchaseOrder: builds the PO with DealCodes.supplier_po", create_po:find("DealCodes.supplier_po", 1, true) ~= nil)
local dsrc = read("lapis/queries/ShopDealQueries.lua")
check("supplier requests: leak check on create, update and the email draft",
    select(2, dsrc:gsub("check_private%(ns_id", "")) >= 3)
check("email draft: nothing is sent (no Mail.send)", not dsrc:find("Mail.send", 1, true) and dsrc:find("sent = false", 1, true))

-- ---------------------------------------------------------------------------
print("Compare table:")
local cmp = Codes.compare(
    { { uuid = "l1", description = "GPU", qty = 2, unit_price_minor = 700000 },
      { uuid = "l2", description = "RAM", qty = 1, unit_price_minor = 100000 } },
    { { uuid = "r1", supplier_name = "Boston", lines = { { line_uuid = "l1", unit_price_minor = 650000 }, { line_uuid = "l2", unit_price_minor = 120000 } } },
      { uuid = "r2", supplier_name = "Scan", lines = { { line_uuid = "l1", unit_price_minor = 690000 } } } })
check("profit per line", cmp.rows[1].suppliers[1].profit_line_minor == 100000)
check("below cost flagged", cmp.rows[2].suppliers[1].below_cost == true and cmp.below_cost_count == 1)
check("no price from a supplier: not flagged", cmp.rows[2].suppliers[2].cost_unit_minor == nil and cmp.rows[2].suppliers[2].below_cost == false)

-- ---------------------------------------------------------------------------
print("Wiring:")
local migs = read("lapis/migrations.lua")
check("migrations zzs55-57 registered under FEATURES.SHOP", migs:find("['zzs55_shop_deal_codes'] = conditional_array(ProjectConfig.FEATURES.SHOP", 1, true)
    and migs:find("['zzs57_shop_deal_codes_backfill'] = conditional_array(ProjectConfig.FEATURES.SHOP", 1, true))
check("backfill fills NULLs only", dsrc:find("WHERE deal_code IS NULL", 1, true) ~= nil and not dsrc:find("SET deal_code = NULL", 1, true))
check("a revision takes its original's code", dsrc:find("U.nz(q.revision_of_id)", 1, true) ~= nil)
local admin_routes = read("lapis/routes/shop-admin.lua")
check("deal routes are staff routes (shop RBAC guard)", admin_routes:find('app:get(BASE .. "/deals/:code", guard("read"', 1, true) ~= nil)
check("no deal route on the public shop API", not read("lapis/routes/shop-public.lua"):find("/deals", 1, true))

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
