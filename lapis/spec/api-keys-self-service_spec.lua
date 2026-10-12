--[[
    Spec: self-service personal API keys (AI Task Runner, Phase 1 part C).

    Standalone, from the repo root:
        luajit lapis/spec/api-keys-self-service_spec.lua

    A member mints a key for themselves (POST /api/v2/me/api-keys). The key may
    never hold more than its owner: scopes are checked against the owner's role
    at mint time, and authenticate() narrows a self-service key to the owner's
    CURRENT role on every request (demoted -> narrowed, removed -> refused).
    Admin-minted keys keep their scopes as granted. The end-to-end proof against
    a real API + Postgres is lapis/spec/api-keys-e2e/run.sh.
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
local function read(path)
    local h = assert(io.open(path))
    local s = h:read("*a")
    h:close()
    return s
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

-- Stubs: just enough of nginx / lapis.db / resty.* for helper/api-key.lua.
local NULL = setmetatable({}, { __tostring = function() return "ngx.null" end })
_G.ngx = setmetatable({ null = NULL, log = function() end, WARN = 4 },
    { __index = function() return function() end end })
local db_rows = {}
package.loaded["lapis.db"] = {
    query = function(sql)
        if sql:find("UPDATE api_keys SET last_used_at", 1, true) then return {} end
        return db_rows
    end,
}
package.loaded["resty.sha256"] = { new = function()
    local buf = {}
    return { update = function(_, s) buf[#buf + 1] = s end, final = function() return table.concat(buf) end }
end }
package.loaded["resty.string"] = { to_hex = function(s) return s end }
local member_perms = {}
package.loaded["queries.NamespaceMemberQueries"] = { getPermissions = function() return member_perms end }

local ApiKey = require("helper.api-key")
local cjson = require("cjson")

-- Order-free comparison of {module -> [actions]} maps.
local function canon(t)
    local mods = {}
    for m, acts in pairs(t or {}) do
        local a = {}
        for _, x in ipairs(acts) do a[#a + 1] = x end
        table.sort(a)
        mods[#mods + 1] = m .. "=" .. table.concat(a, ",")
    end
    table.sort(mods)
    return table.concat(mods, ";")
end
local function same(a, b) return canon(a) == canon(b) end

print("effective_scopes (key scopes ∩ the owner's current role):")
check("keeps only actions both sides hold",
    same(ApiKey.effective_scopes({ crm = { "read", "update" } }, { crm = { "read" } }), { crm = { "read" } }))
check("owner's manage keeps every action the key lists",
    same(ApiKey.effective_scopes({ crm = { "read", "delete" } }, { crm = { "manage" } }), { crm = { "read", "delete" } }))
check("key manage shrinks to the owner's own actions",
    same(ApiKey.effective_scopes({ crm = { "manage" } }, { crm = { "read" } }), { crm = { "read" } }))
check("manage on both sides stays manage",
    same(ApiKey.effective_scopes({ crm = { "manage" } }, { crm = { "manage" } }), { crm = { "manage" } }))
check("a module the owner lost is dropped",
    same(ApiKey.effective_scopes({ crm = { "read" }, cms = { "read" } }, { cms = { "read" } }), { cms = { "read" } }))
check("an owner with no permissions leaves nothing",
    next(ApiKey.effective_scopes(ApiKey.AGENT_PRESET, {})) == nil)
check("kanban (a URL prefix) is covered by the projects module its routes check",
    same(ApiKey.effective_scopes(ApiKey.AGENT_PRESET, { projects = { "read" } }),
        { kanban = { "read" }, projects = { "read" } }))
check("... and a projects manager keeps the full preset",
    same(ApiKey.effective_scopes(ApiKey.AGENT_PRESET, { projects = { "manage" } }), ApiKey.AGENT_PRESET))
check("projects does NOT alias back to kanban",
    next(ApiKey.effective_scopes({ projects = { "read" } }, { kanban = { "manage" } })) == nil)
check("nil inputs are safe", next(ApiKey.effective_scopes(nil, nil)) == nil)

print("\ncheck_self_scopes (mint-time validation, caller answers 422):")
local perms = { projects = { "read", "update" }, crm = { "manage" }, namespace = { "manage" } }
local ok_scopes = ApiKey.check_self_scopes({ kanban = { "read", "update" }, projects = { "read" } }, perms)
check("held scopes pass (kanban via projects)", ok_scopes ~= nil
    and same(ok_scopes, { kanban = { "read", "update" }, projects = { "read" } }))
check("manage covers any action", ApiKey.check_self_scopes({ crm = { "delete", "create" } }, perms) ~= nil)
local s, e = ApiKey.check_self_scopes({ projects = { "delete" }, cms = { "read" } }, perms)
check("scopes the caller lacks are refused, each named", s == nil and has(e or "", "cms.read")
    and has(e or "", "projects.delete"), e)
s, e = ApiKey.check_self_scopes({ projects = { "manage" } }, perms)
check("manage is refused without manage", s == nil and has(e or "", "projects.manage"), e)
s, e = ApiKey.check_self_scopes({ namespace = { "read" } }, perms)
check("namespace is refused even for a namespace manager", s == nil and has(e or "", "namespace"), e)
s, e = ApiKey.check_self_scopes({ api_keys = { "read" } }, { api_keys = { "manage" } })
check("api-key management is refused", s == nil and has(e or "", "api_keys"), e)
check("empty object refused", ApiKey.check_self_scopes({}, perms) == nil)
check("a string refused", ApiKey.check_self_scopes("projects", perms) == nil)
check("an array of names refused", ApiKey.check_self_scopes({ "projects" }, perms) == nil)
check("empty action list refused", ApiKey.check_self_scopes({ projects = {} }, perms) == nil)
check("non-string action refused", ApiKey.check_self_scopes({ projects = { 1 } }, perms) == nil)
check("JSON null refused", ApiKey.check_self_scopes(cjson.null, perms) == nil)
local dedup = ApiKey.check_self_scopes({ projects = { "read", "read" } }, perms)
check("duplicate actions collapse", dedup and #dedup.projects == 1)

print("\nself_expiry_days (required, default 90, max 365):")
check("default 90", ApiKey.self_expiry_days(nil) == 90)
check("1 and 365 allowed", ApiKey.self_expiry_days(1) == 1 and ApiKey.self_expiry_days(365) == 365)
check("numeric string allowed", ApiKey.self_expiry_days("30") == 30)
for _, bad in ipairs({ 0, -1, 366, 1.5, "abc", 0 / 0, math.huge, cjson.null, {} }) do
    check("refused: " .. tostring(bad), ApiKey.self_expiry_days(bad) == nil)
end

print("\nauthenticate (request time):")
local function key_row(over)
    local row = {
        id = 1, uuid = "k-1", name = "agent", namespace_id = 7, user_uuid = "u-1",
        scopes = cjson.encode({ kanban = { "read", "update" }, projects = { "read" } }),
        revoked_at = NULL, expires_at = NULL, is_expired = false, created_via = NULL,
        ns_id = 7, ns_uuid = "ns-7", ns_slug = "acme", ns_name = "Acme", ns_status = "active",
        user_username = "jo", user_active = true, member_id = 42, member_status = "active",
    }
    for k, v in pairs(over or {}) do row[k] = v end
    db_rows = { row }
end
local raw = "opsk_" .. string.rep("ab", 24)

member_perms = { projects = { "read" } }
key_row()
local p = ApiKey.authenticate(raw)
check("admin-minted key keeps its scopes as granted", p and same(p.scopes,
    { kanban = { "read", "update" }, projects = { "read" } }), p and canon(p.scopes))
check("... and still acts as its bound user", p and p.uuid == "u-1" and p.user_bound == true)

key_row({ created_via = "self" })
p = ApiKey.authenticate(raw)
check("self-service key is narrowed to the owner's role", p and same(p.scopes,
    { kanban = { "read" }, projects = { "read" } }), p and canon(p.scopes))

member_perms = {}
p = ApiKey.authenticate(raw)
check("owner demoted to nothing -> key reaches no module", p and next(p.scopes) == nil, p and canon(p.scopes))
check("... and permits_uri then refuses every API path",
    p and not ApiKey.permits_uri(p, "/api/v2/kanban/my-tasks"))

member_perms = { projects = { "read" } }
for label, over in pairs({
    ["removed from the workspace"] = { member_id = NULL, member_status = NULL },
    ["membership suspended"] = { member_status = "suspended" },
    ["user deactivated"] = { user_active = false },
}) do
    over.created_via = "self"
    key_row(over)
    local pr, _, status = ApiKey.authenticate(raw)
    check("self-service key refused when owner " .. label .. " (401)", pr == nil and status == 401, status)
end
key_row({ member_id = NULL, member_status = NULL })
check("admin-minted key unaffected by membership (today's behaviour)", ApiKey.authenticate(raw) ~= nil)

key_row({ created_via = "self", revoked_at = "2026-10-01 00:00:00" })
local _, _, st = ApiKey.authenticate(raw)
check("revoked key refused (401)", st == 401)
key_row({ created_via = "self", is_expired = true })
_, _, st = ApiKey.authenticate(raw)
check("expired key refused (401)", st == 401)
key_row({ created_via = "self", ns_status = "suspended" })
_, _, st = ApiKey.authenticate(raw)
check("suspended workspace refused (403)", st == 403)

print("\nwiring (source):")
local helper = read("lapis/helper/api-key.lua")
check("membership resolved in the same key lookup (no extra round trip)",
    has(helper, "LEFT JOIN namespace_members nm ON nm.namespace_id = ak.namespace_id AND nm.user_id = u.id"))
check("expiry boundary is inclusive", has(helper, "ak.expires_at <= NOW()"))
check("uses the cached permission lookup", has(helper, 'require("queries.NamespaceMemberQueries").getPermissions'))
local route = read("lapis/routes/api-keys.lua")
check("/me routes exist", has(route, '"/api/v2/me/api-keys"') and has(route, '"/api/v2/me/api-keys/:uuid"'))
check("/me routes refuse API-key callers", has(route, "local refused = refuse_api_key_auth(self)")
    and select(2, route:gsub("member_session%(function", "")) == 3)
check("create binds the key to the caller as self-service",
    has(route, "user_uuid = user_uuid,") and has(route, "created_via = ApiKeyHelper.SELF"))
check("create is rate-limited per user", has(route, 'RateLimit.check("me_api_keys:" .. user_uuid'))
check("create caps live keys", has(route, "countActiveMine"))
check("create and revoke are audited", has(route, '"api_key.created"') and has(route, '"api_key.revoked"'))
check("revoke looks up by owner + workspace (404 for others)", has(route, "ApiKeyQueries.findMine(self.params.uuid"))
local q = read("lapis/queries/ApiKeyQueries.lua")
check("own-key queries filter namespace + owner + self",
    select(2, q:gsub("WHERE namespace_id = %? AND user_uuid = %? AND created_via = 'self'", "")) == 2
    and has(q, "WHERE uuid = ? AND namespace_id = ? AND user_uuid = ? AND created_via = 'self'"))
local mig = read("lapis/migrations/api-keys.lua")
check("created_via column added idempotently", has(mig, 'column_exists("api_keys", "created_via")'))
check("registered under a zzak key", has(read("lapis/migrations.lua"),
    "['zzak1_api_keys_created_via'] = api_key_migrations[3]"))

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
