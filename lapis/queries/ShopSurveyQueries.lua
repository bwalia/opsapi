-- luacheck: max line length 140
--[[
    Shop survey funnel events (shop_survey_events, migrations/shop-survey.lua)
    ===========================================================================
      record(ns_id, events)        POST /api/v2/public/shop/:ns/survey-events (validated by lib/shop-survey.lua)
      report(ns_id, params)        GET  /api/v2/shop/admin/analytics/survey
      export_rows(ns_id, w, s)     GET  /api/v2/shop/admin/analytics/export?report=survey
      prune(ns_id)                 13-month retention (ShopInsightsQueries.dailySnapshot)

    Every figure counts DISTINCT visitor_id, so a visitor who reloads or goes back is counted once.
    Windows are UK calendar days, inclusive, exactly as the rest of Shop Analytics (lib/shop-analytics.lua).
]]

local db = require("lapis.db")
local A = require("lib.shop-analytics")
local S = require("lib.shop-survey")

local Q = {}

local TZ = "'" .. A.TIMEZONE .. "'"
local BOUND = "((?::date)::timestamp AT TIME ZONE " .. TZ .. ")"
-- Tenant + survey + window: parameters ns_id, survey, from, to_exclusive.
local SCOPE = "namespace_id = ? AND survey = ? AND created_at >= " .. BOUND .. " AND created_at < " .. BOUND
local n = A.num
local unpack = table.unpack or unpack -- luacheck: ignore 143 113

local function opt(v)
    if v == nil then return db.NULL end
    return v
end

