--[[
    Spec: the LLM fallback CHAIN (lib/agent/llm.lua) and the cloud providers it can
    fall through to — AWS Bedrock (Converse, SigV4), Azure OpenAI, Google Vertex AI
    (service account -> OAuth token; Gemini + Claude on Vertex) and several named
    OpenAI-compatible hosts (e.g. two vast.ai boxes).

    Covers: chain parsing + order, unconfigured hops skipped (one INFO line),
    falling through on timeout / 5xx / 429, the per-hop circuit breaker, the time
    budget across N hops, tool-using calls skipping tool-less hops, per-feature
    chains, the legacy AI_FALLBACK_PROVIDER path, SigV4 against AWS's published
    test vectors, Azure URL + headers, the Vertex JWT assertion (token exchange
    mocked), and each provider's reply normalised into the one assistant-message
    shape, tool calls included. No network: resty.http is a fake.

    Needs luaossl + cjson (the API image has both). Run from the repo root:
        luajit lapis/spec/llm-fallback-chain_spec.lua
    or inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/llm-fallback-chain_spec.lua
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
        delete = function(_, k) d[k] = nil end,
    }
end
local clock, logs = 1000, {}
ngx = { ERR = 3, WARN = 4, INFO = 7, ctx = {}, shared = { cache = dict(), locks = dict() }, -- luacheck: ignore 111
    log = function(level, ...) logs[#logs + 1] = { level = level, text = table.concat({ ... }) } end,
    now = function() return clock end, time = function() return math.floor(clock) end, update_time = function() end,
    get_phase = function() return "content" end }

-- Scripted HTTP: URL substring -> queue of responses ({ status, body | raw } or "timeout"; .default repeats).
-- (Env values set to false below mean "unset": lib/agent/llm treats them like a missing variable.)
local script, reqs = {}, {}
package.loaded["resty.http"] = require("spec.fixtures.fake-http")(function(url, req)
    for pattern, queue in pairs(script) do
        if url:find(pattern, 1, true) then
            reqs[#reqs + 1] = { pattern = pattern, url = url, headers = req.headers, raw = req.body,
                body = cjson.decode(req.body or "") }
            local r = table.remove(queue, 1) or queue.default
            if type(r) == "function" then r = r(url, req) end
            if r == "timeout" then return nil, "timeout" end
            return { status = r.status or 200, body = r.raw or cjson.encode(r.body) }
        end
    end
    return nil, "no route for " .. url
end)
package.loaded["resty.jwt"] = { sign = function() return "eyJ.minted.sig" end }
package.loaded["lapis.db"] = { insert = function() end, query = function() return {} end }

local real_getenv = os.getenv
local function load(env)
    os.getenv = function(k) return env[k] end -- luacheck: ignore 122
    package.loaded["lib.agent.llm"] = nil
    logs = {}
    local Llm = require("lib.agent.llm")
    os.getenv = real_getenv -- luacheck: ignore 122
    ngx.shared = { cache = dict(), locks = dict() }
    script, reqs = {}, {}
    require("lib.agent.llm-auth").forget_tokens()
    return Llm
end
local function merged(a, b)
    local t = {}
    for k, v in pairs(a) do t[k] = v end
    for k, v in pairs(b or {}) do t[k] = v end
    return t
end
local function names(chain)
    local out = {}
    for i, c in ipairs(chain) do out[i] = c.name end
    return table.concat(out, ",")
end
local function patterns()
    local out = {}
    for i, r in ipairs(reqs) do out[i] = r.pattern end
    return table.concat(out, ",")
end

local LlmAuth = require("lib.agent.llm-auth")
local pkey = require("openssl.pkey")
local digest = require("openssl.digest")

-- A throwaway service account (generated per run; never a real key).
local RSA = pkey.new({ type = "RSA", bits = 2048 })
local SA = { type = "service_account", project_id = "demo-proj",
    client_email = "opsapi@demo-proj.iam.gserviceaccount.com",
    private_key = RSA:toPEM("private"), token_uri = "https://oauth2.googleapis.com/token" }

-- The owner's example: Ollama qwen first, then Bedrock, Azure, Vertex, two vast.ai hosts, Anthropic.
local FULL = {
    OLLAMA_URL = "https://ollama.example", OLLAMA_MODEL = "qwen3.8:latest", OLLAMA_API_KEY = "ollama-secret",
    AI_FALLBACK_CHAIN = "bedrock, azure,vertex,vast1,vast2,anthropic,bedrock",
    AWS_ACCESS_KEY_ID = "AKIDEXAMPLE", AWS_SECRET_ACCESS_KEY = "aws-secret-example", AWS_REGION = "eu-west-2",
    BEDROCK_MODEL = "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
    AZURE_OPENAI_ENDPOINT = "https://res.openai.azure.com/", AZURE_OPENAI_API_KEY = "azure-secret",
    AZURE_OPENAI_DEPLOYMENT = "gpt4o-prod",
    GCP_CREDENTIALS_JSON = cjson.encode(SA), GCP_LOCATION = "europe-west2", VERTEX_MODEL = "gemini-2.5-flash",
    AI_HOP_VAST1_PROVIDER = "openai", AI_HOP_VAST1_BASE_URL = "https://vast1.example:8000/v1",
    AI_HOP_VAST1_API_KEY = "vast1-secret", AI_HOP_VAST1_MODEL = "qwen3-32b",
    AI_HOPS = cjson.encode({ vast2 = { provider = "vllm", base_url = "https://vast2.example/v1",
        api_key = "vast2-secret", model = "llama-3.3-70b", tools = false } }),
    ANTHROPIC_API_KEY = "sk-ant-secret",
    OPENAI_API_KEY = "sk-openai-never-to-vast",
}
local HELLO = { { role = "user", content = "hi" } }
local TOOLS = { { type = "function", ["function"] = { name = "lookup", description = "Look up",
    parameters = { type = "object", properties = { q = { type = "string" } } } } } }
local OK = {
    ollama = { body = { message = { content = "from ollama" } } },
    bedrock = { body = { output = { message = { role = "assistant", content = { { text = "from bedrock" } } } },
        usage = { inputTokens = 11, outputTokens = 3 } } },
    azure = { body = { choices = { { message = { content = "from azure" } } } } },
    vertex = { body = { candidates = { { content = { role = "model", parts = { { text = "from vertex" } } } } },
        usageMetadata = { promptTokenCount = 7, candidatesTokenCount = 2 } } },
    vast1 = { body = { choices = { { message = { content = "from vast1" } } } } },
    vast2 = { body = { choices = { { message = { content = "from vast2" } } } } },
    anthropic = { body = { content = { { type = "text", text = "from claude" } }, usage = {} } },
    token = { body = { access_token = "ya29.test-token", expires_in = 3600 } },
}
local URL = { ollama = "ollama.example", bedrock = "bedrock-runtime.eu-west-2", azure = "res.openai.azure.com",
    vertex = "aiplatform.googleapis.com", vast1 = "vast1.example", vast2 = "vast2.example",
    anthropic = "api.anthropic.com", token = "oauth2.googleapis.com" }
local function route(map)
    script = {}
    for name, r in pairs(map) do script[URL[name]] = { default = r } end
    script[URL.token] = script[URL.token] or { default = OK.token }
end
local DOWN = { status = 503, body = { error = { message = "down" } } }

-- ---------------------------------------------------------------------------
print("chain configuration:")
-- ---------------------------------------------------------------------------
local Llm = load(FULL)
check("order kept, duplicates dropped", names(Llm.chain) == "bedrock,azure,vertex,vast1,vast2,anthropic",
    names(Llm.chain))
check("Llm.fallback = the first hop (dashboard footer)", Llm.fallback.name == "bedrock")
check("bedrock: standard AWS env, URL from the region",
    Llm.hops.bedrock.url == "https://bedrock-runtime.eu-west-2.amazonaws.com"
    and Llm.hops.bedrock.model == FULL.BEDROCK_MODEL)
check("azure: deployment URL + api-version + api-key header", Llm.hops.azure.chat_url
    == "https://res.openai.azure.com/openai/deployments/gpt4o-prod/chat/completions?api-version=2024-10-21"
    and Llm.hops.azure.headers["api-key"] == "azure-secret", Llm.hops.azure.chat_url)
check("vertex: project from the key, regional endpoint", Llm.hops.vertex.project == "demo-proj"
    and Llm.hops.vertex.url == "https://europe-west2-aiplatform.googleapis.com")
check("vast1 from AI_HOP_VAST1_* env", Llm.hops.vast1.provider == "openai" and Llm.hops.vast1.key == "vast1-secret"
    and Llm.hops.vast1.url == "https://vast1.example:8000/v1" and Llm.hops.vast1.model == "qwen3-32b")
check("vast2 from the AI_HOPS JSON (vllm = openai, tools=false)", Llm.hops.vast2.provider == "openai"
    and Llm.hops.vast2.key == "vast2-secret" and Llm.hops.vast2.tools == false)
check("a custom host never picks up OPENAI_API_KEY", Llm.hops.vast1.key ~= FULL.OPENAI_API_KEY
    and Llm.hops.vast2.key ~= FULL.OPENAI_API_KEY)
check("AI_HOP_<NAME>_* overrides AI_HOPS",
    load(merged(FULL, { AI_HOP_VAST2_MODEL = "other" })).hops.vast2.model == "other")
check("'none' = no fallback at all", #load(merged(FULL, { AI_FALLBACK_CHAIN = "none" })).chain == 0)

Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "bedrock,azure,ghost,vast3,vast1", AWS_REGION = false,
    AI_HOP_VAST3_PROVIDER = "openai" }))
