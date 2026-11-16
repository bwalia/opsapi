--[[
    Spec: fixes from the VAT review (one check per area). The database is a fake that
    records SQL and answers what each case needs.

      * a business's lines are its own: a workspace codes its accounting lines (money out
        stored negative there, VAT still positive), never the signed-in person's
      * capital goods: an adjustment can only point at this business's own item
      * a VAT number can't be squatted (no platform-wide "taken" check)
      * a VAT group member can leave
      * rounding: half pennies, and whole-pound boxes from float sums
      * real calendar dates only
      * CSV export can't carry spreadsheet formulas
      * HMRC sign-in keeps the scopes the person already has
      * RBAC modules vat / vat_agent are seeded; the business preset has no VAT

    Run: /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-review-gaps_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end

ngx = { null = {}, log = function() end, ERR = 3, WARN = 4, NOTICE = 6 } -- luacheck: ignore 111

-- Fake lapis.db: answer(sql, args) decides the rows; every call is recorded.
local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
local log, answer = {}, function() return {} end
local tables = { tax_transactions = true, tax_statements = true, accounting_bank_transactions = true,
    accounting_expenses = true }
local function lit(v) return type(v) == "number" and tostring(v) or ("'" .. tostring(v):gsub("'", "''") .. "'") end
package.loaded["lapis.db"] = {
    NULL = NULL,
    raw = function(s) return s end,
    escape_literal = lit,
    query = function(sql, ...)
        local args = { ... }
        log[#log + 1] = { op = "query", sql = sql, args = args }
        if sql:find("to_regclass", 1, true) then
            return { { ok = tables[tostring(args[1]):gsub("^public%.", "")] == true } }
        end
        return answer(sql, args) or {}
    end,
    update = function(tbl, fields, where, ...)
        log[#log + 1] = { op = "update", tbl = tbl, fields = fields, where = where, args = { ... } }
    end,
    insert = function(tbl, row)
        log[#log + 1] = { op = "insert", tbl = tbl, row = row }
        return { { uuid = "new" } }
    end,
}
local function last(op)
    for i = #log, 1, -1 do if log[i].op == op then return log[i] end end
end
local function any_sql(fragment)
    for _, l in ipairs(log) do if l.sql and l.sql:find(fragment, 1, true) then return l end end
end

local VAT = require("lib.vat")
local L = require("queries.VatReturnQueries")
local VatQueries = require("queries.VatQueries")

local person = { id = 1, namespace_id = 7, user_id = 42, vrn = "980780684", scheme = "standard" }
local workspace = { id = 2, namespace_id = 7, user_id = NULL, vrn = "980780684", scheme = "standard" }

print("== a business's lines are its own")
local from = L.lines_from(person)
check("a person's: their own bank lines, by the registration's user", from:find("FROM tax_transactions", 1, true)
    and from:find("t.user_id = 42", 1, true) and not from:find("accounting_", 1, true), from)
from = L.lines_from(workspace)
check("a workspace's: accounting bank lines + expenses, never tax_transactions",
    from:find("FROM accounting_bank_transactions", 1, true) and from:find("FROM accounting_expenses", 1, true)
    and not from:find("tax_transactions", 1, true))
check("amounts come back positive (money out is stored negative there)",
    select(2, from:gsub("abs%(t%.amount%)", "")) == 2)
check("expenses as the return reads them: approved, not paid through a bank line",
    from:find("bank_transaction_id IS NULL", 1, true) and from:find("'approved', 'posted'", 1, true))
tables.accounting_bank_transactions, tables.accounting_expenses = false, false
check("no accounting tables in this deployment: no lines, no SQL error", L.lines_from(workspace) == nil)
tables.accounting_bank_transactions, tables.accounting_expenses = true, true
check("tax years only filter a person's lines", #L.line_filters(workspace, { tax_year = "2025-26" }) == 0
    and #L.line_filters(person, { tax_year = "2025-26" }) == 1)

-- Coding a workspace's bank payment of £120 (stored -120).
log = {}
answer = function(sql)
    if sql:find("WHERE l.uuid = ?", 1, true) then
        return { { src = "accounting_bank_transactions", id = 5, amount = 120, transaction_type = "DEBIT" } }
    end
    return { { uuid = "b5" } }
end
local row = VatQueries.set_transaction_vat(workspace, "b5-uuid", { vat_code = "STD20" }, 99)
local up = last("update")
check("a workspace line is written to its accounting table", row and up and up.tbl == "accounting_bank_transactions"
    and up.where.id == 5)
check("net £100 and VAT £20, both positive", up and up.fields.net_amount == 100 and up.fields.vat_amount == 20,
    up and (tostring(up.fields.net_amount) .. "/" .. tostring(up.fields.vat_amount)))
check("only tax_transactions has is_vat_applicable", up and up.fields.is_vat_applicable == nil)
check("stamped with this registration", up and up.fields.vat_registration_id == 2 and up.fields.vat_decided_by == 99)
log = {}
answer = function() return {} end
check("a line that isn't this business's: 404", select(3, VatQueries.set_transaction_vat(workspace, "x",
    { vat_code = "STD20" }, 99)) == 404)

-- AI coding / status read the business's lines too (the accountant's own never leak in).
log = {}
answer = function(sql) if sql:find("COUNT(*)", 1, true) then return { { total = 3, uncoded = 1 } } end end
package.loaded["lib.agent.llm"] = {}
local Ai = require("queries.VatAiQueries")
local st = Ai.status(workspace, {})
check("status counts the workspace's lines", st.total == 3 and any_sql("FROM accounting_bank_transactions")
    and not any_sql("FROM tax_transactions"))
log = {}
Ai.decisions(person)
check("AI memory is this person's own lines", any_sql("t.user_id = 42") ~= nil)

print("== capital goods: only this business's item")
log = {}
answer = function() return {} end
local _, msg, status = L.create_adjustment(person, { period_start = "2026-01-01", period_end = "2026-03-31",
    type = "cgs", vat = 100, capital_item_id = 77 }, 1)
check("someone else's capital item id -> 404", status == 404 and msg:find("not found") ~= nil, msg)
local q = any_sql("FROM vat_capital_items WHERE id = ? AND registration_id = ?")
check("looked up by id AND registration", q and q.args[1] == 77 and q.args[2] == 1)
check("nothing written", last("insert") == nil)
local Schemes = require("queries.VatSchemeQueries")
log = {}
answer = function(sql) if sql:find("FROM vat_capital_items WHERE registration_id", 1, true) then
    return { { id = 3, kind = "building" } } end end
Schemes.list_items(person)
check("an item's adjustments are read by registration too",
    any_sql("capital_item_id = ? AND registration_id = ?") ~= nil)

print("== VAT numbers can't be squatted")
log = {}
answer = function() return {} end
VatQueries.save_registration(7, 42, { vrn = "980780684" }, 42)
check("no lookup of other businesses' VAT numbers", any_sql("WHERE vrn = ?") == nil and last("insert") ~= nil)

print("== a VAT group member can leave")
log = {}
answer = function() return { { id = 1 } } end
check("leaves its active membership", (Schemes.leave(7) or {}).status == "removed"
    and any_sql("member_namespace_id = ? AND status = 'active'").args[1] == 7)
answer = function() return {} end
check("not in a group: 404", select(3, Schemes.leave(7)) == 404)

print("== rounding")
check("1.005 -> 1.01 (half a penny rounds up)", VAT.round2(1.005) == 1.01, VAT.round2(1.005))
check("-1.005 -> -1.01", VAT.round2(-1.005) == -1.01)
check("2.675 -> 2.68", VAT.round2(2.675) == 2.68)
check("1.004 -> 1.00", VAT.round2(1.004) == 1)
check("tiny negative isn't -0", tostring(VAT.round2(-0.001)) == "0")
local Return = require("lib.vat-return")
local lines = {}
for i, n in ipairs({ 0.3, 0.6, 0.1 }) do -- 0.3 + 0.6 + 0.1 = 0.99999999999999989 in floats
    lines[#lines + 1] = { id = i, direction = "sale", vat_code = "ZERO", net = n, vat = 0 }
end
check("Box 6 from a float sum just under £1 is £1", Return.build(lines, { scheme = "standard" }).boxes.box6 == 1)

print("== real dates only")
check("2026-02-30 isn't a date", not VAT.valid_date("2026-02-30"))
check("2024-02-29 is (leap year)", VAT.valid_date("2024-02-29"))
check("2100-02-29 isn't (not a leap year)", not VAT.valid_date("2100-02-29"))
check("month 13 isn't", not VAT.valid_date("2026-13-01"))
check("a period with an impossible date -> refused", L.check_period("2026-01-01", "2026-02-30") == nil)
package.loaded["lib.error_catalog"], package.loaded["lib.error_locale"] = {}, {}
package.loaded["lib.error_occurrence"] = {}
package.loaded["helper.global"] = { generateUUID = function() return "u" end }
local ce = require("lib.errors").classify('q\nERROR: date/time field value out of range: "2026-02-30"')
check("anywhere else, a date Postgres rejects is the caller's 400, not a 500", ce and ce.status == 400)

print("== CSV export can't carry formulas")
local csv = require("lib.vat-management").export_csv({
    t1 = { date = "2026-01-02", description = "=HYPERLINK(\"http://x\")", amount = -12.5, transaction_type = "DEBIT" },
    t2 = { date = "2026-01-03", description = "@SUM(A1)", amount = 10 },
}, { box1 = { "t1", "t2" } }, {})
check("= and @ text is quoted", csv:find("'=HYPERLINK", 1, true) and csv:find("'@SUM", 1, true), csv)
check("negative numbers stay numbers", csv:find(",-12.5,", 1, true) ~= nil, csv)

print("== HMRC sign-in keeps the scopes the person has")
package.loaded["resty.http"] = {}
package.loaded["helper.global"] = { getEnvVar = function(k)
    return ({ HMRC_CLIENT_ID = "cid", HMRC_REDIRECT_URI = "https://x/cb", HMRC_ENVIRONMENT = "sandbox",
        JWT_SECRET_KEY = "s" })[k] end }
package.loaded["middleware.rate-limit"] = { wrap = function(_, fn) return fn end }
package.loaded["queries.HMRCTokenQueries"] = {}
ngx.encode_base64 = function(s) return (tostring(s):gsub("[^%w]", "")) end
ngx.hmac_sha1 = function() return "sig" end
ngx.time = function() return 0 end
ngx.escape_uri = function(s) return (tostring(s):gsub(" ", "%%20")) end
ngx.unescape_uri = function(s) return (tostring(s):gsub("%%20", " ")) end
ngx.req = { get_headers = function() return {} end }
local routes = {}
require("routes.tax-hmrc-auth")({ get = function(_, path, fn) routes[path] = fn end, delete = function() end })
local function scopes(purpose, stored)
    answer = function(sql) if sql:find("FROM hmrc_tokens", 1, true) then return { { scope = stored } } end end
    local res = routes["/auth/hmrc/initiate"]({ params = { purpose = purpose }, current_user = { uuid = "u1" } })
    local s = ngx.unescape_uri(res.json.auth_url:match("scope=([^&]+)"))
    local set = {}
    for w in s:gmatch("%S+") do set[w] = true end
    return set
end
local s = scopes("vat_agent", "read:self-assessment write:self-assessment")
check("agent connection keeps Income Tax scopes", s["write:self-assessment"] and s["write:sent-invitations"])
s = scopes(nil, "read:self-assessment write:self-assessment read:vat write:vat")
check("Income Tax reconnection keeps VAT scopes", s["write:vat"] and s["write:self-assessment"])
s = scopes("vat", ngx.null)
check("no connection yet: just the purpose's scopes", s["write:vat"] and not s["write:sent-invitations"])

print("== RBAC modules and presets")
local mig = read("lapis/migrations/vat-menu.lua")
check("modules vat and vat_agent are seeded and granted to owner/admin",
    mig:find('"vat_agent"', 1, true) and mig:find('{ "vat", "VAT"', 1, true)
    and mig:find("propagateToNamespaceAdmins", 1, true))
local key = read("lapis/migrations.lua"):match("%['(zz_vat_[%w_]*rbac[%w_]*)'%]")
check("its key runs after the VAT tables (keys run in string order)", key and key > "zz_vat_records_9", key)
local PC = require("helper.project-config")
local has_vat = false
for _, f in ipairs(PC.PROJECT_FEATURES.business) do if f == "vat" then has_vat = true end end
check("business preset has no VAT (it needs tax_copilot)", not has_vat)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
