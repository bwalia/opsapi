--[[
    Spec: the AI assistant's model is picked by env only (lib/agent/llm.lua).

    Run inside the API container (it has cjson):
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/llm-providers_spec.lua

    For each provider (ollama, anthropic, openai) it stubs the HTTP client and
    checks the exact request the provider API expects — tool calls, tool results,
    system prompt, auth headers, default model — and that the provider's reply
    (text + tool calls) comes back in the agent's one message format.
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

ngx = { log = function() end, ERR = 3, time = os.time, now = os.time, update_time = function() end } -- luacheck: ignore 111

local captured, responses = nil, {}
package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function(_, url, req)
                captured = { url = url, headers = req.headers, body = cjson.decode(req.body) }
                local r = table.remove(responses, 1)
                return { status = r.status or 200, body = cjson.encode(r.body) }
            end,
        }
    end,
}
package.loaded["resty.jwt"] = { sign = function() return "eyJ.minted.sig" end }

local real_getenv = os.getenv
local function load_llm(env)
    os.getenv = function(k) return env[k] end -- luacheck: ignore 122
    package.loaded["lib.agent.llm"] = nil
    local Llm = require("lib.agent.llm")
    os.getenv = real_getenv -- luacheck: ignore 122
    return Llm
end

-- The agent's conversation after one tool round-trip.
local CONVO = {
    { role = "system", content = "You are the Timesheets assistant." },
    { role = "user", content = "List my timesheets" },
    { role = "assistant", content = "", tool_calls = {
        { id = "call_1", ["function"] = { name = "call_api", arguments = { method = "GET", path = "/api/v2/timesheets" } } },
    } },
    { role = "tool", tool_call_id = "call_1", tool_name = "call_api", content = '{"ok":true}' },
    { role = "system", content = "[Reference data] earlier results" },
    { role = "user", content = "Thanks" },
}
local TOOLS = { {
    type = "function",
    ["function"] = { name = "ask_user", description = "Ask", parameters = { type = "object", properties = {} } },
} }

print("anthropic:")
local Llm = load_llm({ AI_PROVIDER = "anthropic", AI_API_KEY = "sk-ant-test" })
check("default model is the latest Opus", Llm.model == "claude-opus-5-5", Llm.model)
responses = { { body = { content = {
    { type = "text", text = "Checking." },
    { type = "tool_use", id = "toolu_9", name = "call_api", input = { method = "POST", path = "/x", body = {} } },
} } } }
local msg = Llm.chat(CONVO, TOOLS, {})
local b = captured.body
check("POSTs to /v1/messages", captured.url == "https://api.anthropic.com/v1/messages", captured.url)
check("x-api-key + anthropic-version headers",
    captured.headers["x-api-key"] == "sk-ant-test" and captured.headers["anthropic-version"] ~= nil)
check("leading system message becomes `system`", b.system == "You are the Timesheets assistant.", b.system)
check("first message is the user's", b.messages[1].role == "user")
check("roles alternate", (function()
    for i = 2, #b.messages do if b.messages[i].role == b.messages[i - 1].role then return false end end
    return true
end)())
local tool_use = b.messages[2].content[1]
check("assistant tool call -> tool_use block with id + input object",
    tool_use.type == "tool_use" and tool_use.id == "call_1" and tool_use.input.path == "/api/v2/timesheets")
local result = b.messages[3].content[1]
check("tool result -> tool_result with tool_use_id", result.type == "tool_result" and result.tool_use_id == "call_1")
check("later system note -> user-side [Note]", b.messages[3].content[2].text:find("^%[Note%]") ~= nil)
check("tools use input_schema", b.tools[1].name == "ask_user" and b.tools[1].input_schema.type == "object")
check("empty schema properties stay an object", cjson.encode(b.tools[1].input_schema):find('"properties":{}', 1, true) ~= nil)
check("reply text parsed", msg.content == "Checking.")
check("reply tool_use -> tool_calls with table arguments",
    msg.tool_calls[1].id == "toolu_9" and msg.tool_calls[1]["function"].arguments.path == "/x")

print("openai (and compatible):")
Llm = load_llm({ AI_PROVIDER = "openai", AI_API_KEY = "sk-test", AI_MODEL = "gpt-x", AI_BASE_URL = "https://router.example/v1/" })
check("model from AI_MODEL", Llm.model == "gpt-x")
responses = {
    { status = 400, body = { error = { message = "Unsupported parameter: 'max_tokens'" } } },
    { body = { choices = { { message = { content = cjson.null, tool_calls = {
        { id = "c7", type = "function", ["function"] = { name = "call_api", arguments = '{"method":"GET","path":"/y"}' } },
    } } } } } },
}
msg = Llm.chat(CONVO, TOOLS, {})
b = captured.body
check("POSTs to AI_BASE_URL/chat/completions", captured.url == "https://router.example/v1/chat/completions", captured.url)
check("Bearer auth", captured.headers["Authorization"] == "Bearer sk-test")
check("retried with max_completion_tokens after a max_tokens 400", b.max_completion_tokens == 2048 and b.max_tokens == nil)
check("assistant tool_calls carry JSON-string arguments", type(b.messages[3].tool_calls[1]["function"].arguments) == "string")
check("tool result keeps tool_call_id", b.messages[4].role == "tool" and b.messages[4].tool_call_id == "call_1")
check("null content parsed as empty", msg.content == "")
check("string arguments decoded to a table", msg.tool_calls[1]["function"].arguments.path == "/y")

print("ollama (default):")
Llm = load_llm({ OLLAMA_URL = "https://ollama.example", OLLAMA_API_KEY = "signing-secret" })
check("provider defaults to ollama", Llm.provider == "ollama" and Llm.model == "qwen3.8:latest")
responses = { { body = { message = { content = "", tool_calls = {
    { ["function"] = { name = "ask_user", arguments = { question = "Which day?" } } },
} } } } }
msg = Llm.chat(CONVO, TOOLS, {})
b = captured.body
check("POSTs to OLLAMA_URL/api/chat", captured.url == "https://ollama.example/api/chat")
check("gateway gets a JWT minted from the secret", captured.headers["x-api-key"] == "eyJ.minted.sig")
check("think off, reply capped", b.think == false and b.options.num_predict == 2048)
check("tool calls get ids", msg.tool_calls[1].id == "call_1" and msg.tool_calls[1]["function"].arguments.question == "Which day?")

print("unknown provider falls back to ollama:")
Llm = load_llm({ AI_PROVIDER = "nonsense" })
check("fallback", Llm.provider == "ollama")
check("claude alias = anthropic", load_llm({ AI_PROVIDER = "Claude", AI_API_KEY = "k" }).provider == "anthropic")

print("hallucination guard (claims without a tool call):")
package.loaded["lib.agent.llm"] = { provider = "ollama", model = "m" }
local Agent = require("lib.agent.agent")
for _, t in ipairs({
    { "Ada Lovelace's phone number is now 07700 900999.", true },
    { "Done — moved the task.", true },
    { "Updated the deal stage to Won.", true },
    { "I've changed the phone number.", true },
    { "To submit a timesheet, open the My Timesheets tab and click Submit for Approval.", false },
    { "You don't have any projects yet, so there's no first one.", false },
}) do
    check((t[2] and "claim: " or "not a claim: ") .. t[1]:sub(1, 50), Agent.claims_action(t[1]) == t[2])
end

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
