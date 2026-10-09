-- Reports (SPEC §3.8 #10): time per stage, late days, conversion, supplier /
-- solicitor / council speed, AI usage and cost. All read-only, one workspace,
-- a [from, to) window on the relevant date (default: the last 90 days).
local db = require("lapis.db")
local U = require("property_deals.util")

local R = {}

local function n(v) return tonumber(v) end

--- Window from params: from/to as YYYY-MM-DD; default the last 90 days.
function R.window(params)
    local function d(v) return type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d$") and v or nil end
    local to = d(params and params.to) or U.one("SELECT (CURRENT_DATE + 1)::text AS d").d
    local from = d(params and params.from) or U.one("SELECT (?::date - 90)::text AS d", to).d
    return from, to
end

function R.stage_times(ns, from, to)
    local rows = db.query([[
        SELECT h.stage_key, COUNT(*)::int AS deals,
               ROUND(AVG(EXTRACT(EPOCH FROM (h.left_at - h.entered_at)) / 86400)::numeric, 1)::float AS avg_days,
               ROUND((percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (h.left_at - h.entered_at)) / 86400))::numeric, 1)::float AS median_days,
               ROUND(MAX(EXTRACT(EPOCH FROM (h.left_at - h.entered_at)) / 86400)::numeric, 1)::float AS max_days
        FROM property_deals_stage_history h
        WHERE h.namespace_id = ? AND h.left_at IS NOT NULL AND h.left_at >= ?::date AND h.left_at < ?::date
        GROUP BY h.stage_key ORDER BY avg_days DESC
    ]], ns, from, to)
    local open = db.query([[
        SELECT h.stage_key, COUNT(*)::int AS deals,
               ROUND(AVG(EXTRACT(EPOCH FROM (NOW() - h.entered_at)) / 86400)::numeric, 1)::float AS avg_days_so_far
        FROM property_deals_stage_history h JOIN property_deals_deals d ON d.uuid = h.deal_uuid AND d.status = 'active'
        WHERE h.namespace_id = ? AND h.left_at IS NULL GROUP BY h.stage_key ORDER BY avg_days_so_far DESC
    ]], ns)
    return { completed_stages = U.array(rows), current = U.array(open) }
end

