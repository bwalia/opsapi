-- luacheck: max line length 140
--[[
    Shop survey funnel events — pure rules (no nginx, no DB), unit-tested in spec/shop-survey_spec.lua.

    The shop's "What do I need?" survey (shop.workstation.co.uk/trade/what-do-i-need) reports how far
    people get: view → start → answer (per question) → result → lead / ask / apply. Each event is
    stored first-party in shop_survey_events (migrations/shop-survey.lua).

    Non-personal by design: a random visitor id the browser makes up, the event, and the survey's own
    labels (question key, answer key, product, plan). No IP address, email, name or free text is stored.
    The rules below refuse anything that looks like an email address, so a free-text box cannot leak
    one into the table by mistake.
]]

local M = {}

M.DEFAULT_SURVEY = "what-do-i-need"
M.EVENTS = { "view", "start", "answer", "back", "result", "lead", "ask", "apply" }
local EVENT = {}
for _, e in ipairs(M.EVENTS) do EVENT[e] = true end

-- The funnel shown in the report, in order.
M.FUNNEL = { "view", "start", "result", "lead", "apply" }

M.MAX_BATCH = 20
M.MAX_STEP = 100
M.LIMITS = { survey = 48, visitor_id = 64, question = 120, answer = 120, product = 32, plan = 8 }
M.MIN_VISITOR_ID = 8

-- Raw events are deleted after this long (ShopInsightsQueries.dailySnapshot, the daily market-sync job).
M.RETENTION_MONTHS = 13

local cjson_null
do
    local ok, cjson = pcall(require, "cjson")
    cjson_null = ok and cjson.null or nil
end

local function absent(v)
    return v == nil or (cjson_null ~= nil and v == cjson_null)
end

local function trim(v)
    return (v:match("^%s*(.-)%s*$"))
end

--- Optional string field: (value | nil, ok). ok=false means present but invalid.
-- pattern: a whole-string Lua pattern the trimmed value must match.
local function str(v, max, pattern)
    if absent(v) then return nil, true end
    if type(v) ~= "string" then return nil, false end
    v = trim(v)
    if v == "" then return nil, true end
    if #v > max then return nil, false end
    if v:find("[%c]") then return nil, false end
    if pattern and not v:match(pattern) then return nil, false end
    return v, true
end

local function looks_like_email(v)
    return v ~= nil and v:find("[^%s@]+@[^%s@]+%.[^%s@]+") ~= nil
end

local SLUG = "^[a-z0-9][a-z0-9%-]*$"
local TOKEN = "^[%w_%-]+$"
local KEY = "^[%w][%w%._:%-]*$"

local function bad(code, message, index)
    local msg = message
    if index then msg = ("events[%d]: %s"):format(index, message) end
    return nil, code, msg
end

--- Validate one event. Unknown fields are dropped.
-- Returns rec | nil, code, message.
function M.validate_event(e, index)
    if type(e) ~= "table" then return bad("INVALID_EVENT", "each event must be an object", index) end

    local survey, ok = str(e.survey, M.LIMITS.survey, SLUG)
    if not ok then return bad("INVALID_SURVEY", "survey must be a lower-case slug of up to 48 characters", index) end

    local visitor_id
    visitor_id, ok = str(e.visitor_id, M.LIMITS.visitor_id, TOKEN)
    if not ok or not visitor_id or #visitor_id < M.MIN_VISITOR_ID then
        return bad("INVALID_VISITOR_ID", "visitor_id is required: 8-64 characters of A-Z, a-z, 0-9, _ or -", index)
    end

    local event = type(e.event) == "string" and trim(e.event) or nil
    if not event or not EVENT[event] then
        return bad("INVALID_EVENT", "event must be one of: " .. table.concat(M.EVENTS, ", "), index)
    end

    local step
    if not absent(e.step) then
        step = tonumber(e.step)
        if type(e.step) ~= "number" or not step or step ~= math.floor(step) or step < 0 or step > M.MAX_STEP then
            return bad("INVALID_STEP", "step must be a whole number from 0 to " .. M.MAX_STEP, index)
        end
    end

    local question, answer, product, plan
    question, ok = str(e.question, M.LIMITS.question)
    if not ok or looks_like_email(question) then
        return bad("INVALID_QUESTION", "question must be text of up to 120 characters", index)
    end
    answer, ok = str(e.answer, M.LIMITS.answer)
    if not ok or looks_like_email(answer) then
        return bad("INVALID_ANSWER", "answer must be text of up to 120 characters, and not an email address", index)
    end
    product, ok = str(e.product, M.LIMITS.product, KEY)
    if not ok then return bad("INVALID_PRODUCT", "product must be a key of up to 32 characters", index) end
    plan, ok = str(e.plan, M.LIMITS.plan, TOKEN)
    if not ok then return bad("INVALID_PLAN", "plan must be a key of up to 8 characters", index) end

    if event == "answer" and not question then
        return bad("INVALID_QUESTION", "an answer event needs a question", index)
    end

    return {
        survey = survey or M.DEFAULT_SURVEY,
        visitor_id = visitor_id,
        event = event,
        step = step,
        question = question,
        answer = answer,
        product = product,
        plan = plan,
    }
