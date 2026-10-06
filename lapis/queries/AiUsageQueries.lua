--[[
    AI usage reports (ai_usage, written by lib/agent/llm on every model call)

    One shape for both audiences: a workspace (ns_id) or the whole platform
    (ns_id = nil, which adds the per-workspace table). Days are UTC days.

    "Requests" are what a person asked for: one assistant message = one request
    however many model calls it took (grouped by run_uuid); every other AI
    feature call is its own request. "Model calls" counts the calls themselves.
]]

local db = require("lapis.db")

local AiUsageQueries = {}

local REQUESTS = "COUNT(DISTINCT COALESCE(a.run_uuid, a.id::text))::int"
local TOKENS_IN = "COALESCE(SUM(a.input_tokens), 0)::bigint"
local TOKENS_OUT = "COALESCE(SUM(a.output_tokens), 0)::bigint"
local NAME = "NULLIF(trim(coalesce(u.first_name, '') || ' ' || coalesce(u.last_name, '')), '')"

local function iso(col)
    return ("to_char(%s AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"):format(col)
end

--- Clamp a ?days= value to [1, 365].
function AiUsageQueries.days(value)
    local n = math.floor(tonumber(value) or 30)
    return math.max(1, math.min(365, n))
end

function AiUsageQueries.summary(ns_id, days)
    -- Both values are integers we produced (clamped days, the middleware's
    -- namespace id), so they are formatted in rather than bound.
    local since = ("(date_trunc('day', NOW() AT TIME ZONE 'UTC') - interval '%d days')"):format(days - 1)
    local where = ("a.created_at >= %s AT TIME ZONE 'UTC'"):format(since)
        .. (ns_id and (" AND a.namespace_id = %d"):format(tonumber(ns_id)) or "")

    local totals = db.query(([[
        SELECT %s AS requests, COUNT(*)::int AS model_calls,
               %s AS input_tokens, %s AS output_tokens,
               COUNT(*) FILTER (WHERE NOT a.ok)::int AS failed,
               COUNT(DISTINCT a.user_uuid)::int AS users,
               COALESCE(ROUND(AVG(a.latency_ms) FILTER (WHERE a.ok)), 0)::int AS avg_latency_ms
        FROM ai_usage a WHERE %s
    ]]):format(REQUESTS, TOKENS_IN, TOKENS_OUT, where))[1]

    local series = db.query(([[
        SELECT to_char(d.day, 'YYYY-MM-DD') AS day,
               COALESCE(x.requests, 0)::int AS requests, COALESCE(x.model_calls, 0)::int AS model_calls,
               COALESCE(x.input_tokens, 0)::bigint AS input_tokens,
               COALESCE(x.output_tokens, 0)::bigint AS output_tokens
        FROM generate_series(%s, NOW() AT TIME ZONE 'UTC', interval '1 day') AS d(day)
        LEFT JOIN (
            SELECT (a.created_at AT TIME ZONE 'UTC')::date AS day, %s AS requests,
                   COUNT(*) AS model_calls, %s AS input_tokens, %s AS output_tokens
            FROM ai_usage a WHERE %s GROUP BY 1
        ) x ON x.day = d.day::date
        ORDER BY d.day
    ]]):format(since, REQUESTS, TOKENS_IN, TOKENS_OUT, where))

    local members = db.query(([[
        SELECT a.user_uuid, u.email, %s AS name, %s AS requests, COUNT(*)::int AS model_calls,
               %s AS input_tokens, %s AS output_tokens,
               COUNT(*) FILTER (WHERE NOT a.ok)::int AS failed, %s AS last_used_at
        FROM ai_usage a LEFT JOIN users u ON u.uuid = a.user_uuid
        WHERE %s AND a.user_uuid IS NOT NULL
        GROUP BY a.user_uuid, u.email, u.first_name, u.last_name
        ORDER BY SUM(a.input_tokens + a.output_tokens) DESC, COUNT(*) DESC LIMIT 200
    ]]):format(NAME, REQUESTS, TOKENS_IN, TOKENS_OUT, iso("MAX(a.created_at)"), where))

    local features = db.query(([[
        SELECT a.feature, %s AS requests, COUNT(*)::int AS model_calls,
               %s AS input_tokens, %s AS output_tokens
        FROM ai_usage a WHERE %s GROUP BY a.feature ORDER BY SUM(a.input_tokens + a.output_tokens) DESC
    ]]):format(REQUESTS, TOKENS_IN, TOKENS_OUT, where))

    local models = db.query(([[
        SELECT a.provider, a.model, COUNT(*)::int AS model_calls, %s AS input_tokens, %s AS output_tokens
        FROM ai_usage a WHERE %s GROUP BY a.provider, a.model ORDER BY COUNT(*) DESC
    ]]):format(TOKENS_IN, TOKENS_OUT, where))

    local result = {
        days = days, totals = totals, series = series, members = members, features = features, models = models,
    }
    if not ns_id then
        result.workspaces = db.query(([[
            SELECT n.uuid AS namespace_uuid, n.name, n.slug, %s AS requests, COUNT(*)::int AS model_calls,
                   %s AS input_tokens, %s AS output_tokens, COUNT(DISTINCT a.user_uuid)::int AS users
            FROM ai_usage a LEFT JOIN namespaces n ON n.id = a.namespace_id
            WHERE %s GROUP BY n.uuid, n.name, n.slug
            ORDER BY SUM(a.input_tokens + a.output_tokens) DESC LIMIT 200
        ]]):format(REQUESTS, TOKENS_IN, TOKENS_OUT, where))
    end
    return result
end

return AiUsageQueries
