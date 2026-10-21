-- Derived analytics from deliveries + tracking events. Opens are always estimated.
local db = require("lapis.db")
local U = require("opsapi_marketing.util")

local A = {}

function A.overview(ns)
    local camps = U.one([[
        SELECT
            COUNT(*) FILTER (WHERE status IN ('draft','validated','awaiting_approval'))::int AS drafts,
            COUNT(*) FILTER (WHERE status IN ('scheduled','sending'))::int AS active,
            COUNT(*) FILTER (WHERE status = 'completed')::int AS completed,
            COUNT(*) FILTER (WHERE status = 'paused')::int AS paused
        FROM mkt_campaigns WHERE namespace_id = ?
    ]], ns) or {}

    local del = U.one([[
        SELECT
            COUNT(*) FILTER (WHERE state = 'queued')::int AS queued,
            COUNT(*) FILTER (WHERE state = 'accepted')::int AS accepted,
            COUNT(*) FILTER (WHERE state = 'delivered')::int AS delivered,
            COUNT(*) FILTER (WHERE state = 'bounced')::int AS bounced,
            COUNT(*) FILTER (WHERE state = 'failed')::int AS failed,
            COUNT(*) FILTER (WHERE state = 'skipped')::int AS skipped,
            COUNT(*) FILTER (WHERE opened_at IS NOT NULL)::int AS opened_est,
            COUNT(*) FILTER (WHERE clicked_at IS NOT NULL)::int AS clicked
        FROM mkt_deliveries WHERE namespace_id = ?
    ]], ns) or {}

    local replies = U.one([[
        SELECT COUNT(*)::int AS n FROM mkt_replies WHERE namespace_id = ?
          AND created_at > NOW() - interval '30 days'
    ]], ns)

    local conv = U.one([[
        SELECT COUNT(*)::int AS conversions, COALESCE(SUM(value), 0)::float AS revenue,
               COUNT(*) FILTER (WHERE campaign_id IS NOT NULL)::int AS attributed
        FROM mkt_conversions WHERE namespace_id = ? AND created_at > NOW() - interval '30 days'
    ]], ns) or {}
    local web = U.one([[
        SELECT COUNT(*)::int AS events_24h, COUNT(DISTINCT visitor_id)::int AS visitors_24h
        FROM mkt_web_events
        WHERE namespace_id = ? AND NOT is_test AND NOT is_bot AND created_at > NOW() - interval '24 hours'
    ]], ns) or {}
    local pixels = U.one("SELECT COUNT(*)::int AS n FROM mkt_pixels WHERE namespace_id = ? AND is_active", ns)

    return {
        campaigns = camps,
        deliveries = del,
        conversions_30d = conv,
        web = { events_24h = web.events_24h or 0, visitors_24h = web.visitors_24h or 0,
                pixels = pixels and pixels.n or 0 },
        top_campaigns = A.attribution(ns, 90, 5),
        replies_30d = replies and replies.n or 0,
        notes = {
            opens_are_estimated = true,
            accepted_is_not_delivered = true,
        },
    }
end

local function rate(n, d)
    n, d = tonumber(n) or 0, tonumber(d) or 0
    if d <= 0 then return 0 end
    return math.floor(n / d * 10000 + 0.5) / 100 -- percent, 2dp
end

