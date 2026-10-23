--[[
    ATS — interview kits (shared contract: snazzy docs/specs/fixtures/interview-kit.json,
    RoleKit.swift). normalise() fills defaults the way the Swift decoder does;
    validate() ports KitValidator. Errors block approval; warnings are shown and
    the recruiter decides.
]]

local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local T = require("lib.ats.text")
local Topics = require("lib.ats.topics")
local J = require("lib.ats.json")

local Kit = {}

Kit.FORMAT = 1

Kit.DEFAULT_ADJUSTMENTS = { "extra time", "a pause", "questions repeated or rephrased", "text instead of voice",
    "voice instead of text", "large text or high contrast" }

local function default_settings()
    return {
        interviewer_name = "Snazzy Interviewer", minutes = 25, max_follow_ups = 2, seconds_per_answer = 0,
        allow_voice = true, allow_pause = true, allowed_adjustments = J.array({ unpack(Kit.DEFAULT_ADJUSTMENTS) }),
        next_steps = "The hiring team reviews every interview and will contact you within 5 working days.",
        ratings_enabled = true, written_communication = false, retention_days = 180,
    }
end

Kit.default_settings = default_settings

local function str(v, default)
    v = J.val(v)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return default
end

local function list(v)
    v = J.val(v)
    return type(v) == "table" and v or {}
end

