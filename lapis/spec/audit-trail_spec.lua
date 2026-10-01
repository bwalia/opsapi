--[[
    Regression spec: the record-change audit trail (helper/plugin-events.lua +
    helper/request-context.lua).

    Every piece below fails silently if it's removed: changes stop being
    audited, or are recorded under the wrong person (connections are pooled,
    so a missed refresh leaks the previous user's identity into a row).

    Standalone — run from the repo root with:
        luajit lapis/spec/audit-trail_spec.lua
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

-- ── request context: who Postgres thinks is acting ─────────────────────────

local phase, ctx, var = "content", {}, { request_id = "req-1" }
_G.ngx = {
    get_phase = function() return phase end,
    ctx = ctx,
    var = var,
    log = function() end,
    ERR = 4,
}
package.path = "lapis/?.lua;" .. package.path
package.loaded["helper.client-ip"] = { get = function() return "203.0.113.9" end }
local RequestContext = dofile("lapis/helper/request-context.lua")

local sent, queries = nil, 0
local fake = {
    escape_literal = function(_, v) return "'" .. tostring(v):gsub("'", "''") .. "'" end,
    query = function(_, sql) sent, queries = sql, queries + 1 return true end,
}
local function settings()
    local out = {}
    for name, value in sent:gmatch("set_config%('opsapi%.([%w_]+)', '(.-)', false%)") do out[name] = value end
    return out
end

ctx.user = { uuid = "u-1" }
RequestContext.apply(fake)
local s = settings()
check("signed-in user: actor, via=jwt, ip, request id",
    s.actor_uuid == "u-1" and s.actor_via == "jwt" and s.actor_ip == "203.0.113.9" and s.request_id == "req-1")
check("settings are session-level (not reset by a transaction)", not sent:find(", true%)"))

ctx.user = { uuid = "u-2", api_key = true, key_uuid = "k-9" }
RequestContext.apply(fake)
s = settings()
check("API key: via=api_key with the key id", s.actor_uuid == "u-2" and s.actor_via == "api_key" and s.api_key_uuid == "k-9")

ctx.user = nil
RequestContext.apply(fake)
s = settings()
check("no user: anonymous, every field reset (pooled connection)",
    s.actor_uuid == "" and s.actor_via == "anonymous" and s.actor_ip == "" and s.request_id == "")

phase, ctx.user = "timer", { uuid = "u-1" }
RequestContext.apply(fake)
s = settings()
check("timer: system, never a leftover user", s.actor_uuid == "" and s.actor_via == "system")
phase = "content"

ctx.user = { uuid = "o'brien" }
RequestContext.apply(fake)
check("values are escaped", sent:find("'o''brien'", 1, true) ~= nil)

sent = nil
ctx.pgmoon_default = fake
RequestContext.refresh()
check("refresh re-applies on the request's open connection", sent ~= nil)

-- install() wraps lapis' connect hook exactly once
local original = 0
package.loaded["lapis.logging"] = { db_connection = function() original = original + 1 end }
RequestContext.install()
RequestContext.install()
queries = 0
require("lapis.logging").db_connection({}, fake, true)
check("install hooks new connections once and keeps lapis' own logger", queries == 1 and original == 1)

-- ── wiring ─────────────────────────────────────────────────────────────────

for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    local src = read(conf)
    check(conf .. ": request context installed at init",
        src:find('require%("helper%.request%-context"%)%.install%(%)') ~= nil)
    check(conf .. ": audit env vars declared",
        src:find("env OPSAPI_AUDIT_ENABLED;", 1, true) and src:find("env OPSAPI_AUDIT_RETENTION_DAYS;", 1, true))
end

for _, file in ipairs({ "lapis/middleware/auth.lua", "lapis/helper/auth.lua" }) do
    local src = read(file)
    local _, sets = src:gsub("ngx%.ctx%.user = [^\n]+\n", "")
    local _, refreshed = src:gsub("ngx%.ctx%.user = [^\n]+\n%s*require%(\"helper%.request%-context\"%)%.refresh%(%)", "")
    check(file .. ": every ngx.ctx.user assignment refreshes the actor", sets > 0 and sets == refreshed)
end

local events = read("lapis/helper/plugin-events.lua")
check("trigger writes the audit row", events:find("PERFORM opsapi_audit%(ev, entity") ~= nil)
local _, excluded = events:gsub("subscriber <> 'core%.audit'", "")
check("core.audit never gets outbox events or deliveries (trigger x2, emit x1)", excluded >= 3)
check("audit function redacts secret-looking fields",
    events:find("password|passwd|secret|token|pin_hash|api_key|private_key", 1, true) ~= nil)
check("audit function only records subscribed entities",
    events:find("subscriber = 'core.audit' AND event IN (ev, ent || '.*')", 1, true) ~= nil)
check("sdk.emit events are audited", events:find('SELECT opsapi_audit(?, ?, NULL, ?, NULL, ?::jsonb)', 1, true) ~= nil)
check("retention purge deletes only db-sourced audit rows",
    events:find("DELETE FROM audit_events", 1, true) and events:find("metadata ->> 'source' = 'db'", 1, true))
check("OPSAPI_AUDIT_ENABLED=false removes the subscriptions",
    events:find('os.getenv("OPSAPI_AUDIT_ENABLED") ~= "false"', 1, true) ~= nil)

local migrator = read("lapis/helper/project-migrator.lua")
check("every migrate syncs the audit subscriptions", migrator:find("PluginEvents%.syncAudit%(%)") ~= nil)

local migrations = read("lapis/migrations.lua")
check("audit migrations registered", migrations:find("['zzwh3_audit_trail']", 1, true)
    and migrations:find("['zzwh4_audit_forget_user']", 1, true))
check("audit migrations are core (every PROJECT_CODE)",
    migrations:find('load_if_enabled%(ProjectConfig%.FEATURES%.CORE, "migrations%.audit%-trail"%)') ~= nil)

local forget = read("lapis/migrations/audit-trail.lua")
check("deleting a user erases them from the audit trail",
    forget:find("UPDATE audit_events%s+SET actor_user_uuid = NULL, actor_ip = NULL") ~= nil)

local route = read("lapis/routes/namespace-activity.lua")
check("changes endpoint needs activity.read",
    route:find('app:get%("/api/v2/namespace/activity/changes", Http%.guard%("activity", "read"') ~= nil)
local queries = read("lapis/queries/ActivityQueries.lua")
local changes = queries:match("function ActivityQueries%.changes.-\nend\n")
check("changes are scoped to the namespace and to db-sourced rows",
    changes and changes:find('"a.namespace_id = ?"', 1, true) and changes:find("a.metadata ->> 'source' = 'db'", 1, true))

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