--- Two-proportion z-test between the best and runner-up variant on a metric.
local function ab_winner(variants, metric)
    local ranked = {}
    for _, v in ipairs(variants) do
        if (v.sent or 0) > 0 and v.variant ~= "_default" then
            ranked[#ranked + 1] = { key = v.variant, n = v.sent, x = v[metric] or 0 }
        end
    end
    if #ranked < 2 then return nil end
    table.sort(ranked, function(a, b) return a.x / a.n > b.x / b.n end)
    local a, b = ranked[1], ranked[2]
    local p1, p2 = a.x / a.n, b.x / b.n
    local p = (a.x + b.x) / (a.n + b.n)
    local se = math.sqrt(p * (1 - p) * (1 / a.n + 1 / b.n))
    local z = se > 0 and (p1 - p2) / se or 0
    -- Normal CDF via the Abramowitz–Stegun erf approximation.
    local t = 1 / (1 + 0.3275911 * math.abs(z) / math.sqrt(2))
    local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t
        + 0.254829592) * t * math.exp(-(z * z) / 2)
    local confidence = math.floor(((1 + y) / 2) * 1000 + 0.5) / 10
    return {
        variant = a.key,
        metric = metric,
        rate = rate(a.x, a.n),
        runner_up = b.key,
        runner_up_rate = rate(b.x, b.n),
        lift = p2 > 0 and math.floor((p1 - p2) / p2 * 1000 + 0.5) / 10 or nil,
        confidence = confidence,
        significant = confidence >= 95 and a.n >= 30 and b.n >= 30,
    }
end

