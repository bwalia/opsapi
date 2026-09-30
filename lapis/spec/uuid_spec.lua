--[[
    Regression spec: UUIDs come from the OS CSPRNG (helper/uuid.lua).

    The bug this pins: ids were md5(math.random() .. os.time()) with an unseeded
    PRNG, so two processes produced the same ids.

    Standalone — run from the repo root with:
        luajit lapis/spec/uuid_spec.lua
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

local Uuid = require("helper.uuid")
local V4 = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local first = Uuid.generate()
check("RFC 4122 version 4, lower-case", first:match(V4) ~= nil and first == first:lower(), first)
check("returns exactly one value", select("#", Uuid.generate()) == 1)

local seen, dup = {}, nil
for _ = 1, 200000 do
    local u = Uuid.generate()
    if seen[u] then dup = u break end
    seen[u] = true
end
check("200,000 ids, no duplicate", dup == nil, dup)

-- The actual bug: a fresh process must not repeat another process's ids.
local function first_in_new_process()
    local p = io.popen([[luajit -e "package.path='lapis/?.lua;'..package.path print(require('helper.uuid').generate())"]])
    local out = p:read("*l")
    p:close()
    return out
end
local a, b = first_in_new_process(), first_in_new_process()
check("two fresh processes produce different ids", a and b and a:match(V4) and a ~= b, tostring(a) .. " / " .. tostring(b))

local f = assert(io.open("lapis/helper/global.lua"))
local global = f:read("*a")
f:close()
check("Global.generateUUID uses it (no math.random / md5 hashing left)",
    global:find("return Uuid%.generate%(%)") ~= nil
    and not global:find("ngx%.md5%(tostring%(random%)")
    and global:find("Global%.generateStaticUUID = Global%.generateUUID") ~= nil)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
