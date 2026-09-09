--[[
    Shared merchant-cleaner fixture — must match Python clean_merchant_name.

    Run from repo root:
        luajit lapis/spec/merchant-cleaner_spec.lua

    Fixture (keep identical to diy-tax-return-uk
    backend/app/fixtures/merchant_cleaner_cases.json):
        lapis/spec/fixtures/merchant_cleaner_cases.json
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local MerchantCleaner = require("lib.merchant-cleaner")

local function unescape(s)
    return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

--- Minimal loader for [{"raw":"...","expected":"..."}, ...] (no nested objects).
local function load_cases(path)
    local f = assert(io.open(path, "r"), "missing fixture " .. path)
    local data = f:read("*a")
    f:close()
    local cases = {}
    for raw, expected in data:gmatch('"raw"%s*:%s*"(.-)"%s*,%s*"expected"%s*:%s*"(.-)"') do
        table.insert(cases, { raw = unescape(raw), expected = unescape(expected) })
    end
    -- Also match expected-before-raw order if ever rewritten
    if #cases == 0 then
        for expected, raw in data:gmatch('"expected"%s*:%s*"(.-)"%s*,%s*"raw"%s*:%s*"(.-)"') do
            table.insert(cases, { raw = unescape(raw), expected = unescape(expected) })
        end
    end
    return cases
end

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

print("merchant-cleaner")

local cases = load_cases("lapis/spec/fixtures/merchant_cleaner_cases.json")
check("loaded shared fixture cases", #cases >= 30, "got " .. tostring(#cases))

for i, c in ipairs(cases) do
    local got = MerchantCleaner.clean_merchant_name(c.raw)
    local label = string.format("#%d %s", i, c.raw:sub(1, 40))
    check(label, got == c.expected, "got " .. tostring(got) .. " want " .. tostring(c.expected))
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all ok")
