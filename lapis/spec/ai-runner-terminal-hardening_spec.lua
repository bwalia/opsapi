--[[
    Spec: AI Runs web terminal hardening and the live work log (projects/ai-runner, 2026-10-29 review).

    S1 terminal calls stop when the terminal, the workspace or AI Runs is off (the keys feed then sends an empty,
       still signed list); S2 no unattended agent by default, `--` before the prompt, prompts never start with "-";
    S3 the auto sign-in step-up never takes TEST_OTP_CODE; S4 terminal addresses must be https (but this machine);
    S5 PR sign-off is scoped to the task; S6 an agent's PR moves the task only when it is in the project's repo;
    W1 names in the keys feed; W4 suspended keys are left out; W3 the stale sweep; W5 the work log's filters are
    parameters and the count is bounded; W6 the timeline cursor; the menu shows a plugin page once.

    Standalone, from the repo root (what CI does):
        luajit lapis/spec/ai-runner-terminal-hardening_spec.lua
    Unit checks with lapis.db and the nginx-only modules stubbed; end to end: projects/ai-runner/spec/run.sh.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;projects/ai-runner/?.lua;" .. package.path

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
    local h = io.open(path)
    if not h then return "" end
    local s = h:read("*a")
    h:close()
    return s
end

local cjson = require("cjson")
_G.ngx = setmetatable({ var = {}, ctx = {}, header = {}, shared = {}, log = function() end, WARN = 4, ERR = 3,
    INFO = 7, NOTICE = 6, DEBUG = 8, time = function() return os.time() end,
    encode_base64 = function(s) return s end, decode_base64 = function(s) return s end },
    { __index = function() return function() end end })

-- lapis.db: every query goes to `handler` (set per test); `log` keeps { sql, args } of each.
local handler = function() return {} end
local log = {}
local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
package.loaded["lapis.db"] = {
    NULL = NULL,
    raw = function(s) return { raw = s } end,
    query = function(sql, ...)
        log[#log + 1] = { sql = sql, args = { ... } }
        return handler(sql, ...)
    end,
    insert = function() return {} end,
    escape_literal = function(s) return "'" .. tostring(s) .. "'" end,
}
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
package.loaded["resty.sha256"] = { new = function()
    local buf = {}
    return { update = function(_, s) buf[#buf + 1] = s end, final = function() return table.concat(buf) end }
end }
package.loaded["resty.string"] = { to_hex = hex }
package.loaded["helper.secret-box"] = { open = function() return "s3cret" end }
local plugin_on = true
package.loaded["helper.plugin-workspaces"] = {
    isEnabled = function() return plugin_on end,
    disabledIn = function() return {} end,
}
package.loaded["helper.plugin-sdk"] = { array = function(t) return setmetatable(t or {}, cjson.array_mt) end }
package.loaded["helper.global"] = {
    getEnvVar = function() return "jwt" end,
    perPageParam = function(v, d, max)
        local n = tonumber(v)
        if not n then return d end
        return math.max(1, math.min(math.floor(n), max))
    end,
}

local R = require("ai_runner.runs")
local T = require("ai_runner.terminal")
T.hmac_hex = function(secret, msg) return hex(secret .. "|" .. msg) end -- stands in for HMAC-SHA256

local function failure(fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return nil end
    return type(err) == "table" and err or { message = tostring(err) }
end

print("S2: unattended agents, the prompt on the command line")
local ids = {}
for _, a in ipairs(T.DEFAULT_AGENTS) do
    ids[#ids + 1] = a.id
    check("default agent " .. a.id .. " stops to ask", not T.is_unattended(a))
end
check("claude_auto isn't a default", not table.concat(ids, ","):find("auto"), table.concat(ids, ","))
for id, line in pairs(T.RUN_LINES) do
    check("run line for " .. id .. " ends the options before the prompt", line:find('-- "$OPSAPI_TASK_PROMPT"', 1, true)
        ~= nil, line)
end
check("an id ending in _auto is unattended", T.is_unattended({ id = "claude_auto" }))
check("so is one marked unattended", T.is_unattended({ id = "night", unattended = true }))
check("claude isn't", not T.is_unattended({ id = "claude" }))
local row = { agents = cjson.encode({ { id = "claude", label = "C" }, { id = "claude_auto", label = "U" } }) }
check("not offered to someone who can't start it", #T.agents_for(row, false) == 1 and T.agents_for(row, false)[1].id
    == "claude")
local mgr = T.agents_for(row, true)
check("offered to a manager, marked unattended", #mgr == 2 and mgr[2].unattended == true and mgr[1].unattended == nil)
check("agents_of keeps unattended = true", T.agents_of({ { id = "x", label = "X", unattended = true } })[1].unattended
    == true)
check("agents_of refuses a non-boolean unattended",
    failure(T.agents_of, { { id = "x", label = "X", unattended = "yes" } }) ~= nil)
check("a prompt starting with - gets a word in front", T.safe_prompt("-rf /") == "Task: -rf /")
check("…also after spaces", T.safe_prompt("  --help me") == "Task: --help me")
check("other prompts stay as they are", T.safe_prompt("Fix the header\n-- detail") == "Fix the header\n-- detail")
local api_terminal = read("projects/ai-runner/api/terminal.lua")
check("launch: an unattended agent needs ai_runs.manage", api_terminal:find('T.is_unattended(agent) and not '
    .. 'sdk.can(self, "ai_runs", "manage")', 1, true) ~= nil)
check("launch: the prompt goes through safe_prompt", api_terminal:find("T.safe_prompt(T.with_folder(", 1, true) ~= nil)
local wt = read("opsapi-dashboard/components/ai-runner/WebTerminals.tsx")
check("dashboard config block: no run line without --", not wt:find('[^-] "%$OPSAPI_TASK_PROMPT"')
    and wt:find('-- "$OPSAPI_TASK_PROMPT"', 1, true) ~= nil)

print("S4: terminal addresses")
for _, u in ipairs({ "https://dev.example.com", "https://dev.example.com:8443/", "http://localhost:3000",
    "http://127.0.0.1", "http://[::1]:8080" }) do
    check(u .. " accepted", R.secure_base_url(u) ~= nil)
end
for _, u in ipairs({ "http://dev.example.com", "http://localhost.evil.com", "http://127.0.0.1.evil.com",
    "ftp://x.example", "https://x.example/path" }) do
    check(u .. " refused", R.secure_base_url(u) == nil)
end
check("terminal create/update use it", api_terminal:find("R.secure_base_url(v)", 1, true) ~= nil)

print("S1 + W1 + W4: the keys feed")
local TU = "11111111-2222-3333-4444-555555555555"
local term = { id = 9, uuid = TU, namespace_id = 7, is_active = true, secret_sealed = "x", name = "Mac" }
local ns_status = "active"
local function feed()
    log = {}
    handler = function(sql)
        if sql:find("FROM ar_terminals WHERE uuid", 1, true) then return { term } end
        if sql:find("FROM namespaces", 1, true) then return { { status = ns_status } } end
        if sql:find("JOIN users pu", 1, true) then
            return { { user = "dev", public_key = "ssh-ed25519 AAAA", expires_unix = 1, email = "d@x.io",
                name = "Dev" } }
        end
        return {}
    end
    local ts = tostring(ngx.time())
    local body, sig = T.keys_for_terminal(TU, ts, "sha256=" .. T.hmac_hex("s3cret", "keys\n" .. TU .. "\n" .. ts))
    return body and cjson.decode(body), sig
end
local out, sig = feed()
check("on: the live keys, each with the person's name", out and #out.keys == 1 and out.keys[1].name == "Dev"
    and out.keys[1].email == "d@x.io", out and cjson.encode(out))
local keys_sql
for _, q in ipairs(log) do if q.sql:find("JOIN users pu", 1, true) then keys_sql = q.sql end end
check("suspended keys are left out of the feed", keys_sql and keys_sql:find("k.suspended_at IS NULL", 1, true) ~= nil)
plugin_on = false
out, sig = feed()
check("AI Runs off: an empty list, still signed", out and #out.keys == 0 and type(sig) == "string" and #sig > 0)
plugin_on, ns_status = true, "suspended"
out = feed()
check("workspace not active: an empty list", out and #out.keys == 0)
ns_status, term.is_active = "active", false
out = feed()
check("terminal switched off: an empty list", out and #out.keys == 0)
term.is_active = true

local err = failure(T.require_on, { is_active = false, namespace_id = 7 })
check("signed call from a switched-off terminal: 403 TERMINAL_OFF", err and err.status == 403
    and err.extra and err.extra.code == "TERMINAL_OFF")
plugin_on = false
handler = function(sql) if sql:find("FROM namespaces", 1, true) then return { { status = "active" } } end return {} end
err = failure(T.require_on, { is_active = true, namespace_id = 7 })
check("…with AI Runs off: 404 PLUGIN_DISABLED", err and err.status == 404 and err.extra
    and err.extra.code == "PLUGIN_DISABLED")
plugin_on = true
check("…removed: 403", (failure(T.require_on, nil) or {}).status == 403)
check("webhook and signed_terminal check it", select(2, read("projects/ai-runner/ai_runner/terminal.lua")
    :gsub("T.require_on%(", "")) >= 4)

print("S6: an agent's PR report")
local automated, inserted
package.loaded["ai_runner.vault_pr"] = {
    parse_repo = function(u)
        return type(u) == "string" and u:match("github%.com[:/]+([^/]+/[^/%.]+)") or nil
    end,
    view = function(r) return r end,
}
R.task = function() return nil end -- no comments in this spec
R.automate_task = function() automated = true end
local repo_url = ""
R.project_settings = function() return { target_repo_url = repo_url } end
local function report(pr)
    automated, inserted = false, nil
    handler = function(sql, ...)
        local args = { ... }
        if sql:find("FROM ar_terminal_sessions WHERE report_token_hash", 1, true) then
            return { { id = 1, namespace_id = 7, task_uuid = "t", project_uuid = "p", terminal_uuid = TU,
                agent_label = "Claude" } }
        end
        if sql:find("FROM ar_terminals WHERE uuid", 1, true) then return { term } end
        if sql:find("FROM namespaces", 1, true) then return { { status = "active" } } end
        if sql:find("INSERT INTO ar_task_prs", 1, true) then
            inserted = { repo = args[4], pr_number = args[6] }
            return { { uuid = "pr", pr_url = args[5], pr_number = args[6] } }
        end
        return {}
    end
    return T.report(string.rep("a", 43), { pr_url = pr })
end
local r1 = report("https://github.com/acme/web/pull/7")
check("no project repository: recorded, not followed, task not moved", r1 and r1.tracked == false
    and inserted and inserted.pr_number == NULL and not automated and (r1.message or ""):find("doesn't move", 1, true))
local r2 = report("https://gitlab.example.com/acme/web/-/merge_requests/3")
check("a GitLab merge request: recorded, not followed", r2 and r2.tracked == false and not automated)
repo_url = "https://github.com/acme/web.git"
local r3 = report("https://github.com/Acme/Web/pull/8")
check("the project's repository: followed, task moved", r3 and r3.tracked == true and inserted.pr_number == 8
    and automated)
local _, st = report("https://github.com/else/where/pull/1")
check("another repository: refused (422)", st == 422)

print("S3: the step-up never takes TEST_OTP_CODE")
local real_getenv = os.getenv
os.getenv = function(k) -- luacheck: ignore 122
    if k == "OPSAPI_DEPLOY_ENV" then return "dev" end
    if k == "TEST_OTP_CODE" then return "424242" end
    return real_getenv(k)
end
package.loaded["helper.mail"] = {}
package.loaded["helper.auth-throttle"] = { key = function() return "k" end, blocked = function() return false end,
    hit = function() end, OTP_FAIL = { window = 60 }, OTP_SEND = { window = 60 } }
handler = function() return {} end
local OTP = require("helper.otp")
check("sign-in (non-production) still takes the test code", OTP.verify(1, "424242") == true)
check("the step-up option refuses it", OTP.verify(1, "424242", { no_test_bypass = true }) == false)
os.getenv = real_getenv -- luacheck: ignore 122
check("the terminal step-up passes the option", read("projects/ai-runner/ai_runner/terminal.lua")
    :find('verify(u.id, tostring(code or ""), { no_test_bypass = true })', 1, true) ~= nil)

print("S5: PR sign-off is scoped to the task")
local vsrc = read("projects/ai-runner/ai_runner/vault_pr.lua")
check("the UPDATE has the task in its WHERE",
    vsrc:find("WHERE namespace_id = ? AND task_uuid = ? AND uuid = ?", 1, true) ~= nil)
check("the route passes the task", read("projects/ai-runner/api/runs.lua")
    :find("V.review(ns, task.uuid, self.params.pr_uuid", 1, true) ~= nil)

print("W3 + W5 + W6: the work log")
local W = require("ai_runner.worklog")
log = {}
handler = function(sql)
    if sql:find("COUNT(*)", 1, true) then return { { n = 1001 } } end
    return {}
end
local evil = "50%_off'; DROP TABLE users; --"
local _, meta = W.list(7, { q = evil, state = "open", agent = "claude", terminal_uuid = TU }, 1, 50)
local count_q, list_q = log[1], log[2]
check("the count stops at 1001 rows", count_q and count_q.sql:find("LIMIT 1001", 1, true) ~= nil)
check("…and says so", meta.total == 1000 and meta.total_capped == true)
check("the search is a parameter, never in the SQL", list_q and not list_q.sql:find("DROP", 1, true)
    and not count_q.sql:find("DROP", 1, true))
local pattern
for _, a in ipairs(list_q.args) do if type(a) == "string" and a:find("DROP", 1, true) then pattern = a end end
check("…with its own % and _ matched literally", pattern == "%50\\%\\_off'; DROP TABLE users; --%", pattern)
check("terminal, state and agent filters, scoped to the workspace", list_q.sql:find("t.closed_at IS NULL", 1, true)
    and list_q.sql:find("t.agent = ?", 1, true)
    and list_q.sql:find("FROM ar_terminals WHERE namespace_id = ?", 1, true))
check("one row more than a page, for has_more", list_q.args[#list_q.args - 1] == 51)

log = {}
W.events({ id = 3 }, { after = "1 OR 1=1", type = "drop", q = "npm" })
check("a bad cursor and an unknown type are ignored", not log[1].sql:find("c.id = ?", 1, true)
    and not log[1].sql:find("e.type = ?", 1, true) and log[1].sql:find("e.text ILIKE ?", 1, true))
log = {}
W.events({ id = 3 }, { after = "42", type = "user_prompt" })
check("a cursor continues after that event, in this tab only", log[1].sql:find("c.id = ? AND c.tab_ref = ?", 1, true)
    and log[1].args[1] == 3 and log[1].sql:find("e.type = ?", 1, true))

log = {}
W.close_stale()
check("tabs of terminals that report each minute close after 10 minutes", log[1] and log[1].sql:find(
    "attached IS NOT NULL AND seen_at < NOW() - interval '600 seconds'", 1, true) ~= nil)
check("older terminals keep the 12-hour rule", log[1] and log[1].sql:find("interval '12 hours'", 1, true) ~= nil)

print("Menu: a plugin page listed twice shows once")
package.loaded["helper.project-config"] = { getProjectCode = function() return "all" end, PROJECT_FEATURES = {},
    PROJECT_MODULES = {} }
package.loaded["helper.project-loader"] = {
    getRegistered = function() return { { code = "ai_runner", name = "AI Runs", modules = {} } } end,
    getByCode = function() return { code = "ai_runner" } end,
}
package.loaded["queries.MenuQueries"] = nil
local M = require("queries.MenuQueries")
local items = {
    { key = "plugin:ai_runner:work-log", path = "/dashboard/ai-runner/work-log", module = "ai_runs", ns_enabled = true,
        priority = 94, settings = "{}" },
    { key = "plugin:ai_runner:work-log-team", path = "/dashboard/ai-runner/work-log", module = "ai_terminal_worklogs",
        ns_enabled = true, priority = 96, settings = "{}" },
}
handler = function() return items end
local function keys(perms, admin)
    local out = {}
    for _, i in ipairs(M.getForNamespace(7, perms, false, admin, "all")) do out[#out + 1] = i.key end
    return table.concat(out, ",")
end
check("both modules: one Work log", keys({ ai_runs = { "read" }, ai_terminal_worklogs = { "read" } })
    == "plugin:ai_runner:work-log")
check("only the work log module: the Work log", keys({ ai_terminal_worklogs = { "read" } })
    == "plugin:ai_runner:work-log-team")
check("only AI runs: the Work log", keys({ ai_runs = { "read" } }) == "plugin:ai_runner:work-log")
check("platform admin: one Work log", keys({}, true) == "plugin:ai_runner:work-log")
check("the manifest lists it for ai_terminal_worklogs", read("projects/ai-runner/project.lua")
    :find('module = "ai_terminal_worklogs",%s+icon = "ClipboardList", key = "work%-log%-team"') ~= nil)

print()
if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
