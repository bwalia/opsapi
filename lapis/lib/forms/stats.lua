--[[
    Form analytics: views, starts and steps reached per form per day (UTC)
    ====================================================================

    A view is the public GET; a start is the visitor's first answer; a step is
    a step of a multi-step form reached (the page reports both, best effort).
    Counted in this worker's memory and added to form_daily_stats every
    FLUSH_SECONDS, so a popular form costs one write per worker per flush, not
    one per visitor. A worker that dies loses at most that many seconds of
    counts: fine for analytics. Responses come from form_submissions itself.
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")

local Stats = {}

Stats.FLUSH_SECONDS = 30
Stats.MAX_STEP = 50

local pending = {} -- [form_id] = { [day] = { views, starts, steps = { [n] = count } } }

local function today()
    return os.date("!%Y-%m-%d")
end

--- Count one event. kind: "view" | "start" | "step" (with step n >= 2).
function Stats.hit(form_id, kind, step)
    form_id = tonumber(form_id)
    if not form_id then return end
    local day = today()
    pending[form_id] = pending[form_id] or {}
    local c = pending[form_id][day]
    if not c then
        c = { views = 0, starts = 0, steps = {} }
        pending[form_id][day] = c
    end
    if kind == "view" then
        c.views = c.views + 1
    elseif kind == "start" then
        c.starts = c.starts + 1
    elseif kind == "step" then
        local n = tonumber(step)
        if n and n >= 2 and n <= Stats.MAX_STEP and n == math.floor(n) then
            c.steps[tostring(n)] = (c.steps[tostring(n)] or 0) + 1
        end
    end
end

--- Add this worker's counts to the table (the counts are handed over first,
-- so hits during the writes start a fresh batch).
function Stats.flush()
    local batch = pending
    pending = {}
    for form_id, days in pairs(batch) do
        for day, c in pairs(days) do
            local ok, err = pcall(db.query, [[
                INSERT INTO form_daily_stats (form_id, day, views, starts, steps)
                SELECT ?, ?::date, ?, ?, ?::jsonb WHERE EXISTS (SELECT 1 FROM forms WHERE id = ?)
                ON CONFLICT (form_id, day) DO UPDATE SET
                    views = form_daily_stats.views + EXCLUDED.views,
                    starts = form_daily_stats.starts + EXCLUDED.starts,
                    steps = (SELECT COALESCE(jsonb_object_agg(k, COALESCE((form_daily_stats.steps ->> k)::int, 0)
                                                             + COALESCE((EXCLUDED.steps ->> k)::int, 0)), '{}'::jsonb)
                             FROM jsonb_object_keys(form_daily_stats.steps || EXCLUDED.steps) k)
            ]], form_id, day, c.views, c.starts, cjson.encode(c.steps), form_id)
            if not ok then ngx.log(ngx.WARN, "[forms] stats flush failed: ", tostring(err)) end
        end
    end
end

function Stats.tick(premature)
    Stats.flush()
    if premature then return end -- shutting down: flushed what we had
    require("helper.plugin-events").releaseConnection()
end

--- Analytics for one form over the last `days` days (admin API).
function Stats.report(form, days)
    days = math.min(math.max(math.floor(tonumber(days) or 30), 1), 365)
    local since = os.date("!%Y-%m-%d", os.time() - (days - 1) * 86400)
    local series, by_day = {}, {}
    for i = days - 1, 0, -1 do
        local d = os.date("!%Y-%m-%d", os.time() - i * 86400)
        local row = { day = d, views = 0, starts = 0, responses = 0 }
        series[#series + 1] = row
        by_day[d] = row
    end
    local steps = {}
    for _, r in ipairs(db.query([[SELECT to_char(day, 'YYYY-MM-DD') AS d, views, starts, steps
        FROM form_daily_stats WHERE form_id = ? AND day >= ?::date]], form.id, since)) do
        local row = by_day[r.d]
        if row then
            row.views, row.starts = tonumber(r.views), tonumber(r.starts)
            local s = type(r.steps) == "string" and cjson.decode(r.steps) or r.steps or {}
            for k, v in pairs(s) do steps[k] = (steps[k] or 0) + tonumber(v) end
        end
    end
    for _, r in ipairs(db.query([[
        SELECT to_char((created_at AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD') AS d, COUNT(*)::int AS n
        FROM form_submissions WHERE form_id = ? AND status <> 'spam' AND created_at >= ?::date
        GROUP BY 1
    ]], form.id, since)) do
        if by_day[r.d] then by_day[r.d].responses = tonumber(r.n) end
    end
    local totals = { views = 0, starts = 0, responses = 0 }
    for _, row in ipairs(series) do
        for k in pairs(totals) do totals[k] = totals[k] + row[k] end
    end
    totals.conversion = totals.views > 0 and math.floor(totals.responses / totals.views * 1000 + 0.5) / 10 or nil
    totals.completion = totals.starts > 0 and math.floor(math.min(totals.responses / totals.starts, 1) * 1000 + 0.5) / 10
        or nil
    local extra = db.query([[
        SELECT ROUND(AVG((meta ->> 'duration_ms')::numeric) / 1000)::int AS avg_seconds
        FROM form_submissions WHERE form_id = ? AND status <> 'spam' AND created_at >= ?::date
          AND meta ->> 'duration_ms' ~ '^[0-9]+$'
    ]], form.id, since)[1]
    totals.avg_seconds = extra and extra.avg_seconds ~= db.NULL and tonumber(extra.avg_seconds) or nil

    local funnel = { { step = 1, reached = totals.starts } }
    local n = 2
    while steps[tostring(n)] do
        funnel[#funnel + 1] = { step = n, reached = steps[tostring(n)] }
        n = n + 1
    end
    local sources = db.query([[
        SELECT COALESCE(NULLIF(meta -> 'utm' ->> 'source', ''),
                        NULLIF(substring(meta ->> 'referrer' from ?), ''), 'direct') AS source,
               COUNT(*)::int AS responses
        FROM form_submissions WHERE form_id = ? AND status <> 'spam' AND created_at >= ?::date
        GROUP BY 1 ORDER BY 2 DESC LIMIT 8
    ]], "^https?://([^/:]+)", form.id, since)
    return {
        days = days,
        totals = totals,
        series = setmetatable(series, cjson.array_mt),
        funnel = setmetatable(funnel, cjson.array_mt),
        sources = setmetatable(sources, cjson.array_mt),
    }
end

return Stats
