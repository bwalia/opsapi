--[[
    Regression spec: the template cache is keyed by the whole template.

    Standalone — run from the repo root with:
        luajit lapis/spec/template-cache_spec.lua

    It used to key on length + the first and last 16 characters, so two
    templates sharing those (every "<!DOCTYPE html>…</html>" document of the
    same length, e.g. two workspaces' invoices) rendered each other's cached
    template: one tenant's branding in another tenant's document.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local R = require("lib.template-renderer")
local head, tail = "<!DOCTYPE html>\n<html><body>", "</body></html>\n<!-- end -->"
local a = head .. "<h1>Acme Ltd invoice {{ number }}</h1>" .. tail
local b = head .. "<h1>Zeta Co invoice {{ number }}!</h1>" .. tail
assert(#a == #b and a:sub(1, 16) == b:sub(1, 16) and a:sub(-16) == b:sub(-16) and a ~= b)

local ra = R.render(a, { number = 7 })
local rb = R.render(b, { number = 7 })
check("first template renders itself", ra:find("Acme Ltd invoice 7", 1, true) ~= nil, ra)
check("a same-length template with the same ends renders itself, not the cached one",
    rb:find("Zeta Co invoice 7!", 1, true) ~= nil and not rb:find("Acme", 1, true), rb)

print(failures == 0 and "\nall template cache checks passed" or ("\n" .. failures .. " check(s) FAILED"))
os.exit(failures == 0 and 0 or 1)
