-- Deal health, completion slip, money at risk and task urgency (SPEC §3.3).
-- All deterministic; the formula and weights are documented in
-- docs/property-deals/urgency.md. The AI may later explain these numbers, it
-- never sets them.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local Days = require("property_deals.workdays")
local Template = require("property_deals.template")

local H = {}

H.DEFAULT_WEIGHTS = { time = 35, completion = 20, blocking = 15, blockers = 10, silence = 10, money = 10 }
H.DEFAULT_STAGE_DAYS = 2 -- expected working days for a stage that doesn't say

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function round(x, places)
    local m = 10 ^ (places or 0)
    return math.floor(x * m + 0.5) / m
end

local function weights(settings)
    local w = {}
    for k, v in pairs(H.DEFAULT_WEIGHTS) do
        w[k] = tonumber(settings and settings["urgency_w_" .. k]) or v
    end
    return w
end

--- Facts about a deal that health and urgency share.
function H.facts(ctx)
    local ns, deal, cal = ctx.ns, ctx.deal, ctx.cal
    local today = Days.today(cal)
    local f = { today = today }
    f.target = deal.target_completion_date and tostring(deal.target_completion_date) or nil
    f.wd_left = f.target and Days.between(cal, today, f.target) or nil

    local row = U.one([[
        SELECT COUNT(*) FILTER (WHERE d.blocking)::int AS open_blocking_tasks,
               COUNT(*) FILTER (WHERE d.blocking AND d.due_at < NOW())::int AS overdue_blocking,
               COUNT(*) FILTER (WHERE d.blocking AND d.sla_warned_at IS NOT NULL AND d.due_at >= NOW())::int AS warned_blocking
        FROM property_deals_task_details d
        WHERE d.namespace_id = ? AND d.deal_uuid = ? AND d.pd_status NOT IN ('done', 'cancelled')
          AND (d.snoozed_until IS NULL OR d.snoozed_until < NOW())
    ]], ns, deal.uuid)
    f.open_blocking_tasks, f.overdue_blocking, f.warned_blocking =
        row.open_blocking_tasks, row.overdue_blocking, row.warned_blocking

    local enq = U.one([[
        SELECT COUNT(*)::int AS n, MIN(raised_at) AS oldest FROM property_deals_enquiries
        WHERE namespace_id = ? AND deal_uuid = ? AND status = 'open' AND blocking
    ]], ns, deal.uuid)
    f.open_blockers = enq.n

    -- Third-party silence: hours since the last reply to a chase; never replied
    -- -> since the first chase (or the oldest open enquiry).
    local s = U.one([[
        SELECT EXTRACT(EPOCH FROM (NOW() - COALESCE(
                 (SELECT MAX(reply_at) FROM property_deals_chases WHERE namespace_id = ? AND deal_uuid = ?),
                 (SELECT MIN(sent_at) FROM property_deals_chases WHERE namespace_id = ? AND deal_uuid = ?),
                 ?::timestamptz))) / 3600 AS hours
    ]], ns, deal.uuid, ns, deal.uuid, enq.oldest or db.NULL)
    f.silence_hours = (f.open_blockers > 0 and tonumber(s.hours)) or 0

    -- Completion slip (rules): what is left of the current stage plus every
    -- later stage on the critical path (not parallel, not optional, applies).
    local E = require("property_deals.engine")
    local stage, idx = Template.stage(ctx.def, deal.stage_key)
    local entered = Days.local_date(cal, tostring(deal.stage_entered_at))
    local cur = 0
    local reasons = {}
    if stage then
        local expected = tonumber(stage.expected_working_days) or H.DEFAULT_STAGE_DAYS
        cur = math.max(0, expected - Days.between(cal, entered, today))
        for _, t in ipairs(db.query([[
            SELECT due_at, (due_at < NOW()) AS overdue FROM property_deals_task_details
            WHERE namespace_id = ? AND deal_uuid = ? AND blocking AND stage_key = ?
              AND pd_status NOT IN ('done', 'cancelled') AND due_at IS NOT NULL
        ]], ctx.ns, deal.uuid, deal.stage_key)) do
            local wd = t.overdue and 1 or Days.between(cal, today, Days.local_date(cal, tostring(t.due_at)))
            cur = math.max(cur, wd)
        end
    end
    local later = 0
    for j = (idx or 0) + 1, #ctx.def.stages do
        local st = ctx.def.stages[j]
        if not st.parallel and not st.optional and E.when(ctx, st.when) then
            later = later + (tonumber(st.expected_working_days) or H.DEFAULT_STAGE_DAYS)
        end
    end
    local silence_wd = 0
    if f.open_blockers > 0 and f.silence_hours > 24 then
        silence_wd = math.min(5, math.floor((f.silence_hours - 24) / 24) + 1)
        reasons[#reasons + 1] = "third party silent " .. math.floor(f.silence_hours) .. "h: +" .. silence_wd .. " working day(s)"
    end
    f.remaining_wd = cur + later + silence_wd
    f.predicted = Days.add(cal, today, math.max(f.remaining_wd, 0))
    f.slip_detail = { current_stage_wd = cur, later_stages_wd = later, silence_wd = silence_wd, notes = U.array(reasons) }
    f.days_late = f.target and math.max(0, Days.days(f.target, f.predicted)) or 0

    local per_day = tonumber(deal.late_penalty_per_day) or 0
    local cap = tonumber(deal.late_penalty_cap_days)
    f.days_at_risk = cap and math.min(f.days_late, cap) or f.days_late
    f.money_at_risk = round(per_day * f.days_at_risk, 2)
    return f
end

--- green / amber / red with reasons (SPEC §3.3).
function H.health(ctx, f)
    local red, amber = {}, {}
    local n = tonumber(ctx.settings.red_min_working_days) or 10
    if f.target and f.predicted > f.target then
        red[#red + 1] = string.format("Predicted completion %s is after the target %s (%d day(s) late)",
            f.predicted, f.target, f.days_late)
    end
    if f.overdue_blocking > 0 then
        red[#red + 1] = f.overdue_blocking .. " blocking task(s) overdue"
    end
    if f.wd_left and f.wd_left < n and (f.open_blockers > 0 or f.open_blocking_tasks > 0) then
        red[#red + 1] = string.format("%d working day(s) to completion with %d open blocker(s) and %d open blocking task(s)",
            f.wd_left, f.open_blockers, f.open_blocking_tasks)
    end
    if #red == 0 then
        if f.target and Days.between(ctx.cal, f.predicted, f.target) <= 2 then
            amber[#amber + 1] = "Predicted completion is within 2 working days of the target"
        end
        if f.warned_blocking > 0 then amber[#amber + 1] = f.warned_blocking .. " blocking task(s) near their deadline" end
        if f.open_blockers > 0 and f.silence_hours >= 48 then
            amber[#amber + 1] = "No third-party reply for " .. math.floor(f.silence_hours) .. "h with open enquiries"
        end
        if f.wd_left and f.wd_left < 2 * n and f.open_blockers > 0 then
            amber[#amber + 1] = f.wd_left .. " working day(s) left with open enquiries"
        end
    end
    if #red > 0 then return "red", red end
    if #amber > 0 then return "amber", amber end
    return "green", {}
end

--- Urgency 0–100 for one open task, with the reasons (urgency.md).
function H.urgency(ctx, f, task, w)
    w = w or weights(ctx and ctx.settings)
    local parts = {}
    local function part(key, x, text)
        x = clamp(x, 0, 1)
        parts[#parts + 1] = { factor = key, value = round(x, 3), points = round(w[key] * x, 1), why = text }
    end

    -- Time pressure: share of the SLA window used (overdue counts up to 1.5 = full points).
    local used = tonumber(task.sla_used) -- fraction, from SQL
    if used then
        local text = used >= 1 and ("Overdue (" .. math.floor(used * 100) .. "% of its time used)")
            or (math.floor(used * 100) .. "% of its time used")
        part("time", used / 1.5, text)
    else
        part("time", 0, task.due_at and "Not started yet" or "No deadline")
    end

    if f and f.wd_left then
        part("completion", 1 - f.wd_left / 20, f.wd_left .. " working day(s) to target completion")
    else
        part("completion", 0, "No target completion date")
    end
    part("blocking", task.blocking and 1 or 0, task.blocking and "On the path to exchange/completion" or "Not blocking")
    if f then
        part("blockers", f.open_blockers / 5, f.open_blockers .. " open blocking enquir" .. (f.open_blockers == 1 and "y" or "ies"))
        part("silence", f.silence_hours / 120, f.silence_hours > 0 and (math.floor(f.silence_hours) .. "h since the last third-party reply")
            or "No one to chase")
        local scale = tonumber(ctx.settings.urgency_money_scale) or 5000
        part("money", f.money_at_risk / scale, "£" .. f.money_at_risk .. " at risk on the deal")
    end
    local score = 0
    for _, p in ipairs(parts) do score = score + p.points end
    table.sort(parts, function(a, b) return a.points > b.points end)
    return round(clamp(score, 0, 100), 2), U.array(parts)
end

local function open_tasks(ns, deal_uuid)
    local where = deal_uuid and "d.deal_uuid = " .. db.escape_literal(deal_uuid) or "d.deal_uuid IS NULL"
    return db.query([[
        SELECT d.task_uuid, d.blocking, d.due_at,
               CASE WHEN d.due_at IS NOT NULL AND d.sla_started_at IS NOT NULL AND d.due_at > d.sla_started_at
                    THEN EXTRACT(EPOCH FROM (NOW() - d.sla_started_at)) / EXTRACT(EPOCH FROM (d.due_at - d.sla_started_at))
               END AS sla_used
        FROM property_deals_task_details d
        WHERE d.namespace_id = ? AND ]] .. where .. [[ AND d.pd_status NOT IN ('done', 'cancelled')
    ]], ns)
end

--- Recompute one deal: facts, health (+ event on change), money at risk,
-- predicted completion, and the urgency of its open tasks.
function H.recompute_deal(ns, deal_uuid, settings)
    local E = require("property_deals.engine")
    local ctx = E.context(ns, deal_uuid, settings)
    if not ctx or ctx.deal.status ~= "active" then return nil end
    local f = H.facts(ctx)
    local health, reasons = H.health(ctx, f)
    if f.money_at_risk > 0 then
        table.insert(reasons, string.format("£%.2f at risk: %d day(s) late × £%s/day%s", f.money_at_risk, f.days_at_risk,
            tostring(ctx.deal.late_penalty_per_day), ctx.deal.late_penalty_cap_days
            and (" (cap " .. ctx.deal.late_penalty_cap_days .. " days)") or ""))
    end
    db.query([[
        UPDATE property_deals_deals SET health = ?, health_reasons = ?::jsonb, money_at_risk = ?,
               predicted_completion_date = ?, metadata = metadata || ?::jsonb, updated_at = updated_at
        WHERE namespace_id = ? AND uuid = ?
          AND (health IS DISTINCT FROM ? OR health_reasons IS DISTINCT FROM ?::jsonb OR money_at_risk IS DISTINCT FROM ?
               OR predicted_completion_date IS DISTINCT FROM ?::date)
    ]], health, cjson.encode(U.array(reasons)), f.money_at_risk, f.predicted,
        cjson.encode({ slip = f.slip_detail, facts_at = f.today }), ns, deal_uuid,
        health, cjson.encode(U.array(reasons)), f.money_at_risk, f.predicted)
    if health ~= ctx.deal.health then
        require("helper.plugin-sdk").emit(ns, "property_deals.deal.health_changed", {
            uuid = deal_uuid, from = ctx.deal.health, to = health, reasons = U.array(reasons),
            money_at_risk = f.money_at_risk, predicted_completion_date = f.predicted,
        })
    end
    local w = weights(ctx.settings)
    for _, t in ipairs(open_tasks(ns, deal_uuid)) do
        local score, why = H.urgency(ctx, f, t, w)
        db.query([[
            UPDATE property_deals_task_details SET urgency_score = ?, urgency_why = ?::jsonb
            WHERE task_uuid = ? AND (urgency_score IS DISTINCT FROM ? OR urgency_why IS DISTINCT FROM ?::jsonb)
        ]], score, cjson.encode(why), t.task_uuid, score, cjson.encode(why))
    end
    return { health = health, reasons = reasons, facts = f }
end

--- Tasks not on a deal: urgency from their own clock only.
function H.recompute_loose_tasks(ns, settings)
    local ctx = { settings = settings or {} }
    local w = weights(settings)
    for _, t in ipairs(open_tasks(ns, nil)) do
        local score, why = H.urgency(ctx, nil, t, w)
        db.query("UPDATE property_deals_task_details SET urgency_score = ?, urgency_why = ?::jsonb WHERE task_uuid = ?",
            score, cjson.encode(why), t.task_uuid)
    end
end

--- Every active deal in a workspace (the SLA tick runs this each minute).
function H.recompute_workspace(ns, settings)
    local n = 0
    for _, d in ipairs(db.query("SELECT uuid FROM property_deals_deals WHERE namespace_id = ? AND status = 'active'", ns)) do
        H.recompute_deal(ns, d.uuid, settings)
        n = n + 1
    end
    H.recompute_loose_tasks(ns, settings)
    return n
end

return H
