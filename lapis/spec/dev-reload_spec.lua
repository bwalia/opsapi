--[[
    Spec: dev hot reload (helper/dev-reload.lua) and `opsapi reload`.

    Standalone, in the image (needs busybox find/stat):
        docker run --rm -v "$PWD:/w" -w /w lapis-lapis luajit lapis/spec/dev-reload_spec.lua
]]

local failures = 0
local function check(name, ok)
    print((ok and "  ok   - " or "  FAIL - ") .. name)
    if not ok then failures = failures + 1 end
end
local function read(path)
    local f = assert(io.open(path))
    local s = f:read("*a")
    f:close()
    return s
end
local function write(path, s)
    local f = assert(io.open(path, "w"))
    f:write(s)
    f:close()
end

-- ── scanner: what counts as a change ───────────────────────────────────────
package.path = "lapis/?.lua;" .. package.path
local DevReload = dofile("lapis/helper/dev-reload.lua")
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p " .. dir .. "/node_modules " .. dir .. "/.git")
write(dir .. "/a.lua", "return 1")
local scan = DevReload._scanner({ dir }, dir .. ".stamp")
local function names(list)
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = p:match("[^/]+$") end
    table.sort(out)
    return table.concat(out, ",")
end
check("files present at start are the baseline (no reload loop)", names(scan()) == "")
write(dir .. "/a.lua", "return 2")
check("an edited file is reported", names(scan()) == "a.lua")
check("...once", names(scan()) == "")
write(dir .. "/b.lua", "return 3")
write(dir .. "/notes.txt", "x")
write(dir .. "/node_modules/c.lua", "x")
write(dir .. "/.git/d.lua", "x")
check("new .lua files reported; other files, node_modules and dot dirs ignored", names(scan()) == "b.lua")
-- A host save surfacing late keeps its (older) mtime: still a change.
write(dir .. "/a.lua", "return 4")
os.execute("touch -d @" .. (os.time() - 10) .. " " .. dir .. "/a.lua")
check("a save that surfaces late (older mtime) is still caught", names(scan()) == "a.lua")
os.execute("rm -rf " .. dir .. " " .. dir .. ".stamp")

-- ── wiring ─────────────────────────────────────────────────────────────────
for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    local src = read(conf)
    local gate = src:find('if os.getenv("OPSAPI_DEV_RELOAD") == "true" then', 1, true)
    local agent = src:find("enable_privileged_agent()", 1, true)
    check(conf .. ": privileged agent only when OPSAPI_DEV_RELOAD=true", gate and agent and agent > gate and agent - gate < 150)
    check(conf .. ": the agent only watches (returns before the worker setup)",
        src:find('== "privileged agent" then.-require%("helper.dev%-reload"%)%.start.-return\n%s*end') ~= nil)
    check(conf .. ": env declared", src:find("env OPSAPI_DEV_RELOAD;", 1, true) ~= nil)
end
check("compose: off unless asked", read("lapis/docker-compose.yml"):find("OPSAPI_DEV_RELOAD=${OPSAPI_DEV_RELOAD:-false}", 1, true) ~= nil)
check("start.sh: on for -e local only, never in CI",
    read("start.sh"):find('if [ "$TARGET_ENV" = "local" ] && ! $CI_MODE; then', 1, true) ~= nil)
local src = read("lapis/helper/dev-reload.lua")
check("broken files block the reload", src:find("if #broken > 0 then", 1, true) ~= nil)
check("migrations are never run automatically", not src:find("migrate(", 1, true) and not src:find("lapis migrate", 1, true))
local cli = read("lapis/bin/opsapi")
check("opsapi reload checks plugins before signalling", cli:find("cmd_check(root) -- exits 1 on problems", 1, true) ~= nil)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
