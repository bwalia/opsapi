-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-delivery-change.lua (no nginx, no DB, no busted).

    Run from the repo root (as CI does) or from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/shop-delivery-change_spec.lua
]]

package.path = "./?.lua;./lapis/?.lua;" .. package.path

local R = require("lib.shop-delivery-change")

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

-- text ----------------------------------------------------------------------------------------
check("clean_line trims and collapses spaces", R.clean_line("  12   High  St ", 50) == "12 High St")
check("clean_line turns control characters into spaces", R.clean_line("a\0b\1c\27d\127e\nf", 50) == "a b c d e f",
    R.clean_line("a\0b\1c\27d\127e\nf", 50))
check("clean_line drops bidi overrides", R.clean_line("abc\226\128\174def\226\129\166", 50) == "abc def",
    R.clean_line("abc\226\128\174def\226\129\166", 50))
check("clean_line drops C1 controls", R.clean_line("a\194\133b", 50) == "a b")
check("clean_line drops invalid UTF-8 bytes", R.clean_line("caf\195\169 \255\254ok", 50) == "café ok",
    R.clean_line("caf\195\169 \255\254ok", 50))
check("clean_line caps by characters, not bytes", R.clean_line(string.rep("é", 10), 4) == "éééé")
check("clean_line: blank is nil", R.clean_line("   \n\t ", 50) == nil)
check("clean_line: non-strings are nil", R.clean_line({}, 50) == nil and R.clean_line(true, 50) == nil)
check("clean_note keeps line breaks, at most one blank line", R.clean_note("Hi\r\n\n\n\nLeave at  reception\0", 100)
    == "Hi\n\nLeave at reception", R.clean_note("Hi\r\n\n\n\nLeave at  reception\0", 100))
