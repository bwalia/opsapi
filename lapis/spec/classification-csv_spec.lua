--[[
    Regression spec for lib/classification-csv.lua.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/classification-csv_spec.lua
    (plain `lua5.1` works too).

    Guards the multiple-return bug that made every AI-training CSV upload
    return SYSTEM_500: `normalizeHeader` returned gsub's (string, count) pair,
    so `table.insert(parts, normalizeHeader(h))` became the 3-arg
    `table.insert(list, pos, value)` overload and threw
    "bad argument #2 to 'insert' (number expected, got string)".
]]

-- The module pulls in cjson at load time; stub it so this runs anywhere.
package.preload["cjson"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end
package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local CSV = require("lib.classification-csv")

local failures = 0

local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

print("classification-csv")

-- The actual defect: one value out, not two.
check("normalizeHeader returns exactly one value",
    select("#", CSV.normalizeHeader("Date")) == 1,
    "got " .. select("#", CSV.normalizeHeader("Date")) .. " values")

check("normalizeHeader lowercases and trims",
    CSV.normalizeHeader("  Transaction Date  ") == "transaction date",
    CSV.normalizeHeader("  Transaction Date  "))

check("normalizeHeader tolerates nil",
    CSV.normalizeHeader(nil) == "")

-- fingerprint() is the crash site (line 63 in the INT traceback).
local fp_ok, fp = pcall(CSV.fingerprint, { " Date ", "Description", "Amount" })
check("fingerprint does not throw", fp_ok, fp)
check("fingerprint joins normalized headers", fp_ok and fp == "date|description|amount", fp)

-- guessMapping() carries the same call shape and would crash next.
local gm_ok, mapping, amount_mode = pcall(CSV.guessMapping, { "Date", "Description", "Amount", "Category" })
check("guessMapping does not throw", gm_ok, mapping)
check("guessMapping finds the date column", gm_ok and mapping and mapping.date == 1,
    gm_ok and mapping and mapping.date)
check("guessMapping picks an amount mode", gm_ok and amount_mode ~= nil, amount_mode)

-- Debit/credit layouts should select the two-column mode.
local _, dc_mapping, dc_mode = pcall(CSV.guessMapping, { "Date", "Narrative", "Money Out", "Money In", "Category" })
check("guessMapping detects debit/credit layout",
    dc_mode == "debit_credit" and dc_mapping and dc_mapping.debit and dc_mapping.credit,
    tostring(dc_mode))

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
