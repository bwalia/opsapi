--[[
    Spec: workspace AI providers (lib/ai-providers.lua) and the model client
    (lib/agent/llm.lua) after the October 2026 review:
      - SSRF: public addresses only, OPSAPI_AI_PRIVATE_HOSTS allow-list,
        link-local / cloud metadata always refused, and the connection goes to
        the address that was checked (no DNS rebinding)
      - failures are short reasons, never the server's own text (/test,
        last_error, JobShout)
      - a workspace provider never falls back to the platform's model, and
        has its own circuit breaker
      - TLS verified by default (AI_TLS_VERIFY=false for local dev)
      - every Llm.chat has a total time budget, streaming and fallback included
      - local workspace servers are streamed (OpenAI SSE)
      - the shared platform model only runs allow-listed models
      - a missing OPENSSL_SECRET_KEY is a validation error, not a 500

    Run from the repo root (what CI does):
        luajit lapis/spec/ai-providers-guard_spec.lua
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

local b64 = require("spec.fixtures.openssl")
local function dict()
    local d = {}
    return {
        get = function(_, k) return d[k] end,
        set = function(_, k, v) d[k] = v return true end,
        add = function(_, k, v) if d[k] ~= nil then return false end d[k] = v return true end,
        delete = function(_, k) d[k] = nil end,
    }
end
local clock, phase = 1000, "content"
ngx = { log = function() end, ERR = 3, WARN = 4, INFO = 6, ctx = {}, shared = { cache = dict() }, -- luacheck: ignore 111
    now = function() return clock end, time = function() return math.floor(clock) end, update_time = function() end,
    get_phase = function() return phase end, escape_uri = function(s) return s end,
    encode_base64 = b64.encode_base64, decode_base64 = b64.decode_base64 }

-- DNS: host -> address (what resty.dns.resolver answers).
local dns = {}
package.loaded["resty.dns.resolver"] = { new = function()
    return { TYPE_A = 1, query = function(_, host)
        if not dns[host] then return { errcode = 3, errstr = "name error" } end
        return { { address = dns[host] } }
    end }
end }

-- HTTP: respond(url, req) is swapped per test; every request is kept.
local requests, respond = {}, nil
package.loaded["resty.http"] = require("spec.fixtures.fake-http")(function(url, req)
    req.url = url
    requests[#requests + 1] = req
    return respond(url, req)
end)
package.loaded["resty.jwt"] = { sign = function() return "eyJ.minted.sig" end }

-- DB: provider rows by uuid; updates kept.
local providers, updates = {}, {}
package.loaded["lapis.db"] = {
    NULL = setmetatable({}, { __tostring = function() return "NULL" end }),
    raw = function(s) return s end,
    query = function(sql, _, uuid)
        if sql:find("FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", 1, true) then
            return { providers[uuid] }
        end
        return {}
    end,
    insert = function(tbl, row) return { row } end,
    update = function(tbl, vals) updates[#updates + 1] = { tbl = tbl, vals = vals } end,
}

local ENV = {}
os.getenv = function(k) return ENV[k] end -- luacheck: ignore 122
local function fresh(env)
    ENV = env
    for _, m in ipairs({ "lib.agent.llm", "lib.ai-providers", "lib.jobshout-client", "lib.outbound-webhooks" }) do
        package.loaded[m] = nil
    end
    ngx.shared.cache = dict()
    requests, updates, clock, phase = {}, {}, 1000, "content"
    return require("lib.agent.llm"), require("lib.ai-providers")
end

local function json(status, body) return function() return { status = status, body = cjson.encode(body) } end end
local OK_OPENAI = json(200, { choices = { { message = { content = "ok" } } }, usage = { prompt_tokens = 3 } })
local OK_CLAUDE = json(200, { content = { { type = "text", text = "from claude" } }, usage = {} })
local OK_OLLAMA = json(200, { message = { content = "from ollama" } })
local HELLO = { { role = "user", content = "hi" } }
local UUID = "11111111-2222-3333-4444-555555555555"

local function row(t)
    local r = { id = 1, uuid = UUID, name = "Mine", enabled = true, is_local = false, options = "{}", models = "[]" }
    for k, v in pairs(t) do r[k] = v end
    providers[r.uuid] = r
    return r
end

print("SSRF guard:")
local Llm, P = fresh({})
dns["api.example.com"], dns["evil.example.com"], dns["ollama.lan"], dns["meta.lan"] =
    "93.184.216.34", "10.0.0.7", "192.168.1.50", "169.254.169.254"
local t = P.target("https://api.example.com/v1")
check("public https host: allowed, pinned to the address it resolved to", t and t.ip == "93.184.216.34"
    and t.host == "api.example.com")
local _, err = P.target("https://evil.example.com/v1")
check("public name resolving to a private address: refused", err and err:find("private address", 1, true), err)
check("...without echoing the internal address", err and not err:find("10.0.0.7", 1, true), err)
_, err = P.target("http://api.example.com/v1")
check("plain http to a public host: refused", err and err:find("https", 1, true), err)
_, err = P.target("http://ollama.lan:11434/v1")
check("a LAN model server isn't allowed by default", err ~= nil and err:find("OPSAPI_AI_PRIVATE_HOSTS", 1, true), err)
check("url_ok keeps its yes/no contract (plugins use it)", P.url_ok("https://api.example.com") == true
    and P.url_ok("http://ollama.lan:11434") == nil)

Llm, P = fresh({ OPSAPI_AI_PRIVATE_HOSTS = "ollama.lan:11434, Meta.lan" })
t = P.target("http://ollama.lan:11434/v1")
check("OPSAPI_AI_PRIVATE_HOSTS host:port: allowed (http too)", t and t.ip == "192.168.1.50", err)
_, err = P.target("http://ollama.lan:5432/")
check("...only on the listed port (not Postgres on the same box)", err ~= nil, err)
_, err = P.target("http://meta.lan/latest/meta-data")
check("a listed host that resolves to link-local (cloud metadata): still refused", err ~= nil, err)
_, err = P.target("http://evil.example.com/")
check("hosts not listed stay public-only", err ~= nil, err)

Llm, P = fresh({ OPSAPI_AI_ALLOW_PRIVATE = "true" })
check("OPSAPI_AI_ALLOW_PRIVATE (dev): private addresses allowed", P.target("http://10.1.2.3:8080/v1") ~= nil)
_, err = P.target("http://169.254.169.254/latest/meta-data")
check("...but never link-local / metadata", err ~= nil, err)
check("startup warns when it is set", (function()
    local warned = false
    local log = ngx.log
    ngx.log = function(level, ...) if level == ngx.WARN and table.concat({ ... }):find("OPSAPI_AI_ALLOW_PRIVATE") then
        warned = true end end
    package.loaded["lib.ai-providers"] = nil
    require("lib.ai-providers")
    ngx.log = log
    return warned
end)())

print("workspace provider calls:")
Llm, P = fresh({ AI_PROVIDER = "anthropic", AI_API_KEY = "sk-platform", OLLAMA_URL = "https://ollama.example",
    OLLAMA_MODEL = "qwen3.8:latest", OPSAPI_AI_PRIVATE_HOSTS = "ollama.lan:11434" })
local r = row({ provider_type = "openai_compatible", base_url = "http://ollama.lan:11434/v1", default_model = "llama" })
local cfg = P.cfg(r)
check("cfg marks it as the workspace's (uuid) with a vetted URL", cfg.workspace_provider == UUID and cfg.user_url)
respond = OK_OPENAI
local msg = Llm.chat(HELLO, nil, { cfg = cfg })
check("connects to the address that was checked; Host stays the name", msg and requests[1].connect.host == "192.168.1.50"
    and requests[1].connect.ssl_server_name == "ollama.lan" and requests[1].headers.Host == "ollama.lan:11434")
dns["ollama.lan"] = "169.254.169.254" -- re-pointed after it was saved
requests = {}
local none, rerr = Llm.chat(HELLO, nil, { cfg = cfg })
check("DNS re-pointed at metadata after saving: refused on the call", none == nil and #requests == 0, rerr)
dns["ollama.lan"] = "192.168.1.50"

print("no fallback, own breaker:")
requests = {}
respond = function(url)
    if url:find("ollama.lan", 1, true) then return { status = 500, body = "boom" } end
    return OK_OLLAMA()
end
none = Llm.chat(HELLO, nil, { cfg = cfg })
check("a failing workspace provider is NOT retried on the platform's fallback", none == nil and #requests == 1
    and requests[1].url:find("ollama.lan", 1, true))
-- The platform's own model goes down: its breaker opens...
respond = function(url)
    if url:find("api.anthropic.com", 1, true) then return nil, "timeout" end
    return OK_OLLAMA()
end
Llm.chat(HELLO, nil, {})
-- ...a workspace's Anthropic key (same provider + model) works: it must not re-open the platform's breaker.
local ws = P.cfg(row({ uuid = "99999999-2222-3333-4444-555555555555", provider_type = "anthropic",
    default_model = Llm.default.model, base_url = "https://api.example.com" }))
respond = OK_CLAUDE
check("workspace call with the same provider/model answers", Llm.chat(HELLO, nil, { cfg = ws, no_fallback = true }) ~= nil)
requests = {}
respond = function(url) return url:find("ollama.example", 1, true) and OK_OLLAMA() or OK_CLAUDE() end
msg = Llm.chat(HELLO, nil, {})
check("...and the platform's breaker is still open (its own key)", msg and msg.fallback and #requests == 1
    and requests[1].url:find("ollama.example", 1, true), msg and msg.content)

print("TLS:")
Llm, P = fresh({ AI_PROVIDER = "anthropic", AI_API_KEY = "k", AI_FALLBACK_PROVIDER = "none" })
respond = OK_CLAUDE
Llm.chat(HELLO, nil, {})
check("certificates verified by default", requests[1].connect.ssl_verify == true)
ENV.AI_TLS_VERIFY = "false"
Llm.chat(HELLO, nil, {})
check("AI_TLS_VERIFY=false turns it off (local dev)", requests[2].connect.ssl_verify == false)
local src = io.open("lapis/lib/llm-client.lua"):read("*a")
check("embeddings follow the same switch", not src:find("ssl_verify = false", 1, true)
    and select(2, src:gsub("ssl_verify = Llm.tls_verify%(%)", "")) == 3)

print("total time budget:")
-- A model that streams slowly: the reply arrives after `secs` (the clock moves while it "streams").
local function slow(secs, answer)
    return function(url, req)
        clock = clock + secs
        return answer(url, req)
    end
end
Llm, P = fresh({ AI_PROVIDER = "anthropic", AI_API_KEY = "k", AI_FALLBACK_PROVIDER = "none" })
respond = slow(130, OK_CLAUDE)
none, rerr = Llm.chat(HELLO, nil, {})
check("serving a request: 2 min in total by default, even while streaming", none == nil
    and tostring(rerr):find("timeout", 1, true), rerr)
respond = slow(100, OK_CLAUDE)
check("an answer inside the budget is kept", Llm.chat(HELLO, nil, {}) ~= nil)
phase = "timer"
respond = slow(200, OK_CLAUDE)
check("background work (timers): 5 min by default", Llm.chat(HELLO, nil, {}) ~= nil)
phase = "content"
respond = slow(40, OK_CLAUDE)
check("timeout_ms is the caller's total", Llm.chat(HELLO, nil, { timeout_ms = 30000 }) == nil)
Llm, P = fresh({ AI_PROVIDER = "anthropic", AI_API_KEY = "k", OLLAMA_URL = "https://ollama.example" })
respond = function(url)
    if url:find("api.anthropic.com", 1, true) then clock = clock + 90 return OK_CLAUDE() end
    clock = clock + 10
    return OK_OLLAMA()
end
local started = clock
msg = Llm.chat(HELLO, nil, {})
check("a slow main provider leaves a third of the budget to the fallback", msg and msg.fallback
    and clock - started <= 120, msg and msg.content)
local agent_src = io.open("lapis/lib/agent/agent.lua"):read("*a")
local route_src = io.open("lapis/routes/chat-agent.lua"):read("*a")
check("an assistant run has its own budget, under the stale cutoff",
    agent_src:find("Agent.RUN_SECONDS = 15 * 60", 1, true) and agent_src:find("math.min(Llm.TIMEOUT_MS, left_ms)", 1, true)
    and route_src:find("local STALE_SECONDS = 2 * Agent.RUN_SECONDS", 1, true))

print("streaming local servers (OpenAI SSE):")
Llm, P = fresh({ OPSAPI_AI_PRIVATE_HOSTS = "ollama.lan" })
cfg = P.cfg(row({ provider_type = "ollama", base_url = "http://ollama.lan:11434/v1", default_model = "qwen" }))
respond = function()
    return { status = 200, body = table.concat({
        'data: {"choices":[{"delta":{"content":"Hello "}}]}',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"call_api","arguments":"{\\"pa"}}]}}]}',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"/x\\"}"}}]}}]}',
        'data: {"choices":[{"delta":{"content":"there"}}]}',
        'data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4}}',
        "data: [DONE]", "" }, "\n\n") }