check("unconfigured hops are skipped", names(Llm.chain) == "azure,vast1", names(Llm.chain))
local infos = {}
for _, l in ipairs(logs) do if l.level == ngx.INFO then infos[#infos + 1] = l.text end end
check("one INFO line per skipped hop, saying why", #infos == 3 and infos[1]:find("bedrock skipped: no region", 1, true)
    and infos[2]:find("ghost skipped: unknown provider", 1, true) and infos[3]:find("vast3", 1, true),
    table.concat(infos, " | "))
local secret_logged = false
for _, l in ipairs(logs) do
    for _, s in ipairs({ "aws-secret-example", "azure-secret", "vast1-secret", "PRIVATE KEY" }) do
        if l.text:find(s, 1, true) then secret_logged = true end
    end
end
check("nothing logged contains a key", not secret_logged)
check("enabled=false keeps a hop listed but unused",
    names(load(merged(FULL, { AI_HOP_AZURE_ENABLED = "false" })).chain) == "bedrock,vertex,vast1,vast2,anthropic")
check("a hop identical to the main model is skipped",
    names(load(merged(FULL, { AI_FALLBACK_CHAIN = "ollama,vast1" })).chain) == "vast1")

-- ---------------------------------------------------------------------------
print("falling through the chain:")
-- ---------------------------------------------------------------------------
Llm = load(FULL)
route({ ollama = OK.ollama })
local msg = Llm.chat(HELLO, nil, {})
check("healthy main model answers alone", msg.content == "from ollama" and not msg.fallback and #reqs == 1
    and msg.provider == "ollama" and msg.model == "qwen3.8:latest")

Llm = load(FULL)
route({ ollama = "timeout", bedrock = DOWN, azure = { status = 429, body = { error = { message = "rate" } } },
    vertex = { status = 500, body = { error = { message = "boom" } } }, vast1 = OK.vast1, vast2 = OK.vast2 })
msg = Llm.chat(HELLO, nil, {})
check("timeout -> 503 -> 429 -> 500 -> answered by vast1", msg and msg.content == "from vast1", msg and msg.content)
check("tried in order", patterns() == "ollama.example,bedrock-runtime.eu-west-2,res.openai.azure.com,"
    .. "oauth2.googleapis.com,aiplatform.googleapis.com,vast1.example", patterns())
check("answer says which hop and model", msg.fallback == true and msg.hop == "vast1" and msg.model == "qwen3-32b"
    and msg.provider == "openai")
check("vast1 got its own key", reqs[#reqs].headers.Authorization == "Bearer vast1-secret")

print("circuit breaker per hop:")
reqs = {}
route({ ollama = OK.ollama, bedrock = OK.bedrock, azure = OK.azure, vertex = OK.vertex, vast1 = OK.vast1 })
msg = Llm.chat(HELLO, nil, {})
check("main + the three failed hops are skipped for 60s", msg.content == "from vast1" and patterns() == "vast1.example",
    patterns())
reqs = {}
msg = Llm.chat(HELLO, nil, { no_fallback = true })
check("the health check still probes the main model, and closes its breaker", msg.content == "from ollama")
reqs = {}
msg = Llm.chat(HELLO, nil, {})
check("main back in use; the hops' breakers are their own", msg.content == "from ollama" and #reqs == 1)
local st = Llm.chain_status()
local open = {}
for _, h in ipairs(st.hops) do if h.circuit_open then open[#open + 1] = h.name end end
check("chain_status shows which hops are open", table.concat(open, ",") == "bedrock,azure,vertex",
    table.concat(open, ","))

Llm = load(FULL)
route({ ollama = { status = 400, body = { error = { message = "prompt too long" } } }, bedrock = OK.bedrock })
msg = Llm.chat(HELLO, nil, {})
check("a 400 (this request) falls through...", msg.content == "from bedrock" and msg.hop == "bedrock")
reqs = {}
route({ ollama = OK.ollama })
msg = Llm.chat(HELLO, nil, {})
check("...without opening the breaker", msg.content == "from ollama" and #reqs == 1)

Llm = load(FULL)
route({ ollama = "timeout", bedrock = "timeout", azure = DOWN, vertex = DOWN, vast1 = DOWN, vast2 = DOWN,
    anthropic = DOWN })
local _, err, status = Llm.chat(HELLO, nil, {})
check("all down: one error naming every hop, the main status", err and err:find("timeout", 1, true)
    and err:find("fallback llama-3.3-70b also failed", 1, true)
    and err:find("fallback claude-opus-5-5 also failed", 1, true)
    and status == nil, err)
reqs = {}
route({ ollama = OK.ollama })
msg = Llm.chat(HELLO, nil, {})
check("everything marked down: the main model is still tried", msg and msg.content == "from ollama")

print("tools:")
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "vast2,vast1" }))
route({ ollama = DOWN, vast1 = OK.vast1, vast2 = OK.vast2 })
msg = Llm.chat(HELLO, TOOLS, {})
check("a tool-using call skips the tool-less hop",
    msg.content == "from vast1" and not patterns():find("vast2", 1, true),
    patterns())
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "vast2,vast1" }))
route({ ollama = DOWN, vast1 = OK.vast1, vast2 = OK.vast2 })
msg = Llm.chat(HELLO, nil, {})
check("...and uses it for plain calls", msg.content == "from vast2")