--- A kit table with every field present (tolerant, like RoleKit's decoder).
function Kit.normalise(k)
    k = type(k) == "table" and k or {}
    local out = {
        id = str(k.id, nil), format = tonumber(J.val(k.format)) or Kit.FORMAT, version = tonumber(J.val(k.version))
            or 0,
        title = str(k.title, "Untitled role"), organisation = str(k.organisation, ""), summary = str(k.summary, ""),
        language = str(k.language, "en-GB"), job_description = str(k.job_description, ""),
        approved_at = str(k.approved_at, nil), approved_by = str(k.approved_by, nil),
        created = str(k.created, nil), updated = str(k.updated, nil),
    }
    -- Generators sometimes give lists; keep them as lines.
    local facts = J.val(k.company_facts)
    if type(facts) == "table" then
        local lines = {}
        for _, l in ipairs(facts) do lines[#lines + 1] = tostring(l) end
        out.company_facts = table.concat(lines, "\n")
    else
        out.company_facts = str(facts, "")
    end
    out.warnings = J.array({})
    for _, w in ipairs(list(k.warnings)) do
        if type(w) == "string" then
            out.warnings[#out.warnings + 1] = w
        elseif type(w) == "table" then
            local values = {}
            for _, v in pairs(w) do values[#values + 1] = tostring(v) end
            table.sort(values)
            out.warnings[#out.warnings + 1] = table.concat(values, " → ")
        end
    end
    out.competencies = J.array({})
    for _, c in ipairs(list(k.competencies)) do
        if type(c) == "table" and str(c.id, nil) then
            local a = type(J.val(c.anchors)) == "table" and c.anchors or {}
            out.competencies[#out.competencies + 1] = {
                id = str(c.id), name = str(c.name, str(c.id)), description = str(c.description, ""),
                weight = math.floor(tonumber(J.val(c.weight)) or 0), source = str(c.source, ""),
                anchors = { ["1"] = str(a["1"], ""), ["3"] = str(a["3"], ""), ["5"] = str(a["5"], "") },
            }
        end
    end
    out.eligibility = J.array({})
    for _, e in ipairs(list(k.eligibility)) do
        if type(e) == "table" and str(e.id, nil) then
            local kind = str(e.kind, "text")
            if kind ~= "yes_no" and kind ~= "choice" and kind ~= "text" then kind = "text" end
            out.eligibility[#out.eligibility + 1] = {
                id = str(e.id), text = str(e.text, ""), kind = kind,
                options = J.array({ unpack(list(e.options)) }), accepted = J.array({ unpack(list(e.accepted)) }),
            }
        end
    end
    out.questions = J.array({})
    for _, q in ipairs(list(k.questions)) do
        if type(q) == "table" and str(q.id, nil) then
            local kind = str(q.kind, "behavioural")
            if kind ~= "behavioural" and kind ~= "situational" then kind = "behavioural" end
            out.questions[#out.questions + 1] = { id = str(q.id), text = str(q.text, ""),
                competency = str(q.competency, ""), kind = kind }
        end
    end
    local s, d = type(J.val(k.settings)) == "table" and k.settings or {}, default_settings()
    out.settings = {}
    for key, default in pairs(d) do
        local v = J.val(s[key])
        if v == nil or type(v) ~= type(default) then v = default end
        if type(default) == "number" then v = math.floor(v) end
        out.settings[key] = v
    end
    out.settings.allowed_adjustments = J.array({ unpack(out.settings.allowed_adjustments) })
    return out
end

function Kit.competency(kit, id)
    for _, c in ipairs(kit.competencies) do
        if c.id == id then return c end
    end
end

--- The fixed choices for an eligibility question (nil: free text).
function Kit.choices(q)
    if q.kind == "yes_no" then return { "Yes", "No" } end
    if q.kind == "choice" and #q.options > 0 then return q.options end
    return nil
end

--- Whether an eligibility answer meets the requirement; nil when the kit doesn't say.
function Kit.meets(q, answer)
    if #q.accepted == 0 then return nil end
    local a = T.trim(answer):lower()
    for _, ok in ipairs(q.accepted) do
        if tostring(ok):lower() == a then return true end
    end
    return false
end

function Kit.allows_criminal_record_question(kit)
    return T.contains(kit.company_facts:lower(), "legal basis for criminal record question:")
end

--- Issues: { severity = "error"|"warning", message, subject }.
function Kit.validate(kit)
    kit = Kit.normalise(kit)
    local issues = {}
    local function add(sev, m, s) issues[#issues + 1] = { severity = sev, message = m, subject = s } end
    local function err(m, s) add("error", m, s) end
    local function warn(m, s) add("warning", m, s) end

    if T.trim(kit.title) == "" then err("Give the role a title.") end
    if #kit.competencies == 0 then err("Add at least one competency.") end
    if #kit.competencies > 8 then warn("More than 8 competencies makes a first-round interview long and shallow.") end
    if #kit.questions == 0 then err("Add at least one core question.") end
    if #kit.eligibility > 5 then warn("More than 5 eligibility questions; keep only hard requirements.") end

    local counts, order = {}, {}
    local function count(id)
        if not counts[id] then order[#order + 1] = id end
        counts[id] = (counts[id] or 0) + 1
    end
    for _, c in ipairs(kit.competencies) do count(c.id) end
    for _, q in ipairs(kit.questions) do count(q.id) end
    for _, e in ipairs(kit.eligibility) do count(e.id) end
    for _, id in ipairs(order) do
        if counts[id] > 1 then err("The id “" .. id .. "” is used twice.", id) end
        if T.trim(id) == "" then err("Every competency and question needs an id.") end
    end

    local weights = 0
    for _, c in ipairs(kit.competencies) do weights = weights + c.weight end
    if #kit.competencies > 0 and weights ~= 100 then
        warn("Competency weights add up to " .. weights .. ", not 100.")
    end

    for _, c in ipairs(kit.competencies) do
        if T.trim(c.name) == "" then err("A competency has no name.", c.id) end
        local a = c.anchors
        if T.trim(a["1"]) == "" or T.trim(a["3"]) == "" or T.trim(a["5"]) == "" then
            err("“" .. c.name .. "” needs rubric anchors for levels 1, 3 and 5.", c.id)
        end
        local asked = false
        for _, q in ipairs(kit.questions) do
            if q.competency == c.id then asked = true end
        end
        if not asked then err("No question gathers evidence for “" .. c.name .. "”.", c.id) end
        for _, problem in ipairs(Topics.find(table.concat({ c.name, c.description, a["1"], a["3"], a["5"] }, " "))) do
            warn("“" .. c.name .. "” mentions " .. problem
                .. ". Rubrics should describe what people did, not who they are.", c.id)
        end
    end
    for _, q in ipairs(kit.questions) do
        if T.trim(q.text) == "" then err("A question has no text.", q.id) end
        if not Kit.competency(kit, q.competency) then
            err("Question “" .. q.id .. "” isn't linked to a competency in this kit.", q.id)
        end
        for _, problem in ipairs(Topics.find(q.text)) do err("Question “" .. q.id .. "” asks about " .. problem
            .. ".", q.id) end
        local _, marks = q.text:gsub("%?", "")
        if marks > 2 then
            warn("Question “" .. q.id .. "” asks several things at once; candidates answer better one at a time.", q.id)
        end
    end
    for _, e in ipairs(kit.eligibility) do
        if T.trim(e.text) == "" then err("An eligibility question has no text.", e.id) end
        for _, problem in ipairs(Topics.find(e.text, Kit.allows_criminal_record_question(kit))) do
            err("Eligibility question “" .. e.id .. "” asks about " .. problem .. ".", e.id)
        end
        if Topics.asks_salary_history(e.text) then
            err("Eligibility question “" .. e.id .. "” asks for salary history. Ask for expectations instead.", e.id)
        end
        if e.kind == "choice" and #e.options < 2 then
            err("Eligibility question “" .. e.id .. "” needs at least two options.", e.id)
        end
    end
    if T.trim(kit.company_facts) == "" then
        warn("Add company facts (hours, pay range, team, process) so the interviewer can answer candidates' questions.")
    end
    if kit.settings.minutes < 10
        or kit.settings.minutes > 60 then warn("Interviews between 10 and 60 minutes work best.") end
    if kit.settings.max_follow_ups > 3 then
        warn("More than 3 follow-ups per question can feel like an interrogation.")
    end
    return issues
end

--- The kit a candidate's device may hold (offline interviews): the rubric anchors
-- (levels 1/3/5) are the evaluator's alone and are blanked; everything the
-- interviewer needs (questions, competencies, weights, settings, facts, the job
-- description) is kept. Returns a new table; the input is not changed.
function Kit.for_candidate(kit)
    local out = Kit.normalise(J.decode(J.encode(Kit.normalise(kit))))
    for _, c in ipairs(out.competencies) do
        c.anchors = { ["1"] = "", ["3"] = "", ["5"] = "" }
    end
    return out
end

function Kit.can_approve(kit)
    for _, i in ipairs(Kit.validate(kit)) do
        if i.severity == "error" then return false end
    end
    return true
end

return Kit
