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

local function days_since(ts)
    if not ts or ts == db.NULL then return nil end
    local r = U.one("SELECT EXTRACT(EPOCH FROM (NOW() - ?::timestamptz)) / 86400 AS d", ts)
    return r and tonumber(r.d)
end

local function first(name) return (tostring(name or ""):match("^(%S+)")) or "them" end

local function ago_text(days)
    if days < 1 then return "today" elseif days < 2 then return "yesterday" end
    return string.format("%d days ago", math.floor(days))
end

--- Score one opportunity. o = row with uuid, title, temperature, person_name, last_meaningful_contact_at.
-- @return { score, signals = [{ key, weight, text, ref }], action, objective, minutes }
function R.score(ns, o)
    local W, signals = R.WEIGHTS, {}
    local who = first(o.person_name)
    local function add(key, text, ref, weight)
        signals[#signals + 1] = { key = key, weight = weight or W[key], text = text, ref = ref }
    end
    local promise = U.one([[SELECT uuid, title, at, (at < NOW()) AS overdue FROM pa_events WHERE namespace_id = ?
        AND opportunity_uuid = ?::uuid AND kind = 'promise' AND NOT done AND at < NOW() + INTERVAL '1 day'
        ORDER BY at LIMIT 1]], ns, o.uuid)
    if promise then add("promise_due", promise.title .. (promise.overdue and " (due now)" or " (due within a day)"),
        "pa_events:" .. promise.uuid) end
    local ev = U.one([[SELECT uuid, kind, title, at, EXTRACT(EPOCH FROM (NOW() - at)) / 86400 AS days FROM pa_events
        WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND kind IN ('valuation', 'price_reduction', 'appointment',
        'listing', 'sstc', 'fall_through') AND at BETWEEN NOW() - INTERVAL '48 hours' AND NOW() ORDER BY at DESC LIMIT 1]],
        ns, o.uuid)
    if ev then add("event_just_happened", ev.title .. " (" .. ago_text(tonumber(ev.days) or 0) .. ")",
        "pa_events:" .. ev.uuid) end
    local na = U.one([[SELECT d.task_uuid, t.title, d.due_at, d.reason, (d.due_at < NOW()) AS overdue,
        (d.due_at < date_trunc('day', NOW()) + INTERVAL '1 day') AS today
        FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
        WHERE d.namespace_id = ? AND d.opportunity_uuid = ?::uuid AND d.pd_status NOT IN ('done', 'cancelled')
        ORDER BY d.due_at ASC NULLS LAST LIMIT 1]], ns, o.uuid)
    if na and na.overdue then add("next_action_overdue", "Next action overdue: " .. na.title, "property_deals_task_details:"
        .. na.task_uuid)
    elseif na and na.today then add("next_action_today", "Next action due today: " .. na.title,
        "property_deals_task_details:" .. na.task_uuid) end
    local offer = U.one([[SELECT uuid, amount FROM pa_offers WHERE namespace_id = ? AND opportunity_uuid = ?::uuid
        AND response = 'pending' ORDER BY made_at DESC LIMIT 1]], ns, o.uuid)
    if offer then add("offer_awaiting", string.format("Offer of £%s waiting for an answer",
        (tostring(math.floor(tonumber(offer.amount) or 0)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))),
        "pa_offers:" .. offer.uuid) end
    if o.temperature == "hot" or o.temperature == "warm" then
        add(o.temperature, (o.temperature == "hot" and "Hot" or "Warm") .. " opportunity",
            "pa_opportunities:" .. o.uuid .. ":temperature")
    end
    local d = days_since(o.last_meaningful_contact_at)
    if d and d >= 14 then add("gone_quiet", string.format("No meaningful contact for %d days", math.floor(d)),
        "pa_opportunities:" .. o.uuid .. ":last_meaningful_contact_at")
    elseif d and d >= 7 then add("quiet", string.format("%d days since meaningful contact", math.floor(d)),
        "pa_opportunities:" .. o.uuid .. ":last_meaningful_contact_at") end
    local waiting = U.one([[SELECT COUNT(*)::int AS n FROM pa_proposed_updates WHERE namespace_id = ? AND status = 'proposed'
        AND target_uuid = ?]], ns, o.uuid)
    if waiting and waiting.n > 0 then add("changes_waiting", waiting.n .. " change(s) from notes waiting for you") end

    table.sort(signals, function(a, b) return a.weight > b.weight end)
    local score = 0
    for _, s in ipairs(signals) do score = score + s.weight end
    -- What to do and why (the strongest signal decides; an existing next action wins).
    local top = signals[1] and signals[1].key
    local action, objective, minutes
    if na then
        action, objective, minutes = na.title, na.reason ~= db.NULL and na.reason or nil, R.MINUTES.call
    end
    if top == "promise_due" then
        action = action or ("Call " .. who)
        objective = objective or ("Hear " .. who .. "'s decision and agree the next step")
    elseif top == "event_just_happened" then
        action = action or ("Call " .. who .. " about the " .. (EVENT_WORDS[ev.kind] or "event"))
        objective = objective or ("Find out how the " .. (EVENT_WORDS[ev.kind] or "event") .. " changed " .. who
            .. "'s expectations")
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
        next_action = na and { task_uuid = na.task_uuid, title = na.title, due_at = na.due_at } or cjson.null }
end

--- My ranked day. minutes = optional time budget. @return { cards, fits?, waits? }
function R.today(ns, user_uuid, minutes)
    local opps = db.query([[
        SELECT o.uuid, o.title, o.kind, o.temperature, o.last_meaningful_contact_at, o.expectation_price,
               NULLIF(TRIM(CONCAT(c.first_name, ' ', c.last_name)), '') AS person_name, o.person_uuid,
               p.address_line1 AS property_address
        FROM pa_opportunities o LEFT JOIN crm_contacts c ON c.uuid = o.person_uuid
        LEFT JOIN property_deals_properties p ON p.uuid = o.property_uuid
        WHERE o.namespace_id = ? AND o.owner_user_uuid = ? AND o.status = 'open'
    ]], ns, user_uuid)
    local cards = {}
    for _, o in ipairs(opps) do
        local s = R.score(ns, o)
        s.opportunity_uuid, s.title, s.kind, s.person_name, s.person_uuid, s.property_address =
            o.uuid, o.title, o.kind, o.person_name, o.person_uuid, o.property_address
        s.why_now = s.signals[1] and s.signals[1].text or "Nothing pressing"
        cards[#cards + 1] = s
    end
    table.sort(cards, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return tostring(a.title) < tostring(b.title)
    end)
    for i, c in ipairs(cards) do c.rank = i end
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

return R