function A.campaign(ns, campaign_id)
    local del = U.one([[
        SELECT
            COUNT(*)::int AS total,
            COUNT(*) FILTER (WHERE state IN ('accepted', 'delivered'))::int AS sent,
            COUNT(*) FILTER (WHERE state = 'accepted')::int AS accepted,
            COUNT(*) FILTER (WHERE state = 'delivered')::int AS delivered,
            COUNT(*) FILTER (WHERE state = 'bounced')::int AS bounced,
            COUNT(*) FILTER (WHERE state = 'failed')::int AS failed,
            COUNT(*) FILTER (WHERE state = 'skipped')::int AS skipped,
            COUNT(*) FILTER (WHERE state = 'queued')::int AS queued,
            COUNT(*) FILTER (WHERE opened_at IS NOT NULL)::int AS opened_estimated,
            COUNT(*) FILTER (WHERE clicked_at IS NOT NULL)::int AS clicked,
            COUNT(*) FILTER (WHERE converted_at IS NOT NULL)::int AS converted
        FROM mkt_deliveries WHERE namespace_id = ? AND campaign_id = ?
    ]], ns, campaign_id) or {}

    local conv = U.one([[
        SELECT COUNT(*)::int AS conversions, COALESCE(SUM(value), 0)::float AS revenue,
               COUNT(DISTINCT contact_uuid)::int AS converters, MAX(currency) AS currency
        FROM mkt_conversions WHERE namespace_id = ? AND campaign_id = ?
    ]], ns, campaign_id) or {}

    local variants = db.query([[
        SELECT COALESCE(variant_key, '_default') AS variant,
               COUNT(*)::int AS total,
               COUNT(*) FILTER (WHERE state IN ('accepted', 'delivered'))::int AS sent,
               COUNT(*) FILTER (WHERE state = 'accepted')::int AS accepted,
               COUNT(*) FILTER (WHERE opened_at IS NOT NULL)::int AS opened_estimated,
               COUNT(*) FILTER (WHERE clicked_at IS NOT NULL)::int AS clicked,
               COUNT(*) FILTER (WHERE converted_at IS NOT NULL)::int AS converted,
               COALESCE(SUM(conversion_value), 0)::float AS revenue
        FROM mkt_deliveries WHERE namespace_id = ? AND campaign_id = ?
        GROUP BY COALESCE(variant_key, '_default') ORDER BY 1
    ]], ns, campaign_id)
    for _, v in ipairs(variants) do
        v.open_rate = rate(v.opened_estimated, v.sent)
        v.click_rate = rate(v.clicked, v.sent)
        v.conversion_rate = rate(v.converted, v.sent)
    end

    local classes = db.query([[
        SELECT classification, COUNT(*)::int AS n
        FROM mkt_replies WHERE namespace_id = ? AND campaign_id = ?
        GROUP BY classification ORDER BY n DESC
    ]], ns, campaign_id)

    local track = U.one([[
        SELECT
            COUNT(*) FILTER (WHERE event_type = 'open' AND NOT is_bot)::int AS opens_raw,
            COUNT(*) FILTER (WHERE event_type = 'click' AND NOT is_bot)::int AS clicks_raw,
            COUNT(*) FILTER (WHERE is_bot)::int AS bot_events,
            COUNT(*) FILTER (WHERE is_bot AND event_type = 'open')::int AS bot_opens,
            COUNT(*) FILTER (WHERE is_bot AND event_type = 'click')::int AS bot_clicks
        FROM mkt_tracking_events WHERE namespace_id = ? AND campaign_id = ?
    ]], ns, campaign_id) or {}

    local top_links = db.query([[
        SELECT url, COUNT(*)::int AS clicks, COUNT(DISTINCT contact_uuid)::int AS unique_clicks
        FROM mkt_tracking_events
        WHERE namespace_id = ? AND campaign_id = ? AND event_type = 'click' AND NOT is_bot
        GROUP BY url ORDER BY clicks DESC LIMIT 10
    ]], ns, campaign_id)

    -- Engagement over the first 7 days after the campaign started (hourly buckets).
    local timeline = db.query([[
        SELECT to_char(date_trunc('hour', t.created_at), 'YYYY-MM-DD"T"HH24:00:00"Z"') AS hour,
               COUNT(*) FILTER (WHERE t.event_type = 'open')::int AS opens,
               COUNT(*) FILTER (WHERE t.event_type = 'click')::int AS clicks,
               COUNT(*) FILTER (WHERE t.event_type = 'conversion')::int AS conversions
        FROM mkt_tracking_events t
        JOIN mkt_campaigns c ON c.id = t.campaign_id
        WHERE t.namespace_id = ? AND t.campaign_id = ? AND NOT t.is_bot
          AND t.created_at < COALESCE(c.started_at, c.created_at) + interval '7 days'
        GROUP BY 1 ORDER BY 1
    ]], ns, campaign_id)

    local sent = del.sent or 0
    local funnel = {
        { stage = "sent", count = sent },
        { stage = "opened", count = del.opened_estimated or 0, estimated = true },
        { stage = "clicked", count = del.clicked or 0 },
        { stage = "converted", count = del.converted or 0 },
    }

    return {
        deliveries = del,
        conversions = conv,
        rates = {
            open_rate = rate(del.opened_estimated, sent),
            click_rate = rate(del.clicked, sent),
            click_to_open_rate = rate(del.clicked, del.opened_estimated),
            conversion_rate = rate(del.converted, sent),
            bounce_rate = rate(del.bounced, (del.total or 0) - (del.skipped or 0) - (del.queued or 0)),
            revenue_per_recipient = sent > 0 and math.floor((conv.revenue or 0) / sent * 100 + 0.5) / 100 or 0,
        },
        funnel = funnel,
        variants = U.array(variants),
        ab_winner = ab_winner(variants, (conv.conversions or 0) > 0 and "converted" or "clicked"),
        reply_classes = U.array(classes),
        tracking = track,
        top_links = U.array(top_links),
        timeline = U.array(timeline),
        notes = { opens_are_estimated = true, bots_excluded = true },
    }
end

