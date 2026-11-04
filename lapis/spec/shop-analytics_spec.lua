--[[
    Spec: Shop Analytics (lib/shop-analytics.lua + queries/ShopAnalyticsQueries.lua)

    Standalone — no busted/luarocks. Run from the repo root:
        luajit lapis/spec/shop-analytics_spec.lua

    Covers:
      1. UK date windows: parsing, leap years, inclusive day counts, the
         previous period, the "to is never in the future" clamp, limits.
      2. Rate maths that must never show a misleading 0% or divide by zero.
      3. The transcript rules: what counts as an AI reply, tool parsing,
         and the agreed "completed chat" definition.
      4. Every query is tenant-scoped and passes exactly as many parameters
         as it has placeholders (a stub database records each call).

    The SQL itself runs against real Postgres in lapis/spec/shop-analytics-e2e/run.sh.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local calls = {}
local function fake_rows(sql)
    if sql:find("information_schema.columns") then
        return { { column_name = "refunded_minor" }, { column_name = "member_discount_minor" } }
    end
    if sql:find("to_regclass") then return { { memberships = true } } end
    if sql:find("AS today") then return { { today = "2026-11-04" } } end
    return { {} }
end
package.loaded["lapis.db"] = {
    NULL = {},
    query = function(sql, ...)
        calls[#calls + 1] = { sql = sql, args = { n = select("#", ...), ... } }
        return fake_rows(sql)
    end,
}

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local A = require("lib.shop-analytics")

-- ---------------------------------------------------------------------------
print("Dates")
check("parses a real date", select(3, A.parse_date("2026-11-04")) == 4)
check("rejects 30 February", A.parse_date("2026-02-30") == nil)
check("29 Feb only in leap years", A.parse_date("2028-02-29") ~= nil and A.parse_date("2026-02-29") == nil)
check("2000 is a leap year, 1900 is not", A.parse_date("2000-02-29") ~= nil and A.parse_date("1900-02-29") == nil)
check("rejects junk and SQL", A.parse_date("2026-1-4") == nil and A.parse_date("2026-11-04'; drop") == nil
    and A.parse_date(nil) == nil and A.parse_date(20261104) == nil)
check("add_days crosses month and year", A.add_days("2026-12-31", 1) == "2027-01-01"
    and A.add_days("2026-03-01", -1) == "2026-02-28" and A.add_days("2028-03-01", -1) == "2028-02-29")
check("add_days across the October clock change", A.add_days("2026-10-24", 2) == "2026-10-26")
check("inclusive day count", A.days_inclusive("2026-10-01", "2026-10-31") == 31
    and A.days_inclusive("2026-11-04", "2026-11-04") == 1)
check("day numbers are epoch days", A.day_number("1970-01-01") == 0 and A.day_number("2026-11-04") == 20761)

print("Windows")
local w = A.window({}, "2026-11-04")
check("default is the last 30 days including today", w.from == "2026-10-06" and w.to == "2026-11-04" and w.days == 30)
check("to_exclusive is the next day", w.to_exclusive == "2026-11-05")
check("previous period is the 30 days before", w.previous.from == "2026-09-06" and w.previous.to == "2026-10-05"
    and w.previous.to_exclusive == "2026-10-06")
check("default bucket is daily", w.bucket == "day" and w.includes_today == true)
check("timezone is Europe/London", w.timezone == "Europe/London")

w = A.window({ from = "2026-10-01", to = "2026-10-31" }, "2026-11-04")
check("explicit range", w.days == 31 and w.previous.from == "2026-08-31" and w.previous.to == "2026-09-30")
check("a past range does not include today", w.includes_today == false)
w = A.window({ days = "7" }, "2026-11-04")
check("days=7", w.from == "2026-10-29" and w.to == "2026-11-04")
w = A.window({ from = "2026-11-01", to = "2027-01-01" }, "2026-11-04")
check("to in the future is clamped to today", w.to == "2026-11-04" and w.days == 4)
check("quarter is daily, year is weekly, longer is monthly",
    A.window({ days = "92" }, "2026-11-04").bucket == "day"
    and A.window({ days = "93" }, "2026-11-04").bucket == "week"
    and A.window({ days = "366" }, "2026-11-04").bucket == "week"
    and A.window({ days = "400" }, "2026-11-04").bucket == "month")
check("bucket can be chosen", A.window({ days = "30", bucket = "week" }, "2026-11-04").bucket == "week")
check("an unknown bucket falls back", A.window({ days = "30", bucket = "hour; drop" }, "2026-11-04").bucket == "day")
check("days is capped at the maximum", A.window({ days = "99999" }, "2026-11-04").days == A.MAX_DAYS)
check("days=0 or junk uses the default", A.window({ days = "0" }, "2026-11-04").days == 30
    and A.window({ days = "abc" }, "2026-11-04").days == 30)
local bad, err = A.window({ from = "2026-11-04", to = "2026-11-01" }, "2026-11-04")
check("from after to is refused", bad == nil and err:find("on or before"))
bad, err = A.window({ from = "2020-01-01", to = "2026-11-04" }, "2026-11-04")
check("more than two years is refused", bad == nil and err:find("at most"))
bad = A.window({ from = "yesterday" }, "2026-11-04")
check("a bad from is refused", bad == nil)
check("empty strings mean 'not given'", A.window({ from = "", to = "" }, "2026-11-04").days == 30)

print("Rates")
check("ratio rounds to 4 dp", A.ratio(1, 3) == 0.3333 and A.ratio(2, 3) == 0.6667)
check("ratio of nothing is nil, not 0", A.ratio(0, 0) == nil and A.ratio(5, nil) == nil)
check("ratio handles bigint strings", A.ratio("50", "200") == 0.25)
check("change up and down", A.change(150, 100) == 0.5 and A.change(50, 100) == -0.5)
check("change from zero is nil", A.change(10, 0) == nil)
check("average in whole pence, half up", A.average_minor(1001, 2) == 501 and A.average_minor(1000, 3) == 333)
check("average of no orders is nil", A.average_minor(0, 0) == nil)
check("sql_list quotes plain words", A.sql_list({ "paid", "shipped" }) == "('paid','shipped')")
check("sql_list refuses anything else", not pcall(A.sql_list, { "paid'); drop" }))

print("Chat transcripts")
check("plain reply counts", A.is_ai_reply("The RTX PRO 6000 has 96 GB."))
check("'(no reply)' does not", not A.is_ai_reply("(no reply)"))
check("'(no reply)' with tools does not", not A.is_ai_reply("(no reply)\n\n[tools: search_catalog]"))
check("only a tools suffix does not", not A.is_ai_reply("\n\n[tools: add_to_cart]"))
check("reply with tools counts", A.is_ai_reply("Added it.\n\n[tools: add_to_cart, view_cart]"))
check("blank does not", not A.is_ai_reply("   ") and not A.is_ai_reply(nil))
local t = A.tools_from_content("Done.\n\n[tools: search_catalog, add_to_cart]")
check("tools parsed from the suffix", #t == 2 and t[1] == "search_catalog" and t[2] == "add_to_cart")
check("no suffix, no tools", #A.tools_from_content("Hello [tools: not at the end] there") == 0)
check("completed needs an AI reply", not A.chat_completed({ ai_replied = false, quote = true }))
check("completed needs an outcome", not A.chat_completed({ ai_replied = true }))
check("reply + contact saved", A.chat_completed({ ai_replied = true, contact_saved = true }))
check("reply + quote / cart / order", A.chat_completed({ ai_replied = true, quote = true })
    and A.chat_completed({ ai_replied = true, added_to_cart = true })
    and A.chat_completed({ ai_replied = true, order = true }))

-- ---------------------------------------------------------------------------
print("Queries (stub database)")
local Q = require("queries.ShopAnalyticsQueries")

local function placeholders(sql)
    local count = 0
    -- Only bare ? are lapis placeholders; this SQL uses no ?| / ?& operators.
    for _ in sql:gmatch("%?") do count = count + 1 end
    return count
end

calls = {}
local report = Q.report(42, { from = "2026-10-01", to = "2026-10-31" })
check("report builds", type(report) == "table" and report.window.days == 31)
check("previous period included by default", report.previous ~= nil and report.changes ~= nil)
check("visitor tracking is reported as off", report.visitor_tracking.enabled == false
    and report.visitor_tracking.status == "awaiting_privacy_signoff")
check("basket adds flagged incomplete for a past window", report.basket_adds_complete == false)

local data_calls, mismatched, unscoped = 0, {}, {}
for _, c in ipairs(calls) do
    local sql = c.sql
    local is_meta = sql:find("information_schema") or sql:find("to_regclass") or sql:find("AS today")
    if placeholders(sql) ~= c.args.n then
        mismatched[#mismatched + 1] = ("%d placeholders, %d args: %s"):format(placeholders(sql), c.args.n,
            (sql:gsub("%s+", " ")):sub(1, 90))
    end
    if not is_meta then
        data_calls = data_calls + 1
        local scoped = sql:find("namespace_id = %?") ~= nil
        local has_ns = false
        for i = 1, c.args.n do if c.args[i] == 42 then has_ns = true end end
        if not (scoped and has_ns) then unscoped[#unscoped + 1] = (sql:gsub("%s+", " ")):sub(1, 90) end
    end
end
check("every query has as many parameters as placeholders", #mismatched == 0, mismatched[1])
check("every data query is scoped to the namespace", #unscoped == 0, unscoped[1])
check("current and previous period both queried", data_calls >= 2 * 6 + 5, data_calls)

calls = {}
Q.report(42, { days = "7", compare = "false" })
local saw_previous = false
for _, c in ipairs(calls) do
    for i = 1, c.args.n do if c.args[i] == "2026-10-22" then saw_previous = true end end
end
check("compare=false skips the previous period", not saw_previous)

local r, e = Q.report(42, { from = "2026-12-01", to = "2026-11-01" })
check("bad window is an error, not a query", r == nil and type(e) == "string")

local csv, status = Q.export(42, "products", { days = "30" })
check("products export envelope", csv and csv.key == "shop-products-2026-10-06-to-2026-11-04" and #csv.columns == 6)
local _, st404 = Q.export(42, "customers", {})
check("unknown export is a 404", st404 == 404)
local _, st400 = Q.export(42, "daily", { from = "nope" })
check("bad window on export is a 400", st400 == 400)
check("export envelope status unused on success", status == nil)

print("Registration")
local function read(path)
    local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local app = read("lapis/app.lua")
check("route is loaded behind the shop feature", app:find('load_if%("shop", "routes.shop%-analytics"%)') ~= nil)
local migrations = read("lapis/migrations.lua")
for i, key in ipairs({ "zzs31_shop_analytics_indexes", "zzs32_shop_analytics_module", "zzs33_shop_analytics_grants",
    "zzs34_shop_analytics_menu_item", "zzs35_shop_analytics_enable_menu" }) do
    check("migration " .. key, migrations:find("%['" .. key .. "'%] = conditional_array%(ProjectConfig.FEATURES.SHOP, "
        .. "shop_analytics_migrations, " .. i .. "%)") ~= nil)
end
check("module is in PROJECT_MODULES", read("lapis/helper/project-config.lua"):find('machine_name = "shop_analytics"') ~= nil)
check("menu item sits in Shop & Orders", read("lapis/queries/MenuQueries.lua"):find('shop_analytics = "commerce"') ~= nil)
local routes = read("lapis/routes/shop-analytics.lua")
check("routes require shop_analytics read", routes:find('local MODULE = "shop_analytics"') ~= nil
    and routes:find('requirePermission%(MODULE, "read"') ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
