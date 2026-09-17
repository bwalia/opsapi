--[[
    Spec for the Simpro-aligned CRM pieces that must not quietly go wrong.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/simpro-reports_spec.lua

    Covers:
      1. the UK F-Gas leak-check interval derived from tCO2e (including the
         hermetically sealed exemption) and the GWP lookup that feeds it;
      2. the report CSV writer: quoting, numeric columns left bare, booleans,
         and the spreadsheet formula-injection guard on free text;
      3. the report catalogue: every report DBS publish from Simpro is present,
         each key dispatches, and an unknown key is refused.

    Database-backed behaviour (the report SQL, survey recording, the sync) is
    exercised end to end by wslcrm-app/scripts/seed-dbs-portfolio.py.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

-- The query modules require lapis.db and cjson at load time. None of the code
-- under test touches the database, so stand-ins are enough.
package.loaded["lapis.db"] = setmetatable({ NULL = {}, raw = function(s) return s end }, {
    __index = function() return function() error("database not available in this spec") end end,
})
package.loaded["cjson"] = package.loaded["cjson"] or {
    encode = function() return "{}" end,
    decode = function() return {} end,
    null = {},
    empty_array = {},
}
package.loaded["helper.global"] = package.loaded["helper.global"] or { generateUUID = function() return "uuid" end }

local failures = 0

local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- ---------------------------------------------------------------------------
print("F-Gas leak-check intervals")
local Assets = require("queries.FieldServiceAssetQueries")

check("R410A GWP is 2088", Assets.gwp_for("R410A") == 2088)
check("GWP lookup ignores case and spaces", Assets.gwp_for(" r32 ") == 675)
check("unknown refrigerant has no GWP", Assets.gwp_for("R999") == nil)

local lcm = Assets.leak_check_months
check("under 5 tCO2e: no statutory check", lcm(4.99, false) == nil)
check("5 tCO2e: every 12 months", lcm(5, false) == 12)
check("49.9 tCO2e: every 12 months", lcm(49.9, false) == 12)
check("50 tCO2e: every 6 months", lcm(50, false) == 6)
check("500 tCO2e: every 3 months", lcm(500, false) == 3)
check("hermetically sealed below 10 tCO2e: exempt", lcm(9.9, true) == nil)
check("hermetically sealed at 10 tCO2e: every 12 months", lcm(10, true) == 12)
check("zero or missing charge: no check", lcm(0, false) == nil and lcm(nil, false) == nil)

-- A 14.2 kg R410A VRV (NBS-VRV-02 in the DBS demo) is 29.6 tCO2e -> annual.
local co2e = 14.2 * Assets.gwp_for("R410A") / 1000
check("14.2 kg R410A is annual", lcm(co2e, false) == 12, co2e)

-- ---------------------------------------------------------------------------
print("Report CSV")
local Csv = require("helper.report-csv")

check("plain text passes through", Csv.cell("Harling House", "text") == "Harling House")
check("comma is quoted", Csv.cell("Aldgate, London", "text") == '"Aldgate, London"')
check("quotes are doubled", Csv.cell('The "Olive" Tree', "text") == '"The ""Olive"" Tree"')
check("newline is quoted", Csv.cell("line1\nline2", "text") == '"line1\nline2"')
check("nil is empty", Csv.cell(nil, "text") == "")
check("booleans read Yes/No", Csv.cell(true, "text") == "Yes" and Csv.cell(false, "text") == "No")
check("numeric column left bare", Csv.cell(133.63, "number") == "133.63")
check("negative money left bare", Csv.cell(-166804, "money") == "-166804")
check("formula in free text is neutralised", Csv.cell("=HYPERLINK(\"x\")", "text"):sub(1, 3) == "\"'=")
check("leading + in text is neutralised", Csv.cell("+44 20 7946 0321", "text") == "'+44 20 7946 0321")

local rendered = Csv.render({
    columns = { { key = "tag", label = "Asset" }, { key = "kg", label = "Charge kg", type = "number" } },
    rows = { { tag = "SKY-BLR-01" }, { tag = "NBS-VRV-02", kg = 14.2 } },
})
check("render: header, rows, CRLF, trailing newline",
    rendered == "Asset,Charge kg\r\nSKY-BLR-01,\r\nNBS-VRV-02,14.2\r\n", rendered)

-- ---------------------------------------------------------------------------
print("Report catalogue")
local Reports = require("queries.SimproReportQueries")

local expected = {
    "asset_failure_history", "asset_history", "ppm_forecast", "routine_maintenance",
    "fgas_register", "employee_licences", "engineer_locations", "labour_forecast",
    "response_times", "admin_efficiency", "powerbi_extract",
}
local listed = {}
for _, r in ipairs(Reports.list()) do listed[r.key] = r end
for _, key in ipairs(expected) do
    check("catalogue has " .. key, listed[key] ~= nil and type(listed[key].filters) == "table")
end
check("catalogue has exactly the published pack", #Reports.list() == #expected, #Reports.list())

local ok, err = Reports.run(1, "no_such_report", {})
check("unknown report is refused without touching the database",
    ok == nil and tostring(err):match("^Unknown report") ~= nil, err)

local _, asset_err = Reports.run(1, "asset_history", {})
check("asset history requires an asset", tostring(asset_err):match("asset_uuid is required") ~= nil, asset_err)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