--- Per-campaign performance + attributed revenue over the last `days` (newest first,
-- or by revenue when `limit` is set — the overview's top campaigns).
function A.attribution(ns, days, limit)
    days = math.min(math.max(tonumber(days) or 30, 1), 365)
    local rows = db.query([[
        SELECT c.uuid, c.name, c.status, c.channel, c.started_at,
               COALESCE(d.sent, 0) AS sent, COALESCE(d.opened, 0) AS opened,
               COALESCE(d.clicked, 0) AS clicked, COALESCE(d.converted, 0) AS converted,
               COALESCE(v.conversions, 0) AS conversions, COALESCE(v.revenue, 0)::float AS revenue
        FROM mkt_campaigns c
        LEFT JOIN LATERAL (
            SELECT COUNT(*) FILTER (WHERE state IN ('accepted', 'delivered'))::int AS sent,
                   COUNT(*) FILTER (WHERE opened_at IS NOT NULL)::int AS opened,
                   COUNT(*) FILTER (WHERE clicked_at IS NOT NULL)::int AS clicked,
                   COUNT(*) FILTER (WHERE converted_at IS NOT NULL)::int AS converted
            FROM mkt_deliveries WHERE campaign_id = c.id
        ) d ON true
        LEFT JOIN LATERAL (
            SELECT COUNT(*)::int AS conversions, SUM(value) AS revenue
            FROM mkt_conversions WHERE campaign_id = c.id
        ) v ON true
        WHERE c.namespace_id = ? AND COALESCE(c.started_at, c.created_at) > NOW() - make_interval(days => ?)
          AND c.status NOT IN ('draft', 'validated', 'awaiting_approval')
        ORDER BY ]] .. (limit and "revenue DESC, clicked DESC" or "COALESCE(c.started_at, c.created_at) DESC") .. [[
        LIMIT ?
    ]], ns, days, tonumber(limit) or 200)
    for _, r in ipairs(rows) do
        r.open_rate = rate(r.opened, r.sent)
        r.click_rate = rate(r.clicked, r.sent)
        r.conversion_rate = rate(r.converted, r.sent)
        r.revenue_per_recipient = (r.sent or 0) > 0 and math.floor(r.revenue / r.sent * 100 + 0.5) / 100 or 0
    end
    local unattributed = U.one([[
        SELECT COUNT(*)::int AS conversions, COALESCE(SUM(value), 0)::float AS revenue
        FROM mkt_conversions
        WHERE namespace_id = ? AND campaign_id IS NULL AND created_at > NOW() - make_interval(days => ?)
    ]], ns, days)
    if limit then return U.array(rows) end
    return { days = days, campaigns = U.array(rows), unattributed = unattributed }
end

function A.contact_timeline(ns, contact_uuid, limit)
    limit = math.min(tonumber(limit) or 50, 200)
    local deliveries = db.query([[
        SELECT d.uuid, d.channel, d.state, d.subject, d.queued_at, d.accepted_at, d.opened_at, d.clicked_at,
               c.name AS campaign_name, c.uuid AS campaign_uuid
        FROM mkt_deliveries d
        LEFT JOIN mkt_campaigns c ON c.id = d.campaign_id
        WHERE d.namespace_id = ? AND d.contact_uuid = ?
        ORDER BY d.queued_at DESC LIMIT ?
    ]], ns, contact_uuid, limit)
    local replies = db.query([[
        SELECT uuid, channel, classification, subject, created_at, needs_human
        FROM mkt_replies WHERE namespace_id = ? AND contact_uuid = ?
        ORDER BY created_at DESC LIMIT ?
    ]], ns, contact_uuid, limit)
    local subs = db.query([[
        SELECT channel, list_id, status, source, changed_at
        FROM mkt_subscriptions WHERE namespace_id = ? AND contact_uuid = ?
        ORDER BY changed_at DESC
    ]], ns, contact_uuid)
    local web = db.query([[
        SELECT e.event_name, e.url, e.value, e.currency, e.is_conversion, e.created_at, c.name AS campaign_name
        FROM mkt_web_events e LEFT JOIN mkt_campaigns c ON c.id = e.campaign_id
        WHERE e.namespace_id = ? AND e.contact_uuid = ? AND NOT e.is_test
        ORDER BY e.created_at DESC LIMIT ?
    ]], ns, contact_uuid, limit)
    return {
        deliveries = deliveries,
        web_events = U.array(web),
        replies = replies,
        subscriptions = subs,
        notes = { opens_are_estimated = true },
    }
end

return A
