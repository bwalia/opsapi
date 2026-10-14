--[[
    ATS — evaluation (port of Evaluation.swift in the Snazzy app).
    The AI's assessment is advice for the reviewer, never a decision:
      * the transcript it sees hides the candidate's name and protected sentences,
        and wraps candidate turns as external data;
      * every quote must be the candidate's own words, verbatim (QuoteCheck);
      * no evidence means no level; two runs more than one level apart are
        marked agreed = false; ratings-off keeps evidence only.
]]

local T = require("lib.ats.text")
local Topics = require("lib.ats.topics")
local J = require("lib.ats.json")
local Engine = require("lib.ats.engine")

local Ev = {}

Ev.PROMPT_VERSION = "evaluator.v1"

local function turn_of(session, id)
    for _, t in ipairs(session.turns or {}) do
        if t.id == id then return t end
    end
end

local function name_tokens(name)
    local out = {}
    for tok in tostring(name or ""):gmatch("[^%s%-]+") do
        if T.len(tok) >= 2 then out[#out + 1] = tok end
    end
    return out
end

function Ev.redact_names(text, names)
    for _, n in ipairs(names) do
        text = text:gsub(T.B .. T.caseless(n) .. T.E, "[candidate]")
    end
    return text
end

--- Replaces each sentence touching a banned topic with "[redacted]".
function Ev.redact_protected(text)
    local ranges = Topics.sentences(text)
    if #ranges == 0 then return text end
    for i = #ranges, 1, -1 do
        local r = ranges[i]
        text = text:sub(1, r.first - 1) .. "[redacted] " .. text:sub(r.last + 1)
    end
    return T.trim(text)
end

--- The transcript as the evaluator sees it.
function Ev.transcript(session)
    local names = name_tokens(session.candidate and session.candidate.name)
    local flagged = {}
    for _, f in ipairs(session.flags or {}) do
        if f.kind == "protected_info_volunteered" and J.val(f.turn) then flagged[f.turn] = true end
    end
    local parts = {}
    for _, turn in ipairs(session.turns or {}) do
        if turn.role == "interviewer" then
            parts[#parts + 1] = "[" .. turn.id .. "] Interviewer: " .. Ev.redact_names(turn.text, names)
        elseif turn.role == "candidate" then
            local text = Ev.redact_names(turn.text, names)
            if flagged[turn.id] then text = Ev.redact_protected(text) end
            parts[#parts + 1] = "[" .. turn.id .. "] Candidate:\n<external_data turn=\"" .. turn.id .. "\">\n" .. text
                .. "\n</external_data>"
        end
    end
    return table.concat(parts, "\n\n")
end

-- MARK: QuoteCheck

function Ev.normalise(s)
    local t = tostring(s or ""):lower()
    for _, pair in ipairs({ { "\226\128\153", "'" }, { "\226\128\152", "'" }, { "\226\128\156", '"' },
        { "\226\128\157", '"' }, { "\226\128\166", "..." }, { "\226\128\148", "-" }, { "\226\128\147", "-" } }) do
        t = T.replace(t, pair[1], pair[2])
    end
    t = t:gsub("^[\"' .,%s]+", ""):gsub("[\"' .,%s]+$", "")
    return (t:gsub("%s+", " "))
end

function Ev.is_verbatim(quote, session)
    local turn = turn_of(session, quote and quote.turn)
    if not turn or turn.role ~= "candidate" then return false end
    local q = Ev.normalise(quote.quote)
    if T.len(q) < 3 or T.contains(q, "[redacted]") or T.contains(q, "[candidate]") then return false end
    return T.contains(Ev.normalise(turn.text), q)
end

-- MARK: Parsing and combining

local function level_of(v)
    v = J.val(v)
    if type(v) == "number" then
        local n = math.floor(v)
        if n >= 1 and n <= 5 then return n end
    end
    return nil
end

--- One evaluator run → results, injection, notes, dropped (or nil).
function Ev.parse(text, session)
    local out = J.decode(Engine.first_object(text) or "")
    if type(out) ~= "table" or type(J.val(out.competencies)) ~= "table" then return nil end
    local dropped, results = 0, {}
    for _, competency in ipairs(session.kit.competencies) do
        local item
        for _, it in ipairs(out.competencies) do
            if type(it) == "table" and it.id == competency.id then item = it end
        end
        local quotes = J.array({})
        for _, q in ipairs(item and type(J.val(item.evidence)) == "table" and item.evidence or {}) do
            local quote = type(q) == "table" and { turn = tostring(J.val(q.turn) or ""), quote = tostring(J.val(q.quote) or "") }
            if quote and Ev.is_verbatim(quote, session) then quotes[#quotes + 1] = quote else dropped = dropped + 1 end
        end
        results[#results + 1] = {
            id = competency.id, evidence = quotes,
            level = #quotes > 0 and item and level_of(item.level) or nil,
            reason = T.trim(item and J.val(item.reason) or ""), probe_next = T.trim(item and J.val(item.probe_next) or ""),
            agreed = true,
        }
    end
    local injection = J.array({})
    for _, q in ipairs(type(J.val(out.injection)) == "table" and out.injection or {}) do
        local turn = type(q) == "table" and turn_of(session, q.turn)
        if turn and turn.role == "candidate" then injection[#injection + 1] = { turn = q.turn, quote = tostring(J.val(q.quote) or "") } end
    end
    return { results = results, injection = injection, notes = T.trim(J.val(out.notes_for_reviewer) or ""), dropped = dropped }
end

--- Combines two independent runs (the second may be nil). Returns the evaluation table or nil.
function Ev.combine(first, second, session, model, now_iso)
    local a = Ev.parse(first, session)
    if not a then return nil end
    local b = second and Ev.parse(second, session) or nil
    local ratings = session.kit.settings.ratings_enabled
    local competencies = J.array({})
    for _, r in ipairs(a.results) do
        local other
        for _, o in ipairs(b and b.results or {}) do
            if o.id == r.id then other = o end
        end
        r.second_level = other and other.level or nil
        if other then
            if r.level and other.level then
                r.agreed = math.abs(r.level - other.level) <= 1
            else
                r.agreed = (r.level == nil and other.level == nil)
            end
        end
        if not ratings then
            r.level = nil
            r.second_level = nil
        end
        competencies[#competencies + 1] = r
    end
    return { competencies = competencies, injection = a.injection, notes_for_reviewer = a.notes,
        dropped_quotes = a.dropped, model = model or "", prompt_version = Ev.PROMPT_VERSION, at = now_iso }
end

function Ev.low_agreement(evaluation)
    local ids = {}
    for _, c in ipairs(evaluation and evaluation.competencies or {}) do
        if c.agreed == false then ids[#ids + 1] = c.id end
    end
    return ids
end

return Ev
