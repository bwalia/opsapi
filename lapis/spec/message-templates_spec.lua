--[[
    Spec: message templates (lib/message-templates.lua) and supplier introductions (queries/ShopSupplierIntroQueries.lua).

    Standalone (no busted). From the repo root:
        luajit lapis/spec/message-templates_spec.lua

    Covers:
      - privacy: {{customer.*}} only in a supplier_intro template; refused in price_request and stock_enquiry
      - unknown placeholders and unbalanced braces are refused; empty subject/body refused
      - render: values filled in, {{ spaced }} names, optional lines dropped when empty
      - parity: the built-in price_request template gives exactly lib/deal-codes.lua request_email's message
      - the built-in introduction names the customer, copies the lines and the deal code
      - an introduction is refused without the customer's agreement, before anything is read or sent
      - migrations zzs67 (kind 'intro') and zzs68 (shop_message_templates) are registered
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, INFO = 7, ctx = {}, var = {} } -- luacheck: ignore 111
ngx.escape_uri = ngx.escape_uri or function(s) return s end
local queried = 0
package.loaded["lapis.db"] = { query = function() queried = queried + 1; return {} end, NULL = {}, raw = function(x) return x end }
package.loaded["helper.global"] = package.loaded["helper.global"] or { generateUUID = function() return "u-1" end }

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and (": " .. tostring(detail)) or ""))
    end
end

local T = require("lib.message-templates")
local Codes = require("lib.deal-codes")

print("validate")
check("customer details refused in a price request",
    not T.validate("price_request", "Price request", "Hello, for {{customer.company}}"))
local _, why = T.validate("stock_enquiry", "Stock", "For {{customer.name}}")
check("…and in a stock enquiry, saying why", why and why:find("only allowed in a supplier introduction", 1, true), why)
check("customer details allowed in an introduction",
    T.validate("supplier_intro", "Intro {{deal.code}}", "Meet {{customer.name}} of {{customer.company}} ({{customer.email}})"))
check("unknown placeholder refused", not T.validate("price_request", "x", "{{price}}"))
check("unbalanced braces refused", not T.validate("price_request", "x", "Hello {{supplier.contact}"))
check("empty body refused", not T.validate("supplier_intro", "x", "   "))
check("unknown kind refused", not T.validate("newsletter", "x", "y"))
check("every built-in passes its own rules", T.validate("price_request", T.DEFAULTS.price_request.subject, T.DEFAULTS.price_request.body)
    and T.validate("stock_enquiry", T.DEFAULTS.stock_enquiry.subject, T.DEFAULTS.stock_enquiry.body)
    and T.validate("supplier_intro", T.DEFAULTS.supplier_intro.subject, T.DEFAULTS.supplier_intro.body))
check("built-in price request and stock enquiry never mention the customer",
    not (T.DEFAULTS.price_request.body .. T.DEFAULTS.stock_enquiry.body):find("customer.", 1, true))

print("render")
check("fills values", T.render("Hello {{supplier.contact}}, ref {{ deal.code }}", { ["supplier.contact"] = "Sam", ["deal.code"] = "WS-AB12-CD34" })
    == "Hello Sam, ref WS-AB12-CD34")
check("drops a line that is only an empty placeholder", T.render("a\n{{note}}\nb", { note = "" }) == "a\nb")
check("drops an empty labelled line", T.render("x\n   - Part number: {{product.mpn}}\ny", {}) == "x\ny")
check("keeps a labelled line with a value", T.render("   - Part number: {{product.mpn}}", { ["product.mpn"] = "ABC" }) == "   - Part number: ABC")
check("keeps blank lines that had no placeholder", T.render("a\n\nb", {}) == "a\n\nb")
check("lines_text numbers lines with parts",
    T.lines_text({ { description = "Tower", qty = 2, parts = { "1 x 9950X", "2 x RTX PRO 6000" } } })
    == "1. 2 x Tower\n   - 1 x 9950X\n   - 2 x RTX PRO 6000")

