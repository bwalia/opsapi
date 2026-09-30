--[[
    Regression spec: plugin platform (helper.project-loader, helper.plugin-sdk,
    bin/opsapi). Needs the image's Lua deps (lapis, cjson), so run it in the
    container:

        docker exec -w /app opsapi luajit spec/plugin-platform_spec.lua

    Guards the properties that make plugins safe in a multi-tenant deployment:
    input is whitelisted + type-checked, a plugin can't replace a core route
    or squat a core prefix, bad manifests are refused, and the CLI generates
    code that loads.
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path
local APP = io.open("./helper/plugin-sdk.lua") and "." or "lapis"

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local sdk = require("helper.plugin-sdk")
local ProjectLoader = require("helper.project-loader")
local cjson = require("cjson")

print("sdk.validate")
local rules = {
    title = { type = "string", required = true, max = 10 },
    status = { enum = { "open", "closed" } },
    priority = { type = "integer", min = 1, max = 5 },
    email = { type = "email" },
    due = { type = "date" },
    done = { type = "boolean" },
    meta = { type = "json" },
}
local clean, errs = sdk.validate({ title = "  Hi  ", priority = "3", done = "true", evil = "x", namespace_id = 9 }, rules)
check("valid input passes", clean ~= nil, errs and cjson.encode(errs))
check("strings are trimmed", clean and clean.title == "Hi")
check("numeric strings coerced", clean and clean.priority == 3)
check("'true' coerced to boolean", clean and clean.done == true)
check("unknown keys dropped (no mass assignment)", clean and clean.evil == nil and clean.namespace_id == nil)

clean, errs = sdk.validate({ status = "bogus", priority = 2.5, email = "nope", due = "1/2/2026", meta = "x" }, rules)
check("invalid input rejected", clean == nil)
check("required reported", errs and errs.title == "is required")
check("enum enforced", errs and errs.status and errs.status:find("one of"))
check("integer enforced", errs and errs.priority == "must be a whole number")
check("email pattern", errs and errs.email == "must be a valid email")
check("date pattern", errs and errs.due == "must be a valid date")
check("json must be a table", errs and errs.meta ~= nil)

clean = sdk.validate({ title = string.rep("a", 11) }, rules)
check("max length", clean == nil)
clean = sdk.validate({ priority = 9, title = "x" }, rules)
check("numeric max", clean == nil)
clean = sdk.validate({ priority = 2147483648, title = "x" }, { priority = { type = "integer" }, title = rules.title })
check("integer beyond Postgres INTEGER rejected", clean == nil)

clean, errs = sdk.validate({ priority = 2 }, rules, true)
check("partial update skips absent required fields", clean and clean.priority == 2, errs and cjson.encode(errs))
clean = sdk.validate({ title = cjson.null }, rules, true)
check("partial update: null on required rejected", clean == nil)
clean = sdk.validate({ priority = cjson.null, due = "" }, rules, true)
check("null / empty clears optional fields", clean and clean.priority == sdk.db.NULL and clean.due == sdk.db.NULL)

print("project-loader: manifests")
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp)
local function manifest(src)
    local path = tmp .. "/project.lua"
    local f = assert(io.open(path, "w"))
    f:write(src)
    f:close()
    return ProjectLoader.loadManifest(path, tmp)
end
local m, err = manifest('return { code = "my-plugin", name = "Mine" }')
check("valid manifest loads", m ~= nil, err)
check("code normalised", m and m.code == "my_plugin")
check("default api_prefix", m and m.api_prefix == "/api/v2/my-plugin")
check("default sdk_version", m and m.sdk_version == 1)
check("bad code refused", manifest('return { code = "9x", name = "x" }') == nil)
check("newer SDK refused", manifest('return { code = "x", name = "x", sdk_version = 99 }') == nil)
check("module without machine_name refused", manifest('return { code = "x", name = "x", modules = { { name = "y" } } }') == nil)
check("api_prefix outside /api refused", manifest('return { code = "x", name = "x", api_prefix = "/" }') == nil)
check("built-in feature code reserved", ProjectLoader.isReservedCode("crm"))
check("fresh code not reserved", not ProjectLoader.isReservedCode("helpdesk"))

print("project-loader: routes")
local app = require("lapis").Application()
app:get("/api/v2/core/thing", function() end)
m = manifest('return { code = "probe", name = "Probe" }')
local proxy = ProjectLoader.createPrefixedApp(app, "/api/v2/core", m)
local ok, perr = pcall(proxy.get, proxy, "/thing", function() end)
check("replacing a core route is refused", not ok and tostring(perr):find("already registered"))
ok = pcall(proxy.post, proxy, "/thing", function() end)
check("a new verb on the path is allowed", ok)
proxy = ProjectLoader.createPrefixedApp(app, "/api/v2/probe", m)
ok = pcall(proxy.get, proxy, "/items", function() end)
check("own route registers", ok and m.routes[#m.routes].path == "/api/v2/probe/items")

os.execute("mkdir -p " .. tmp .. "/api")
local f = assert(io.open(tmp .. "/api/a.lua", "w"))
f:write('return function(app) app:get("/x", function() end) end')
f:close()
m = manifest('return { code = "squat", name = "Squat", api_prefix = "/api/v2/core" }')
ProjectLoader.loadRoutes(app, m)
check("squatting a core prefix is refused", m.errors[1] and m.errors[1]:find("already used"), m.errors[1])
check("... and nothing was registered", #m.routes == 0)

print("bin/opsapi")
local dir = tmp .. "/plugins"
local cli = "luajit " .. APP .. "/bin/opsapi"
local function run(args)
    return os.execute(cli .. " " .. args .. " --dir " .. dir .. " >/dev/null 2>&1")
end
local function succeeded(r) return r == 0 or r == true end
check("plugin:new", succeeded(run("plugin:new help-desk")))
check("plugin:new refuses a built-in code", not succeeded(run("plugin:new crm")))
check("make:resource", succeeded(run("make:resource help-desk ticket title:string:required due:date done:boolean")))
check("make:resource rejects unknown type", not succeeded(run("make:resource help-desk thing a:blob")))
check("make:resource rejects reserved column", not succeeded(run("make:resource help-desk thing id:integer")))
local plugin = dir .. "/help-desk"
check("generated api compiles", loadfile(plugin .. "/api/tickets.lua") ~= nil)
local h = io.popen("ls " .. plugin .. "/migrations/*_create_help_desk_tickets.lua")
local mig = h:read("*l")
h:close()
check("generated migration compiles", mig and loadfile(mig) ~= nil)
m = ProjectLoader.loadManifest(plugin .. "/project.lua", plugin)
check("RBAC module added to manifest", m and m.modules[1] and m.modules[1].machine_name == "help_desk_tickets")
check("plugin:check passes", succeeded(run("plugin:check")))

os.execute("rm -rf " .. tmp)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
