--[[
    ATS — interviews from the Snazzy Pro desktop app.

    The app runs interviews itself (Auto Interviews) and sends the result here,
    either directly (integration token) or as a `.snazzy_interview` file a
    recruiter imports:

        {"format": "snazzy-interview", "version": 1, "exported_at": ISO8601,
         "app": "Snazzy Pro <version>", "interview": <InterviewSession>}

    InterviewSession is the app's JSON (snake_case; InterviewSession.swift): id,
    kit (RoleKit), candidate {name, email, reference}, channel, state, turns,
    flags, eligibility_answers, adjustments, notice_hash, notice_accepted_at,
    started_at, ended_at, end_reason, models, evaluation, review, audit,
    created, delete_after. A bare InterviewSession is accepted too.

    Everything in it is untrusted: parse() keeps only known fields with known
    values, caps sizes, and re-checks evaluation quotes against the transcript.
]]

local T = require("lib.ats.text")
local J = require("lib.ats.json")
local Kit = require("lib.ats.kit")
local Ev = require("lib.ats.evaluator")
local Engine = require("lib.ats.engine")

local I = {}

I.FORMAT = "snazzy-interview"
I.VERSION = 1
I.MAX_BYTES = 1024 * 1024
I.MAX_TURNS = 400

local STATES = { invited = true, in_progress = true, paused = true, completed = true, human_requested = true,
    abandoned = true, expired = true, withdrawn = true }
local ROLES = { interviewer = true, candidate = true, system = true }
local KINDS = { opening = true, eligibility = true, core = true, follow_up = true, acknowledgement = true,
    rephrase = true, candidate_question = true, answer = true, closing = true, notice = true, other = true }
local INPUTS = { typed = true, spoken = true, pasted = true }
local DECISIONS = { advance = true, hold = true, decline = true }
local CHANNELS = { this_mac = true, link = true, hosted = true, auto = true }

local function s(v, max, default)
    v = J.val(v)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" then return default end
    return T.prefix(v, max or 500)
end

local function iso(v)
    v = s(v, 40)
    if v and v:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d") then return v end
    return nil
end

local function tbl(v)
    v = J.val(v)
    return type(v) == "table" and v or nil
end

