-- Manager Today (HOW-IT-WORKS scene 10) and the PA's measurements.
--   M.today(ns, manager_uuid)  exceptions only: handoffs waiting, unusual negotiations, relationship risks, deal
--                              risks, top opportunities across the team. "Everything else is being handled."
--   M.metrics(ns, days)        is the PA working? capture accuracy, groundedness, speed, follow-through.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local M = {}

local function arr(t) return setmetatable(t or {}, cjson.array_mt) end

M.QUIET_DAYS = 14
M.GAP_PCT = 10 -- our position this far below their stated minimum is an "unusual negotiation"

function M.today(ns, me)
    local handoffs = db.query([[
        SELECT h.uuid, h.question, h.pa_recommendation, h.context, h.opportunity_uuid, h.created_at, o.title AS opportunity_title,
               COALESCE(NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), ''), u.email) AS from_name
        FROM pa_handoffs h LEFT JOIN users u ON u.uuid = h.from_user_uuid
        LEFT JOIN pa_opportunities o ON o.uuid = h.opportunity_uuid
        WHERE h.namespace_id = ? AND h.to_user_uuid = ? AND h.status = 'open' ORDER BY h.created_at
    ]], ns, me)
    for _, h in ipairs(handoffs) do h.ref = "pa_handoffs:" .. h.uuid end
    -- Unusual negotiations: an offer waiting, or our position well below their stated minimum.
    local negotiations = {}
    for _, r in ipairs(db.query([[
        SELECT o.uuid, o.title, o.owner_user_uuid, f.amount, 'offer_waiting' AS why
        FROM pa_opportunities o JOIN pa_offers f ON f.opportunity_uuid = o.uuid AND f.response = 'pending'
        WHERE o.namespace_id = ? AND o.status = 'open'
    ]], ns)) do
        negotiations[#negotiations + 1] = { opportunity_uuid = r.uuid, title = r.title, owner_user_uuid = r.owner_user_uuid,
            text = string.format("Offer of £%d waiting for an answer", math.floor(tonumber(r.amount) or 0)),
            ref = "pa_opportunities:" .. r.uuid }
    end
    for _, r in ipairs(db.query([[
        SELECT o.uuid, o.title, o.owner_user_uuid, o.expectation_price, o.our_position FROM pa_opportunities o
        WHERE o.namespace_id = ? AND o.status = 'open' AND o.expectation_price IS NOT NULL AND o.our_position IS NOT NULL
    ]], ns)) do
        local ours = tonumber((tostring(r.our_position):match("£?(%d[%d,]*%.?%d*)%s*[kK]") or ""):gsub(",", ""), 10)
        if ours then ours = ours * 1000 else
            ours = tonumber((tostring(r.our_position):match("£(%d[%d,]+)") or ""):gsub(",", ""), 10)
        end
        local theirs = tonumber(r.expectation_price)
        if ours and theirs and theirs > 0 and (theirs - ours) / theirs * 100 >= M.GAP_PCT then
            negotiations[#negotiations + 1] = { opportunity_uuid = r.uuid, title = r.title, owner_user_uuid = r.owner_user_uuid,
                text = string.format("Our position (£%d, a judgement) is %d%% below the seller's minimum (£%d)", ours,
                    math.floor((theirs - ours) / theirs * 100 + 0.5), theirs),
                ref = "pa_opportunities:" .. r.uuid .. ":our_position" }
        end
    end
    local quiet = db.query([[
        SELECT o.uuid, o.title, o.owner_user_uuid, o.temperature,
               FLOOR(EXTRACT(EPOCH FROM (NOW() - o.last_meaningful_contact_at)) / 86400)::int AS days,
               COALESCE(NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), ''), u.email) AS owner_name
        FROM pa_opportunities o LEFT JOIN users u ON u.uuid = o.owner_user_uuid
        WHERE o.namespace_id = ? AND o.status = 'open' AND o.temperature IN ('hot', 'warm')
          AND o.last_meaningful_contact_at < NOW() - make_interval(days => ?)
        ORDER BY o.last_meaningful_contact_at LIMIT 10
    ]], ns, M.QUIET_DAYS)
    for _, q in ipairs(quiet) do
        q.text = string.format("%s: no meaningful contact for %d days (%s)", q.title, q.days, q.temperature)
        q.ref = "pa_opportunities:" .. q.uuid .. ":last_meaningful_contact_at"
    end
    local overdue = db.query([[
        SELECT o.uuid, o.title, o.owner_user_uuid, t.title AS action, d.due_at, d.task_uuid
        FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
        JOIN pa_opportunities o ON o.uuid = d.opportunity_uuid
        WHERE d.namespace_id = ? AND d.pd_status NOT IN ('done', 'cancelled') AND d.due_at < NOW() - INTERVAL '1 day'
        ORDER BY d.due_at LIMIT 10
    ]], ns)
    for _, x in ipairs(overdue) do x.ref = "property_deals_task_details:" .. x.task_uuid end
    local deal_risks = db.query([[
        SELECT dl.uuid, cd.name, dl.money_at_risk, dl.health_reasons FROM property_deals_deals dl
        JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
        WHERE dl.namespace_id = ? AND dl.status = 'active' AND dl.health = 'red' ORDER BY dl.money_at_risk DESC LIMIT 5
    ]], ns)
    -- Top opportunities: the highest Today scores across the team.
    local R = require("property_pa.priority")
    local top = {}
    for _, o in ipairs(db.query([[
        SELECT o.uuid, o.title, o.kind, o.temperature, o.last_meaningful_contact_at, o.owner_user_uuid,
               NULLIF(TRIM(CONCAT(c.first_name, ' ', c.last_name)), '') AS person_name
        FROM pa_opportunities o LEFT JOIN crm_contacts c ON c.uuid = o.person_uuid
        WHERE o.namespace_id = ? AND o.status = 'open' AND o.temperature = 'hot'
    ]], ns)) do
        local s = R.score(ns, o)
        top[#top + 1] = { opportunity_uuid = o.uuid, title = o.title, owner_user_uuid = o.owner_user_uuid, score = s.score,
            why_now = s.signals[1] and s.signals[1].text or cjson.null, ref = "pa_opportunities:" .. o.uuid }
    end
    table.sort(top, function(a, b) return a.score > b.score end)
    while #top > 3 do table.remove(top) end
    local total = U.one("SELECT COUNT(*)::int AS n FROM pa_opportunities WHERE namespace_id = ? AND status = 'open'", ns).n
    local flagged = {}
    for _, list in ipairs({ negotiations, quiet, overdue }) do
        for _, x in ipairs(list) do flagged[x.opportunity_uuid or x.uuid] = true end
    end
    for _, h in ipairs(handoffs) do if h.opportunity_uuid ~= db.NULL then flagged[h.opportunity_uuid] = true end end
    local n = 0
    for _ in pairs(flagged) do n = n + 1 end
    return {
        handoffs = arr(handoffs), unusual_negotiations = arr(negotiations), relationship_risks = arr(quiet),
        overdue_actions = arr(overdue), deal_risks = arr(deal_risks), top_opportunities = arr(top),
        open_opportunities = total, handled = math.max(0, total - n),
        summary = (#handoffs + #negotiations + #quiet + #overdue + #deal_risks == 0) and "Nothing needs you. Everything else is being handled."
            or string.format("%d need you. Everything else (%d) is being handled.", n + #deal_risks, math.max(0, total - n)),
    }
end

--- PA measurements over the last `days`. Rates are 0..1 (null when there is nothing to measure).
function M.metrics(ns, days)
    days = days or 30
    local function rate(a, b) return b > 0 and (math.floor(a / b * 1000 + 0.5) / 1000) or cjson.null end
    local pu = U.one([[
        SELECT COUNT(*)::int AS total, COUNT(*) FILTER (WHERE status = 'confirmed')::int AS confirmed,
               COUNT(*) FILTER (WHERE status = 'corrected')::int AS corrected,
               COUNT(*) FILTER (WHERE status = 'rejected')::int AS rejected,
               COUNT(*) FILTER (WHERE status = 'proposed')::int AS waiting,
               COUNT(DISTINCT source_interaction_uuid)::int AS captures,
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (decided_at - created_at)))
                   FILTER (WHERE decided_at IS NOT NULL) AS median_confirm_s
        FROM pa_proposed_updates WHERE namespace_id = ? AND created_at > NOW() - make_interval(days => ?)
    ]], ns, days)
    local runs = U.one([[
        SELECT COUNT(*)::int AS total, COUNT(*) FILTER (WHERE status = 'succeeded')::int AS succeeded,
               COUNT(*) FILTER (WHERE status = 'failed')::int AS failed,
               COUNT(*) FILTER (WHERE status = 'succeeded' AND (output ->> 'grounded')::boolean)::int AS grounded,
               COUNT(*) FILTER (WHERE status = 'succeeded' AND NOT (output ->> 'grounded')::boolean)::int AS withheld,
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at)))
                   FILTER (WHERE finished_at IS NOT NULL) AS p50_s,
               PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at)))
                   FILTER (WHERE finished_at IS NOT NULL) AS p90_s
        FROM property_deals_agent_runs WHERE namespace_id = ? AND provider = 'jobshout-pa'
          AND created_at > NOW() - make_interval(days => ?)
    ]], ns, days)
    local actions = U.one([[
        SELECT COUNT(*) FILTER (WHERE pd_status NOT IN ('done', 'cancelled'))::int AS open,
               COUNT(*) FILTER (WHERE pd_status NOT IN ('done', 'cancelled') AND due_at < NOW())::int AS overdue,
               COUNT(*) FILTER (WHERE pd_status = 'done')::int AS done
        FROM property_deals_task_details WHERE namespace_id = ? AND opportunity_uuid IS NOT NULL
          AND created_at > NOW() - make_interval(days => ?)
    ]], ns, days)
    local hand = U.one([[
        SELECT COUNT(*)::int AS total, COUNT(*) FILTER (WHERE status = 'open')::int AS waiting,
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (replied_at - created_at)))
                   FILTER (WHERE replied_at IS NOT NULL) AS median_reply_s
        FROM pa_handoffs WHERE namespace_id = ? AND created_at > NOW() - make_interval(days => ?)
    ]], ns, days)
    local decided = pu.confirmed + pu.corrected + pu.rejected
    local stale = U.one([[SELECT COUNT(*)::int AS n FROM pa_opportunities WHERE namespace_id = ? AND status = 'open'
        AND (last_meaningful_contact_at IS NULL OR last_meaningful_contact_at < NOW() - INTERVAL '14 days')]], ns).n
    local function num(v) return v ~= nil and v ~= db.NULL and math.floor(tonumber(v) + 0.5) or cjson.null end
    return {
        days = days,
        capture = { captures = pu.captures, proposals = pu.total, waiting = pu.waiting, confirmed = pu.confirmed,
            corrected = pu.corrected, rejected = pu.rejected,
            accepted_as_proposed = rate(pu.confirmed, decided), -- extraction accuracy as people judged it
            correction_rate = rate(pu.corrected, decided), rejection_rate = rate(pu.rejected, decided),
            median_seconds_to_confirm = num(pu.median_confirm_s) },
        answers = { runs = runs.total, succeeded = runs.succeeded, failed = runs.failed, grounded = runs.grounded,
            withheld = runs.withheld, grounded_rate = rate(runs.grounded, runs.succeeded),
            p50_seconds = num(runs.p50_s), p90_seconds = num(runs.p90_s) },
        follow_through = { next_actions_open = actions.open, next_actions_overdue = actions.overdue,
            next_actions_done = actions.done, opportunities_gone_quiet = stale },
        handoffs = { total = hand.total, waiting = hand.waiting, median_seconds_to_reply = num(hand.median_reply_s) },
    }
end

return M
