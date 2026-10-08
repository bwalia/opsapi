--[[
    Spec: when the main AI provider fails, the request falls back (Ollama by
    default, AI_FALLBACK_PROVIDER / AI_FALLBACK_MODEL by env), a provider that
    is down is skipped for a minute, and the health check reports it.

    Run inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/ai-fallback_spec.lua
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

-- ngx with a shared dict (the breaker and the health-check cache).
local function dict()
    local d = {}
    return {
        get = function(_, k) return d[k] end,
        set = function(_, k, v) d[k] = v return true end,
        add = function(_, k, v) if d[k] ~= nil then return false end d[k] = v return true end,
        delete = function(_, k) d[k] = nil end,
    }
end
ngx = { log = function() end, ERR = 3, WARN = 4, time = os.time, now = os.time, update_time = function() end, -- luacheck: ignore 111
    ctx = {}, shared = { cache = dict(), locks = dict() } }

-- Scripted providers: URL substring -> list of responses (status, body) or "timeout".
local script, hits = {}, {}
package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function(_, url)
                for pattern, queue in pairs(script) do
                    if url:find(pattern, 1, true) then
                        hits[#hits + 1] = pattern
                        local r = table.remove(queue, 1) or queue.default
                        if r == "timeout" then return nil, "timeout" end
                        return { status = r.status or 200, body = cjson.encode(r.body) }
                    end
                end
                return nil, "no route for " .. url
            end,
        }
    end,
}
package.loaded["resty.jwt"] = { sign = function() return "eyJ.minted.sig" end }
local rows = {}
package.loaded["lapis.db"] = { insert = function(_, row) rows[#rows + 1] = row end, query = function() return {} end }

local real_getenv = os.getenv
local function load(env)
    os.getenv = function(k) return env[k] end -- luacheck: ignore 122
    package.loaded["lib.agent.llm"] = nil
    package.loaded["lib.agent.agent"] = nil
    local Llm = require("lib.agent.llm")
    os.getenv = real_getenv -- luacheck: ignore 122
    ngx.shared = { cache = dict(), locks = dict() }
    script, hits, rows = {}, {}, {}
    return Llm
end

local CLAUDE = { AI_PROVIDER = "anthropic", AI_API_KEY = "sk-ant", OLLAMA_URL = "https://ollama.example",
    OLLAMA_MODEL = "qwen3.8:latest", OLLAMA_API_KEY = "secret" }
local OK_CLAUDE = { body = { content = { { type = "text", text = "from claude" } }, usage = {} } }
local OK_OLLAMA = { body = { message = { content = "from ollama" } } }
local HELLO = { { role = "user", content = "hi" } }

print("configuration:")
local Llm = load(CLAUDE)
check("fallback defaults to Ollama", Llm.fallback and Llm.fallback.provider == "ollama"
    and Llm.fallback.model == "qwen3.8:latest" and Llm.fallback.url == "https://ollama.example")
local env2 = {}
for k, v in pairs(CLAUDE) do env2[k] = v end
env2.AI_FALLBACK_MODEL = "llama3.3:70b"
check("AI_FALLBACK_MODEL picks the fallback model", load(env2).fallback.model == "llama3.3:70b")
env2.AI_FALLBACK_PROVIDER = "none"
check("AI_FALLBACK_PROVIDER=none turns it off", load(env2).fallback == nil)
env2.AI_FALLBACK_PROVIDER, env2.AI_FALLBACK_MODEL, env2.OPENAI_API_KEY, env2.OPENAI_MODEL = "openai", nil, "sk-oa", "gpt-x"
local f = load(env2).fallback
check("any provider can be the fallback", f and f.provider == "openai" and f.model == "gpt-x")
check("Ollama main + Ollama fallback = no fallback (same model)",
    load({ OLLAMA_URL = "https://ollama.example", OLLAMA_MODEL = "m" }).fallback == nil)
check("no fallback when Ollama isn't configured", load({ AI_PROVIDER = "anthropic", AI_API_KEY = "k" }).fallback == nil)

print("falling back:")
Llm = load(CLAUDE)
script = { ["api.anthropic.com"] = { OK_CLAUDE }, ["ollama.example"] = { OK_OLLAMA } }
local msg = Llm.chat(HELLO, nil, {})
check("healthy main provider answers; fallback untouched", msg.content == "from claude" and #hits == 1
    and not msg.fallback)

for _, case in ipairs({
    { "timeout", "timeout" }, { "500", { status = 500, body = { error = { message = "boom" } } } },
    { "529 overloaded", { status = 529, body = { error = { message = "Overloaded" } } } },
    { "429 rate limit", { status = 429, body = { error = { message = "rate" } } } },
    { "401 bad key", { status = 401, body = { error = { message = "invalid x-api-key" } } } },
}) do
    Llm = load(CLAUDE)
    script = { ["api.anthropic.com"] = { case[2] }, ["ollama.example"] = { OK_OLLAMA } }
    msg = Llm.chat(HELLO, nil, {})
    check(case[1] .. " -> answered by the Ollama fallback", msg and msg.content == "from ollama" and msg.fallback
        and msg.model == "qwen3.8:latest", msg and msg.content)
end
check("both attempts are metered", #rows == 2 and rows[1].provider == "anthropic" and rows[1].ok == false
    and rows[2].provider == "ollama" and rows[2].ok == true)

print("circuit breaker:")
Llm = load(CLAUDE)
script = { ["api.anthropic.com"] = { "timeout", OK_CLAUDE }, ["ollama.example"] = { default = OK_OLLAMA } }
Llm.chat(HELLO, nil, {})
hits = {}
msg = Llm.chat(HELLO, nil, {})
check("a down provider is skipped: straight to the fallback", msg.content == "from ollama" and #hits == 1
    and hits[1] == "ollama.example")
msg = Llm.chat(HELLO, nil, { no_fallback = true })
check("the health check still tries the main provider", msg and msg.content == "from claude")
hits = {}
script["api.anthropic.com"] = { OK_CLAUDE }
msg = Llm.chat(HELLO, nil, {})
check("...and its success re-opens it for everyone", msg.content == "from claude" and hits[1] == "api.anthropic.com")

Llm = load(CLAUDE)
script = { ["api.anthropic.com"] = { { status = 400, body = { error = { message = "prompt too long" } } }, OK_CLAUDE },
    ["ollama.example"] = { OK_OLLAMA } }
msg = Llm.chat(HELLO, nil, {})
check("a 400 (this request) still falls back...", msg.content == "from ollama")
hits = {}
msg = Llm.chat(HELLO, nil, {})
check("...but doesn't mark the provider down", msg.content == "from claude" and hits[1] == "api.anthropic.com")

print("edges:")
Llm = load(CLAUDE)
script = { ["api.anthropic.com"] = { "timeout" }, ["ollama.example"] = { "timeout" } }
local _, err = Llm.chat(HELLO, nil, {})
check("both down: one clear error naming both", err and err:find("fallback qwen3.8:latest also failed", 1, true),
    err)
Llm = load(CLAUDE)
script = { ["api.anthropic.com"] = { "timeout" }, ["ollama.example"] = { OK_OLLAMA } }
_, err = Llm.chat(HELLO, nil, { no_fallback = true })
check("no_fallback: the main provider's own result", err and #hits == 1)
Llm = load({ OLLAMA_URL = "https://ollama.example", OLLAMA_API_KEY = "s" })
script = { ["ollama.example"] = { { body = { message = { content = "", tool_calls = {
    { ["function"] = { name = "a", arguments = {} } }, { ["function"] = { name = "b", arguments = {} } } } } } },
    { body = { message = { content = "", tool_calls = { { ["function"] = { name = "c", arguments = {} } } } } } } } }
local m1 = Llm.chat(HELLO, nil, {})
local m2 = Llm.chat(HELLO, nil, {})
check("Ollama tool-call ids are unique across calls (a mixed run is valid for Claude)",
    m1.tool_calls[1].id ~= m1.tool_calls[2].id and m2.tool_calls[1].id ~= m1.tool_calls[1].id
    and m2.tool_calls[1].id ~= m1.tool_calls[2].id)

print("health check:")
Llm = load(CLAUDE)
local Agent = require("lib.agent.agent")
script = { ["api.anthropic.com"] = { { status = 401, body = { error = { message = "invalid x-api-key" } } } },
    ["ollama.example"] = { OK_OLLAMA } }
local st = Agent.status()
check("main down + fallback up: amber, fallback model, says why", st.status == "slow" and st.fallback == true
    and st.model == "qwen3.8:latest" and st.reason:find("claude-opus-5-5 is unavailable", 1, true), cjson.encode(st))
check("cached against the main model (not re-probed every poll)", Agent.status().checked_at == st.checked_at
    and #hits == 2)
Llm = load(CLAUDE)
Agent = require("lib.agent.agent")
script = { ["api.anthropic.com"] = { OK_CLAUDE } }
st = Agent.status()
check("healthy main model: reported as itself", st.status ~= "down" and st.model == "claude-opus-5-5"
    and not st.fallback)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