function R.late_days(ns, from, to)
    local deals = db.query([[
        SELECT d.uuid, cd.name, d.target_completion_date::text AS target, d.actual_completion_at::date::text AS actual,
               GREATEST(0, d.actual_completion_at::date - d.target_completion_date)::int AS days_late,
               COALESCE(d.late_penalty_per_day, 0)::float AS penalty_per_day, d.late_penalty_cap_days
        FROM property_deals_deals d JOIN crm_deals cd ON cd.uuid = d.crm_deal_uuid
        WHERE d.namespace_id = ? AND d.status = 'completed' AND d.actual_completion_at >= ?::date
          AND d.actual_completion_at < ?::date
        ORDER BY days_late DESC
    ]], ns, from, to)
    local out = { completed = #deals, with_target = 0, on_time = 0, late = 0, total_days_late = 0, penalty_cost = 0,
        worst = {} }
    for _, d in ipairs(deals) do
        if d.target ~= db.NULL and d.target then
            out.with_target = out.with_target + 1
            local late = n(d.days_late) or 0
            if late > 0 then
                out.late, out.total_days_late = out.late + 1, out.total_days_late + late
                local cap = n(d.late_penalty_cap_days)
                out.penalty_cost = out.penalty_cost + (n(d.penalty_per_day) or 0) * (cap and math.min(late, cap) or late)
                if #out.worst < 10 then
                    out.worst[#out.worst + 1] = { uuid = d.uuid, name = d.name, target = d.target, actual = d.actual, days_late = late }
                end
            else out.on_time = out.on_time + 1 end
        end
    end
    out.avg_days_late = out.late > 0 and math.floor(out.total_days_late / out.late * 10 + 0.5) / 10 or 0
    out.on_time_pct = out.with_target > 0 and math.floor(out.on_time / out.with_target * 1000 + 0.5) / 10 or nil
    out.worst = U.array(out.worst)
    return out
end

function R.conversion(ns, from, to)
    local by_month = db.query([[
        WITH months AS (SELECT generate_series(date_trunc('month', ?::date), date_trunc('month', ?::date - 1), interval '1 month') AS m),
        leads AS (SELECT date_trunc('month', created_at) AS m, COUNT(*) AS n FROM crm_leads
                  WHERE namespace_id = ? AND deleted_at IS NULL AND created_at >= ?::date AND created_at < ?::date GROUP BY 1),
        deals AS (SELECT date_trunc('month', created_at) AS m, COUNT(*) AS n,
                         COUNT(*) FILTER (WHERE actual_exchange_at IS NOT NULL) AS exchanged,
                         COUNT(*) FILTER (WHERE status = 'completed') AS completed,
                         COUNT(*) FILTER (WHERE status = 'fell_through') AS fell_through
                  FROM property_deals_deals WHERE namespace_id = ? AND created_at >= ?::date AND created_at < ?::date GROUP BY 1)
        SELECT to_char(months.m, 'YYYY-MM') AS month, COALESCE(leads.n, 0)::int AS leads, COALESCE(deals.n, 0)::int AS deals,
               COALESCE(deals.exchanged, 0)::int AS exchanged, COALESCE(deals.completed, 0)::int AS completed,
               COALESCE(deals.fell_through, 0)::int AS fell_through
        FROM months LEFT JOIN leads ON leads.m = months.m LEFT JOIN deals ON deals.m = months.m ORDER BY months.m
    ]], from, to, ns, from, to, ns, from, to)
    local by_source = db.query([[
        SELECT COALESCE(l.source, 'unknown') AS source, COUNT(DISTINCT l.uuid)::int AS leads,
               COUNT(DISTINCT d.uuid)::int AS deals, COUNT(DISTINCT d.uuid) FILTER (WHERE d.status = 'completed')::int AS completed
        FROM crm_leads l LEFT JOIN property_deals_deals d ON d.seller_lead_uuid = l.uuid
        WHERE l.namespace_id = ? AND l.deleted_at IS NULL AND l.created_at >= ?::date AND l.created_at < ?::date
        GROUP BY 1 ORDER BY leads DESC
    ]], ns, from, to)
    local t = { leads = 0, deals = 0, completed = 0 }
    for _, r in ipairs(by_month) do t.leads, t.deals, t.completed = t.leads + r.leads, t.deals + r.deals, t.completed + r.completed end
    t.lead_to_deal_pct = t.leads > 0 and math.floor(t.deals / t.leads * 1000 + 0.5) / 10 or nil
    t.deal_to_completion_pct = t.deals > 0 and math.floor(t.completed / t.deals * 1000 + 0.5) / 10 or nil
    return { totals = t, by_month = U.array(by_month), by_source = U.array(by_source) }
end

function R.supplier_speed(ns, from, to)
    return U.array(db.query([[
        SELECT s.uuid AS supplier_uuid, a.name, s.kinds, COUNT(b.id)::int AS bookings,
               ROUND(AVG(EXTRACT(EPOCH FROM (b.confirmed_at - b.requested_at)) / 3600)::numeric, 1)::float AS avg_hours_to_confirm,
               ROUND(AVG(EXTRACT(EPOCH FROM (b.done_at - b.requested_at)) / 3600)::numeric, 1)::float AS avg_hours_to_done,
               COUNT(b.id) FILTER (WHERE b.done_at IS NOT NULL AND b.slot_end IS NOT NULL)::int AS measured,
               ROUND(100.0 * COUNT(b.id) FILTER (WHERE b.done_at IS NOT NULL AND b.slot_end IS NOT NULL
                   AND b.done_at <= b.slot_end + interval '1 hour')
                   / NULLIF(COUNT(b.id) FILTER (WHERE b.done_at IS NOT NULL AND b.slot_end IS NOT NULL), 0), 1)::float AS on_time_pct,
               COUNT(b.id) FILTER (WHERE b.status = 'cancelled')::int AS cancelled
        FROM property_deals_suppliers s JOIN crm_accounts a ON a.uuid = s.account_uuid
        LEFT JOIN property_deals_bookings b ON b.supplier_uuid = s.uuid AND b.requested_at >= ?::date AND b.requested_at < ?::date
        WHERE s.namespace_id = ? GROUP BY s.uuid, a.name, s.kinds ORDER BY bookings DESC, a.name
    ]], from, to, ns))
end

--- Solicitors, lenders, councils…: how fast they reply to chases and clear enquiries.
function R.party_speed(ns, from, to)
    local chases = db.query([[
        SELECT to_party, COUNT(*)::int AS chases, COUNT(*) FILTER (WHERE reply_at IS NOT NULL)::int AS replied,
               ROUND(AVG(EXTRACT(EPOCH FROM (reply_at - sent_at)) / 3600)::numeric, 1)::float AS avg_hours_to_reply,
               ROUND((percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (reply_at - sent_at)) / 3600))::numeric, 1)::float
                   AS median_hours_to_reply
        FROM property_deals_chases WHERE namespace_id = ? AND sent_at >= ?::date AND sent_at < ?::date
        GROUP BY to_party ORDER BY avg_hours_to_reply DESC NULLS LAST
    ]], ns, from, to)
    local enquiries = db.query([[
        SELECT owner_party, COUNT(*)::int AS raised, COUNT(*) FILTER (WHERE status = 'resolved')::int AS resolved,
               COUNT(*) FILTER (WHERE status = 'open')::int AS still_open,
               ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - raised_at)) / 86400)::numeric, 1)::float AS avg_days_to_resolve
        FROM property_deals_enquiries WHERE namespace_id = ? AND raised_at >= ?::date AND raised_at < ?::date
        GROUP BY owner_party ORDER BY avg_days_to_resolve DESC NULLS LAST
    ]], ns, from, to)
    return { chases = U.array(chases), enquiries = U.array(enquiries) }