--- Parses a `.snazzy_interview` file or a bare InterviewSession.
-- @return record | nil, error message
function I.parse(raw)
    if type(raw) ~= "string" or raw == "" then return nil, "The file is empty." end
    if #raw > I.MAX_BYTES then return nil, "The interview is larger than 1 MB." end
    local doc = J.decode(raw)
    if type(doc) ~= "table" then return nil, "This isn't valid JSON." end
    local meta = {}
    local session = doc
    if J.val(doc.format) ~= nil then
        if doc.format ~= I.FORMAT then return nil, "This isn't a Snazzy interview file." end
        if tonumber(J.val(doc.version)) ~= I.VERSION then
            return nil, "This interview file is version " .. tostring(J.val(doc.version))
                .. "; this server reads version " .. I.VERSION .. "."
        end
        session = tbl(doc.interview)
        if not session then return nil, "The file has no interview in it." end
        meta.app = s(doc.app, 80)
        meta.exported_at = iso(doc.exported_at)
    end
    local id = s(session.id, 64)
    if not id or not id:match("^[%w%-]+$") then return nil, "The interview has no id." end
    local kit_raw = tbl(session.kit)
    if not kit_raw then return nil, "The interview has no kit." end
    local kit = Kit.normalise(kit_raw)
    if #kit.questions == 0 then return nil, "The interview's kit has no questions." end

    local rec = {
        external_id = id, kit = kit, app = meta.app, exported_at = meta.exported_at,
        candidate = { name = s(tbl(session.candidate) and session.candidate.name, 200, ""),
            email = s(tbl(session.candidate) and session.candidate.email, 254, ""):lower(),
            reference = s(tbl(session.candidate) and session.candidate.reference, 200, "") },
        channel = CHANNELS[J.val(session.channel)] and session.channel or "this_mac",
        state = STATES[J.val(session.state)] and session.state or "completed",
        notice_hash = s(session.notice_hash, 64), notice_accepted_at = iso(session.notice_accepted_at),
        started_at = iso(session.started_at), ended_at = iso(session.ended_at), end_reason = s(session.end_reason, 64),
        created = iso(session.created), delete_after = iso(session.delete_after),
        turns = J.array({}), flags = J.array({}), adjustments = J.array({}), forwarded_questions = J.array({}),
        eligibility_answers = {}, models = {}, audit = J.array({}),
    }
    for i, t in ipairs(tbl(session.turns) or {}) do
        if i > I.MAX_TURNS then break end
        if type(t) == "table" and ROLES[J.val(t.role)] and s(t.id, 16) then
            rec.turns[#rec.turns + 1] = { id = s(t.id, 16), role = t.role, text = s(t.text, Engine.MAX_ANSWER, ""),
                kind = KINDS[J.val(t.kind)] and t.kind or "other", question_id = s(t.question_id, 32),
                at = iso(t.at), input = INPUTS[J.val(t.input)] and t.input or nil }
        end
    end
    for i, f in ipairs(tbl(session.flags) or {}) do
        if i > 200 then break end
        if type(f) == "table" then
            rec.flags[#rec.flags + 1] = { kind = Engine.FLAG_KINDS[J.val(f.kind)] and f.kind or "other",
                detail = s(f.detail, 200, ""), turn = s(f.turn, 16), at = iso(f.at) }
        end
    end
    for k, v in pairs(tbl(session.eligibility_answers) or {}) do
        if type(k) == "string" and #k <= 32 then rec.eligibility_answers[k] = s(v, 500, "") end
    end
    for i, a in ipairs(tbl(session.adjustments) or {}) do
        if i <= 20 then rec.adjustments[#rec.adjustments + 1] = s(a, 500, "") end
    end
    for i, q in ipairs(tbl(session.forwarded_questions) or {}) do
        if i <= 20 then rec.forwarded_questions[#rec.forwarded_questions + 1] = s(q, 1000, "") end
    end
    for k, v in pairs(tbl(session.models) or {}) do
        if type(k) == "string" and #k <= 32 then rec.models[k] = s(v, 200, "") end
    end
    for i, a in ipairs(tbl(session.audit) or {}) do
        if i > 200 then break end
        if type(a) == "table" then
            rec.audit[#rec.audit + 1] = { at = iso(a.at), who = s(a.who, 100, ""), action = s(a.action, 64, ""),
                detail = s(a.detail, 300, "") }
        end
    end
    -- The evaluation: keep only quotes that really are the candidate's words.
    local ev = tbl(session.evaluation)
    if ev then
        local check = { turns = rec.turns, kit = kit }
        local comps = J.array({})
        for _, c in ipairs(tbl(ev.competencies) or {}) do
            if type(c) == "table" and Kit.competency(kit, J.val(c.id)) then
                local quotes = J.array({})
                for _, q in ipairs(tbl(c.evidence) or {}) do
                    local quote = type(q) == "table" and { turn = s(q.turn, 16, ""), quote = s(q.quote, 2000, "") }
                    if quote and Ev.is_verbatim(quote, check) then quotes[#quotes + 1] = quote end
                end
                local level = tonumber(J.val(c.level))
                local second = tonumber(J.val(c.second_level))
                comps[#comps + 1] = { id = c.id, evidence = quotes,
                    level = (#quotes > 0 and level and level >= 1 and level <= 5) and math.floor(level) or nil,
                    second_level = (second and second >= 1 and second <= 5) and math.floor(second) or nil,
                    agreed = J.val(c.agreed) ~= false, reason = s(c.reason, 2000, ""), probe_next = s(c.probe_next, 1000, "") }
            end
        end
        rec.evaluation = { competencies = comps, injection = J.array({}), notes_for_reviewer = s(ev.notes_for_reviewer, 2000, ""),
            dropped_quotes = tonumber(J.val(ev.dropped_quotes)) or 0, model = s(ev.model, 200, ""),
            prompt_version = s(ev.prompt_version, 40, ""), at = iso(ev.at), source = "snazzy_desktop" }
        for _, q in ipairs(tbl(ev.injection) or {}) do
            if type(q) == "table" then
                rec.evaluation.injection[#rec.evaluation.injection + 1] = { turn = s(q.turn, 16, ""), quote = s(q.quote, 500, "") }
            end
        end
    end
    -- A review comes from a person in the app; a decision only if they made one.
    local rv = tbl(session.review)
    if rv and s(rv.reviewer, 200) then
        local levels = {}
        for k, v in pairs(tbl(rv.levels) or {}) do
            local n = tonumber(J.val(v))
            if type(k) == "string" and n and n >= 0 and n <= 5 then levels[k] = math.floor(n) end
        end
        rec.review = { reviewer = s(rv.reviewer, 200), decision = DECISIONS[J.val(rv.decision)] and rv.decision or nil,
            reason = s(rv.reason, 500, ""), note = s(rv.note, 4000, ""), levels = levels, at = iso(rv.at),
            via = "Snazzy Pro" }
    end
    return rec
end

--- An engine session (epoch times) as the app's InterviewSession JSON shape.
function I.to_snazzy(session, id)
    local function at(ts) return ts and T.iso(ts) or nil end
    return {
        id = id, kit = session.kit, candidate = session.candidate, channel = session.channel or "hosted",
        state = session.state, turns = session.turns, flags = session.flags,
        eligibility_answers = session.eligibility_answers, adjustments = session.adjustments,
        notice_hash = session.notice_hash, notice_accepted_at = at(session.notice_accepted_ts),
        started_at = at(session.started_ts), ended_at = at(session.ended_ts), end_reason = session.end_reason,
        paused_seconds = session.paused_seconds, step = session.step, follow_ups = session.follow_ups,
        forwarded_questions = session.forwarded_questions, models = session.models or {},
        evaluation = session.evaluation, review = session.review, audit = session.audit,
        created = at(session.created_ts), delete_after = at(session.delete_after_ts),
    }
end

return I
