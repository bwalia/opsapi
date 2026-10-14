--[[
    ATS — the interview engine. A port of the Snazzy app's InterviewEngine.swift;
    keep them in step (docs/plans/PROMPT_ATS_INTERVIEWS.md §3).

    The engine owns the order, the timing and the end: it asks every question
    word for word. The model only chooses follow-ups and their wording, and the
    engine checks what it says (Guard). Pure Lua: the caller runs the model when
    the engine asks, and stores the session table.

    local e = Engine.new(session, now_fn)    -- session: see Engine.new_session
    e:acknowledge(notice_hash, adjustments)
    local next = e:start()                    -- {type = "wait" | "model" | "finished", directive = ...}
    next = e:receive({ type = "answer", text = "...", input = "typed" })
    next = e:apply(reply_or_nil, raw_text)    -- after a "model" step
    next = e:tick()                           -- time limit
]]

local T = require("lib.ats.text")
local Topics = require("lib.ats.topics")
local J = require("lib.ats.json")
local Kit = require("lib.ats.kit")

local Engine = {}
Engine.__index = Engine

Engine.MAX_ANSWER = 6000

local FINISHED = { completed = true, human_requested = true, abandoned = true, expired = true, withdrawn = true }
Engine.FLAG_KINDS = { adjustment = true, human_requested = true, distress = true, protected_info_volunteered = true,
    injection_attempt = true, technical = true, off_topic = true, pasted = true, time_up = true, other = true }
local ACTIONS = { follow_up = true, move_on = true, rephrase = true, answer = true, forward = true, done = true,
    ["end"] = true }

local WAIT, DONE = { type = "wait" }, { type = "finished" }
local function model(directive) return { type = "model", directive = directive } end

--- A new session for a kit (all times are epoch seconds; turns carry ISO dates).
function Engine.new_session(kit, candidate, now)
    kit = Kit.normalise(kit)
    return {
        kit = kit, candidate = candidate or { name = "" }, state = "invited", turns = J.array({}),
        flags = J.array({}), eligibility_answers = {}, adjustments = J.array({}), paused_seconds = 0,
        step = 0, follow_ups = 0, forwarded_questions = J.array({}), audit = J.array({}),
        created_ts = now, delete_after_ts = now + math.max(kit.settings.retention_days, 1) * 86400,
    }
end

function Engine.is_finished(session)
    return FINISHED[session.state] == true
end

