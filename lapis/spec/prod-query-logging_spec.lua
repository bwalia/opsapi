--[[
    Regression spec: production must not log SQL.

    Lapis logs every interpolated SQL statement by default, which put emails,
    IPs and names into the production logs. Production turns it off; the
    LAPIS_SHOW_QUERIES override must stay reachable from the nginx workers.

    Standalone — run from the repo root with:
        luajit lapis/spec/prod-query-logging_spec.lua
]]

local failures = 0
local function check(name, ok)
    print((ok and "  ok   - " or "  FAIL - ") .. name)
    if not ok then failures = failures + 1 end
end

local function read(path)
    local f = assert(io.open(path))
    local text = f:read("*a")
    f:close()
    return text
end

local config = read("lapis/config.lua")
local production = config:match('config%("production", {(.-)\n}%)')
check("production config found", production ~= nil)
check("production sets logging.queries = false",
    production ~= nil and production:find("logging = {%s*queries = false") ~= nil)
check("production keeps request logging", production ~= nil and production:find("requests = true") ~= nil)

for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    check(conf .. " declares LAPIS_SHOW_QUERIES for the workers",
        read(conf):find("\nenv LAPIS_SHOW_QUERIES;") ~= nil or read(conf):find("^env LAPIS_SHOW_QUERIES;") ~= nil)
end

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
