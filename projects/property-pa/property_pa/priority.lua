-- Today: which opportunity first, and why (build prompt rule 8 "explainable priority"; P01, P07).
--
-- A plain rules engine, not a model: each open opportunity of the person gets points from named signals. Every
-- signal carries its weight, a sentence a person can read and the record it came from (ref), so "Why #1?" lists the
-- real signals and their weights. The model only phrases the brief; it never decides the order.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local R = {}

-- Signal weights (points). Change them here; the tests pin the order they produce on the fixtures.
R.WEIGHTS = {
    promise_due = 30,        -- a promise from them or us falls due within a day (or is overdue)
    event_just_happened = 25, -- a valuation / price change / appointment in the last 48 hours
    next_action_overdue = 25,
    next_action_today = 15,
    offer_awaiting = 20,      -- an offer with no response yet
    hot = 15, warm = 5,
    gone_quiet = 20,          -- no meaningful contact for 14+ days (relationship risk)
    quiet = 10,               -- 7-13 days
    changes_waiting = 5,      -- proposed updates waiting for confirmation
}
-- Minutes a card takes, for "I have 30 minutes".
R.MINUTES = { call = 15, follow_up = 10, review = 5 }

local EVENT_WORDS = { valuation = "valuation", price_reduction = "price reduction", appointment = "appointment",
    listing = "listing", sstc = "sale agreed", fall_through = "fall-through", deadline = "deadline", other = "event" }

R.MAX_CARDS = 100 -- Today shows the top 100; "why" ranks against all of them

local function first(name) return (tostring(name or ""):match("^(%S+)")) or "them" end
local function yes(v) return v == true end
local function null(v) return v == nil or v == db.NULL end

local function ago_text(days)
    if days < 1 then return "today" elseif days < 2 then return "yesterday" end
    return string.format("%d days ago", math.floor(days))
end

--- Every signal of every opportunity matching `where`, in one query (one LATERAL lookup per signal, all indexed),
-- with the score summed in SQL from the same weights, so the ranking can be sorted and cut in the database.
local function scored(where)
    local W = R.WEIGHTS
    return string.format([[
        SELECT s.*, (CASE WHEN promise_uuid IS NOT NULL THEN %d ELSE 0 END
            + CASE WHEN event_uuid IS NOT NULL THEN %d ELSE 0 END
            + CASE WHEN na_overdue THEN %d WHEN na_today THEN %d ELSE 0 END
            + CASE WHEN offer_uuid IS NOT NULL THEN %d ELSE 0 END
            + CASE temperature WHEN 'hot' THEN %d WHEN 'warm' THEN %d ELSE 0 END
            + CASE WHEN quiet_days >= 14 THEN %d WHEN quiet_days >= 7 THEN %d ELSE 0 END
            + CASE WHEN waiting > 0 THEN %d ELSE 0 END) AS score
        FROM (
            SELECT o.uuid, o.title, o.kind, o.temperature, o.owner_user_uuid, o.person_uuid, o.expectation_price,
                   o.last_meaningful_contact_at, p.address_line1 AS property_address,
                   NULLIF(TRIM(CONCAT(c.first_name, ' ', c.last_name)), '') AS person_name,
                   pr.uuid AS promise_uuid, pr.title AS promise_title, pr.at < NOW() AS promise_overdue,
                   ev.uuid AS event_uuid, ev.kind AS event_kind, ev.title AS event_title,
                   EXTRACT(EPOCH FROM (NOW() - ev.at)) / 86400 AS event_days,
                   na.task_uuid AS na_task_uuid, na.title AS na_title, na.due_at AS na_due_at, na.reason AS na_reason,
                   na.due_at < NOW() AS na_overdue, na.due_at < date_trunc('day', NOW()) + INTERVAL '1 day' AS na_today,
                   f.uuid AS offer_uuid, f.amount AS offer_amount,
                   EXTRACT(EPOCH FROM (NOW() - o.last_meaningful_contact_at)) / 86400 AS quiet_days,
                   w.n AS waiting
            FROM pa_opportunities o
            LEFT JOIN crm_contacts c ON c.uuid = o.person_uuid
            LEFT JOIN property_deals_properties p ON p.uuid = o.property_uuid
            LEFT JOIN LATERAL (SELECT uuid, title, at FROM pa_events WHERE namespace_id = o.namespace_id
                AND opportunity_uuid = o.uuid AND kind = 'promise' AND NOT done AND at < NOW() + INTERVAL '1 day'
                ORDER BY at LIMIT 1) pr ON TRUE
            LEFT JOIN LATERAL (SELECT uuid, kind, title, at FROM pa_events WHERE namespace_id = o.namespace_id
                AND opportunity_uuid = o.uuid AND kind IN ('valuation', 'price_reduction', 'appointment', 'listing',
                'sstc', 'fall_through') AND at BETWEEN NOW() - INTERVAL '48 hours' AND NOW() ORDER BY at DESC LIMIT 1) ev ON TRUE
            LEFT JOIN LATERAL (SELECT d.task_uuid, t.title, d.due_at, d.reason
                FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
                WHERE d.namespace_id = o.namespace_id AND d.opportunity_uuid = o.uuid
                  AND d.pd_status NOT IN ('done', 'cancelled') ORDER BY d.due_at ASC NULLS LAST LIMIT 1) na ON TRUE
            LEFT JOIN LATERAL (SELECT uuid, amount FROM pa_offers WHERE namespace_id = o.namespace_id
                AND opportunity_uuid = o.uuid AND response = 'pending' ORDER BY made_at DESC LIMIT 1) f ON TRUE
            LEFT JOIN LATERAL (SELECT COUNT(*)::int AS n FROM pa_proposed_updates WHERE namespace_id = o.namespace_id
                AND status = 'proposed' AND target_uuid = o.uuid::text) w ON TRUE
            WHERE o.namespace_id = ? AND %s
        ) s]], W.promise_due, W.event_just_happened, W.next_action_overdue, W.next_action_today, W.offer_awaiting,
        W.hot, W.warm, W.gone_quiet, W.quiet, W.changes_waiting, where)