print("per-feature chains:")
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN_BY_FEATURE = "tax_classify=vast2,vast1; statement_extract=vertex" }))
route({ ollama = DOWN, vast1 = OK.vast1, vast2 = OK.vast2, bedrock = OK.bedrock, vertex = OK.vertex })
msg = Llm.chat(HELLO, nil, { usage = { feature = "tax_classify" } })
check("tax_classify uses its own chain", msg.content == "from vast2", msg.content)
reqs = {}
msg = Llm.chat(HELLO, nil, { usage = { feature = "assistant" } })
check("other features use AI_FALLBACK_CHAIN", msg.content == "from bedrock", msg.content)
check("chain_status lists the per-feature chains", Llm.chain_status().by_feature.tax_classify[1] == "vast2")

print("time budget across N hops:")
-- Every hop "hangs" until its own deadline: the clock moves to it, then the read times out.
do
    local Webhooks = require("lib.outbound-webhooks")
    local real_fetch, deadlines = Webhooks.fetch, {}
    Webhooks.fetch = function(target, _, o)
        deadlines[#deadlines + 1] = { host = target.host, at = o.deadline }
        clock = math.max(clock, o.deadline)
        return nil, "could not read the response: timeout"
    end
    Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "vast1,vast2,anthropic" }))
    local start = clock
    Llm.chat(HELLO, nil, { timeout_ms = 90000 })
    Webhooks.fetch = real_fetch
    local rel = {}
    for i, d in ipairs(deadlines) do rel[i] = d.at - start end
    check("main gets 2/3, each hop an equal share of the rest, the last all of it",
        #rel == 4 and rel[1] == 60 and rel[2] == 70 and rel[3] == 80 and rel[4] == 90, table.concat(rel, ","))
    check("never past the total budget", clock - start <= 90)
end

-- ---------------------------------------------------------------------------
print("backward compatibility (AI_FALLBACK_CHAIN unset):")
-- ---------------------------------------------------------------------------
local LEGACY = { AI_PROVIDER = "anthropic", AI_API_KEY = "sk-ant", OLLAMA_URL = "https://ollama.example",
    OLLAMA_MODEL = "qwen3.8:latest", OLLAMA_API_KEY = "s" }
Llm = load(LEGACY)
check("default fallback is still Ollama", #Llm.chain == 1 and Llm.fallback.provider == "ollama"
    and Llm.chain_source == "AI_FALLBACK_PROVIDER")
Llm = load(merged(LEGACY, { AI_FALLBACK_PROVIDER = "openai", OPENAI_API_KEY = "sk-o", OPENAI_MODEL = "gpt-x" }))
check("AI_FALLBACK_PROVIDER=openai still works", Llm.fallback.provider == "openai" and Llm.fallback.model == "gpt-x")
script = { ["api.anthropic.com"] = { default = DOWN }, ["api.openai.com"] = { default = DOWN } }
Llm.chat(HELLO, nil, {})
reqs = {}
Llm.chat(HELLO, nil, {})
check("the legacy fallback keeps no breaker of its own (tried every time, as before)",
    patterns() == "api.openai.com", patterns())
check("AI_FALLBACK_PROVIDER is ignored once AI_FALLBACK_CHAIN is set",
    names(load(merged(FULL, { AI_FALLBACK_PROVIDER = "anthropic", AI_FALLBACK_CHAIN = "vast1" })).chain) == "vast1")

-- ---------------------------------------------------------------------------
print("SigV4 (AWS test vectors):")
-- ---------------------------------------------------------------------------
local SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
check("signing key (AWS docs example, iam 20120215)",
    LlmAuth.hex(LlmAuth.sigv4_key(SECRET, "20120215", "us-east-1", "iam"))
    == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
local h, info = LlmAuth.sigv4({ method = "GET", host = "example.amazonaws.com", path = "/", payload = "",
    access_key = "AKIDEXAMPLE", secret_key = SECRET, region = "us-east-1", service = "service",
    amz_date = "20150830T123600Z" })
check("get-vanilla canonical request", info.canonical_request == table.concat({ "GET", "/", "",
    "host:example.amazonaws.com", "x-amz-date:20150830T123600Z", "", "host;x-amz-date",
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" }, "\n"), info.canonical_request)
check("get-vanilla signature", h.Authorization == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/"
    .. "aws4_request, SignedHeaders=host;x-amz-date, "
    .. "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", h.Authorization)
h = LlmAuth.sigv4({ method = "POST", host = "example.amazonaws.com", path = "/", payload = "",
    access_key = "AKIDEXAMPLE", secret_key = SECRET, region = "us-east-1", service = "service",
    amz_date = "20150830T123600Z" })
check("post-vanilla signature", h.Authorization:find(
    "Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b", 1, true), h.Authorization)
h = LlmAuth.sigv4({ method = "POST", host = "x", path = "/", payload = "", access_key = "A", secret_key = "S",
    region = "r", service = "s", session_token = "tok", amz_date = "20150830T123600Z" })
check("a session token is sent and signed", h["x-amz-security-token"] == "tok"
    and h.Authorization:find("SignedHeaders=host;x-amz-date;x-amz-security-token", 1, true))
local _, enc = LlmAuth.sigv4({ method = "POST", host = "x", path = "/model/a.b-v1%3A0/converse", payload = "{}",
    access_key = "A", secret_key = "S", region = "r", service = "bedrock", amz_date = "20150830T123600Z" })
check("the path is encoded once more for signing (model ids carry ':')",
    enc.canonical_request:find("\n/model/a.b-v1%253A0/converse\n", 1, true) ~= nil)

-- ---------------------------------------------------------------------------
print("bedrock (Converse):")
-- ---------------------------------------------------------------------------
local CONVO = {
    { role = "system", content = "You are the tax assistant." },
    { role = "user", content = "Classify this", attachments = { { mime = "image/jpg", data = "aGk=" } } },
    { role = "assistant", content = "", tool_calls = { { id = "call_1", ["function"] = { name = "lookup",
        arguments = { q = "fuel" } } } } },
    { role = "tool", tool_call_id = "call_1", tool_name = "lookup", content = '{"category":"motor"}' },
    { role = "system", content = "Later note" },
    { role = "user", content = "Thanks" },
}
Llm = load(merged(FULL, { AI_PROVIDER = "bedrock", AI_FALLBACK_CHAIN = "none", AWS_SESSION_TOKEN = "sess-tok" }))
check("bedrock can be the main provider too", Llm.default.provider == "bedrock" and Llm.configured())
script = { ["bedrock-runtime"] = { { body = { output = { message = { role = "assistant", content = {
    { text = "Looking." }, { toolUse = { toolUseId = "tooluse_abc", name = "lookup", input = { q = "x" } } } } } },
    stopReason = "tool_use", usage = { inputTokens = 120, outputTokens = 9, cacheReadInputTokens = 100 } } } } }
msg = Llm.chat(CONVO, TOOLS, {})
local r = reqs[1]
check("POSTs /model/<url-encoded id>/converse", r.url == "https://bedrock-runtime.eu-west-2.amazonaws.com/model/"
    .. "eu.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse", r.url)
check("SigV4 Authorization + x-amz-date + session token", r.headers.Authorization:find(
    "^AWS4%-HMAC%-SHA256 Credential=AKIDEXAMPLE/%d+/eu%-west%-2/bedrock/aws4_request, SignedHeaders="
    .. "content%-type;host;x%-amz%-date;x%-amz%-security%-token, Signature=%x+$") ~= nil
    and r.headers["x-amz-date"] and r.headers["x-amz-security-token"] == "sess-tok", r.headers.Authorization)
check("one Host header (no lowercase duplicate)", r.headers.host == nil and r.headers.Host
    == "bedrock-runtime.eu-west-2.amazonaws.com")
local resigned = LlmAuth.sigv4({ method = "POST", host = r.headers.Host,
    path = "/model/eu.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse",
    headers = { ["Content-Type"] = "application/json" }, payload = r.raw, access_key = "AKIDEXAMPLE",
    secret_key = "aws-secret-example", session_token = "sess-tok", region = "eu-west-2", service = "bedrock",
    amz_date = r.headers["x-amz-date"] })
check("the signature covers the exact bytes sent", resigned.Authorization == r.headers.Authorization)
local b = r.body
check("system prompt -> system[]", b.system[1].text == "You are the tax assistant.")
check("image attachment -> image block (jpg -> jpeg)", b.messages[1].content[1].image.format == "jpeg"
    and b.messages[1].content[1].image.source.bytes == "aGk=")
check("assistant tool call -> toolUse", b.messages[2].role == "assistant"
    and b.messages[2].content[1].toolUse.toolUseId == "call_1" and b.messages[2].content[1].toolUse.input.q == "fuel")
check("tool result -> user toolResult, later system -> [Note], roles alternate",
    b.messages[3].role == "user" and b.messages[3].content[1].toolResult.toolUseId == "call_1"
    and b.messages[3].content[2].text == "[Note] Later note" and b.messages[3].content[3].text == "Thanks"
    and #b.messages == 3)
check("tools -> toolConfig.toolSpec with inputSchema.json", b.toolConfig.tools[1].toolSpec.name == "lookup"
    and b.toolConfig.tools[1].toolSpec.inputSchema.json.properties.q.type == "string")
check("inferenceConfig carries max tokens + temperature", b.inferenceConfig.maxTokens == 2048
    and b.inferenceConfig.temperature == 0.2)
check("reply -> text + tool_calls (table arguments) + usage", msg.content == "Looking."
    and msg.tool_calls[1].id == "tooluse_abc" and msg.tool_calls[1]["function"].name == "lookup"
    and msg.tool_calls[1]["function"].arguments.q == "x" and msg.usage.input == 120 and msg.usage.cached == 100)
script = { ["bedrock-runtime"] = { { status = 400, body = { message = "temperature is not supported" } },
    { body = { output = { message = { content = { { text = "ok" } } } } } } } }
reqs = {}
msg = Llm.chat(HELLO, nil, {})
check("a model that rejects temperature: retried without it (AWS {message} errors read)", msg and msg.content == "ok"
    and #reqs == 2 and reqs[2].body.inferenceConfig.temperature == nil)
Llm = load(merged(FULL, { AI_PROVIDER = "bedrock", AI_FALLBACK_CHAIN = "none",
    AWS_BEARER_TOKEN_BEDROCK = "bedrock-api-key" }))
script = { ["bedrock-runtime"] = { { body = { output = { message = { content = { { text = "ok" } } } } } } } }
Llm.chat(HELLO, nil, {})
check("a Bedrock API key is sent as a bearer token (no SigV4)",
    reqs[1].headers.Authorization == "Bearer bedrock-api-key"
    and reqs[1].headers["x-amz-date"] == nil)

-- ---------------------------------------------------------------------------
print("azure openai:")
-- ---------------------------------------------------------------------------
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "azure" }))
route({ ollama = DOWN, azure = { body = { choices = { { message = { content = "", tool_calls = { { id = "c1",
    type = "function", ["function"] = { name = "lookup", arguments = '{"q":"y"}' } } } } } } } } })
msg = Llm.chat(CONVO, TOOLS, {})
r = reqs[#reqs]
check("deployment URL with api-version", r.url
    == "https://res.openai.azure.com/openai/deployments/gpt4o-prod/chat/completions?api-version=2024-10-21", r.url)
check("api-key header, no bearer token", r.headers["api-key"] == "azure-secret" and r.headers.Authorization == nil)
check("tools sent in OpenAI shape", r.body.tools[1]["function"].name == "lookup")
check("tool call normalised", msg.tool_calls[1].id == "c1" and msg.tool_calls[1]["function"].arguments.q == "y"
    and msg.hop == "azure")
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "azure", AZURE_OPENAI_API_VERSION = "v1" }))
check("api_version=v1 -> the /openai/v1 API",
    Llm.hops.azure.chat_url == "https://res.openai.azure.com/openai/v1/chat/completions")
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "azure2", AI_HOP_AZURE2_PROVIDER = "azure_openai",
    AI_HOP_AZURE2_BASE_URL = "https://other.openai.azure.com", AI_HOP_AZURE2_API_KEY = "k2",
    AI_HOP_AZURE2_DEPLOYMENT = "mini", AI_HOP_AZURE2_API_VERSION = "2025-01-01-preview" }))
