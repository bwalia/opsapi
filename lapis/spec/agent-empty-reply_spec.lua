--[[
    Spec: the agent never sends the user an empty message.

    Seen live on int: a landlord gave their mortgage interest, the model's turn ended
    with "" and nothing was saved, so the chat showed a blank bubble. Guards:
      * an empty answer gets one nudge, and the model's next step (a tool call) runs;
      * an answer still empty after the nudge becomes an honest message;
      * ask_user with no question text doesn't end the turn: the model is told and
        carries on.

    Standalone (no model): lib.agent.llm is stubbed with scripted replies. Run in the
    API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/agent-empty-reply_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local clock = 0
_G.ngx = {
    WARN = 4, ERR = 3, INFO = 7,
    log = function() end,
    now = function() return clock end,
    update_time = function() clock = clock + 1 end,
    shared = {},
    time = function() return clock end,
}

local script, seen = {}, {}
package.loaded["lib.agent.llm"] = {
    TIMEOUT_MS = 300000,
    chat = function(messages)
        seen[#seen + 1] = messages[#messages]
        local nxt = table.remove(script, 1)
        if not nxt then return { role = "assistant", content = "fallthrough" } end
        return nxt
    end,
}

local Agent = require("lib.agent.agent")
local function call(name, args) return { role = "assistant", content = "",
    tool_calls = { { id = "c1", ["function"] = { name = name, arguments = args } } } } end

print("== empty answer → nudge → the model saves the figures")
local executed = {}
script = {
    { role = "assistant", content = "" },
    call("set_property_finance_costs", { residential_finance_costs = 398600, commercial_finance_costs = 113800 }),
    { role = "assistant", content = "Saved: £398,600 residential, £113,800 commercial." },
}
seen = {}
local r = Agent.run({ system = "sys", messages = { { role = "user", content = "interest was £398,600" } },
    tools = {}, execute = function(name, args) executed[#executed + 1] = { name, args }; return { saved = true } end })
check("the tool ran after the nudge", executed[1] and executed[1][1] == "set_property_finance_costs",
    executed[1] and executed[1][1])
check("the model was nudged with a system message", seen[2] and seen[2].role == "system"
    and seen[2].content:find("empty", 1, true) ~= nil)
check("the user gets the model's real answer", r.reply == "Saved: £398,600 residential, £113,800 commercial.", r.reply)

print("== still empty after the nudge")
script = { { role = "assistant", content = "" }, { role = "assistant", content = "   " } }
r = Agent.run({ system = "sys", messages = { { role = "user", content = "hi" } }, tools = {},
    execute = function() return {} end })
check("an honest message, never blank", r.reply:find("%S") ~= nil and r.reply:find("say it again", 1, true) ~= nil,
    r.reply)

print("== empty after a successful save")
script = {
    call("set_property_finance_costs", { residential_finance_costs = 1 }),
    { role = "assistant", content = "" }, { role = "assistant", content = "" },
}
r = Agent.run({ system = "sys", messages = { { role = "user", content = "x" } }, tools = {},
    execute = function() return { saved = true } end })
check("says it was saved", r.reply:find("saved", 1, true) ~= nil, r.reply)

print("== ask_user without a question")
script = {
    call("ask_user", { quick_replies = { "Yes", "No" } }),
    call("ask_user", { question = "Was that the residential interest?" }),
}
seen = {}
r = Agent.run({ system = "sys", messages = { { role = "user", content = "x" } }, tools = {},
    execute = function() return {} end })
check("the empty ask is reported back to the model", seen[2] and seen[2].role == "tool"
    and seen[2].content:find("needs the question", 1, true) ~= nil, seen[2] and seen[2].content)
check("the next ask with a question ends the turn", r.reply == "Was that the residential interest?", r.reply)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
