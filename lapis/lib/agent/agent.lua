--[[
    AI assistant agent loop
    =======================

    Drives a multi-step tool-calling conversation against whichever model the
    env selects (lib/agent/llm: Ollama, Anthropic Claude, or any OpenAI-
    compatible API — a secret change, never a code change): send the
    conversation + tool definitions; if the model responds with tool_calls,
    execute them, feed the results back as `role:"tool"` messages, and loop
    until the model returns a plain text answer (or the iteration cap is hit).

    Tool-agnostic: the caller supplies the tool *definitions* (JSON-schema) and
    an `execute(name, args)` function. This module knows nothing about opsapi's
    domain — see lib/agent/tools.lua for the actual opsapi tools and their RBAC.
]]

local Llm = require("lib.agent.llm")

-- Private cjson instance (the shared one encodes {} as [] — see lib/agent/llm).
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)

local Agent = {}

-- ---------------------------------------------------------------------------
-- Health, for the dashboard footer (GET /api/chat/agent/status)
-- ---------------------------------------------------------------------------

local STATUS_KEY, STATUS_LOCK = "ai:status", "ai:status:probe"
local PROBE_TIMEOUT_MS = 20000
local SLOW_MS = 3000

-- One real 1-token request to the configured model: the latency users of the
-- agent actually get (gateway + queue + model). It also keeps the model loaded.
local function probe()
    ngx.update_time()
    local started = ngx.now()
    local msg, err, status = Llm.chat({ { role = "user", content = "ping" } }, nil,
        { max_tokens = 1, timeout_ms = PROBE_TIMEOUT_MS, usage = { feature = "health_check", system = true } })
    ngx.update_time()
    local ms = math.floor((ngx.now() - started) * 1000)
    if msg then
        return { status = ms > SLOW_MS and "slow" or "ok", latency_ms = ms }
    end
    if status == 401 or status == 403 then
        return { status = "down", reason = "The model provider rejected the credentials (AI_API_KEY)" }
    end
    if status == 404 then
        return { status = "down", reason = Llm.model .. " isn't available from " .. Llm.provider }
    end
    if status then
        return { status = "down", reason = "The model server answered HTTP " .. status }
    end
    return { status = "down", reason = tostring(err):find("timeout", 1, true)
        and ("No answer within " .. PROBE_TIMEOUT_MS / 1000 .. "s: the model server is busy or unreachable")
        or ("Unreachable: " .. tostring(err)) }
end

--- The model's health: { provider, model, status = ok|slow|down|checking|off,
-- latency_ms?, reason?, checked_at? }. Shared by every worker and refreshed
-- every 60s (30s while down); one worker probes at a time and the rest return
-- the last result, so dashboards polling it never pile load onto the model.
function Agent.status()
    local base = { provider = Llm.provider, model = Llm.model }
    if not Llm.configured() then
        base.status, base.reason = "off", "No AI model is configured on this server (AI_PROVIDER / AI_API_KEY)"
        return base
    end
    local cache, locks = ngx.shared.cache, ngx.shared.locks
    local last = cache and cache:get(STATUS_KEY)
    last = last and cjson.decode(last)
    if last and last.model == Llm.model and ngx.time() - (last.checked_at or 0) < (last.status == "down" and 30 or 60) then
        return last
    end
    if locks and not locks:add(STATUS_LOCK, true, PROBE_TIMEOUT_MS / 1000 + 5) then
        if last then return last end
        base.status = "checking"
        return base
    end
    local ok, result = pcall(probe)
    if locks then locks:delete(STATUS_LOCK) end
    if not ok then result = { status = "down", reason = "Health check failed: " .. tostring(result) } end
    for k, v in pairs(base) do result[k] = v end
    result.checked_at = ngx.time()
    if cache then cache:set(STATUS_KEY, cjson.encode(result), 600) end
    return result
end

-- Bounds the tool-call loop so a confused model can't spin forever. Each
-- iteration is one model round-trip (~seconds on the local model).
local MAX_ITERATIONS = 8
local REQUEST_TIMEOUT_MS = 120000
-- Same call failing this many times in one turn = stop and say so.
local MAX_REPEATED_FAILURES = 2

-- Does a reply claim it performed a write ("Done — created …", "has been added")?
-- ponytail: keyword heuristic; a false positive only costs one extra model call.
-- Seen live: "Ada Lovelace's phone number is now 07700 900999." with no call.
local CLAIM_PATTERNS = {
    "^%s*done", "has been %a+", "have been %a+", "successfully", "i've %a+ed", "i have %a+ed",
    "i've %a+ ", "i have %a+ ", " is now ", " are now ", "now set to", "^%s*%a+ed ",
}
function Agent.claims_action(text)
    local t = (text or ""):lower()
    for _, p in ipairs(CLAIM_PATTERNS) do
        if t:find(p) then return true end
    end
    return false
end

