-- luacheck: max line length 140
-- luacheck: globals ngx
--[[
    Plain-Lua spec (no nginx, no DB, nothing sent) for the shop payment and outbound-email fixes:

      - U.tx / U.afterCommit: side work (the staff alert, lead saves, closing a Stripe checkout) runs only
        after COMMIT and is dropped on a rollback, so it can never take a payment's transaction down
      - U.date (real calendar dates) and U.cut (UTF-8 safe truncation)
      - mark paid: bad dates, huge amounts and part payments are 400s, nothing written
      - paid twice: a card payment for an Order Authorisation another order already paid is cancelled and
        flagged for a refund, never fulfilled again; a still-open card checkout is closed when one is paid
      - Leads → Notifications without CRM (the ecommerce preset): defaults, the missing table is never read
      - email headers: CR/LF in a subject, a name or Reply-To can't add headers
      - bank details: every change is audited (before/after) and emailed to the owners, digits masked

    Run from the repo root (as CI does):
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/shop-payments-mail_spec.lua
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

-- SPEC_DEBUG=1 prints what the code logs (e.g. a swallowed error in a best-effort alert).
ngx = { ctx = {}, ERR = 1, WARN = 2, NOTICE = 3, INFO = 4, var = {}, -- luacheck: ignore 111
    log = function(...) if os.getenv("SPEC_DEBUG") then print(...) end end,
    encode_base64 = function(s) return s end }

-- Scripted database: every statement is recorded; `answer(sql, args)` decides the rows.
local log, answer = {}, function() return {} end
local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
local function stmt(sql) return (sql:gsub("%s+", " "):gsub("^ ", "")) end
package.loaded["lapis.db"] = {
    NULL = NULL,
    raw = function(s) return s end,
    escape_literal = function(s) return "'" .. tostring(s) .. "'" end,
    query = function(sql, ...)
        log[#log + 1] = { sql = stmt(sql), args = { ... } }
        return answer(stmt(sql), { ... }) or {}
    end,
    select = function(sql, ...)
        log[#log + 1] = { sql = "SELECT " .. stmt(sql), args = { ... } }
        return answer("SELECT " .. stmt(sql), { ... }) or {}
    end,
    update = function(tbl, fields, where)
        log[#log + 1] = { sql = "UPDATE " .. tbl, fields = fields, where = where }
        return answer("UPDATE " .. tbl, fields) or {}
    end,
    insert = function(tbl, fields)
        log[#log + 1] = { sql = "INSERT " .. tbl, fields = fields }
        return answer("INSERT " .. tbl, fields) or { { id = 99 } }
    end,
}
local function reset(fn) log, answer, ngx.ctx = {}, fn or function() return {} end, {} end
local function find(pattern)
    for i, q in ipairs(log) do if q.sql:find(pattern, 1, true) then return q, i end end
end
local function index_of(pattern) local _, i = find(pattern) return i end

package.loaded["helper.global"] = { generateUUID = function() return "uuid-x" end, getCurrentTimestamp = function() return "now" end }

local U = require("lib.shop-util")

-- ---------------------------------------------------------------------------------------------------
print("after-commit work")
-- ---------------------------------------------------------------------------------------------------
reset()
local ran = {}
U.tx(function()
    U.afterCommit(function() ran[#ran + 1] = "alert"; package.loaded["lapis.db"].query("SELECT after") end)
    package.loaded["lapis.db"].query("UPDATE shop_orders SET status = 'paid'")
    return true
end)
check("runs after COMMIT, not inside the transaction", ran[1] == "alert" and index_of("COMMIT") < index_of("SELECT after"))

reset()
ran = {}
U.tx(function()
    U.afterCommit(function() ran[#ran + 1] = "alert" end)
    return nil, { status = 409 }
end)
check("dropped when the transaction rolls back", #ran == 0 and find("ROLLBACK") ~= nil)

reset()
ran = {}
pcall(U.tx, function()
    U.afterCommit(function() ran[#ran + 1] = "alert" end)
    error("boom")
end)
check("dropped when the transaction raises", #ran == 0)

reset()
ran = {}
U.tx(function()
    U.tx(function() U.afterCommit(function() ran[#ran + 1] = "inner" end) return true end)
    check("a nested tx keeps the work for the outer COMMIT", #ran == 0)
    return true
end)
check("...which runs it", ran[1] == "inner")

reset()
ran = {}
U.tx(function()
    U.afterCommit(function() error("smtp down") end)
    U.afterCommit(function() ran[#ran + 1] = "second" end)
    return true
end)
check("a failing piece of work doesn't stop the next (or the caller)", ran[1] == "second")
U.afterCommit(function() ran[#ran + 1] = "now" end)
check("outside a transaction it runs straight away", ran[2] == "now")

print("dates and truncation")
check("real date", U.date("2026-02-28") == "2026-02-28")
check("leap day", U.date("2028-02-29") == "2028-02-29" and U.date("2026-02-29") == nil)
check("2026-02-30 is not a date", U.date("2026-02-30") == nil)
check("31 April is not a date", U.date("2026-04-31") == nil and U.date("2026-12-31") == "2026-12-31")
check("time part dropped", U.date("2026-11-30T10:00:00Z") == "2026-11-30")
check("rubbish", U.date("30/11/2026") == nil and U.date(20261130) == nil and U.date("2026-13-01") == nil)
check("cut: short text unchanged", U.cut("abc", 5) == "abc")
check("cut: never inside a character", U.cut("aé", 2) == "a" and U.cut("a€b", 3) == "a" and U.cut("a€b", 4) == "a€")

-- ---------------------------------------------------------------------------------------------------
print("mark paid and paid twice")
-- ---------------------------------------------------------------------------------------------------
local stock, credits, expired, alerts = {}, {}, {}, {}
package.loaded["lib.shop-pricing"] = { unpriced_lines = function() return {} end }
package.loaded["queries.ShopCatalogQueries"] = {}
package.loaded["queries.ShopCartQueries"] = { markConverted = function() end }
package.loaded["queries.ShopQuoteQueries"] = {}
package.loaded["queries.PaymentMethodQueries"] = { forDocuments = function() return {} end }
package.loaded["queries.ShopStockQueries"] = {
    commit = function(_, id) stock[#stock + 1] = "commit " .. id end,
    release = function(id) stock[#stock + 1] = "release " .. id end,
}
package.loaded["queries.ShopMembershipQueries"] = {
    useCredits = function() end, maybeIssueRefundCredit = function() end,
    releaseCredits = function(id) credits[#credits + 1] = id end,
}
package.loaded["lib.payment-provider"] = { get_stripe = function()
    return { _request = function(_, method, path) expired[#expired + 1] = method .. " " .. path return {} end }
end }
package.loaded["queries.CrmLeadNotificationQueries"] = { notify = function(_, _, opts) alerts[#alerts + 1] = opts end }
package.loaded["queries.ShopSettingsQueries"] = { orderAlertEmail = function() return nil end }
local Orders = require("queries.ShopOrderQueries")
Orders.applyQuoteFields = function() end
Orders.adminGet = function() return { ok = true } end

local ORDER = { id = 7, uuid = "o-7", namespace_id = 3, order_number = "WS-7", status = "pending_payment",
    payment_method = "bank_transfer", total_minor = 12000, quote_id = 5, customer = "{}", lines = "[]", cart_id = 1 }
local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function shop_db(o, other_paid, stale)
    return function(sql)
        if sql:find("FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE", 1, true) then return { o } end
        if sql:find("SELECT order_number FROM shop_orders WHERE quote_id", 1, true) then
            return other_paid and { { order_number = "WS-6" } } or {}
        end
        if sql:find("SELECT id, stripe_session_id, payment_method FROM shop_orders", 1, true) then return stale or {} end
        if sql:find("FROM shop_orders o WHERE o.id = ?", 1, true) then return { o } end
        if sql:find("FROM namespaces WHERE id", 1, true) then return { { id = 3, name = "Acme Ltd" } } end
    end
end

for _, case in ipairs({
    { "2026-02-30", { paid_at = "2026-02-30" }, "VALIDATION_ERROR" },
    { "an amount above 2^31", { amount_minor = 2 ^ 31 }, "VALIDATION_ERROR" },
    { "a negative amount", { amount_minor = -1 }, "VALIDATION_ERROR" },
    { "less than the total (no part-paid orders)", { amount_minor = 11999 }, "PART_PAYMENT" },
}) do
    reset(shop_db(copy(ORDER)))
    local res, err = Orders.markPaid(3, "o-7", case[2], "sam@acme.co.uk")
    check("mark paid: " .. case[1] .. " → 400", res == nil and err and err.status == 400 and err.code == case[3],
        err and err.code)
    check("mark paid: " .. case[1] .. " → nothing marked paid", find("SET status = 'paid'") == nil)
end

reset(shop_db(copy(ORDER), false, { { id = 8, stripe_session_id = "cs_open", payment_method = "card" } }))
stock, credits, expired = {}, {}, {}
local res = Orders.markPaid(3, "o-7", { amount_minor = 12000, paid_at = "2026-11-14" }, "sam@acme.co.uk")
check("mark paid: the full amount marks it paid", res and res.ok and find("SET status = 'paid'") ~= nil)
local cancel = find("SET status = 'cancelled'")
check("mark paid: the open card order for the same authorisation is cancelled, stock and credit back",
    cancel and cancel.args[2] == 8 and cancel.args[1]:find("WS-7 for the same Order Authorisation was paid instead", 1, true)
    and table.concat(stock, ","):find("release 8", 1, true) and credits[1] == 8, table.concat(stock, ","))
check("mark paid: its Stripe checkout is closed, after COMMIT", expired[1] == "POST /checkout/sessions/cs_open/expire"
    and index_of("COMMIT") ~= nil)

-- the card payment arrives anyway (webhook): order 6 was already paid
local card = copy(ORDER)
card.id, card.order_number, card.payment_method, card.status = 8, "WS-8", "card", "cancelled"
reset(shop_db(card, true))
stock, credits, alerts = {}, {}, {}
local applied
U.tx(function() applied = Orders.applyPaid(card, { id = "cs_open", payment_intent = "pi_123" }) return true end)
local flagged = find("SET status = 'cancelled'")
check("paid twice: not applied (no second fulfilment, quote untouched)", applied == false
    and find("SET status = 'paid'") == nil and find("UPDATE shop_quotes") == nil)
check("paid twice: kept cancelled with the payment id and a refund note", flagged and flagged.args[1] == "pi_123"
    and flagged.args[2]:find("PAID TWICE: WS-6", 1, true) and flagged.args[2]:find("pi_123", 1, true), flagged and flagged.args[2])
check("paid twice: stock and credit released", stock[1] == "release 8" and credits[1] == 8)
check("paid twice: staff told after COMMIT", #alerts == 1 and alerts[1].staff.subject:find("Refund needed", 1, true) ~= nil,
    alerts[1] and alerts[1].staff.subject)

-- a normal card payment: the staff alert runs after COMMIT, never inside the payment's transaction
local fresh = copy(ORDER)
fresh.payment_method = "card"
reset(shop_db(fresh, false))
alerts = {}
U.tx(function() applied = Orders.applyPaid(fresh, { payment_intent = "pi_9" }) return true end)
check("paid: applied", applied == true and find("SET status = 'paid'") ~= nil)
-- (#alerts was 0 before: with no customer PO number the notes table had a nil in the middle and table.concat threw)
check("paid: the alert is built without a PO number, and reads its settings only after COMMIT", #alerts == 1
    and index_of("COMMIT") < index_of("FROM namespaces WHERE id"))

-- ---------------------------------------------------------------------------------------------------
print("Leads → Notifications without CRM")
-- ---------------------------------------------------------------------------------------------------
package.loaded["queries.CrmLeadNotificationQueries"] = nil
local Notif = require("queries.CrmLeadNotificationQueries")
reset(function(sql)
    if sql:find("to_regclass", 1, true) then return { { ok = false } } end
    if sql:find("crm_lead_notification_settings WHERE", 1, true) then error("relation does not exist") end
end)
local eff = Notif.getEffective(3)
check("no CRM table: defaults, the table is never queried", eff.notify_admin == true
    and find("crm_lead_notification_settings WHERE") == nil)

-- ---------------------------------------------------------------------------------------------------
print("email headers")
-- ---------------------------------------------------------------------------------------------------
local sent
package.loaded["resty.mail"] = { new = function() return { send = function(_, o) sent = o return true end } end }
local Mail = require("helper.mail")
local ok = Mail.send({
    to = { "Ann\r\nBcc: spy@evil.co.uk <ann@acme.co.uk>" }, sync = true, html = "<p>Hi</p>",
    subject = "New order paid: WS-7 (Ann\r\nBcc: spy@evil.co.uk\r\n\r\nfake body)",
    reply_to = "ann@acme.co.uk\nReply-To: x@evil.co.uk",
    smtp = { host = "smtp.acme.co.uk", port = 587, from_email = "shop@acme.co.uk", from_name = "Acme\r\nX-Evil: 1" },
})
local headers = sent and table.concat({ sent.subject, sent.from, sent.reply_to, table.concat(sent.to, ",") }, "|") or ""
check("sent", ok and sent ~= nil)
check("no CR/LF in subject, from, reply-to or to", headers ~= "" and not headers:find("[\r\n]"), headers)
check("the text is kept on one line", sent and sent.subject == "New order paid: WS-7 (Ann Bcc: spy@evil.co.uk fake body)",
    sent and sent.subject)

-- ---------------------------------------------------------------------------------------------------
print("bank details: audit + owner email")
-- ---------------------------------------------------------------------------------------------------
local audits, mails = {}, {}
package.loaded["queries.NamespaceAuditLogQueries"] = { log = function(d) audits[#audits + 1] = d end }
package.loaded["helper.mail"] = { isConfigured = function() return true end,
    send = function(m) mails[#mails + 1] = m return true end }
package.loaded["queries.PaymentMethodQueries"] = nil
local PMQ = require("queries.PaymentMethodQueries")
local OLD = { id = 4, uuid = "pm-1", kind = "bank_transfer", label = "Main account", account_name = "Acme Ltd",
    sort_code = "12-34-56", account_number = "12345678", currency = "GBP", is_default = true, show_on_documents = true,
    is_active = true, sort_order = 0 }
local saved = copy(OLD)
ngx.ctx = { user = { uuid = "u-1" } }
reset(function(sql)
    if sql:find("AND uuid = ?", 1, true) and sql:find("namespace_payment_methods", 1, true) then return { OLD } end
    if sql:find("namespace_payment_methods WHERE id = ?", 1, true) then return { saved } end
    if sql:find("FROM users WHERE uuid", 1, true) then return { { id = 11, email = "sam@acme.co.uk" } } end
    if sql:find("SELECT name FROM namespaces", 1, true) then return { { name = "Acme Ltd" } } end
    if sql:find("SELECT DISTINCT u.email", 1, true) then return { { email = "owner@acme.co.uk" } } end
end)
ngx.ctx.user = { uuid = "u-1" }
saved.account_number = "87654321"
local row, perr = PMQ.update(3, "pm-1", { account_number = "87654321" })
check("update saved", row and row.account_number == "87654321", perr)
local a = audits[1]
check("audit: who, what, before and after (only what changed)", a and a.action == "payment_method.updated"
    and a.user_id == 11 and a.entity_id == "pm-1" and a.old_values.account_number == "12345678"
    and a.new_values.account_number == "87654321" and a.old_values.sort_code == nil)
local m = mails[1]
check("owners emailed", m and m.to[1] == "owner@acme.co.uk" and m.subject == "Bank details changed in Acme Ltd", m and m.subject)
check("email: old and new shown by their last digits only", m and m.data.details:find("••••5678 → ••••4321", 1, true)
    and not m.data.details:find("87654321", 1, true) and not m.data.details:find("12345678", 1, true), m and m.data.details)
check("email: says who did it", m and m.data.message:find("sam@acme.co.uk", 1, true) ~= nil)

audits, mails = {}, {}
saved.account_number = "12345678"
local same = PMQ.update(3, "pm-1", { account_number = "12345678" })
check("no change: nothing audited or emailed", same ~= nil and #audits == 0 and #mails == 0, #audits)

audits, mails = {}, {}
reset(function(sql)
    if sql:find("AND uuid = ?", 1, true) and sql:find("namespace_payment_methods", 1, true) then return { OLD } end
    if sql:find("FROM invoices", 1, true) then return {} end
    if sql:find("FROM users WHERE uuid", 1, true) then return { { id = 11, email = "sam@acme.co.uk" } } end
    if sql:find("SELECT DISTINCT u.email", 1, true) then return { { email = "owner@acme.co.uk" } } end
end)
ngx.ctx.user = { uuid = "u-1" }
PMQ.remove(3, "pm-1")
check("delete: audited and emailed", audits[1] and audits[1].action == "payment_method.deleted" and #mails == 1
    and mails[1].subject:find("deleted", 1, true) ~= nil)

-- ---------------------------------------------------------------------------------------------------
print("admin routes")
-- ---------------------------------------------------------------------------------------------------
local fh = io.open("lapis/routes/shop-admin.lua") or io.open("routes/shop-admin.lua")
local src = fh:read("*a")
fh:close()
check("no handler turns bad JSON into an empty body (bad JSON on mark-paid used to mark it paid in full)",
    not src:find("body_or_400() or {}", 1, true) and not src:find("read_json() or {}", 1, true))
check("mark paid needs shop.manage", src:find('"/orders/:uuid/mark-paid", guard("manage"', 1, true) ~= nil)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