print("parity with the existing price request")
local lines = { { description = "AI Tower", qty = 1, parts = { "1 x Threadripper PRO 9975WX" } }, { description = "Monitor", qty = 2 } }
local old = Codes.request_email({ deal_code = "WS-AB12-CD34", contact_name = "Sam", lines = lines }, { company = "Workstation", sender = "Bal Walia" })
local vars = { ["supplier.contact"] = "Sam", ["deal.code"] = "WS-AB12-CD34", lines = T.lines_text(lines), ["sender.name"] = "Bal Walia",
               company = "Workstation" }
check("same subject", T.render(T.DEFAULTS.price_request.subject, vars) == old.subject)
check("same body", T.render(T.DEFAULTS.price_request.body, vars) == old.body, "\n" .. T.render(T.DEFAULTS.price_request.body, vars) .. "\n---\n" .. old.body)

print("supplier introduction")
local I = require("queries.ShopSupplierIntroQueries")
local cust = I.customer({ customer = '{"name":"Ada Lovelace","company":"Analytical Engines Ltd","email":"ada@example.com","phone":" "}' })
check("customer read, blank phone ignored", cust.name == "Ada Lovelace" and cust.company == "Analytical Engines Ltd" and cust.phone == nil)
local iv = I.vars("WS-AB12-CD34", { name = "Boston Limited", contact_name = "Sam Rogers" }, cust, lines,
    { first_name = "Bal", last_name = "Walia" }, "Workstation")
local intro = { subject = T.render(T.DEFAULTS.supplier_intro.subject, iv), body = T.render(T.DEFAULTS.supplier_intro.body, iv) }
check("subject names the organisation and the deal code", intro.subject == "Introduction: Analytical Engines Ltd (WS-AB12-CD34)", intro.subject)
check("greets the supplier's contact", intro.body:find("^Hello Sam Rogers,") ~= nil)
check("introduces the customer", intro.body:find("introduce Ada Lovelace of Analytical Engines Ltd", 1, true) ~= nil)
check("lists what they need", intro.body:find("1. 1 x AI Tower\n   - 1 x Threadripper PRO 9975WX", 1, true) ~= nil)
check("gives the customer's contact (no blank phone)", intro.body:find("Ada Lovelace · ada@example.com\n", 1, true) ~= nil, intro.body)
check("asks them to quote the deal code", intro.body:find("quote our reference WS-AB12-CD34", 1, true) ~= nil)

queried = 0
local res, err = I.send(1, "q-1", { supplier_uuid = "s-1", channel = "email", subject = "x", message = "y" }, { id = 1 })
check("refused without the customer's agreement", res == nil and err and err.code == "CUSTOMER_AGREEMENT_REQUIRED", err and err.code)
check("…before reading or sending anything", queried == 0, queried)
res, err = I.send(1, "q-1", { channel = "pigeon", customer_agreed = true }, { id = 1 })
check("bad channel refused", res == nil and err and err.status == 400)

print("migrations")
local function read(p)
    local f = io.open(p) or io.open("lapis/" .. p)
    local s = f:read("*a"); f:close(); return s
end
local mig = read("migrations.lua")
check("zzs67 registered", mig:find("['zzs67_supplier_introductions'] = conditional_array(ProjectConfig.FEATURES.SHOP, shop_deal_code_migrations, 6)", 1, true) ~= nil)
check("zzs68 registered", mig:find("['zzs68_shop_message_templates'] = conditional_array(ProjectConfig.FEATURES.SHOP, shop_deal_code_migrations, 7)", 1, true) ~= nil)
local dc = read("migrations/shop-deal-codes.lua")
check("kind allows intro", dc:find("CHECK (kind IN ('price', 'stock', 'intro'))", 1, true) ~= nil)
check("one default template per kind", dc:find("ON shop_message_templates (namespace_id, kind) WHERE is_default", 1, true) ~= nil)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
