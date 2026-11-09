-- luacheck: max line length 140
--[[
    Shop survey funnel events: lib/shop-survey.lua rules + queries/ShopSurveyQueries.lua against a stub
    database + the wiring (migration registered, public ingest route, admin report, export, retention).

    Standalone — run from the repo root with:
        luajit lapis/spec/shop-survey_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local calls = {}
local function fake_rows(sql)
    if sql:find("AS today") then return { { today = "2026-11-09" } } end
    if sql:find("to_regclass") then return { { present = true } } end
    if sql:find("GROUP BY event") then
        return {
            { event = "view", visitors = 200 }, { event = "start", visitors = 120 }, { event = "result", visitors = 60 },
            { event = "lead", visitors = 15 }, { event = "apply", visitors = 6 }, { event = "unknown", visitors = 99 },
        }
    end
    if sql:find("per_step") then
        return {
            { step = 1, question = "use", visitors = 110, step_visitors = 110 },
            { step = 2, question = "budget", visitors = 80, step_visitors = 90 },
            { step = 2, question = "models", visitors = 10, step_visitors = 90 },
        }
    end
    if sql:find("event = 'apply'") then return { { plan = "y", visitors = 4 }, { plan = "m", visitors = 2 } } end
    if sql:find("FROM shop_memberships") then
        return { { started = 9, joined = 5, joined_yearly = 3, joined_monthly = 2 } }
    end
    if sql:find("DISTINCT ON") then
        return {
            { question = "use", answer = "ai-training", step = 1, visitors = 70 },
            { question = "use", answer = "inference", step = 1, visitors = 40 },
        }
    end
    return {}
end
package.loaded["lapis.db"] = {
    NULL = setmetatable({}, { __tostring = function() return "NULL" end }),
    query = function(sql, ...)
        calls[#calls + 1] = { sql = sql, args = { n = select("#", ...), ... } }
        return fake_rows(sql)
    end,
}

local failures = 0
local function check(name, ok, detail)
    print((ok and "  ok   - " or "  FAIL - ") .. name .. ((not ok and detail ~= nil) and ("  [" .. tostring(detail) .. "]") or ""))
    if not ok then failures = failures + 1 end
end

local function read(path)
    local f = assert(io.open(path))
    local s = f:read("*a")
    f:close()
    return s
end

local S = require("lib.shop-survey")

-- ---------------------------------------------------------------------------
print("Validation")
local VID = "v_3f9a2c71b0e44d1a"
local function ev(over)
    local e = { visitor_id = VID, event = "answer", step = 2, question = "budget", answer = "5k-15k" }
    for k, v in pairs(over or {}) do e[k] = v end
    return e
end

local list, code = S.validate_body(ev())
check("single event accepted", list ~= nil and #list == 1, code)
check("survey defaults to what-do-i-need", list and list[1].survey == "what-do-i-need")
check("fields kept", list and list[1].step == 2 and list[1].question == "budget" and list[1].answer == "5k-15k")

local dropped = S.validate_body(ev({ email = "a@b.co", ip = "1.2.3.4", name = "Jo", extra = { 1 } }))
local leaked = false
for k in pairs(dropped and dropped[1] or {}) do
    if k == "email" or k == "ip" or k == "name" or k == "extra" then leaked = true end
end
check("unknown fields dropped", dropped ~= nil and not leaked)

local batch = {}
for i = 1, S.MAX_BATCH do batch[i] = ev({ step = i }) end
local many = S.validate_body({ events = batch })
check("batch of 20 accepted", many ~= nil and #many == 20)
batch[#batch + 1] = ev()
local _, c_many = S.validate_body({ events = batch })
check("batch of 21 rejected", c_many == "TOO_MANY_EVENTS")
local _, c_empty = S.validate_body({ events = {} })
check("empty batch rejected", c_empty == "NO_EVENTS")
local _, c_obj = S.validate_body({ events = { a = ev() } })
check("events as an object rejected", c_obj == "INVALID_BODY")
local _, c_one_bad, m_one_bad = S.validate_body({ events = { ev(), ev({ event = "click" }) } })
check("one bad event rejects the batch, with its index", c_one_bad == "INVALID_EVENT" and m_one_bad:find("events%[2%]") ~= nil)

for _, e in ipairs(S.EVENTS) do
    local q = e == "answer" and "use" or nil
    check("event " .. e .. " accepted", S.validate_body({ visitor_id = VID, event = e, question = q }) ~= nil)
end

local cases = {
    { "unknown event", { event = "click" }, "INVALID_EVENT" },
    { "missing event", { event = false }, "INVALID_EVENT" },
    { "missing visitor id", { visitor_id = false }, "INVALID_VISITOR_ID" },
    { "short visitor id", { visitor_id = "abc" }, "INVALID_VISITOR_ID" },
    { "long visitor id", { visitor_id = string.rep("a", 65) }, "INVALID_VISITOR_ID" },
    { "visitor id with odd characters", { visitor_id = "abc def; drop" }, "INVALID_VISITOR_ID" },
    { "fractional step", { step = 1.5 }, "INVALID_STEP" },
    { "negative step", { step = -1 }, "INVALID_STEP" },
    { "step as text", { step = "2" }, "INVALID_STEP" },
    { "step over 100", { step = 101 }, "INVALID_STEP" },
    { "question over 120", { question = string.rep("q", 121) }, "INVALID_QUESTION" },
    { "answer over 120", { answer = string.rep("a", 121) }, "INVALID_ANSWER" },
    { "answer that is an email address", { answer = "me@firm.co.uk" }, "INVALID_ANSWER" },
    { "answer with a control character", { answer = "a\nb" }, "INVALID_ANSWER" },
    { "answer as a number", { answer = 5 }, "INVALID_ANSWER" },
    { "product over 32", { product = string.rep("p", 33) }, "INVALID_PRODUCT" },
    { "plan over 8", { plan = "yearly-plan" }, "INVALID_PLAN" },
    { "survey not a slug", { survey = "What Do I Need" }, "INVALID_SURVEY" },
    { "answer event without question", { question = false }, "INVALID_QUESTION" },
}
for _, c in ipairs(cases) do
    local over = {}
    for k, v in pairs(c[2]) do over[k] = (v ~= false) and v or nil end
    local e = ev(over)
    for k, v in pairs(c[2]) do if v == false then e[k] = nil end end
    local _, got = S.validate_body(e)
    check(c[1] .. " rejected", got == c[3], got)
end
local edge = S.validate_body(ev({ question = string.rep("q", 120), answer = "  trimmed  ", plan = "y", product = "dgx-spark" }))
check("120-character question kept, answer trimmed", edge and #edge[1].question == 120 and edge[1].answer == "trimmed")
check("survey param: default, valid, invalid", S.survey_param(nil) == "what-do-i-need"
    and S.survey_param("gpu-quiz") == "gpu-quiz" and S.survey_param("x'; drop") == nil)

-- ---------------------------------------------------------------------------
print("Report maths")
local f = S.funnel({ view = 200, start = 120, result = 60, lead = 15, apply = 6 })
check("funnel in order", f[1].stage == "view" and f[5].stage == "apply")
check("funnel rates", f[2].rate_from_previous == 0.6 and f[3].rate_from_previous == 0.5 and f[5].rate_from_view == 0.03)
check("first stage has no previous rate", f[1].rate_from_previous == nil and f[1].rate_from_view == 1)
local zero = S.funnel({})
check("empty funnel shows no rates, not 0%", zero[2].rate_from_previous == nil and zero[1].visitors == 0)

local d = S.dropoff({
    { step = 1, question = "use", visitors = 110, step_visitors = 110 },
    { step = 2, question = "budget", visitors = 80, step_visitors = 90 },
    { step = 2, question = "models", visitors = 10, step_visitors = 90 },
}, 120)
check("drop-off grouped by step", #d == 2 and #d[2].questions == 2)
check("first step measured against starters", d[1].previous_visitors == 120 and d[1].lost_from_previous == 0.0833)
check("next step measured against the previous step", d[2].lost_from_previous == 0.1818)
check("lost never negative", S.lost(130, 120) == 0 and S.lost(5, 0) == nil)

-- ---------------------------------------------------------------------------
print("Queries (stub database)")
local Q = require("queries.ShopSurveyQueries")

calls = {}
local stored = Q.record(42, S.validate_body({ events = { ev(), { visitor_id = VID, event = "view" } } }))
check("record inserts in one statement", stored == 2 and #calls == 1 and calls[1].args.n == 18)
check("record writes no ip/email column", not calls[1].sql:find("ip") and not calls[1].sql:find("email"))

local function placeholders(sql)
    local count = 0
    for _ in sql:gmatch("%?") do count = count + 1 end
    return count
end

calls = {}
local report, err = Q.report(42, { from = "2026-10-01", to = "2026-10-31" })
check("report builds", type(report) == "table" and report.window.days == 31, err)
check("visitors per event, unknown events ignored", report.visitors.view == 200 and report.visitors.ask == 0
    and report.visitors.unknown == nil)
check("funnel from visitors", report.funnel[2].rate_from_previous == 0.6)
check("drop-off uses starters", report.dropoff[1].previous_visitors == 120)
check("answers grouped by question", report.answers[1].question == "use" and #report.answers[1].answers == 2)
check("apply split by plan", report.apply_by_plan.y == 4 and report.apply_by_plan.m == 2 and report.apply_by_plan.total == 6)
check("trade sign-ups by plan", report.trade_signups.joined == 5 and report.trade_signups.joined_by_plan.y == 3)
check("retention reported", report.retention_months == 13 and report.complete == true)

local mismatched, unscoped = {}, {}
for _, c in ipairs(calls) do
    local sql = c.sql
    if placeholders(sql) ~= c.args.n then
        mismatched[#mismatched + 1] = ("%d placeholders, %d args: %s"):format(placeholders(sql), c.args.n,
            (sql:gsub("%s+", " ")):sub(1, 90))
    end
    if not (sql:find("AS today") or sql:find("to_regclass")) then
        local has_ns = false
        for i = 1, c.args.n do if c.args[i] == 42 then has_ns = true end end
        if not (sql:find("namespace_id = %?") and has_ns) then unscoped[#unscoped + 1] = (sql:gsub("%s+", " ")):sub(1, 90) end
    end
end
check("every query has as many parameters as placeholders", #mismatched == 0, mismatched[1])
check("every data query is scoped to the namespace", #unscoped == 0, unscoped[1])

local old = Q.report(42, { from = "2025-06-01", to = "2025-06-30" })
check("window older than 13 months flagged incomplete", old and old.complete == false)
local bad, e2 = Q.report(42, { from = "2026-12-01", to = "2026-11-01" })
check("bad window is an error", bad == nil and type(e2) == "string")
local bad2 = Q.report(42, { survey = "Not A Slug" })
check("bad survey is an error", bad2 == nil)

calls = {}
check("prune returns a count", Q.prune(42) == 0 and calls[1].sql:find("make_interval%(months") ~= nil and calls[1].args[2] == 13)

local QA = require("queries.ShopAnalyticsQueries")
local csv = QA.export(42, "survey", { days = "30" })
check("survey CSV export", csv and csv.key == "shop-survey-2026-10-11-to-2026-11-09" and #csv.columns == 6 and csv.row_count > 0)
local _, st = QA.export(42, "survey", { survey = "Bad Slug" })
check("survey CSV export rejects a bad survey", st == 400)

-- ---------------------------------------------------------------------------
print("Wiring")
local mig = read("lapis/migrations.lua")
check("migration registered as zzs38", mig:find("zzs38_shop_survey_events", 1, true) ~= nil)
check("migration module loaded under SHOP", mig:find('FEATURES.SHOP, "migrations.shop-survey"', 1, true) ~= nil)
local sql = read("lapis/migrations/shop-survey.lua")
for _, e in ipairs(S.EVENTS) do
    check("migration CHECK allows event " .. e, sql:find("'" .. e .. "'", 1, true) ~= nil)
end
check("window index", sql:find("(namespace_id, survey, created_at)", 1, true) ~= nil)
check("no personal columns", not sql:find("client_ip") and not sql:find("email varchar") and not sql:find("user_agent"))
local pub = read("lapis/routes/shop-public.lua")
local at = pub:find('app:post(BASE .. "/survey-events", public(', 1, true)
check("public POST /survey-events exists behind public()", at ~= nil)
check("ingest is rate limited per visitor", at and pub:find('"shop_survey:" .. visitor_ip(self)', at, true) ~= nil)
check("ingest answers 202", at and pub:find("U.ok({ accepted = accepted }, 202)", at, true) ~= nil)
local admin = read("lapis/routes/shop-analytics.lua")
check("admin GET /survey behind the analytics guard", admin:find('app:get(BASE .. "/survey", guard(', 1, true) ~= nil)
local ins = read("lapis/queries/ShopInsightsQueries.lua")
check("daily job prunes survey events", ins:find("ShopSurveyQueries\").prune", 1, true) ~= nil)

print(failures == 0 and "\nall shop-survey checks passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