check("a second, named Azure hop", Llm.chain[1] and Llm.chain[1].chat_url
    == "https://other.openai.azure.com/openai/deployments/mini/chat/completions?api-version=2025-01-01-preview"
    and Llm.chain[1].model == "mini")

-- ---------------------------------------------------------------------------
print("vertex ai:")
-- ---------------------------------------------------------------------------
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "vertex" }))
route({ ollama = DOWN, vertex = { body = { candidates = { { content = { role = "model", parts = {
    { text = "thinking...", thought = true }, { text = "Checking." },
    { functionCall = { name = "lookup", args = { q = "z" } }, thoughtSignature = "sig-1" } } } } },
    usageMetadata = { promptTokenCount = 50, candidatesTokenCount = 4, cachedContentTokenCount = 10 } } } })
msg = Llm.chat(CONVO, TOOLS, {})
local tok = reqs[2]
check("token exchange: JWT-bearer grant to the key's token_uri", tok.url == "https://oauth2.googleapis.com/token"
    and tok.raw:find("^grant_type=urn%%3Aietf%%3Aparams%%3Aoauth%%3Agrant%-type%%3Ajwt%-bearer&assertion=") ~= nil
    and tok.headers["Content-Type"] == "application/x-www-form-urlencoded", tok.raw)
