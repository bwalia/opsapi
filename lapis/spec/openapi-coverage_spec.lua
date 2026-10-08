--[[
    Spec: /openapi.json documents every route style, so the SDK
    (sdk/typescript, generated from it) types every endpoint.

    Run inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/openapi-coverage_spec.lua

    Before: only `app:get("/path"` on one line was found — app:match(...,
    respond_to({...})) blocks, paths on the next line and PATCH were missing
    (162 operations, e.g. orders, cart, categories, the AI assistant).
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

ngx = setmetatable({ log = function() end, now = os.time, time = os.time, var = {}, shared = {}, ctx = {} }, -- luacheck: ignore 111
    { __index = function() return function() end end })
package.loaded["lapis.db"] = setmetatable({}, { __index = function() return function() return {} end end })

local spec = require("helper.openapi_generator").generate()
local paths = spec.paths
local function has(path, method) return paths[path] ~= nil and paths[path][method] ~= nil end

local ops = 0
for _, item in pairs(paths) do
    for m in pairs(item) do
        if m == "get" or m == "post" or m == "put" or m == "patch" or m == "delete" then ops = ops + 1 end
    end
end
check("documents the whole API (> 1,200 operations)", ops > 1200, ops)
check("app:match respond_to routes: every method",
    has("/api/v2/categories/{id}", "get") and has("/api/v2/categories/{id}", "put")
        and has("/api/v2/categories/{id}", "delete"))
check("app:match with a route name", has("/api/v2/namespace/roles/{id}", "put"))
check("paths that start on the next line", has("/api/chat/agent", "post") and has("/api/chat/agent/conversation", "get"))
check("PATCH routes", has("/api/v2/tax/transactions/{id}", "patch"))
check("PATCH gets a request body", paths["/api/v2/tax/transactions/{id}"]
    and paths["/api/v2/tax/transactions/{id}"].patch.requestBody ~= nil)
check("one-line routes still found", has("/api/v2/customers", "get") and has("/api/v2/namespace/ai-usage", "get"))
local scim = false
for p in pairs(paths) do if p:find("^/scim/") then scim = true end end
check("SCIM (identity-provider sync) is not documented", not scim)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
