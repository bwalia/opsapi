--[[
    ATS — the interviewer, evaluator and kit-generator prompts, filled in.
    The templates in lib/ats/prompts/*.v1.md are byte-identical copies of the
    Snazzy app's (Packages/SnazzyKit/Sources/Interview/Resources/prompts); a
    change means a new version on both sides. Port of InterviewPrompts.swift.
]]

local T = require("lib.ats.text")
local J = require("lib.ats.json")
local Kit = require("lib.ats.kit")
local Engine = require("lib.ats.engine")
local Ev = require("lib.ats.evaluator")
local Hash = require("lib.ats.hash")

local P = {}

P.INTERVIEWER = "interviewer.v1"
P.EVALUATOR = "evaluator.v1"
P.KIT_GENERATOR = "kit-generator.v1"

local DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or ".") .. "/prompts/"
local cache = {}

function P.template(name)
    if not cache[name] then
        local f = assert(io.open(DIR .. name .. ".md", "rb"), "ATS prompt " .. name .. " is missing")
        cache[name] = f:read("*a")
        f:close()
    end
    return cache[name]
end

--- Replaces each {{key}}; unknown keys are left as they are.
function P.render(template, values)
    return (template:gsub("{{([%w_]+)}}", function(key)
        local v = values[key]
        if v == nil then return nil end
        return tostring(v)
    end))
end

function P.interviewer_system(kit, voice)
    local comps = {}
    for _, c in ipairs(kit.competencies) do comps[#comps + 1] = "- " .. c.id .. ": " .. c.name .. ". " .. c.description end
    return P.render(P.template(P.INTERVIEWER), {
        organisation = kit.organisation == "" and "the hiring organisation" or kit.organisation,
        role_title = kit.title,
        interviewer_name = kit.settings.interviewer_name,
        role_summary = kit.summary == "" and kit.title or kit.summary,
        competencies = table.concat(comps, "\n"),
        next_steps = kit.settings.next_steps,
        allowed_adjustments = table.concat(kit.settings.allowed_adjustments, ", "),
        company_facts = T.trim(kit.company_facts) == "" and "(none given)" or kit.company_facts,
        style = voice and "You are speaking aloud: short sentences, no lists, no symbols or markdown, no links."
            or "Plain text, no markdown.",
        language = kit.language,
    })
end

function P.interviewer_message(session, directive)
    local parts = {}
    for _, turn in ipairs(session.turns) do
        if turn.role == "interviewer" then
            parts[#parts + 1] = "[" .. turn.id .. "] Interviewer: " .. turn.text
        elseif turn.role == "candidate" then
            parts[#parts + 1] = "[" .. turn.id .. "] Candidate:\n<external_data turn=\"" .. turn.id .. "\">\n"
                .. turn.text .. "\n</external_data>"
        end
    end
    return "<transcript>\n" .. table.concat(parts, "\n\n") .. "\n</transcript>\n\n<engine>\n" .. directive .. "\n</engine>"
end

function P.evaluator_prompt(session)
    local kit = session.kit
    local rubric = {}
    for _, c in ipairs(kit.competencies) do
        rubric[#rubric + 1] = "Competency " .. c.id .. ": " .. c.name .. ". " .. c.description .. "\n"
            .. "  Level 1: " .. c.anchors["1"] .. "\n  Level 3: " .. c.anchors["3"] .. "\n  Level 5: " .. c.anchors["5"]
            .. "\n  (2 and 4 fall between their neighbours.)"
    end
    return P.render(P.template(P.EVALUATOR), {
        role_title = kit.title,
        rubric = table.concat(rubric, "\n"),
        transcript = Ev.transcript(session),
        written_communication_rule = kit.settings.written_communication
            and " (except for a written-communication competency, judged only against its anchors)" or "",
    })
end

function P.kit_generator_prompt(job_description, language)
    return P.render(P.template(P.KIT_GENERATOR), { job_description = job_description, language = language or "en-GB" })
end

--- The generator's JSON as a draft (unapproved) kit, or nil.
function P.parse_generated_kit(text, job_description)
    local raw = J.decode(Engine.first_object(text) or "")
    if type(raw) ~= "table" then return nil end
    local kit = Kit.normalise(raw)
    if #kit.competencies == 0 or #kit.questions == 0 then return nil end
    kit.id, kit.version, kit.approved_at, kit.approved_by = nil, 0, nil, nil
    kit.job_description = job_description or ""
    kit.format = Kit.FORMAT
    return kit
end

--- What a candidate reads before starting (InterviewPrompts.notice, word for word).
function P.notice(kit, provider)
    local org = kit.organisation == "" and "the hiring team" or kit.organisation
    local s = kit.settings
    return table.concat({
        "This is a first-round interview for " .. kit.title .. " with " .. org .. ". The interviewer is an AI, not a person.",
        "What happens: the AI asks every candidate for this role the same main questions in the same order, and may ask "
            .. "short follow-up questions about your answers. It takes about " .. s.minutes .. " minutes. You can ask for any "
            .. "question to be repeated or rephrased" .. (s.allow_pause and ", and you can pause" or "")
            .. ". At the end you can ask your own questions.",
        "Who decides: a person at " .. org .. " reads your answers and makes the decision. The AI does not decide, rank or "
            .. "reject anyone. After the interview, the AI summarises the evidence in your answers against the skills the "
            .. "role needs; the hiring team sees your answers alongside that summary.",
        "What is not used: the AI does not analyse your face, voice, tone, emotions or typing. Only the words of your "
            .. "answers are assessed. Personal details you mention (for example about health, family or religion) are "
            .. "hidden from the assessment.",
        "Your data: your answers are processed by " .. provider .. " and kept by " .. org .. " for up to "
            .. s.retention_days .. " days after a decision, then deleted. You can ask " .. org
            .. " for a copy, a correction or deletion at any time.",
        "Adjustments: tell us below if you need extra time, a pause, text instead of voice or anything else. Asking won't "
            .. "count against you.",
        "If you'd rather speak to a person instead, choose \"I'd prefer to speak to a person\". That won't count against "
            .. "you either.",
    }, "\n\n")
end

P.hash = Hash.notice

return P