--- The steps, fixed by the kit: eligibility, core questions in kit order, the
-- candidate's questions, closing. 0-based indexes, like the Swift engine.
function Engine.plan(kit)
    local steps = {}
    for _, q in ipairs(kit.eligibility) do steps[#steps + 1] = { kind = "eligibility", q = q } end
    for _, q in ipairs(kit.questions) do steps[#steps + 1] = { kind = "core", q = q } end
    steps[#steps + 1] = { kind = "candidate_questions" }
    steps[#steps + 1] = { kind = "closing" }
    return steps
end

function Engine.new(session, now)
    local self = setmetatable({}, Engine)
    self.session = session
    session.kit = Kit.normalise(session.kit)
    self.steps = Engine.plan(session.kit)
    self.now = now or os.time
    return self
end

-- MARK: State

function Engine:current_step()
    return self.steps[self.session.step + 1]
end

function Engine:current_question_id()
    local s = self:current_step()
    if s and (s.kind == "eligibility" or s.kind == "core") then return s.q.id end
end

function Engine:current_choices()
    local s = self:current_step()
    if s and s.kind == "eligibility" then return Kit.choices(s.q) end
end

function Engine:progress()
    local total = math.max(1, #self.steps - 2)
    return math.min(1, self.session.step / total)
end

--- Active time so far (pauses excluded).
function Engine.elapsed(session, now)
    if not session.started_ts then return 0 end
    local finish = session.ended_ts or session.paused_ts or now
    return math.max(0, finish - session.started_ts - (session.paused_seconds or 0))
end

--- The time limit, with extra time when the candidate asked for it.
function Engine.time_limit(session)
    local base = session.kit.settings.minutes * 60
    for _, a in ipairs(session.adjustments or {}) do
        local l = tostring(a):lower()
        if T.contains(l, "extra time") or T.contains(l, "more time") then return base * 1.5 end
    end
    return base
end

function Engine:seconds_left()
    return math.max(0, Engine.time_limit(self.session) - Engine.elapsed(self.session, self.now()))
end

function Engine:finished_or_wait()
    return Engine.is_finished(self.session) and DONE or WAIT
end

-- MARK: Internals

function Engine:log(action, who, detail)
    local a = self.session.audit
    a[#a + 1] = { at = T.iso(self.now()), who = who, action = action, detail = detail or "" }
end

function Engine:flag(kind, detail, turn)
    local f = self.session.flags
    f[#f + 1] = { kind = kind, detail = detail or "", turn = turn, at = T.iso(self.now()) }
end

function Engine:append(role, text, kind, question_id, input)
    local turns = self.session.turns
    local turn = { id = "t" .. (#turns + 1), role = role, text = text, kind = kind, question_id = question_id,
        at = T.iso(self.now()), input = input }
    turns[#turns + 1] = turn
    return turn
end

local ASKED = { eligibility = true, core = true, follow_up = true, rephrase = true }

function Engine:last_asked()
    local turns = self.session.turns
    for i = #turns, 1, -1 do
        if turns[i].role == "interviewer" and ASKED[turns[i].kind] then return turns[i] end
    end
end

function Engine:last_candidate()
    local turns = self.session.turns
    for i = #turns, 1, -1 do
        if turns[i].role == "candidate" then return turns[i] end
    end
end

function Engine:finish(state, reason)
    local s, t = self.session, self.now()
    if s.state == "paused" and s.paused_ts then s.paused_seconds = (s.paused_seconds or 0) + (t - s.paused_ts) end
    s.paused_ts = nil
    s.state = state
    s.ended_ts = t
    s.end_reason = reason
    s.delete_after_ts = t + math.max(s.kit.settings.retention_days, 1) * 86400
    self:log("ended", "engine", reason)
end

function Engine:close()
    if Engine.is_finished(self.session) then return end
    self:append("interviewer", "Thank you for your time today. " .. self.session.kit.settings.next_steps, "closing")
    self:finish("completed", "completed")
end

function Engine:ask_current(prefix)
    local lead = (prefix and prefix ~= "") and (prefix .. " ") or ""
    local step = self:current_step()
    if not step then return end
    if step.kind == "eligibility" then
        self:append("interviewer", lead .. step.q.text, "eligibility", step.q.id)
    elseif step.kind == "core" then
        self:append("interviewer", lead .. step.q.text, "core", step.q.id)
    elseif step.kind == "candidate_questions" then
        self:append("interviewer", lead ..
            "That's all my questions. Do you have any questions for me about the role or the process?",
            "candidate_question")
    elseif step.kind == "closing" then
        self:close()
    end
end

function Engine:advance(ack)
    self.session.step = self.session.step + 1
    self.session.follow_ups = 0
    local step = self:current_step()
    if self:seconds_left() <= 0 and step and step.kind == "core" then
        self:tick()
        return
    end
    self:ask_current(ack)
end

-- MARK: Directives for the model

function Engine:directive(rephrase)
    local minutes = math.floor(self:seconds_left() / 60)
    if rephrase then
        return 'The candidate asked for the question to be rephrased. Reply with action "rephrase" and, in "say", one '
            .. 'plainer wording of this question with the same meaning and no hints: "' .. rephrase .. '"'
    end
    local step = self:current_step()
    if step and step.kind == "core" then
        local c = Kit.competency(self.session.kit, step.q.competency)
        return "Phase: core question " .. step.q.id .. " for competency " .. step.q.competency .. " ("
            .. (c and c.name or "") .. "). Follow-ups used: " .. self.session.follow_ups .. " of "
            .. self.session.kit.settings.max_follow_ups .. ". Minutes left: " .. minutes .. ". Decide on the "
            .. 'candidate\'s last answer: "follow_up" with one short neutral question, or "move_on" with a short '
            .. "neutral acknowledgement (no question; the engine asks the next question)."
    elseif step and step.kind == "candidate_questions" then
        return "Phase: candidate questions. Minutes left: " .. minutes .. ". If the candidate asked something the "
            .. 'company facts answer, reply "answer". If the facts don\'t answer it, reply "forward". If they have '
            .. 'no (more) questions, reply "done".'
    end
    return "No reply is needed."
end

-- MARK: Guard (what the model says)

local Guard = {}
Engine.Guard = Guard

Guard.praise = {
    "great", "excellent", "impressive", "perfect", "fantastic", "brilliant", "amazing", "outstanding", "awesome",
    "good answer", "well done", "strong answer", "nice", "wonderful", "love that", "exactly right", "spot on",
    "not quite", "that's wrong", "that is wrong", "disappointing", "your score", "you scored", "your rating",
    "i'd rate", "i would rate", "rubric", "you'll get the job", "you will get the job", "you're hired",
}

function Guard.drop_sentences(words, text)
    local kept = {}
    for _, s in ipairs(T.sentences(text)) do
        local lower = s.text:lower()
        local hit = false
        for _, w in ipairs(words) do
            if lower:find(T.B .. T.escape(w)) then
                hit = true
                break
            end
        end
        local t = T.trim(s.text)
        if not hit and t ~= "" then kept[#kept + 1] = t end
    end
    return table.concat(kept, " ")
end

--- A follow-up or rephrased question: one short question, neutral, on topic; nil if unusable.
function Guard.question(text)
    local t = T.trim(text):gsub("\n", " ")
    if t == "" or T.len(t) > 400 or not T.contains(t, "?") then return nil end
    t = Guard.drop_sentences(Guard.praise, t)
    if not T.contains(t, "?") or #Topics.find(t) > 0 then return nil end
    return t
end

--- A neutral acknowledgement with no question in it.
function Guard.acknowledgement(text)
    local t = Guard.drop_sentences(Guard.praise, (T.trim(text):gsub("\n", " ")))
    if t == "" or T.len(t) > 160 or T.contains(t, "?") or #Topics.find(t) > 0 then return "Thank you." end
    return t
end

function Guard.answer(text)
    local t = T.trim(text)
    if t == "" then return "I don't have that information, so I've passed your question to the hiring team." end
    return T.prefix(t, 800)
end

local NONE = {}
for _, n in ipairs({ "no", "nope", "no thanks", "no thank you", "none", "nothing", "not really", "no questions",
    "no, thank you", "no, thanks", "i'm good", "im good", "that's all", "thats all", "no that's all" }) do
    NONE[n] = true
end

function Guard.says_no_more_questions(text)
    local t = tostring(text or ""):lower():gsub("^[%p%s]+", ""):gsub("[%p%s]+$", "")
    return NONE[t] == true
end

-- MARK: The model's reply

--- The first JSON object in model text (models wrap it in prose or fences).
function Engine.first_object(text)
    text = tostring(text or "")
    local start = text:find("{", 1, true)
    if not start then return nil end
    local depth, in_string, escaped = 0, false, false
    for i = start, #text do
        local ch = text:sub(i, i)
        if in_string then
            if escaped then escaped = false
            elseif ch == "\\" then escaped = true
            elseif ch == '"' then in_string = false end
        elseif ch == '"' then
            in_string = true
        elseif ch == "{" then
            depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then return text:sub(start, i) end
        end
    end
    return nil
end

--- {action, say, enough_evidence, flags} from model text, or nil.
function Engine.parse_reply(text)
    local obj = J.decode(Engine.first_object(text) or "")
    if type(obj) ~= "table" or not ACTIONS[J.val(obj.action)] then return nil end
    local reply = { action = obj.action, say = type(J.val(obj.say)) == "string" and obj.say or "",
        enough_evidence = J.val(obj.enough_evidence), flags = {} }
    for _, f in ipairs(type(J.val(obj.flags)) == "table" and obj.flags or {}) do
        if type(f) == "table" then
            reply.flags[#reply.flags + 1] = { kind = tostring(J.val(f.kind) or "other"), detail = tostring(J.val(f.detail) or "") }
        end
    end
    return reply
end

-- MARK: Starting

function Engine:acknowledge(notice_hash, adjustments)
    local s = self.session
    s.notice_hash = notice_hash
    s.notice_accepted_ts = self.now()
    for _, a in ipairs(adjustments or {}) do
        if T.trim(a) ~= "" then
            s.adjustments[#s.adjustments + 1] = a
            self:flag("adjustment", a)
        end
    end
    self:log("notice_acknowledged", "candidate")
end

function Engine:start()
    local s = self.session
    if s.state ~= "invited" then return self:finished_or_wait() end
    local t = self.now()
    s.state = "in_progress"
    s.started_ts = t
    s.step = 0
    s.follow_ups = 0
    local kit = s.kit
    local first = tostring(s.candidate and s.candidate.name or ""):match("^%s*(%S+)")
    local hello = first and ("Hello " .. first) or "Hello"
    local opening = hello .. ", and thank you for your time. I'm " .. kit.settings.interviewer_name
        .. ", an AI interviewer for " .. (kit.organisation == "" and "the hiring team" or kit.organisation)
        .. ", and this is a first-round interview for " .. kit.title .. ". I'll ask " .. #kit.questions
        .. " main questions" .. (#kit.eligibility == 0 and "" or ", after a few quick ones about the role's requirements")
        .. ", and you can ask me questions at the end. Take your time; you can ask me to repeat or rephrase any "
        .. "question. A person on the hiring team reviews everything and makes the decision."
    self:append("interviewer", opening, "opening")
    self:log("started", "engine")
    self:ask_current()
    return WAIT
end

-- MARK: Candidate events

local function kind_for_answer(step)
    return (step and step.kind == "candidate_questions") and "candidate_question" or "answer"
end

function Engine:after_answer(text)
    local s, step = self.session, self:current_step()
    if not step or step.kind == "closing" then return DONE end
    if step.kind == "eligibility" then
        s.eligibility_answers[step.q.id] = text
        self:advance("Thank you.")
        return self:finished_or_wait()
    elseif step.kind == "core" then
        if self:seconds_left() <= 0 then return self:tick() end
        return model(self:directive())
    else -- candidate questions
        if Guard.says_no_more_questions(text) then
            s.step = s.step + 1
            self:close()
            return DONE
        end
        return model(self:directive())
    end
end

--- event: {type = "answer", text, input} | {type = "repeat" | "rephrase" | "pause" | "resume" | "person" |
--  "withdraw"} | {type = "adjustment", text}
function Engine:receive(event)
    local s = self.session
    if Engine.is_finished(s) then return DONE end
    if event.type ~= "resume" and s.state == "paused" then return WAIT end
    local t = self.now()
    if event.type == "answer" then
        local text = T.prefix(T.trim(event.text), Engine.MAX_ANSWER)
        if text == "" then return WAIT end
        local input = event.input
        if input ~= "typed" and input ~= "spoken" and input ~= "pasted" then input = "typed" end
        local turn = self:append("candidate", text, kind_for_answer(self:current_step()), self:current_question_id(), input)
        if input == "pasted" then self:flag("pasted", "", turn.id) end
        for _, topic in ipairs(Topics.find(text)) do self:flag("protected_info_volunteered", topic, turn.id) end
        return self:after_answer(text)
    elseif event.type == "repeat" then
        local q = self:last_asked()
        if q then self:append("interviewer", q.text, q.kind, q.question_id) end
        return WAIT
    elseif event.type == "rephrase" then
        local q = self:last_asked()
        if q and (q.kind == "core" or q.kind == "follow_up") then return model(self:directive(q.text)) end
        if q then self:append("interviewer", q.text, q.kind, q.question_id) end
        return WAIT
    elseif event.type == "pause" then
        local allowed = s.kit.settings.allow_pause
        for _, a in ipairs(s.adjustments) do
            if T.contains(tostring(a):lower(), "pause") then allowed = true end
        end
        if not allowed then return WAIT end
        s.state = "paused"
        s.paused_ts = t
        self:log("paused", "candidate")
        return WAIT
    elseif event.type == "resume" then
        if s.state == "paused" and s.paused_ts then
            s.paused_seconds = (s.paused_seconds or 0) + (t - s.paused_ts)
            s.paused_ts = nil
            s.state = "in_progress"
            self:log("resumed", "candidate")
            local q = self:last_asked()
            if q then self:append("interviewer", "Welcome back. " .. q.text, q.kind, q.question_id) end
        end
        return WAIT
    elseif event.type == "person" then
        self:flag("human_requested", "Asked to speak to a person")
        self:append("interviewer", "Of course. I've let the hiring team know you'd like to speak to a person, and "
            .. "they'll be in touch. This won't count against you. Thank you.", "closing")
        self:finish("human_requested", "human_requested")
        return DONE
    elseif event.type == "withdraw" then
        self:append("system", "The candidate withdrew.", "other")
        self:finish("withdrawn", "withdrawn")
        return DONE
    elseif event.type == "adjustment" then
        local what = T.prefix(T.trim(event.text), 500)
        if what == "" then return WAIT end
        s.adjustments[#s.adjustments + 1] = what
        self:flag("adjustment", what)
        local granted = false
        for _, a in ipairs(s.kit.settings.allowed_adjustments) do
            if T.contains(what:lower(), tostring(a):lower()) then granted = true end
        end
        self:append("interviewer", granted and "Of course, that's fine. Let's carry on whenever you're ready."
            or "Thank you for telling me. I've passed that to the hiring team. We can carry on now, or stop and let "
            .. "them arrange something else; just say which.", "other")
        return WAIT
    end
    return WAIT
end

--- Call regularly: moves on when time runs out.
function Engine:tick()
    local s = self.session
    if s.state ~= "in_progress" or self:seconds_left() > 0 then return self:finished_or_wait() end
    local step = self:current_step()
    if not step then return DONE end
    if step.kind == "eligibility" or step.kind == "core" then
        self:flag("time_up", "Time ran out at question " .. (self:current_question_id() or ""))
        s.step = #self.steps - 1 -- closing (0-based)
        self:close()
    elseif step.kind == "candidate_questions" then
        s.step = s.step + 1
        self:close()
    else
        self:close()
    end
    return DONE
end

function Engine:apply(reply, raw_text)
    local s = self.session
    local step = self:current_step()
    if s.state ~= "in_progress" or not step then return self:finished_or_wait() end
    local last = self:last_candidate()
    for _, f in ipairs(reply and reply.flags or {}) do
        local kind = Engine.FLAG_KINDS[f.kind] and f.kind or "other"
        self:flag(kind, T.prefix(f.detail, 200), last and last.id)
    end
    if not reply and raw_text and raw_text ~= "" then
        self:flag("technical", "The interviewer's reply couldn't be read; moved on.")
    end

    local asked = self:last_asked()
    if reply and reply.action == "rephrase" and asked then
        self:append("interviewer", Guard.question(reply.say) or asked.text, "rephrase", asked.question_id)
        return WAIT
    end

    if step.kind == "core" then
        if reply and reply.action == "follow_up" and s.follow_ups < s.kit.settings.max_follow_ups
            and self:seconds_left() > 60 then
            local q = Guard.question(reply.say)
            if q then
                s.follow_ups = s.follow_ups + 1
                self:append("interviewer", q, "follow_up", self:current_question_id())
                return WAIT
            end
        end
        self:advance(Guard.acknowledgement(reply and reply.say or ""))
        return self:finished_or_wait()
    elseif step.kind == "candidate_questions" then
        local action = reply and reply.action
        if action == "answer" then
            self:append("interviewer", Guard.answer(reply.say) .. " Do you have any other questions?", "answer")
            return WAIT
        elseif action == "forward" then
            if last then s.forwarded_questions[#s.forwarded_questions + 1] = last.text end
            self:append("interviewer", "I don't have that information, so I've passed your question to the hiring "
                .. "team. Is there anything else you'd like to ask?", "answer")
            return WAIT
        end
        s.step = s.step + 1
        self:close()
        return DONE
    end
    return WAIT
end

return Engine
