--[[
    Spec: the assistant's VAT tools (lib/agent/vat-tools.lua). The tools never file a
    return and never compute VAT themselves; this checks they register, explain boxes,
    and refuse politely without a VAT registration.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-tools_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

package.loaded["queries.VatQueries"] = { get_registration = function() return nil end }
local VatTools = require("lib.agent.vat-tools")
local reg = {}
VatTools.install(function(spec) reg[spec.name] = spec end)

check("five tools", reg.get_vat_status and reg.start_vat_coding and reg.get_vat_review_queue
    and reg.compute_vat_return and reg.explain_vat_box and true or false)
check("no filing tool", (function() for n in pairs(reg) do if n:find("submit") or n:find("file") then
    return false end end return true end)())
local r = reg.explain_vat_box.handler({}, { box = "5" })
check("explains Box 5", r.box == "box5" and r.explanation:find("difference") ~= nil)
check("bad box refused", reg.explain_vat_box.handler({}, { box = "box12" }) == nil)
local res, err = reg.get_vat_status.handler({ namespace_id = 1, user_id = 2 }, {})
check("no registration: a helpful message, not an error", res == nil and err:find("VAT page") ~= nil, err)
local _, err2 = reg.compute_vat_return.handler({ namespace_id = 1, user_id = 2 },
    { period_start = "2026-01-01", period_end = "2026-03-31" })
check("compute without registration refused the same way", err2 and err2:find("VAT number") ~= nil)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