--- Insert validated events (one statement). Returns the number stored.
function Q.record(ns_id, events)
    local rows, args = {}, {}
    for _, e in ipairs(events) do
        rows[#rows + 1] = "(?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())"
        local vals = { ns_id, e.survey, e.visitor_id, e.event, opt(e.step), opt(e.question), opt(e.answer),
            opt(e.product), opt(e.plan) }
        for _, v in ipairs(vals) do args[#args + 1] = v end
    end
    if #rows == 0 then return 0 end
    db.query([[
        INSERT INTO shop_survey_events (namespace_id, survey, visitor_id, event, step, question, answer, product, plan, created_at)
        VALUES ]] .. table.concat(rows, ", "), unpack(args))
    return #rows
end

--- Delete events older than the retention period. Returns the number deleted.
function Q.prune(ns_id)
    local rows = db.query([[
        DELETE FROM shop_survey_events WHERE namespace_id = ? AND created_at < NOW() - make_interval(months => ?)
        RETURNING id
    ]], ns_id, S.RETENTION_MONTHS)
    return #rows
end

-- ---------------------------------------------------------------------------
-- Report parts
-- ---------------------------------------------------------------------------

--- Distinct visitors per event type (every type present, zero when unseen).
function Q.visitors_by_event(ns_id, survey, from, to_excl)
    local out = {}
    for _, e in ipairs(S.EVENTS) do out[e] = 0 end
    for _, r in ipairs(db.query([[
        SELECT event, COUNT(DISTINCT visitor_id)::int AS visitors
          FROM shop_survey_events WHERE ]] .. SCOPE .. [[
         GROUP BY event
    ]], ns_id, survey, from, to_excl)) do
        if out[r.event] ~= nil then out[r.event] = n(r.visitors) end
    end
    return out
end

--- Distinct visitors answering each question, with each step's distinct total.
function Q.question_reach(ns_id, survey, from, to_excl)
    local rows = db.query([[
        WITH a AS (
            SELECT step, question, visitor_id
              FROM shop_survey_events WHERE ]] .. SCOPE .. [[ AND event = 'answer'
        ),
        per_step AS (
            SELECT step, COUNT(DISTINCT visitor_id)::int AS step_visitors FROM a GROUP BY step
        )
        SELECT a.step, a.question, COUNT(DISTINCT a.visitor_id)::int AS visitors, MAX(p.step_visitors) AS step_visitors
          FROM a JOIN per_step p ON p.step IS NOT DISTINCT FROM a.step
         GROUP BY a.step, a.question
         ORDER BY a.step NULLS LAST, a.question
    ]], ns_id, survey, from, to_excl)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            step = tonumber(r.step), question = r.question,
            visitors = n(r.visitors), step_visitors = n(r.step_visitors),
        }
    end
    return out
end

--- Each visitor's final answer per question (going back and changing it counts the new answer),
-- then visitors per answer; the top `limit` answers per question.
function Q.top_answers(ns_id, survey, from, to_excl, limit)
    local rows = db.query([[
        WITH last AS (
            SELECT DISTINCT ON (visitor_id, question) visitor_id, question, answer, step
              FROM shop_survey_events
             WHERE ]] .. SCOPE .. [[ AND event = 'answer' AND answer IS NOT NULL
             ORDER BY visitor_id, question, created_at DESC, id DESC
        ),
        counted AS (
            SELECT question, answer, MIN(step) AS step, COUNT(*)::int AS visitors
              FROM last GROUP BY question, answer
        ),
        ranked AS (
            SELECT question, answer, visitors,
                   MIN(step) OVER (PARTITION BY question) AS step,
                   ROW_NUMBER() OVER (PARTITION BY question ORDER BY visitors DESC, answer) AS rank
              FROM counted
        )
        SELECT question, answer, step, visitors FROM ranked WHERE rank <= ?
         ORDER BY step NULLS LAST, question, visitors DESC, answer
    ]], ns_id, survey, from, to_excl, limit)
    for _, r in ipairs(rows) do
        r.visitors = n(r.visitors)
        r.step = tonumber(r.step)
    end
    return rows
end

--- Distinct visitors who applied, by Trade plan (y = yearly, m = monthly; "unknown" when not sent).
function Q.apply_by_plan(ns_id, survey, from, to_excl)
    local out = { y = 0, m = 0 }
    for _, r in ipairs(db.query([[
        SELECT COALESCE(plan, 'unknown') AS plan, COUNT(DISTINCT visitor_id)::int AS visitors
          FROM shop_survey_events WHERE ]] .. SCOPE .. [[ AND event = 'apply'
         GROUP BY 1
    ]], ns_id, survey, from, to_excl)) do
        out[r.plan] = n(r.visitors)
    end
    return out
end

--- Distinct visitors whose result recommended each product.
function Q.results_by_product(ns_id, survey, from, to_excl, limit)
    local rows = db.query([[
        SELECT product, COUNT(DISTINCT visitor_id)::int AS visitors
          FROM shop_survey_events WHERE ]] .. SCOPE .. [[ AND event = 'result' AND product IS NOT NULL
         GROUP BY product ORDER BY visitors DESC, product LIMIT ?
    ]], ns_id, survey, from, to_excl, limit)
    for _, r in ipairs(rows) do r.visitors = n(r.visitors) end
    return rows
end

local trade_table
--- Trade sign-ups in the window from shop_memberships (only when membership is deployed: SHOP + BILLING).
-- Not linked to survey visitors: these are every Trade join in the window, for context.
function Q.trade_signups(ns_id, from, to_excl)
    if trade_table == nil then
        local r = db.query("SELECT to_regclass('shop_memberships') IS NOT NULL AS present")[1] or {}
        trade_table = r.present == true
    end
    if not trade_table then return nil end
    local r = db.query([[
        SELECT COUNT(*) FILTER (WHERE created_at >= ]] .. BOUND .. [[ AND created_at < ]] .. BOUND .. [[)::int AS started,
               COUNT(*) FILTER (WHERE joined_at >= ]] .. BOUND .. [[ AND joined_at < ]] .. BOUND .. [[)::int AS joined,
               COUNT(*) FILTER (WHERE joined_at >= ]] .. BOUND .. [[ AND joined_at < ]] .. BOUND .. [[
                                AND billing_interval = 'year')::int AS joined_yearly,
               COUNT(*) FILTER (WHERE joined_at >= ]] .. BOUND .. [[ AND joined_at < ]] .. BOUND .. [[
                                AND billing_interval = 'month')::int AS joined_monthly
          FROM shop_memberships WHERE namespace_id = ?
    ]], from, to_excl, from, to_excl, from, to_excl, from, to_excl, ns_id)[1] or {}
    return {
        checkouts_started = n(r.started),
        joined = n(r.joined),
        joined_by_plan = { y = n(r.joined_yearly), m = n(r.joined_monthly) },
    }
end
Q._reset_schema_cache = function() trade_table = nil end

function Q.today()
    return db.query("SELECT to_char((NOW() AT TIME ZONE " .. TZ .. ")::date, 'YYYY-MM-DD') AS today")[1].today
end

-- ---------------------------------------------------------------------------
-- The whole report
-- ---------------------------------------------------------------------------

--- params: { from?, to?, days?, survey? }. Returns report or nil, error message (a 400).
function Q.report(ns_id, params)
    params = params or {}
    local survey = S.survey_param(params.survey)
    if not survey then return nil, "survey must be a lower-case slug" end
    local today = Q.today()
    local w, err = A.window({ from = params.from, to = params.to, days = params.days }, today)
    if not w then return nil, err end
    local from, to_excl = w.from, w.to_exclusive

    local by_event = Q.visitors_by_event(ns_id, survey, from, to_excl)
    local apply = Q.apply_by_plan(ns_id, survey, from, to_excl)
    apply.total = by_event.apply
    -- Lists go out as [] even when empty (the dashboard maps over them).
    local dropoff = S.dropoff(Q.question_reach(ns_id, survey, from, to_excl), by_event.start)
    for _, d in ipairs(dropoff) do A.list(d.questions) end
    local answers = S.answers_by_question(Q.top_answers(ns_id, survey, from, to_excl, 10))
    for _, a in ipairs(answers) do A.list(a.answers) end
    return {
        survey = survey,
        window = { from = w.from, to = w.to, days = w.days, timezone = w.timezone, includes_today = w.includes_today },
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        visitors = by_event,
        funnel = A.list(S.funnel(by_event)),
        dropoff = A.list(dropoff),
        answers = A.list(answers),
        results_by_product = A.list(Q.results_by_product(ns_id, survey, from, to_excl, 20)),
        apply_by_plan = apply,
        trade_signups = Q.trade_signups(ns_id, from, to_excl),
        retention_months = S.RETENTION_MONTHS,
        -- Events older than the retention period are deleted, so a window reaching further back is partial.
        -- 393 days = the shortest 13 months (a February in it).
        complete = A.day_number(w.from) >= A.day_number(today) - 393,
    }
end

--- Flat rows for the CSV export (?report=survey): funnel, drop-off and answers in one sheet.
function Q.export_rows(ns_id, w, survey)
    local from, to_excl = w.from, w.to_exclusive
    local by_event = Q.visitors_by_event(ns_id, survey, from, to_excl)
    local rows = {}
    local function pct(v) return v and string.format("%.1f", v * 100) or "" end
    for _, f in ipairs(S.funnel(by_event)) do
        rows[#rows + 1] = { section = "funnel", step = "", label = f.stage, detail = "",
            visitors = f.visitors, rate = pct(f.rate_from_previous) }
    end
    for _, s in ipairs(S.dropoff(Q.question_reach(ns_id, survey, from, to_excl), by_event.start)) do
        for _, q in ipairs(s.questions) do
            rows[#rows + 1] = { section = "question", step = s.step or "", label = q.question or "", detail = "",
                visitors = q.visitors, rate = pct(s.lost_from_previous) }
        end
    end
    for _, r in ipairs(Q.top_answers(ns_id, survey, from, to_excl, 50)) do
        rows[#rows + 1] = { section = "answer", step = r.step or "", label = r.question or "", detail = r.answer or "",
            visitors = r.visitors, rate = "" }
    end
    return rows
end

Q.EXPORT_COLUMNS = {
    { key = "section", label = "Section", type = "text" },
    { key = "step", label = "Step", type = "text" },
    { key = "label", label = "Stage / question", type = "text" },
    { key = "detail", label = "Answer", type = "text" },
    { key = "visitors", label = "Visitors", type = "number" },
    { key = "rate", label = "Funnel: % of previous stage; question: % lost from previous step", type = "text" },
}

return Q
