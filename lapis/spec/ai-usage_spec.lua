--[[
    Spec: every model call is metered (lib/agent/llm -> ai_usage), and the
    optional per-user daily token limit stops calls before they reach the model.

    Run inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/ai-usage_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path
local cjson = require("cjson.safe")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

ngx = { log = function() end, ERR = 3, time = os.time, now = os.time, update_time = function() end, ctx = {} } -- luacheck: ignore 111

local http_calls, used_today, insert_fails = 0, 0, false
local rows = {}
package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function()
                http_calls = http_calls + 1
                return { status = 200, body = cjson.encode({
                    message = { role = "assistant", content = "hi" }, prompt_eval_count = 120, eval_count = 7 }) }
            end,
        }
    end,
}
package.loaded["resty.jwt"] = { sign = function() return "eyJ.minted.sig" end }
package.loaded["lapis.db"] = {
    insert = function(tbl, row)
        if insert_fails then error("relation \"ai_usage\" does not exist") end
        row._table = tbl
        rows[#rows + 1] = row
    end,
    query = function() return { { used = used_today } } end,
}

local real_getenv = os.getenv
local function load_llm(env)
    os.getenv = function(k) return env[k] end -- luacheck: ignore 122
    package.loaded["lib.agent.llm"] = nil
    local Llm = require("lib.agent.llm")
    os.getenv = real_getenv -- luacheck: ignore 122
    return Llm
end
local HELLO = { { role = "user", content = "hello" } }

print("metering:")
local Llm = load_llm({ OLLAMA_URL = "http://ollama" })
ngx.ctx = { user = { uuid = "user-1" }, namespace_id = 7 }
local msg = Llm.chat(HELLO, nil, { usage = { feature = "tax_classify" } })
local r = rows[#rows]
check("a call writes one ai_usage row", #rows == 1 and r._table == "ai_usage", #rows)
check("user + workspace come from the request", r.user_uuid == "user-1" and r.namespace_id == 7)
check("tokens in/out from the provider", r.input_tokens == 120 and r.output_tokens == 7)
check("feature, provider, model, ok", r.feature == "tax_classify" and r.provider == "ollama"
    and r.model == "qwen3.8:latest" and r.ok == true and r.error == nil)
check("the reply still comes back", msg and msg.content == "hi")

Llm.chat(HELLO, nil, { usage = { feature = "assistant", user_uuid = "user-2", namespace_id = 9,
    scope = "timesheets", run_uuid = "run-1" } })
r = rows[#rows]
check("background runs pass their own attribution", r.user_uuid == "user-2" and r.namespace_id == 9
    and r.scope == "timesheets" and r.run_uuid == "run-1")

Llm.chat(HELLO, nil, { usage = { feature = "health_check", system = true } })
r = rows[#rows]
check("system calls (health checks) are billed to no one", r.user_uuid == nil and r.namespace_id == nil
    and r.feature == "health_check")

Llm.chat(HELLO, nil, {})
check("unlabelled calls are 'other'", rows[#rows].feature == "other")

insert_fails = true
msg = Llm.chat(HELLO, nil, {})
check("a failed usage write never fails the AI call", msg and msg.content == "hi")
insert_fails = false

package.loaded["resty.http"].new = function()
    return { set_timeout = function() end, request_uri = function() return nil, "timeout" end }
end
local before = #rows
local _, err = Llm.chat(HELLO, nil, {})
check("failed calls are recorded too (ok = false + error)", #rows == before + 1 and rows[#rows].ok == false
    and tostring(rows[#rows].error):find("timeout") ~= nil, err)

print("daily limit:")
Llm = load_llm({ OLLAMA_URL = "http://ollama", AI_USER_DAILY_TOKEN_LIMIT = "1000" })
package.loaded["resty.http"].new = function()
    return { set_timeout = function() end, request_uri = function()
        http_calls = http_calls + 1
        return { status = 200, body = cjson.encode({ message = { content = "hi" } }) }
    end }
end
ngx.ctx = { user = { uuid = "user-1" }, namespace_id = 7 }
used_today, http_calls = 999, 0
check("under the limit: the call goes through", Llm.chat(HELLO, nil, {}) ~= nil and http_calls == 1)
used_today, http_calls = 1000, 0
local m2, lerr, status = Llm.chat(HELLO, nil, {})
check("at the limit: refused before reaching the model", m2 == nil and http_calls == 0 and status == 429)
check("refusal says why", lerr == Llm.LIMIT_MESSAGE, lerr)
check("refusal is recorded", rows[#rows].ok == false and rows[#rows].error == "daily limit reached")
http_calls = 0
check("system calls ignore the limit", Llm.chat(HELLO, nil, { usage = { system = true } }) ~= nil and http_calls == 1)
Llm = load_llm({ OLLAMA_URL = "http://ollama" })
used_today, http_calls = 10 ^ 9, 0
check("no limit unless AI_USER_DAILY_TOKEN_LIMIT is set", Llm.chat(HELLO, nil, {}) ~= nil and http_calls == 1)

print("wiring:")
local function read(p)
    local f = io.open(p) or io.open("lapis/" .. p)
    local s = f and f:read("*a") or ""
    if f then f:close() end
    return s
end
local route = read("routes/chat-agent.lua")
check("assistant runs are metered per run", route:find('feature = "assistant"', 1, true)
    and route:find("run_uuid = job.run_uuid", 1, true))
check("the user sees the limit message, not 'unavailable'", route:find("err == Llm.LIMIT_MESSAGE", 1, true))
check("the health probe is a system call", read("lib/agent/agent.lua"):find('feature = "health_check", system = true', 1, true))
check("migration creates ai_usage", read("migrations.lua"):find("['zzw_ai_usage']", 1, true)
    and read("migrations.lua"):find("CREATE TABLE IF NOT EXISTS ai_usage", 1, true))
check("the limit env var reaches Lua", read("nginx.conf"):find("env AI_USER_DAILY_TOKEN_LIMIT;", 1, true))
local usage_routes = read("routes/ai-usage.lua")
check("workspace report needs activity.read", usage_routes:find('Http.guard("activity", "read"', 1, true))
check("platform report needs platform admin", usage_routes:find('requireRole("administrative"', 1, true))
check("reports load in every deployment", read("app.lua"):find('safe_load_routes("routes.ai-usage")', 1, true))

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
