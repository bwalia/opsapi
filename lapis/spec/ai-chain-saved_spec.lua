--[[
    Spec: the platform AI chain saved from the dashboard (ai_chain_settings →
    lib/agent/llm.lua "Saved chains", queries/AiChainQueries.lua), plus the
    fixes that came with it:
      - no saved chain: the env order is unchanged
      - a saved "default" chain is the WHOLE try-order (it can put Bedrock first)
      - a feature's saved chain beats the saved default; an env per-feature
        chain beats the saved default too
      - a call that asked for its own model (vision) only follows its feature's chain
      - disabled / unconfigured hops are skipped; a hop may run another model
      - workspace providers and no_fallback calls never follow a saved chain
      - a save bumps the version, so every worker re-reads at once
      - AiChainQueries.validate refuses unknown names, duplicates, no enabled hop
      - embeddings ignore a request's chat provider (vector(384) stays valid)
      - a workspace "bedrock" provider is native (Converse + a Bedrock API key)

    Run from the repo root (what CI does):
        luajit lapis/spec/ai-chain-saved_spec.lua
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

local function dict()
    local d = {}
    return {
        get = function(_, k) return d[k] end,
        set = function(_, k, v) d[k] = v return true end,
        add = function(_, k, v) if d[k] ~= nil then return false end d[k] = v return true end,
        incr = function(_, k, n, init) d[k] = (d[k] or init or 0) + n return d[k] end,
        delete = function(_, k) d[k] = nil end,
    }
end
local b64 = require("spec.fixtures.openssl")
-- luacheck: ignore 111 112
ngx = { log = function() end, ERR = 3, WARN = 4, INFO = 6, ctx = {}, shared = { cache = dict() },
    now = function() return 1000 end, time = function() return 1000 end, update_time = function() end,
    get_phase = function() return "content" end, escape_uri = function(s) return s end,
    encode_base64 = b64.encode_base64, decode_base64 = b64.decode_base64 }

local dns = { ["bedrock-runtime.eu-west-2.amazonaws.com"] = "52.94.1.1" }
package.loaded["resty.dns.resolver"] = { new = function()
    return { TYPE_A = 1, query = function(_, host)
        if not dns[host] then return { errcode = 3, errstr = "name error" } end
        return { { address = dns[host] } }
    end }
end }

-- HTTP: answered by host; a host in `down` fails with 503.
local requests, down = {}, {}
local OK = {
    ["ollama.example"] = { message = { content = "from ollama" } },
    ["bedrock-runtime.eu-west-2.amazonaws.com"] = { output = { message = { role = "assistant",
        content = { { text = "from bedrock" } } } }, usage = { inputTokens = 5, outputTokens = 1 } },
    ["api.anthropic.com"] = { content = { { type = "text", text = "from claude" } }, usage = {} },
    ["api.openai.com"] = { choices = { { message = { content = "from openai" } } } },
}
package.loaded["resty.http"] = require("spec.fixtures.fake-http")(function(url, req)
    req.url = url
    requests[#requests + 1] = req
    local host = url:match("^%a+://([^/:]+)")
    if down[host] then return { status = 503, body = cjson.encode({ error = { message = "down" } }) } end
    if OK[host] then return { status = 200, body = cjson.encode(OK[host]) } end
    return nil, "no route for " .. url
end)
package.loaded["resty.jwt"] = { sign = function() return "eyJ.minted.sig" end }
package.loaded["helper.secret-box"] = {
    seal = function(s) return "sealed:" .. s end, open = function() return "ws-bedrock-key" end,
    hint = function() return "…key" end,
}

-- DB: ai_chain_settings rows by scope (+ the workspace provider rows the guard spec uses).
local saved, table_exists, providers = {}, true, {}
package.loaded["lapis.db"] = {
    NULL = setmetatable({}, { __tostring = function() return "NULL" end }),
    raw = function(s) return s end,
    query = function(sql, a, b, c)
        if sql:find("to_regclass('ai_chain_settings')", 1, true) then return { { present = table_exists } } end
        if sql:find("DELETE FROM ai_chain_settings", 1, true) then
            saved[a] = nil
            return {}
        end
        if sql:find("SELECT", 1, true) and sql:find("FROM ai_chain_settings", 1, true) then
            local out = {}
            for scope, r in pairs(saved) do
                out[#out + 1] = { scope = scope, hops = r.hops, updated_by = r.updated_by, updated_at = "now" }
            end
            return out
        end
        if sql:find("INSERT INTO ai_chain_settings", 1, true) then
            saved[a] = { hops = b, updated_by = c }
            return {}
        end
        if sql:find("FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", 1, true) then
            return { providers[b] }
        end
        return {}
    end,
    insert = function(_, row) return { row } end,
    update = function() end,
}

local ENV = {}
os.getenv = function(k) return ENV[k] end -- luacheck: ignore 122
local Llm, Q
local function fresh(env, chains)
    ENV = env
    for _, m in ipairs({ "lib.agent.llm", "lib.ai-providers", "lib.outbound-webhooks", "queries.AiChainQueries",
        "lib.llm-client" }) do
        package.loaded[m] = nil
    end
    ngx.shared.cache = dict()
    saved, requests, down, table_exists = {}, {}, {}, true
    for scope, hops in pairs(chains or {}) do saved[scope] = { hops = cjson.encode(hops) } end
    Llm = require("lib.agent.llm")
    Q = require("queries.AiChainQueries")
    return Llm
end
local function hosts()
    local out = {}
    for i, r in ipairs(requests) do out[i] = r.url:match("^%a+://([^/:]+)") end
    return table.concat(out, ",")
end
local HELLO = { { role = "user", content = "hi" } }

local BASE = {
    OLLAMA_URL = "https://ollama.example", OLLAMA_MODEL = "qwen3.8:latest",
    AWS_BEARER_TOKEN_BEDROCK = "br-platform-key", BEDROCK_REGION = "eu-west-2",
    BEDROCK_MODEL = "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
    ANTHROPIC_API_KEY = "sk-ant", AI_FALLBACK_PROVIDER = "none",
}
local function with(extra)
    local t = {}
    for k, v in pairs(BASE) do t[k] = v end
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

print("no saved chain:")
fresh(with())
local msg = Llm.chat(HELLO, nil, { usage = { feature = "tax_classify" } })
check("the env's main model answers (qwen on Ollama)",
    msg and msg.content == "from ollama" and hosts() == "ollama.example", hosts())
fresh(with(), {})
table_exists = false
msg = Llm.chat(HELLO, nil, {})
check("a deployment without the table yet: env order, no error", msg and msg.content == "from ollama")

print("saved default chain:")
fresh(with(), { default = { { name = "bedrock" }, { name = "ollama" } } })
msg = Llm.chat(HELLO, nil, { usage = { feature = "assistant" } })
check("Bedrock is tried first, from the dashboard alone", msg and msg.content == "from bedrock", hosts())
check("...with the Bedrock API key as a bearer token",
    requests[1] and requests[1].headers.Authorization == "Bearer br-platform-key")
check("...and it's not reported as a fallback (it is the chain's first hop)", msg and not msg.fallback)
requests, down = {}, { ["bedrock-runtime.eu-west-2.amazonaws.com"] = true }
msg = Llm.chat(HELLO, nil, {})
check("Bedrock down: the next saved hop answers", msg and msg.content == "from ollama" and msg.fallback,
    hosts())
requests, down = {}, {}
msg = Llm.chat(HELLO, nil, {})
check("...then Bedrock is skipped while its circuit is open", msg and msg.content == "from ollama"
    and hosts() == "ollama.example", hosts())

print("per feature:")
fresh(with(), {
    default = { { name = "ollama" } },
    tax_classify = { { name = "bedrock", model = "eu.anthropic.claude-haiku-4-5-20251001-v1:0" },
        { name = "anthropic", enabled = false }, { name = "ollama" } },
})
msg = Llm.chat(HELLO, nil, { usage = { feature = "tax_classify" } })
check("tax_classify follows its own chain, not the default", msg and msg.content == "from bedrock", hosts())
check("...with the hop's own model (Haiku, not BEDROCK_MODEL)", requests[1] and requests[1].url:find("haiku", 1, true)
    and not requests[1].url:find("sonnet", 1, true), requests[1] and requests[1].url)
requests, down = {}, { ["bedrock-runtime.eu-west-2.amazonaws.com"] = true }
fresh(with(), {
    tax_classify = { { name = "bedrock" }, { name = "anthropic", enabled = false }, { name = "ollama" } },
})
down = { ["bedrock-runtime.eu-west-2.amazonaws.com"] = true }
msg = Llm.chat(HELLO, nil, { usage = { feature = "tax_classify" } })
check("a disabled hop is never called", msg and msg.content == "from ollama"
    and not hosts():find("anthropic", 1, true), hosts())
msg = Llm.chat(HELLO, nil, { usage = { feature = "crm" } })
check("other features keep the env order", msg and msg.content == "from ollama")

fresh(with({ AI_FALLBACK_CHAIN_BY_FEATURE = "tax_classify=anthropic" }), { default = { { name = "bedrock" } } })
msg = Llm.chat(HELLO, nil, { usage = { feature = "tax_classify" } })
check("an env per-feature chain beats the saved default", msg and msg.content == "from ollama", hosts())

fresh(with({ OPENAI_API_KEY = false }), { default = { { name = "openai" }, { name = "ollama" } } })
msg = Llm.chat(HELLO, nil, {})
check("an unconfigured hop (no key in the env) is skipped", msg and msg.content == "from ollama"
    and not hosts():find("openai", 1, true), hosts())

print("calls that pick their own model:")
fresh(with({ AI_VISION_PROVIDER = "anthropic" }), { default = { { name = "bedrock" } } })
msg = Llm.chat(HELLO, nil, { cfg = Llm.vision, usage = { feature = "statement_extract" } })
check("vision ignores the saved default (it may not see images)", msg and msg.content == "from claude", hosts())
fresh(with({ AI_VISION_PROVIDER = "anthropic" }), { statement_extract = { { name = "bedrock" } } })
msg = Llm.chat(HELLO, nil, { cfg = Llm.vision, usage = { feature = "statement_extract" } })
check("...but follows a chain saved for statement reading", msg and msg.content == "from bedrock", hosts())
msg = Llm.chat(HELLO, nil, { cfg = Llm.default, no_fallback = true, usage = { feature = "statement_extract" } })
check("no_fallback (health check, tests) talks to the model it was given", msg and msg.content == "from ollama")

print("saving:")
fresh(with(), {})
Llm.chat(HELLO, nil, {}) -- caches "nothing saved"
local overview = Q.save("default", { { name = "bedrock" }, { name = "ollama" } }, "admin@example.com")
check("save returns the overview", overview and overview.scopes and overview.scopes[1].saved == true)
requests = {}
msg = Llm.chat(HELLO, nil, {})
check("the next call already follows it (version bumped)", msg and msg.content == "from bedrock", hosts())
check("the effective order is reported per scope", overview.scopes[1].effective[1].name == "bedrock"
    and overview.scopes[1].source == "saved:default")
Q.reset("default")
requests = {}
msg = Llm.chat(HELLO, nil, {})
check("reset: back to the env order", msg and msg.content == "from ollama", hosts())

local _, err = Q.validate("default", { { name = "nope" } })
check("unknown model name refused", err and err:find("unknown model", 1, true), err)
_, err = Q.validate("default", { { name = "ollama" }, { name = "ollama" } })
check("the same model twice refused", err and err:find("already in the chain", 1, true), err)
local ok = Q.validate("default", { { name = "bedrock" }, { name = "bedrock", model = "eu.anthropic.claude-haiku" } })
check("...but one provider with two models is fine", ok and #ok == 2)
_, err = Q.validate("default", { { name = "ollama", enabled = false } })
check("at least one hop enabled", err and err:find("at least one", 1, true), err)
_, err = Q.validate("default", { { name = "ollama", model = "qwen; DROP TABLE" } })
check("a model must look like a model id", err and err:find("model id", 1, true), err)
_, err = Q.validate("nope", { { name = "ollama" } })
check("unknown scope refused", err and err:find("unknown scope", 1, true), err)
fresh(with({ AI_HOPS = cjson.encode({ vast1 = { provider = "openai", base_url = "https://vast1.example/v1",
    model = "qwen3-32b" } }) }))
local names = table.concat(Llm.known_hop_names(), ",")
check("custom AI_HOPS hosts appear in the catalogue", names:find("vast1", 1, true) ~= nil, names)

print("tax provider list + embeddings:")
fresh(with(), { tax_classify = { { name = "bedrock" }, { name = "ollama" } } })
local LLMClient = require("lib.llm-client")
local list = LLMClient.get_providers()
check("/tax/classify/providers lists the real order", list[1].id == "bedrock" and list[2].id == "ollama"
    and list[1].is_default == true, cjson.encode(list))
requests = {}
OK["ollama.example"].embedding = { 0.1, 0.2 }
local e = LLMClient.generate_embedding({ text = "Tesco", provider = "claude" })
check("an embedding asked for with provider=claude still uses the 384-dim embedder (Ollama)",
    e and requests[1] and requests[1].url:find("ollama.example/api/embeddings", 1, true), hosts())

print("workspace Bedrock provider (native):")
fresh(with(), { default = { { name = "ollama" } } })
local P = require("lib.ai-providers")
providers["11111111-2222-3333-4444-555555555555"] = { id = 1, uuid = "11111111-2222-3333-4444-555555555555",
    name = "Our Bedrock", provider_type = "bedrock", default_model = "eu.anthropic.claude-haiku-4-5-20251001-v1:0",
    options = cjson.encode({ region = "eu-west-2" }), secret_sealed = "sealed", enabled = true, models = "[]" }
local row = providers["11111111-2222-3333-4444-555555555555"]
local cfg, cerr = P.cfg(row)
check("Bedrock API key + region, no gateway URL needed", cfg and cfg.protocol == "bedrock"
    and cfg.url == "https://bedrock-runtime.eu-west-2.amazonaws.com" and cfg.key == "ws-bedrock-key", cerr)
requests = {}
msg = Llm.chat(HELLO, nil, { cfg = cfg })
check("...answers through Converse with the workspace's key, never the saved chain",
    msg and msg.content == "from bedrock" and requests[1].headers.Authorization == "Bearer ws-bedrock-key", hosts())
local _, errors = P.save(1, "me", { name = "B", provider_type = "bedrock", default_model = "m", secret = "k" })
check("no region and no gateway URL: a clear validation error", errors and errors.options
    and errors.options:find("region", 1, true), errors and cjson.encode(errors))
row.options = cjson.encode({ region = "eu-west-2.evil.example" })
_, cerr = P.cfg(row)
check("a region can't smuggle in another host", cerr and cerr:find("region", 1, true), cerr)

print(failures == 0 and "All checks passed." or (failures .. " check(s) failed."))
os.exit(failures == 0 and 0 or 1)
