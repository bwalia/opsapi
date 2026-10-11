-- Prepare Me (P02) and Coach (P06): built from the record, not by the model.
--
-- Every line of a brief carries the ref of the record it came from (so "every material fact maps to a record id"
-- holds by construction); what isn't recorded is listed as unknown with the question that would find it out. The
-- relevant playbook rules are picked by the situation (triggers), and the PA only phrases the result.
-- Coaching suggests questions and never a higher offer (authority: offers are a person's decision).
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local Br = {}

local function arr(t) return setmetatable(t or {}, cjson.array_mt) end
local function null(v) return v == nil or v == db.NULL or v == cjson.null end
local function gbp(v)
    local n = math.floor(tonumber(v) or 0)
    return "£" .. (tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
local function first(name) return (tostring(name or ""):match("^(%S+)")) or "them" end

-- Questions that find out what isn't recorded (field -> question).
Br.QUESTIONS = {
    motivation = "Why are you thinking of selling, and why now?",
    expectation_price = "What figure would you need to see to go ahead?",
    decision_makers = "Who else needs to be happy with the decision?",
    primary_concern = "What worries you most about selling?",
    timescale = "When would you ideally like to have moved by?",
}

--- The situation's triggers, used to pick playbook rules.
function Br.triggers(ns, o)
    local t = { "always" }
    local function add(x) t[#t + 1] = x end
    if U.one([[SELECT 1 FROM pa_events WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND kind = 'valuation'
        AND at > NOW() - INTERVAL '14 days']], ns, o.uuid) then add("valuation"); add("price") end
    if U.one("SELECT 1 FROM pa_offers WHERE namespace_id = ? AND opportunity_uuid = ?::uuid", ns, o.uuid) then add("offer") end
    if U.one([[SELECT 1 FROM pa_events WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND kind = 'promise' AND NOT done]],
        ns, o.uuid) then add("promise"); add("call_back") end
    local dm = U.json(o.decision_makers)
    if type(dm) == "table" and #dm > 1 then add("decision_makers") end
    if not null(o.expectation_price) then add("price"); add("objection") end
    if not null(o.primary_concern) and tostring(o.primary_concern):lower():find("price") then add("objection") end
    if not U.one([[SELECT 1 FROM crm_activities WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND meaningful
        AND deleted_at IS NULL LIMIT 1]], ns, o.uuid) then add("first_call"); add("new_seller") end
    local quiet = U.one([[SELECT (COALESCE(?::timestamptz, '-infinity') < NOW() - INTERVAL '14 days') AS q]],
        null(o.last_meaningful_contact_at) and db.NULL or o.last_meaningful_contact_at)
    if quiet and quiet.q then add("cold"); add("follow_up") end
    if U.one([[SELECT 1 FROM pa_events WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND kind = 'deadline'
        AND NOT done]], ns, o.uuid) then add("deadline"); add("speed") end
    return t
end

--- Approved rules for these triggers, as { key, version, title, rule, ref }.
function Br.rules(ns, user_uuid, triggers)
    local K = require("property_pa.knowledge")
    local seen, out = {}, {}
    for _, tr in ipairs(triggers) do
        for _, k in ipairs(K.list(ns, user_uuid, { trigger = tr })) do
            if not seen[k.uuid] then
                seen[k.uuid] = true
                out[#out + 1] = { key = k.key, version = k.current_version, scope = k.scope, title = k.title, rule = k.rule,
                    ref = "pa_knowledge:" .. k.uuid }
            end
        end
    end
    return arr(out)
end

local function opp(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one([[
        SELECT o.*, NULLIF(TRIM(CONCAT(c.first_name, ' ', c.last_name)), '') AS person_name,
               p.address_line1 AS property_address, p.postcode AS property_postcode
        FROM pa_opportunities o LEFT JOIN crm_contacts c ON c.uuid = o.person_uuid
        LEFT JOIN property_deals_properties p ON p.uuid = o.property_uuid
        WHERE o.namespace_id = ? AND o.uuid = ?::uuid
    ]], ns, id)
end

--- Prepare Me for an opportunity. @return brief | nil
function Br.prepare(ns, id, user_uuid)
    local o = opp(ns, id)
    if not o then return nil end
    local F = require("property_pa.facts")
    local facts = F.current_facts(ns, "pa_opportunities", o.uuid)
    local R = "pa_opportunities:" .. o.uuid
    local who = first(o.person_name)
    local function fact(field, text)
        local f = facts[field] or {}
        return { text = text, ref = R .. ":" .. field, is_inferred = f.is_inferred == true,
            label = f.is_inferred and "judgement, unconfirmed" or "stated" }
    end
    local b = { opportunity_uuid = o.uuid, title = o.title, person_name = o.person_name, snapshot = {}, unknowns = {},
        questions = {}, promises = {}, price = {}, decision_makers = {}, objections = {} }
    -- Snapshot
    local snap = { { text = o.title .. (null(o.property_postcode) and "" or (", " .. o.property_postcode)), ref = R } }
    if not null(o.temperature) then snap[#snap + 1] = fact("temperature", "Temperature: " .. o.temperature) end
    if not null(o.motivation) then snap[#snap + 1] = fact("motivation", "Motivation: " .. o.motivation) end
    b.snapshot = arr(snap)
    -- Last meaningful interaction
    local last = U.one([[SELECT uuid, channel, activity_date AS at, COALESCE(summary, LEFT(COALESCE(transcript, raw_text,
        description), 400)) AS text FROM crm_activities WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND meaningful
        AND deleted_at IS NULL ORDER BY activity_date DESC LIMIT 1]], ns, o.uuid)
    b.last_interaction = last and { text = last.text, at = last.at, channel = last.channel,
        ref = "crm_activities:" .. last.uuid } or cjson.null
    -- Price and offer position: their number and ours kept apart (playbook rule).
    local price = {}
    if not null(o.expectation_price) then
        price[#price + 1] = fact("expectation_price", who .. "'s stated minimum: " .. gbp(o.expectation_price))
    end
    if not null(o.our_position) then price[#price + 1] = fact("our_position", "Our position: " .. o.our_position) end
    for _, e in ipairs(db.query([[SELECT uuid, title, at, details FROM pa_events WHERE namespace_id = ? AND opportunity_uuid =
        ?::uuid AND kind IN ('valuation', 'price_reduction') ORDER BY at DESC LIMIT 3]], ns, o.uuid)) do
        local amt = type(U.json(e.details)) == "table" and U.json(e.details).amount
        price[#price + 1] = { text = e.title .. (amt and (" (" .. gbp(amt) .. ")") or ""), ref = "pa_events:" .. e.uuid,
            label = "stated" }
    end
    for _, of in ipairs(db.query([[SELECT uuid, amount, response FROM pa_offers WHERE namespace_id = ? AND opportunity_uuid =
        ?::uuid ORDER BY made_at DESC LIMIT 3]], ns, o.uuid)) do
        price[#price + 1] = { text = "Offer " .. gbp(of.amount) .. ": " .. of.response, ref = "pa_offers:" .. of.uuid,
            label = "stated" }
    end
    b.price = arr(price)
    -- Decision makers
    local dm = U.json(o.decision_makers)
    if type(dm) == "table" and #dm > 0 then
        local names = {}
        for _, d in ipairs(dm) do names[#names + 1] = (type(d) == "table" and (d.name or "?") .. (d.role and (" (" .. d.role .. ")") or "")) or tostring(d) end
        b.decision_makers = arr({ fact("decision_makers", table.concat(names, ", ")) })
    end
    -- Promises (theirs and ours) still open
    local pr = {}
    for _, e in ipairs(db.query([[SELECT uuid, title, at FROM pa_events WHERE namespace_id = ? AND opportunity_uuid = ?::uuid
        AND kind = 'promise' AND NOT done ORDER BY at]], ns, o.uuid)) do
        pr[#pr + 1] = { text = e.title, at = e.at, ref = "pa_events:" .. e.uuid, label = "stated" }
    end
    b.promises = arr(pr)
    -- Likely objections (from what's recorded only)
    local obj = {}
    if not null(o.primary_concern) then obj[#obj + 1] = fact("primary_concern", o.primary_concern) end
    if U.one([[SELECT 1 FROM pa_events WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND kind = 'valuation'
        AND at > NOW() - INTERVAL '14 days']], ns, o.uuid) then
        local e = U.one([[SELECT uuid FROM pa_events WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND kind = 'valuation'
            ORDER BY at DESC LIMIT 1]], ns, o.uuid)
        obj[#obj + 1] = { text = "Another agent's valuation may anchor " .. who .. "'s expectations",
            ref = "pa_events:" .. e.uuid, label = "inference" }
    end
    b.objections = arr(obj)
    -- Unknowns -> questions to establish
    local unknown, qs = {}, {}
    for _, f in ipairs({ "motivation", "expectation_price", "decision_makers", "primary_concern" }) do
        local v = o[f]
        if null(v) or (type(U.json(v)) == "table" and #U.json(v) <= (f == "decision_makers" and 1 or 0)) then
            unknown[#unknown + 1] = f
            qs[#qs + 1] = { field = f, question = Br.QUESTIONS[f] }
        end
    end
    if not U.one([[SELECT 1 FROM pa_events WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND kind = 'deadline']],
        ns, o.uuid) then
        unknown[#unknown + 1] = "timescale"
        qs[#qs + 1] = { field = "timescale", question = Br.QUESTIONS.timescale }
    end
    b.unknowns, b.questions = arr(unknown), arr(qs)
    -- Playbook and objective
    b.triggers = arr(Br.triggers(ns, o))
    b.playbook = Br.rules(ns, user_uuid, b.triggers)
    local card = require("property_pa.priority").score(ns, o)
    b.objective, b.recommended_action = card.objective, card.action
    b.why_now = arr(card.signals)
    return b
end

-- Phrases that recommend paying more. A coach answer with one of these is withheld (P06).
Br.HIGHER_OFFER = { "increase the offer", "increase your offer", "increase our offer", "raise the offer",
    "raise your offer", "raise our offer", "higher offer", "offer more", "go up to", "improve the offer",
    "improve our offer", "up the offer", "bump the offer", "meet her at", "meet him at", "meet them at",
    "split the difference" }

--- Does a text recommend a higher offer? @return phrase | nil
function Br.recommends_higher_offer(text)
    local l = tostring(text or ""):lower()
    for _, p in ipairs(Br.HIGHER_OFFER) do
        if l:find(p, 1, true) then return p end
    end
    return nil
end

--- Coach: what's known (cited), what's assumed, the questions to ask first, the rules. Never a figure to offer.
function Br.coach(ns, id, user_uuid, situation)
    local p = Br.prepare(ns, id, user_uuid)
    if not p then return nil end
    local known, assumed = {}, {}
    for _, group in ipairs({ p.snapshot, p.price, p.decision_makers, p.promises }) do
        for _, f in ipairs(group) do
            if f.is_inferred or f.label == "inference" then assumed[#assumed + 1] = f else known[#known + 1] = f end
        end
    end
    for _, f in ipairs(p.objections) do if f.label == "inference" then assumed[#assumed + 1] = f end end
    local who = first(p.person_name)
    local qs = {}
    for _, q in ipairs(p.questions) do qs[#qs + 1] = q.question end
    -- Questions that change the decision before any figure is discussed (seller_no_higher_offer).
    for _, q in ipairs({
        "What matters more to " .. who .. ": the price, or a quick and certain completion?",
        "Is there a date " .. who .. " needs to be out by, and why?",
        "Has everyone who must agree seen the figures? What do they think?",
        "What would " .. who .. " do if the sale doesn't happen this month?",
    }) do qs[#qs + 1] = q end
    return {
        opportunity_uuid = p.opportunity_uuid, situation = situation or cjson.null, known = arr(known),
        assumed = arr(assumed), questions = arr(qs), playbook = p.playbook,
        next_step = "Ask these before discussing any figure. Changing the offer is a decision for someone with authority:"
            .. " hand it off with the answers.",
        never = "The PA does not suggest a higher offer or a price cut.",
    }
end

return Br