end
-- Same order everywhere: score, then title byte order (as Lua compares strings).
local ORDER = [[ORDER BY score DESC, title COLLATE "C"]]

--- One card from a scored row (no queries). @return { score, signals = [{ key, weight, text, ref }], action, ... }
function R.card(o)
    local W, signals = R.WEIGHTS, {}
    local who = first(o.person_name)
    local function add(key, text, ref)
        signals[#signals + 1] = { key = key, weight = W[key], text = text, ref = ref }
    end
    if not null(o.promise_uuid) then add("promise_due", o.promise_title .. (yes(o.promise_overdue) and " (due now)"
        or " (due within a day)"), "pa_events:" .. o.promise_uuid) end
    if not null(o.event_uuid) then add("event_just_happened", o.event_title .. " ("
        .. ago_text(tonumber(o.event_days) or 0) .. ")", "pa_events:" .. o.event_uuid) end
    local na = not null(o.na_task_uuid)
    if yes(o.na_overdue) then add("next_action_overdue", "Next action overdue: " .. o.na_title,
        "property_deals_task_details:" .. o.na_task_uuid)
    elseif yes(o.na_today) then add("next_action_today", "Next action due today: " .. o.na_title,
        "property_deals_task_details:" .. o.na_task_uuid) end
    if not null(o.offer_uuid) then add("offer_awaiting", string.format("Offer of £%s waiting for an answer",
        (tostring(math.floor(tonumber(o.offer_amount) or 0)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))),
        "pa_offers:" .. o.offer_uuid) end
    if o.temperature == "hot" or o.temperature == "warm" then
        add(o.temperature, (o.temperature == "hot" and "Hot" or "Warm") .. " opportunity",
            "pa_opportunities:" .. o.uuid .. ":temperature")
    end
    local d = tonumber(o.quiet_days)
    if d and d >= 14 then add("gone_quiet", string.format("No meaningful contact for %d days", math.floor(d)),
        "pa_opportunities:" .. o.uuid .. ":last_meaningful_contact_at")
    elseif d and d >= 7 then add("quiet", string.format("%d days since meaningful contact", math.floor(d)),
        "pa_opportunities:" .. o.uuid .. ":last_meaningful_contact_at") end
    if (tonumber(o.waiting) or 0) > 0 then add("changes_waiting", o.waiting .. " change(s) from notes waiting for you") end

    table.sort(signals, function(a, b) return a.weight > b.weight end)
    local score = 0
    for _, s in ipairs(signals) do score = score + s.weight end
    -- What to do and why (the strongest signal decides; an existing next action wins).
    local top = signals[1] and signals[1].key
    local action, objective, minutes
    if na then
        action, objective, minutes = o.na_title, not null(o.na_reason) and o.na_reason or nil, R.MINUTES.call
    end
    if top == "promise_due" then
        action = action or ("Call " .. who)
        objective = objective or ("Hear " .. who .. "'s decision and agree the next step")
    elseif top == "event_just_happened" then
        local what = EVENT_WORDS[o.event_kind] or "event"
        action = action or ("Call " .. who .. " about the " .. what)
        objective = objective or ("Find out how the " .. what .. " changed " .. who .. "'s expectations")
    elseif top == "offer_awaiting" then
        action = action or ("Chase the answer on the offer with " .. who)
        objective = objective or "Get a yes, a no or a counter, with the reason"
    elseif top == "gone_quiet" or top == "quiet" then
        action, minutes = action or ("Send " .. who .. " a short personal follow-up"), minutes or R.MINUTES.follow_up
        objective = objective or "Re-open the conversation; refer to the last one"
    elseif top == "changes_waiting" then
        action, minutes = action or "Confirm the changes from your notes", minutes or R.MINUTES.review
        objective = objective or "Keep the record right"
    end
    return { score = score, signals = setmetatable(signals, cjson.array_mt), action = action or ("Check in with " .. who),
        objective = objective or "Keep it moving", minutes = minutes or R.MINUTES.call,
        next_action = na and { task_uuid = o.na_task_uuid, title = o.na_title, due_at = o.na_due_at } or cjson.null }
end

--- Score one opportunity (any owner). o = row with uuid.
function R.score(ns, o)
    local row = U.one(scored("o.uuid = ?::uuid"), ns, o.uuid)
    return R.card(row or o)
end

--- Scored rows matching `where` (SQL over alias o, `?` args after ns), best first, at most `limit`.
function R.top(ns, where, limit, ...)
    return db.query(scored(where) .. " " .. ORDER .. " LIMIT " .. math.floor(limit), ns, ...)
end

local function card_of(o)
    local s = R.card(o)
    s.opportunity_uuid, s.title, s.kind, s.person_name, s.person_uuid, s.property_address =
        o.uuid, o.title, o.kind, o.person_name, o.person_uuid, o.property_address
    s.why_now = s.signals[1] and s.signals[1].text or "Nothing pressing"
    return s
end

--- My ranked day. minutes = optional time budget. @return { cards, fits?, waits? }
function R.today(ns, user_uuid, minutes)
    local cards = {}
    for i, o in ipairs(R.top(ns, "o.owner_user_uuid = ? AND o.status = 'open'", R.MAX_CARDS, user_uuid)) do
        local c = card_of(o)
        c.rank = i
        cards[i] = c
    end
    local out = { cards = U.array(cards), weights = R.WEIGHTS }
    if minutes then
        local used, fits, waits = 0, {}, {}
        for _, c in ipairs(cards) do
            if c.score > 0 and used + c.minutes <= minutes then
                used = used + c.minutes
                fits[#fits + 1] = c
            elseif c.score > 0 then
                waits[#waits + 1] = { opportunity_uuid = c.opportunity_uuid, title = c.title, minutes = c.minutes }
            end
        end
        out.budget = { minutes = minutes, used = used, fits = U.array(fits), waits = U.array(waits) }
    end
    return out
end

--- One card of my day with its rank (ranked in the database; only this card is built). @return card | nil
function R.why(ns, user_uuid, opp_uuid)
    if not U.is_uuid(opp_uuid) then return nil end
    local o = U.one("SELECT * FROM (SELECT x.*, ROW_NUMBER() OVER (" .. ORDER .. ") AS rank, COUNT(*) OVER () AS total FROM ("
        .. scored("o.owner_user_uuid = ? AND o.status = 'open'") .. ") x) y WHERE uuid = ?::uuid", ns, user_uuid, opp_uuid)
    if not o then return nil end
    local c = card_of(o)
    c.rank, c.of = tonumber(o.rank), tonumber(o.total)
    return c
end

return R