check("clean_note caps at the limit", #R.clean_note(string.rep("x", 1500)) == R.NOTE_MAX)

-- postcodes + country -----------------------------------------------------------------------------
local pcs = {
    ["sw1a1aa"] = "SW1A 1AA", ["M1 1AE"] = "M1 1AE", ["b33 8th"] = "B33 8TH", ["CR2 6XH"] = "CR2 6XH",
    ["DN55 1PT"] = "DN55 1PT", ["W1A 0AX"] = "W1A 0AX", ["ec1a 1bb"] = "EC1A 1BB", [" gir 0aa "] = "GIR 0AA",
}
for raw, want in pairs(pcs) do check("postcode " .. raw, R.normalise_postcode(raw) == want, R.normalise_postcode(raw)) end
for _, bad in ipairs({ "12345", "SW1A", "1AA SW1", "SW1A 1A", "QQ", "", "AAA1 1AA", "SW1A 1AAA" }) do
    check("postcode refused: '" .. bad .. "'", R.normalise_postcode(bad) == nil, R.normalise_postcode(bad))
end
check("country: blank means the UK", R.uk_country(nil) == "GB" and R.uk_country("") == "GB")
for _, c in ipairs({ "GB", "gb", "UK", "U.K.", "United Kingdom", "the United Kingdom", "England", "Scotland", "Wales",
                     "Northern Ireland", "Great Britain" }) do
    check("country is the UK: " .. c, R.uk_country(c) == "GB")
end
for _, c in ipairs({ "IE", "Ireland", "France", "BE", "Jersey" }) do check("country refused: " .. c, R.uk_country(c) == nil) end

-- address ---------------------------------------------------------------------------------------
local good = { name = " Sam Taylor ", company = "Acme Ltd", line1 = "1 High St", city = "London", postcode = "sw1a1aa",
               country = "United Kingdom", phone = "+44 (0)20 7946 0000", vat_number = "GB123", evil = "<script>" }
local a, aerr = R.clean_address(good)
check("address: cleaned", a and a.name == "Sam Taylor" and a.postcode == "SW1A 1AA" and a.country == "GB", aerr and aerr.message)
check("address: unknown keys dropped", a and a.evil == nil and a.vat_number == nil)
for _, k in ipairs({ "name", "line1", "city", "postcode" }) do
    local b = {}
    for kk, v in pairs(good) do b[kk] = v end
    b[k] = "  "
    local res, e = R.clean_address(b)
    check("address: " .. k .. " is required", res == nil and e and e.field == k, e and e.field)
end
local _, e1 = R.clean_address({ name = "A", line1 = "1", city = "Dublin", postcode = "D02 X285", country = "IE" })
check("address: a non-UK country is refused", e1 and (e1.field == "country" or e1.field == "postcode"), e1 and e1.field)
local _, e2 = R.clean_address({ name = "A", line1 = "1", city = "Paris", postcode = "SW1A 1AA", country = "France" })
check("address: France is refused even with a UK postcode", e2 and e2.field == "country")
local _, e3 = R.clean_address({ name = "A", line1 = "1", city = "X", postcode = "SW1A 1AA", phone = "call me" })
check("address: a bad phone is refused", e3 and e3.field == "phone")
local _, e4 = R.clean_address({ name = "A", line1 = "1", city = "X", postcode = "SW1A 1AA", phone = "12" })
check("address: a too-short phone is refused", e4 and e4.field == "phone")
local a5 = R.clean_address({ name = "A", line1 = "1", city = "X", postcode = "SW1A 1AA", phone = "" })
check("address: phone is optional", a5 and a5.phone == nil)
local long = R.clean_address({ name = string.rep("n", 500), line1 = "1", city = "X", postcode = "SW1A 1AA" })
check("address: long fields are capped", long and #long.name == 120)
check("address: not a table", select(2, R.clean_address("1 High St")).field == "address")

check("same_address ignores case and spacing", R.same_address({ line1 = "1 High St", city = "London", postcode = "SW1A 1AA" },
    { line1 = "1  high st", city = "LONDON", postcode = "sw1a1aa" }))
check("same_address sees a different line", not R.same_address({ line1 = "1 High St" }, { line1 = "2 High St" }))
check("same_address: nil is never the same", not R.same_address({ line1 = "x" }, nil))

-- dates -----------------------------------------------------------------------------------------
-- 2026-11-13 is a Friday, 2026-11-16 a Monday.
check("weekday: 1970-01-01 is a Thursday", R.weekday(0) == 4)
check("weekday: 2026-11-16 is a Monday", R.weekday(R.parse_date("2026-11-16")) == 1)
check("format_date round-trips", R.format_date(R.parse_date("2028-02-29")) == "2028-02-29")
check("parse_date refuses 31 Nov", R.parse_date("2026-11-31") == nil)
check("parse_date refuses 29 Feb in a common year", R.parse_date("2027-02-29") == nil)
check("parse_date refuses junk", R.parse_date("18/11/2026") == nil and R.parse_date(20261118) == nil)

local earliest, latest = R.date_range("2026-11-13")
check("date_range: Friday → Monday earliest", earliest == "2026-11-16", earliest)
check("date_range: latest is a weekday within 90 days", latest == "2027-02-11", latest)
local e2026, l2026 = R.date_range("2026-11-16")
check("date_range: Monday → Tuesday earliest", e2026 == "2026-11-17", e2026)
check("date_range: latest 90 days on (Sunday → Friday before)", l2026 == "2027-02-12", l2026)

check("check_date: next working day is fine", R.check_date("2026-11-16", "2026-11-13") == "2026-11-16")
check("check_date: today is refused", R.check_date("2026-11-13", "2026-11-13") == nil)
check("check_date: the weekend is refused", R.check_date("2026-11-14", "2026-11-12") == nil)
check("check_date: Saturday when today is Friday", select(2, R.check_date("2026-11-14", "2026-11-13")):find("weekday") ~= nil)
check("check_date: the past is refused", R.check_date("2026-11-02", "2026-11-13") == nil)
check("check_date: 90 days is fine", R.check_date("2027-02-11", "2026-11-13") == "2027-02-11")
check("check_date: 91 days is refused", R.check_date("2027-02-12", "2026-11-13") == nil)
check("date_label", R.date_label("2026-11-18") == "Wed 18 Nov 2026", R.date_label("2026-11-18"))
check("date_label: nothing", R.date_label(nil) == "not set")

-- the whole request ---------------------------------------------------------------------------------
local req, verr = R.validate({ address = good, date = "2026-11-17", window = "am", note = " Ring the bell\0 " }, "2026-11-13")
check("validate: good request", req and req.date == "2026-11-17" and req.window == "am" and req.note == "Ring the bell",
    verr and verr.message)
local r2 = R.validate({ address = good, date = "2026-11-17" }, "2026-11-13")
check("validate: a date without a window means any time", r2 and r2.window == "all_day")
local r3 = R.validate({ address = good }, "2026-11-13")
check("validate: address only", r3 and r3.date == nil and r3.window == nil)
local r4 = R.validate({ address = good, window = "pm" }, "2026-11-13")
check("validate: window only", r4 and r4.window == "pm" and r4.date == nil)
local _, v5 = R.validate({ address = good, window = "evening" }, "2026-11-13")
check("validate: unknown window refused", v5 and v5.field == "window")
local _, v6 = R.validate({ address = good, date = "2026-11-15" }, "2026-11-13")
check("validate: Sunday refused", v6 and v6.field == "date")
local _, v7 = R.validate({ date = "2026-11-17" }, "2026-11-13")
check("validate: address required", v7 and v7.field == "address")
local _, v8 = R.validate({ address = good, note = string.rep("x", 5000) }, "2026-11-13")
check("validate: a huge note is refused", v8 and v8.field == "note")
local r9 = R.validate({ address = good, note = string.rep("x", 1200) }, "2026-11-13")
check("validate: a long note is capped", r9 and #r9.note == R.NOTE_MAX)
local _, v10 = R.validate("nope", "2026-11-13")
check("validate: not an object", v10 and v10.field == "body")

local current = { address = { name = "Sam Taylor", company = "Acme Ltd", line1 = "1 High St", city = "London",
                              postcode = "SW1A 1AA" }, date = nil, window = nil }
check("changes_anything: same address, nothing else", not R.changes_anything(r3, current))
check("changes_anything: a new date", R.changes_anything(r2, current))
check("changes_anything: same date and window", not R.changes_anything({ address = r3.address, date = "2026-11-17",
    window = "all_day" }, { address = current.address, date = "2026-11-17", window = "all_day" }))

-- statuses ----------------------------------------------------------------------------------------------
for _, s in ipairs({ "pending_payment", "paid", "processing" }) do check("open: " .. s, R.order_open(s)) end
for _, s in ipairs({ "shipped", "delivered", "cancelled", "refunded", "payment_failed" }) do
    check("closed: " .. s, not R.order_open(s))
end
check("describe_address", R.describe_address(a) == "Sam Taylor, Acme Ltd, 1 High St, London, SW1A 1AA (tel +44 (0)20 7946 0000)",
    R.describe_address(a))

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
