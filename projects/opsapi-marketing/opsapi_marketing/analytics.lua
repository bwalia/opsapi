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

    return {
        campaigns = camps,
        deliveries = del,
        replies_30d = replies and replies.n or 0,
        notes = {
            opens_are_estimated = true,
            accepted_is_not_delivered = true,
        },
    }
end

function A.campaign(ns, campaign_id)
    local del = U.one([[
        SELECT
            COUNT(*)::int AS total,
            COUNT(*) FILTER (WHERE state = 'accepted')::int AS accepted,
            COUNT(*) FILTER (WHERE state = 'delivered')::int AS delivered,
            COUNT(*) FILTER (WHERE state = 'bounced')::int AS bounced,
            COUNT(*) FILTER (WHERE state = 'failed')::int AS failed,
            COUNT(*) FILTER (WHERE state = 'skipped')::int AS skipped,
            COUNT(*) FILTER (WHERE state = 'queued')::int AS queued,
            COUNT(*) FILTER (WHERE opened_at IS NOT NULL)::int AS opened_estimated,
            COUNT(*) FILTER (WHERE clicked_at IS NOT NULL)::int AS clicked
        FROM mkt_deliveries WHERE namespace_id = ? AND campaign_id = ?
    ]], ns, campaign_id)

    local variants = db.query([[
        SELECT COALESCE(variant_key, '_default') AS variant,
               COUNT(*)::int AS total,
               COUNT(*) FILTER (WHERE state = 'accepted')::int AS accepted,
               COUNT(*) FILTER (WHERE opened_at IS NOT NULL)::int AS opened_estimated,
               COUNT(*) FILTER (WHERE clicked_at IS NOT NULL)::int AS clicked
        FROM mkt_deliveries WHERE namespace_id = ? AND campaign_id = ?
        GROUP BY COALESCE(variant_key, '_default')
    ]], ns, campaign_id)

    local classes = db.query([[
        SELECT classification, COUNT(*)::int AS n
        FROM mkt_replies WHERE namespace_id = ? AND campaign_id = ?
        GROUP BY classification ORDER BY n DESC
    ]], ns, campaign_id)

    local track = U.one([[
        SELECT
            COUNT(*) FILTER (WHERE event_type = 'open')::int AS opens_raw,
            COUNT(*) FILTER (WHERE event_type = 'click')::int AS clicks_raw,
            COUNT(*) FILTER (WHERE is_bot)::int AS bot_events
        FROM mkt_tracking_events WHERE namespace_id = ? AND campaign_id = ?
    ]], ns, campaign_id)

    return {
        deliveries = del,
        variants = variants,
        reply_classes = classes,
        tracking = track,
        notes = { opens_are_estimated = true },
    }
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
    return {
        deliveries = deliveries,
        replies = replies,
        subscriptions = subs,
        notes = { opens_are_estimated = true },
    }
end

return A