end

function R.ai_usage(ns, from, to)
    local daily = db.query([[
        SELECT created_at::date::text AS day, agent_key, COUNT(*)::int AS runs,
               COUNT(*) FILTER (WHERE status = 'failed')::int AS failed, COALESCE(SUM(cost_usd), 0)::float AS cost_usd,
               COALESCE(SUM(tokens_in + tokens_out), 0)::int AS tokens
        FROM property_deals_agent_runs WHERE namespace_id = ? AND created_at >= ?::date AND created_at < ?::date
        GROUP BY 1, 2 ORDER BY 1, 2
    ]], ns, from, to)
    local outcomes = db.query([[
        SELECT COALESCE(r.agent_key, a.requested_by_agent, 'people') AS agent_key, COUNT(*)::int AS drafts,
               COUNT(*) FILTER (WHERE a.status IN ('approved', 'executed'))::int AS approved,
               COUNT(*) FILTER (WHERE a.status = 'rejected')::int AS rejected,
               COUNT(*) FILTER (WHERE a.original_payload IS NOT NULL)::int AS edited,
               COUNT(*) FILTER (WHERE a.status = 'failed')::int AS failed_to_run,
               COUNT(*) FILTER (WHERE a.status = 'pending')::int AS pending
        FROM property_deals_approvals a LEFT JOIN property_deals_agent_runs r ON r.uuid = a.agent_run_uuid
        WHERE a.namespace_id = ? AND a.created_at >= ?::date AND a.created_at < ?::date GROUP BY 1 ORDER BY drafts DESC
    ]], ns, from, to)
    local total = 0
    for _, d in ipairs(daily) do total = total + (n(d.cost_usd) or 0) end
    return { total_cost_usd = total, daily = U.array(daily), approval_outcomes = U.array(outcomes) }
end

--- Nightly: measured supplier speed onto the directory (last 12 months).
function R.update_supplier_stats(ns)
    return #db.query([[
        UPDATE property_deals_suppliers s SET
            avg_turnaround_hours = x.hours, on_time_pct = x.on_time, jobs_measured = x.jobs, updated_at = NOW()
        FROM (
            SELECT supplier_uuid,
                   ROUND(AVG(EXTRACT(EPOCH FROM (COALESCE(done_at, confirmed_at) - requested_at)) / 3600)::numeric, 2) AS hours,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE done_at IS NOT NULL AND slot_end IS NOT NULL AND done_at <= slot_end + interval '1 hour')
                       / NULLIF(COUNT(*) FILTER (WHERE done_at IS NOT NULL AND slot_end IS NOT NULL), 0), 2) AS on_time,
                   COUNT(*) FILTER (WHERE COALESCE(done_at, confirmed_at) IS NOT NULL)::int AS jobs
            FROM property_deals_bookings
            WHERE namespace_id = ? AND requested_at > NOW() - interval '365 days' AND COALESCE(done_at, confirmed_at) IS NOT NULL
            GROUP BY supplier_uuid
        ) x
        WHERE s.uuid = x.supplier_uuid AND s.namespace_id = ?
        RETURNING s.id
    ]], ns, ns)
end

return R
