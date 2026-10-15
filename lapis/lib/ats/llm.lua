--[[
    ATS — model calls, through the platform LLM layer (lib/agent/llm.lua:
    TLS verified, metered in ai_usage, provider fallback).

    With ANTHROPIC_API_KEY set, interviews use Claude:
      ATS_INTERVIEWER_MODEL  default claude-sonnet-5-5 (live turns; latency matters)
      ATS_EVALUATOR_MODEL    default claude-opus-5-5   (evaluation and kit generation)
    Without it, the platform's default provider (often Ollama) runs them, and
    the interview records which model did.
]]

local L = {}

local DEFAULTS = { interviewer = "claude-sonnet-5-5", evaluator = "claude-opus-5-5", generator = "claude-opus-5-5" }
local ENV = { interviewer = "ATS_INTERVIEWER_MODEL", evaluator = "ATS_EVALUATOR_MODEL",
    generator = "ATS_EVALUATOR_MODEL" }

local function env(name)
    local v = os.getenv(name)
    if v == nil or v == "" then return nil end
    return v
end

function L.config(role)
    local Llm = require("lib.agent.llm")
    if env("ANTHROPIC_API_KEY") then
        return Llm.config("anthropic", env(ENV[role]) or DEFAULTS[role])
    end
    return Llm.default
end

--- "provider/model", for the interview's record.
function L.label(role)
    local cfg = L.config(role)
    return cfg.provider .. "/" .. tostring(cfg.model)
end

--- Who processes candidates' answers, for the notice.
function L.provider_name()
    local cfg = L.config("interviewer")
    if cfg.provider == "anthropic" then return "Anthropic (Claude)" end
    if cfg.provider == "openai" then return "an AI service chosen by the hiring team" end
    return "an AI model run by the hiring team's service provider"
end

--- One call: system + one user message. @return text, model_label | nil, err
function L.complete(role, system, user, opts)
    opts = opts or {}
    local Llm = require("lib.agent.llm")
    local cfg = L.config(role)
    local msg, err = Llm.chat({ { role = "system", content = system }, { role = "user", content = user } }, nil, {
        cfg = cfg,
        max_tokens = opts.max_tokens or (role == "interviewer" and 600 or 4000),
        temperature = opts.temperature or (role == "interviewer" and 0.3 or 0.1),
        timeout_ms = opts.timeout_ms,
        usage = { feature = "ats_" .. role, namespace_id = opts.namespace_id, user_uuid = opts.user_uuid },
    })
    if not msg then return nil, err end
    local label = cfg.provider .. "/" .. tostring(msg.model or cfg.model) .. (msg.fallback and " (fallback)" or "")
    return msg.content or "", label
end

return L