end

local function is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

--- Validate a POST /survey-events body: one event object, or { events = [ ... ] } (1 to 20).
-- Returns list | nil, code, message. Any invalid event rejects the whole batch.
function M.validate_body(body)
    if type(body) ~= "table" then return nil, "INVALID_BODY", "body must be a JSON object" end
    local list = body.events
    if absent(list) then
        list = { body }
    elseif not is_array(list) then
        return nil, "INVALID_BODY", "events must be an array"
    end
    if #list == 0 then return nil, "NO_EVENTS", "events must not be empty" end
    if #list > M.MAX_BATCH then
        return nil, "TOO_MANY_EVENTS", ("at most %d events per request"):format(M.MAX_BATCH)
    end
    local out = {}
    for i, e in ipairs(list) do
        local rec, code, msg = M.validate_event(e, #list > 1 and i or nil)
        if not rec then return nil, code, msg end
        out[#out + 1] = rec
    end
    return out
end

--- Survey slug for the report (?survey=), default "what-do-i-need". nil when invalid.
function M.survey_param(v)
    local s, ok = str(v, M.LIMITS.survey, SLUG)
    if not ok then return nil end
    return s or M.DEFAULT_SURVEY
end

-- ---------------------------------------------------------------------------
-- Report maths
-- ---------------------------------------------------------------------------

--- n / d to 4 decimal places; nil when d is 0 (the UI shows "—", never a misleading 0%).
function M.ratio(n, d)
    n, d = tonumber(n), tonumber(d)
    if not n or not d or d <= 0 then return nil end
    return math.floor(n / d * 10000 + 0.5) / 10000
end

--- Share lost between two counts (0.25 = 25% lost). nil without a previous count; never negative.
function M.lost(cur, prev)
    cur, prev = tonumber(cur), tonumber(prev)
    if not cur or not prev or prev <= 0 then return nil end
    return math.max(0, math.floor((prev - cur) / prev * 10000 + 0.5) / 10000)
end

--- Funnel from distinct-visitor counts per event: { {stage, visitors, rate_from_previous, rate_from_view}, … }
function M.funnel(by_event)
    local out = {}
    local first = tonumber(by_event[M.FUNNEL[1]]) or 0
    local prev
    for _, stage in ipairs(M.FUNNEL) do
        local v = tonumber(by_event[stage]) or 0
        out[#out + 1] = {
            stage = stage,
            visitors = v,
            rate_from_previous = prev and M.ratio(v, prev) or nil,
            rate_from_view = M.ratio(v, first),
        }
        prev = v
    end
    return out
end

--- Drop-off by step. rows: { step, question, visitors, step_visitors } ordered by step then question,
-- where step_visitors is the distinct visitors answering anything at that step.
-- starters: distinct visitors who started (the baseline for the first step).
-- Returns { {step, visitors, lost_from_previous, questions = {{question, visitors}}}, … }
function M.dropoff(rows, starters)
    local steps, by_step = {}, {}
    for _, r in ipairs(rows or {}) do
        local key = r.step == nil and "none" or tostring(r.step)
        local s = by_step[key]
        if not s then
            s = { step = r.step, visitors = tonumber(r.step_visitors) or 0, questions = {} }
            by_step[key] = s
            steps[#steps + 1] = s
        end
        s.questions[#s.questions + 1] = { question = r.question, visitors = tonumber(r.visitors) or 0 }
    end
    local prev = tonumber(starters)
    for _, s in ipairs(steps) do
        s.previous_visitors = prev
        s.lost_from_previous = M.lost(s.visitors, prev)
        prev = s.visitors
    end
    return steps
end

--- Group top-answer rows ({question, answer, visitors, rank}) by question, keeping row order.
function M.answers_by_question(rows)
    local out, idx = {}, {}
    for _, r in ipairs(rows or {}) do
        local q = idx[r.question]
        if not q then
            q = { question = r.question, step = r.step, answers = {} }
            idx[r.question] = q
            out[#out + 1] = q
        end
        q.answers[#q.answers + 1] = { answer = r.answer, visitors = tonumber(r.visitors) or 0 }
    end
    return out
end

return M