--- Run the agent loop.
-- @param opts.system   string  system prompt
-- @param opts.messages table   prior conversation [{role="user"|"assistant", content=...}]
-- @param opts.tools    table   tool definitions (Ollama function schema)
-- @param opts.execute  function(name, args) -> (result_table|nil, err_string|nil)
-- @param opts.usage    table   who/what each model call is metered to (lib/agent/llm)
-- @return { reply=string, actions={ {name,args,result,error}, ... }, pending? } | nil, err
function Agent.run(opts)
    local messages = {}
    if opts.system then
        messages[#messages + 1] = { role = "system", content = opts.system }
    end
    for _, m in ipairs(opts.messages or {}) do
        if m.role and m.content ~= nil then
            messages[#messages + 1] = { role = m.role, content = tostring(m.content) }
        end
    end

    local actions = {}
    local nudged = false
    local failures = {} -- "name args" -> times it failed this turn

    for _ = 1, MAX_ITERATIONS do
        local msg, err = Llm.chat(messages, opts.tools, {
            temperature = 0.2, max_tokens = 2048, timeout_ms = REQUEST_TIMEOUT_MS, usage = opts.usage,
        })
        if not msg then
            return nil, err
        end

        -- Keep the assistant turn (with any tool_calls) in history.
        messages[#messages + 1] = msg

        local tool_calls = msg.tool_calls
        if not tool_calls or #tool_calls == 0 then
            local reply = msg.content or ""
            -- Hallucination guard: the model sometimes answers "Done — created X"
            -- without calling any tool (seen live: fake customer + fake INV-0004).
            -- Push back once so it actually calls the tool; if it still claims
            -- success with nothing executed, say so honestly instead.
            if #actions == 0 and Agent.claims_action(reply) then
                if not nudged then
                    nudged = true
                    messages[#messages + 1] = {
                        role = "system",
                        content = "You did NOT call any tool in this turn, so nothing was created or changed. "
                            .. "If the user asked you to do something, call the appropriate tool now "
                            .. "(or ask_user for a missing detail). Do not claim it is done.",
                    }
                    goto continue
                end
                return {
                    reply = "I wasn't able to complete that — no records were created or changed. "
                        .. "Please try again, and include any details (name, email, amount) in one message.",
                    actions = actions,
                }
            end
            return { reply = reply, actions = actions }
        end

        -- Execute each requested tool, appending its result as a tool message.
        for _, tc in ipairs(tool_calls) do
            local fn = tc["function"] or {}
            local name = fn.name or ""
            local args = fn.arguments or {}
            if type(args) == "string" then
                args = cjson.decode(args) or {}
            end

            -- The model asks for missing info by calling an ask-style tool
            -- (qwen sometimes invents "ask_followup"). Treat any of these as the
            -- agent asking the user: return the question and end the turn.
            if name == "ask_user" or name == "ask_followup"
                or name == "ask_clarification" or name == "ask_question" then
                local question = args.question or args.message or args.text or msg.content or ""
                return { reply = question, actions = actions }
            end

            -- A model that keeps re-sending a call that already failed is stuck:
            -- refuse the repeat and, past the limit, end the turn honestly.
            local sig = name .. " " .. (cjson.encode(args) or "")
            local result, terr
            local executed = false
            if (failures[sig] or 0) >= MAX_REPEATED_FAILURES then
                return {
                    reply = "I couldn't complete that — this step keeps failing: " .. tostring(failures[sig .. "#err"])
                        .. "\n\nCould you check the details (or do this step on the page) and tell me how to continue?",
                    actions = actions,
                }
            elseif failures[sig] then
                terr = "You already made exactly this call and it failed with: " .. tostring(failures[sig .. "#err"])
                    .. ". Don't repeat it — change the arguments using that error, or call ask_user."
            else
                result, terr = opts.execute(name, args)
                executed = true
            end

            -- A destructive call waiting for the user's OK (call_api DELETE):
            -- end the turn with the question; the route stores `pending`.
            if type(result) == "table" and result.needs_confirmation then
                return { reply = result.question, actions = actions, pending = result.pending }
            end

            if terr then
                failures[sig] = (failures[sig] or 0) + 1
                failures[sig .. "#err"] = failures[sig .. "#err"] or terr
            end
            if executed then
                actions[#actions + 1] = {
                    name = name,
                    args = args,
                    result = (not terr) and result or nil,
                    error = terr,
                }
            end

            local payload = terr and { ok = false, error = terr } or { ok = true, result = result }
            messages[#messages + 1] = {
                role = "tool",
                tool_call_id = tc.id,
                tool_name = name,
                content = cjson.encode(payload) or "{}",
            }
        end
        ::continue::
    end

    local last_err
    for i = #actions, 1, -1 do
        if actions[i].error then last_err = actions[i].error break end
    end
    return {
        reply = "I couldn't complete that within a few steps"
            .. (last_err and (" — the last step failed with: " .. last_err) or "")
            .. ". Could you break it into a smaller request or add more detail?",
        actions = actions,
    }
end

return Agent