local assertion = tok.raw:match("assertion=(.+)$")
local hb, cb, sb = assertion:match("^([%w_-]+)%.([%w_-]+)%.([%w_-]+)$")
local function unb64url(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    return LlmAuth.unbase64(s .. string.rep("=", (4 - #s % 4) % 4))
end
local jh, jc = cjson.decode(unb64url(hb)), cjson.decode(unb64url(cb))
check("assertion header RS256", jh.alg == "RS256" and jh.typ == "JWT")
check("assertion claims: iss, cloud-platform scope, aud, 1h", jc.iss == SA.client_email
    and jc.scope == "https://www.googleapis.com/auth/cloud-platform" and jc.aud == SA.token_uri
    and jc.exp - jc.iat == 3600 and jc.iat == math.floor(clock))
check("assertion signature verifies with the service account's key",
    RSA:verify(unb64url(sb), digest.new("sha256"):update(hb .. "." .. cb)) == true)
r = reqs[3]
check("generateContent URL", r.url == "https://europe-west2-aiplatform.googleapis.com/v1/projects/demo-proj/"
    .. "locations/europe-west2/publishers/google/models/gemini-2.5-flash:generateContent", r.url)
check("bearer access token", r.headers.Authorization == "Bearer ya29.test-token")
b = r.body
check("systemInstruction + roles user/model", b.systemInstruction.parts[1].text == "You are the tax assistant."
    and b.contents[1].role == "user" and b.contents[2].role == "model" and b.contents[3].role == "user")
check("attachment -> inlineData", b.contents[1].parts[1].inlineData.mimeType == "image/jpg")
check("tool call -> functionCall, result -> functionResponse (by name)",
    b.contents[2].parts[1].functionCall.name == "lookup" and b.contents[2].parts[1].functionCall.args.q == "fuel"
    and b.contents[3].parts[1].functionResponse.name == "lookup"
    and b.contents[3].parts[1].functionResponse.response.category == "motor")
check("tools -> functionDeclarations", b.tools[1].functionDeclarations[1].name == "lookup"
    and b.tools[1].functionDeclarations[1].parametersJsonSchema.properties.q.type == "string")
check("reply: thoughts dropped, text + functionCall + thought signature kept", msg.content == "Checking."
    and msg.tool_calls[1]["function"].arguments.q == "z" and msg.tool_calls[1].id:find("^call_")
    and msg.tool_calls[1].extra_content.google.thought_signature == "sig-1"
    and msg.usage.input == 50 and msg.usage.output == 4 and msg.usage.cached == 10)
reqs = {}
script[URL.vertex] = { default = OK.vertex }
Llm.chat({ { role = "user", content = "x" }, msg, { role = "tool", tool_call_id = msg.tool_calls[1].id,
    tool_name = "lookup", content = "[1,2]" } }, TOOLS, {})
check("the access token is cached (no second exchange)", patterns() == "ollama.example,aiplatform.googleapis.com"
    or patterns() == "aiplatform.googleapis.com", patterns())
check("the thought signature goes back with the call; a non-object result is wrapped",
    reqs[#reqs].body.contents[2].parts[2].thoughtSignature == "sig-1"
    and reqs[#reqs].body.contents[3].parts[1].functionResponse.response.content == "[1,2]")

Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "vertex", VERTEX_MODEL = "claude-sonnet-4-5@20250929",
    GCP_LOCATION = "global" }))
route({ ollama = DOWN, vertex = { body = { content = { { type = "text", text = "claude on vertex" } }, usage = {} } } })
msg = Llm.chat(HELLO, nil, {})
r = reqs[#reqs]
check("Claude on Vertex: rawPredict on the anthropic publisher",
    r.url == "https://aiplatform.googleapis.com/v1/projects/"
    .. "demo-proj/locations/global/publishers/anthropic/models/claude-sonnet-4-5@20250929:rawPredict", r.url)
check("...anthropic_version in the body, no model, bearer token", r.body.anthropic_version == "vertex-2023-10-16"
    and r.body.model == nil and r.headers.Authorization == "Bearer ya29.test-token" and r.headers["x-api-key"] == nil)
check("...answer normalised", msg.content == "claude on vertex" and msg.hop == "vertex")
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "vertex" }))
route({ ollama = DOWN, vertex = OK.vertex, token = { status = 400, body = { error = "invalid_grant",
    error_description = "Invalid JWT Signature." } } })
_, err = Llm.chat(HELLO, nil, {})
check("a rejected service account is a clear error", err and err:find("Invalid JWT Signature", 1, true), err)
check("base64 GCP_CREDENTIALS_JSON accepted", load(merged(FULL, {
    GCP_CREDENTIALS_JSON = LlmAuth.base64(cjson.encode(SA)) })).hops.vertex.missing == nil)

-- ---------------------------------------------------------------------------
print("dashboard health check walks the chain:")
-- ---------------------------------------------------------------------------
load(merged(FULL, { AI_FALLBACK_CHAIN = "vast1,vast2" }))
package.loaded["lib.agent.agent"] = nil
local Agent = require("lib.agent.agent")
route({ ollama = { status = 401, body = { error = "bad key" } }, vast1 = DOWN, vast2 = OK.vast2 })
st = Agent.status()
check("main down, hop 1 down: the first hop that answers is reported (amber)", st.status == "slow"
    and st.fallback == true and st.hop == "vast2" and st.model == "llama-3.3-70b"
    and st.reason:find("qwen3.8:latest is unavailable", 1, true), cjson.encode(st))

-- ---------------------------------------------------------------------------
print("operator view (no secrets):")
-- ---------------------------------------------------------------------------
Llm = load(merged(FULL, { AI_FALLBACK_CHAIN = "bedrock,azure,ghost,vast1,vast2", AWS_REGION = false }))
st = Llm.chain_status()
local text = cjson.encode(st)
local leaked
for _, s in ipairs({ "aws-secret-example", "AKIDEXAMPLE", "azure-secret", "vast1-secret", "vast2-secret",
    "ollama-secret", "PRIVATE KEY" }) do
    if text:find(s, 1, true) then leaked = s end
end
check("no key, secret or private key in chain_status", leaked == nil, leaked)
check("main + every named hop, with why a hop is off", st.main.provider == "ollama" and #st.hops == 5
    and st.hops[1].configured == false and st.hops[1].reason:find("no region", 1, true) and st.hops[1].active == false
    and st.hops[2].active == true and st.hops[2].host == "res.openai.azure.com" and st.hops[5].tools == false,
    text)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
