--[[
    Spec: Global.pageParam / perPageParam (helper/global.lua) — every paged route clamps the
    client's page and page size through these, so "nan", "inf", "1e400", negatives and huge
    pages must never reach Postgres as a NaN, infinite or overflowing LIMIT/OFFSET (a 500).

    Run from the repo root (what CI does):
        luajit lapis/spec/pagination-params_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- global.lua's top-level requires; nothing paging needs.
package.loaded["bcrypt"] = {}
package.loaded["helper.uuid"] = {}
local Global = require("helper.global")
local page, per = Global.pageParam, Global.perPageParam

for _, v in ipairs({ "nan", "NaN", "inf", "-inf", "1e400", "-1e400", "abc", "", nil }) do
    check("page " .. tostring(v) .. " -> 1", page(v) == 1, page(v))
    check("perPage " .. tostring(v) .. " -> default", per(v, 20, 100) == 20, per(v, 20, 100))
end
check("page 0 -> 1", page("0") == 1)
check("page -5 -> 1", page("-5") == 1)
check("page 2.9 -> 2", page("2.9") == 2)
check("huge page is capped", page("1e300") == 1000000, page("1e300"))
check("perPage 0 -> 1", per("0", 20, 100) == 1)
check("perPage over max -> max", per("5000", 20, 100) == 100)
check("perPage 25 -> 25", per("25", 20, 100) == 25)
check("results are finite numbers", page("nan") == page("nan") and per("nan") == per("nan"))

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) failed."))
os.exit(failures == 0 and 0 or 1)
