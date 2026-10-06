--[[
    Regression spec: the page-aware AI assistant (lib/agent/scopes + knowledge).

    Standalone -- run from the repo root with:
        luajit lapis/spec/page-assistant_spec.lua

    Guards: every knowledge file parses; each dashboard page area resolves to its
    own scope (separate history per page); call_api's allow-list is exactly the
    endpoints documented in the guide, inside the `api:` prefixes; guide-only
    pages (tax filing, keys/vault) expose no API; the chat-agent route is core.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path
ngx = ngx or { log = function() end, WARN = 4, NOTICE = 6, ERR = 3 } -- luacheck: ignore 111

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end

local Scopes = require("lib.agent.scopes")

print("Allow-list from the guide:")
local t = Scopes.parse("t", table.concat({
    "---", "title: T", "pages: /dashboard/t", "api: /api/v2/timesheets", "---",
    "- `GET /api/v2/timesheets?page&per_page` — list",
    "- `POST /api/v2/timesheets {work_date*: YYYY-MM-DD}` — create",
    "- `DELETE /api/v2/timesheets/{uuid}` — delete",
}, "\n"))
check("documented GET allowed", Scopes.allows_api(t, "/api/v2/timesheets", "GET"))
local U = "9e98ab27-846a-43c3-9473-64668b0c7859"
check("documented DELETE with a uuid allowed", Scopes.allows_api(t, "/api/v2/timesheets/" .. U, "DELETE"))
check("documented DELETE with a numeric id allowed", Scopes.allows_api(t, "/api/v2/timesheets/42", "DELETE"))
check("id placeholder refuses a fixed word (sibling route)", not Scopes.allows_api(t, "/api/v2/timesheets/sync-settings", "DELETE"))
check("undocumented method refused", not Scopes.allows_api(t, "/api/v2/timesheets/" .. U, "PUT"))
check("placeholder matches one segment only", not Scopes.allows_api(t, "/api/v2/timesheets/" .. U .. "/x", "DELETE"))
check("prefix is a path boundary", not Scopes.allows_api(t, "/api/v2/timesheetsX", "GET"))
check("other module refused", not Scopes.allows_api(t, "/api/v2/users", "GET"))

print("Knowledge files:")
-- Runs from the repo root or from /app in the container.
local dir = io.open("lib/agent/knowledge/general.md") and "lib/agent/knowledge" or "lapis/lib/agent/knowledge"
local files = {}
local h = io.popen("ls -1 " .. dir .. " 2>/dev/null")
for name in h:lines() do files[#files + 1] = name end
h:close()
check("knowledge files exist", #files > 10, #files .. " files")

local scopes, owner = {}, {}
for _, name in ipairs(files) do
    local key = name:match("^([%w%-_]+)%.md$")
    local scope = key and Scopes.parse(key, read(dir .. "/" .. name))
    check(name .. " parses", scope ~= nil)
    if scope then
        scopes[key] = scope
        check(name .. " has pages", #scope.pages > 0)
        for _, p in ipairs(scope.pages) do
            check(name .. " page " .. p .. " is not claimed twice", owner[p] == nil, owner[p])
            owner[p] = key
        end
        if #scope.api > 0 then
            check(name .. " documents its endpoints", #scope.endpoints > 0)
            for _, e in ipairs(scope.endpoints) do
                local path = e.path:gsub("{[^}/]*}", U):gsub(":[%a_][%w_]*", U)
                check(name .. " " .. e.method .. " " .. e.path .. " is inside api:",
                    Scopes.allows_api(scope, path, e.method))
            end
        end
        check(name .. " guide fits the model's context", #scope.guide < 9000, #scope.guide .. " chars")
        -- Shorthand ("`DELETE` same", "`GET|POST /x`", "`GET .../y`") isn't on the
        -- allow-list and a small model can't expand it reliably: spell paths out.
        local shorthand = scope.guide:match("`%u+|[%u|]+ /[^`]*`") or scope.guide:match("`%u+`")
            or scope.guide:match("`%u+ %.%.%./[^`]*`")
        check(name .. " spells every endpoint out", shorthand == nil, shorthand)
    end
end

print("Every dashboard page area has its own scope:")
-- Scopes.resolve reads the real directory through helper.project-loader.
local ph = io.popen("ls -1 opsapi-dashboard/app/dashboard")
for entry in ph:lines() do
    if not entry:find("%.") and entry ~= "chat" then
        local scope = Scopes.resolve("/dashboard/" .. entry)
        check("/dashboard/" .. entry .. " -> " .. scope.key, scope.key ~= "general")
    end
end
ph:close()
check("/dashboard (home) -> general", Scopes.resolve("/dashboard").key == "general")
check("sub-pages share their area's thread",
    Scopes.resolve("/dashboard/timesheets/abc").key == Scopes.resolve("/dashboard/timesheets").key)
check("timesheets and projects never share a thread",
    Scopes.resolve("/dashboard/timesheets").key ~= Scopes.resolve("/dashboard/projects").key)

print("Guide-only pages expose no API:")
local filing = Scopes.resolve("/dashboard/tax/file")
check("tax filing wizard is guide-only", #filing.api == 0, filing.key)
local keys = Scopes.resolve("/dashboard/namespace/api-keys")
check("API keys page is guide-only", #keys.api == 0, keys.key)

print("Wiring:")
local app = read("lapis/app.lua")
check("chat-agent route loads as core", app:find('safe_load_routes("routes.chat-agent")', 1, true) ~= nil)
check("chat-agent no longer chat-gated", app:find('load_if("chat", "routes.chat-agent")', 1, true) == nil)
check("JSON body is mirrored into params for agent calls", app:find("http_x_opsapi_agent", 1, true) ~= nil)
check("JSON bodies never parse as form args", app:find("ngx.req.get_post_args = function", 1, true) ~= nil)
check("model chosen by env (AI_PROVIDER) and declared to nginx",
    read("lapis/nginx.conf"):find("env AI_PROVIDER;", 1, true) ~= nil
    and read("lapis/lib/agent/llm.lua"):find('env("AI_PROVIDER")', 1, true) ~= nil)
check("server failure notices are hidden from the model",
    read("lapis/routes/chat-agent.lua"):find("is_system_reply(m) then goto next_turn", 1, true) ~= nil)
local tools = read("lapis/lib/agent/tools.lua")
check("DELETE waits for confirmation", tools:find("needs_confirmation = true", 1, true) ~= nil)
check("auth/keys/secrets are never callable", tools:find('"api%-keys", "secret", "vault"', 1, true) ~= nil)
check("migration adds the scope column",
    read("lapis/migrations.lua"):find("ADD COLUMN IF NOT EXISTS scope", 1, true) ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