end
msg = Llm.chat(HELLO, nil, { cfg = cfg })
local sent = cjson.decode(requests[#requests].body)
check("asks for a stream with usage", sent.stream == true and sent.stream_options.include_usage == true)
check("pieces joined", msg and msg.content == "Hello there", msg and msg.content)
check("tool call fragments joined", msg and msg.tool_calls[1].id == "c1"
    and msg.tool_calls[1]["function"].arguments.path == "/x")
check("usage from the last chunk", msg and msg.usage.input == 11 and msg.usage.output == 4)
requests = {}
respond = function(_, req)
    if cjson.decode(req.body).stream then return { status = 400, body = '{"error":"stream_options not supported"}' } end
    return OK_OPENAI()
end
msg = Llm.chat(HELLO, nil, { cfg = cfg })
check("a server that refuses streaming: retried once, not streamed", msg and msg.content == "ok" and #requests == 2)
check("cloud APIs aren't streamed", P.TYPES.openai.stream == nil and P.TYPES.anthropic.stream == nil)

print("safe reasons:")
Llm, P = fresh({ OPSAPI_AI_PRIVATE_HOSTS = "ollama.lan" })
local bad = row({ provider_type = "openai_compatible", base_url = "http://ollama.lan:11434/v1", default_model = "m" })
respond = json(401, { error = { message = "Incorrect API key provided: sk-abc123SECRET. internal db=10.0.0.9" } })
local res, terr = P.test(7, bad)
check("/test: a classified reason", res == nil and terr == "Authentication failed (401) — check the API key", terr)
check("last_error stores the reason, never the server's words", updates[#updates].vals.last_error == terr
    and not tostring(updates[#updates].vals.last_error):find("SECRET", 1, true))
respond = function() return nil, "timeout" end
check("timeouts", select(2, P.test(7, bad)) == "Timed out")
respond = function() return nil, "connection refused" end
check("unreachable", select(2, P.test(7, bad)) == "Couldn't connect")
respond = json(404, { error = "model 'x' not found" })
check("unknown model", select(2, P.test(7, bad)):find("^Not found %(404%)") ~= nil)
local _, cerr, attempts = P.chat(7, { { provider_uuid = UUID } }, HELLO, nil, {})
check("Providers.chat attempts carry the reason + status (plugins show them)", attempts[1].status == 404
    and not attempts[1].error:find("model 'x'", 1, true) and not cerr:find("model 'x'", 1, true), cerr)

print("JobShout:")
Llm, P = fresh({})
local JobShout = require("lib.jobshout-client")
local js = row({ uuid = "33333333-2222-3333-4444-555555555555", provider_type = "jobshout",
    base_url = "https://api.example.com/api/v1", username = "svc@x" })
js.secret_sealed = nil
ENV.OPENSSL_SECRET_KEY = "k"
js.secret_sealed = require("helper.secret-box").seal("jsk_orgkey", "ai_provider")
respond = function() return { status = 500, body = '{"error":"pq: password authentication failed for user admin"}' } end
local agents, aerr = JobShout.agents(7, js)
check("an upstream error body is never returned", agents == nil and not aerr:find("pq:", 1, true)
    and aerr == "JobShout: The server had an error (HTTP 500)", aerr)
respond = function() return nil, "connect() failed (111: Connection refused)" end
agents, aerr = JobShout.agents(7, js)
check("socket errors are a category too", aerr == "JobShout: Couldn't connect", aerr)
check("JobShout connects to the checked address", requests[#requests].connect.host == "93.184.216.34")

print("platform model allow-list:")
Llm, P = fresh({ OLLAMA_URL = "https://ollama.example", OLLAMA_MODEL = "qwen3.8:latest", OPENSSL_SECRET_KEY = "k" })
local _, errors = P.save(7, "actor", { name = "Shared", provider_type = "platform", default_model = "llama3.1:405b" })
check("default: only the platform's own model", errors and errors.default_model
    and errors.default_model:find("qwen3.8:latest", 1, true), cjson.encode(errors))
ENV.AI_PLATFORM_MODELS = "qwen3.8:latest, qwen3.8:4b"
_, errors = P.save(7, "actor", { name = "Shared", provider_type = "platform", default_model = "qwen3.8:4b" })
check("AI_PLATFORM_MODELS widens it", errors == nil, cjson.encode(errors))
_, errors = P.save(7, "actor", { name = "Shared", provider_type = "platform", models = { "qwen3.8:4b", "big:70b" } })
check("every listed model is checked", errors and errors.default_model ~= nil)
local pr = row({ uuid = "44444444-2222-3333-4444-555555555555", provider_type = "platform", default_model = "big:70b" })
local pcfg, perr = P.cfg(pr)
check("a stored row with a model no longer offered can't be used", pcfg == nil and perr:find("big:70b", 1, true), perr)
pcfg = P.cfg(pr, "qwen3.8:4b")
check("platform rows don't fall back either", pcfg and pcfg.workspace_provider == pr.uuid and not pcfg.user_url)

print("secrets without OPENSSL_SECRET_KEY:")
Llm, P = fresh({ OPSAPI_AI_PRIVATE_HOSTS = "ollama.lan" })
local ok, saved, serrs = pcall(P.save, 7, "actor", { name = "K", provider_type = "openai_compatible",
    base_url = "http://ollama.lan:11434/v1", secret = "sk-1" })
check("saving a key: a validation error, not a 500", ok and saved == nil and serrs.secret ~= nil, tostring(saved))
ENV.OPENSSL_SECRET_KEY = "k"
local sealed_row = row({ provider_type = "openai_compatible", base_url = "http://ollama.lan:11434/v1",
    default_model = "m", secret_sealed = require("helper.secret-box").seal("sk-1", "ai_provider") })
ENV.OPENSSL_SECRET_KEY = nil
local okc, c2, cerr2 = pcall(P.cfg, sealed_row)
check("using it: provider unavailable (nil + why), never the key unsealed", okc and c2 == nil and cerr2 ~= nil, cerr2)
check("the assistant route degrades instead of 500ing", route_src:find("pcall(Providers.cfg, row)", 1, true)
    and route_src:find("if cfg == false then", 1, true))

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
