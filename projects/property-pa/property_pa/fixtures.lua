-- The "How It Works" fixtures (docs/property-pa/HOW-IT-WORKS.md): Sophie's sellers and James the buyer, with the
-- events, interactions and next actions the scenes need. All people, numbers and addresses are fake. Every row is
-- tagged metadata.fixture = "how_it_works" so a reset removes exactly these and nothing else.
-- Times are relative to now, so "yesterday's valuation" is always yesterday.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local FX = {}
local TAG = "how_it_works"

-- name, address, postcode, temperature, expectation, motivation, days since meaningful contact
local SELLERS = {
    { "Sarah", "Hughes", "22 Station Road", "LE1 1AA", "hot", nil, "Relocating for work; wants certainty", 1 },
    { "Michael", "Grant", "14 Green Lane", "LE2 2BB", "warm", 260000, "Downsizing after the children left", 4 },
    { "Rick", "Dawson", "18 Market Street", "LE3 3CC", "warm", 195000, "Inherited; lives abroad", 21 },
    { "Priya", "Shah", "7 Mill Close", "LE4 4DD", "warm", 210000, "Divorce; both must agree", 6 },
    { "Gary", "Lowe", "51 Church Street", "LE5 5EE", "cold", 300000, "Testing the market", 30 },
    { "Helen", "Price", "3 Orchard Way", "LE6 6FF", "hot", 175000, "Moving into care; family deciding", 2 },
    { "Tom", "Baker", "88 Victoria Road", "LE7 7GG", "cold", 240000, "Probate not yet granted", 45 },
    { "Linda", "Cole", "12 Park Avenue", "LE8 8HH", "warm", 285000, "Wants to buy a bungalow nearby", 9 },
    { "Dev", "Patel", "40 King Street", "LE9 9JJ", "warm", 160000, "Tired landlord; tenant leaving", 12 },
    { "Ann", "Morris", "5 Elm Grove", "LE10 0KK", "cold", 220000, "Repossession risk; arrears", 60 },
}

local function tag() return db.raw("'{\"fixture\":\"" .. TAG .. "\"}'::jsonb") end
local function ago(days, hours) return db.raw(string.format("NOW() - INTERVAL '%d days %d hours'", days, hours or 0)) end

-- Something a person made (not a fixture row) that points at a fixture opportunity / person / property. Such a
-- fixture is kept as an ordinary record (its tag is dropped) rather than deleted, so a reset never takes real work
-- with it. Fixture interactions and events carry the tag; fixture facts have source 'import'.
local USED_OPP = [[
    EXISTS (SELECT 1 FROM crm_activities a WHERE a.namespace_id = o.namespace_id AND a.opportunity_uuid = o.uuid
            AND a.metadata ->> 'fixture' IS NULL)
    OR EXISTS (SELECT 1 FROM property_deals_task_details d WHERE d.namespace_id = o.namespace_id
               AND d.opportunity_uuid = o.uuid)
    OR EXISTS (SELECT 1 FROM pa_events e WHERE e.opportunity_uuid = o.uuid AND e.details ->> 'fixture' IS NULL)
    OR EXISTS (SELECT 1 FROM pa_offers x WHERE x.opportunity_uuid = o.uuid)
    OR EXISTS (SELECT 1 FROM pa_handoffs x WHERE x.opportunity_uuid = o.uuid)
    OR EXISTS (SELECT 1 FROM pa_decisions x WHERE x.opportunity_uuid = o.uuid)
    OR EXISTS (SELECT 1 FROM pa_proposed_updates x WHERE x.namespace_id = o.namespace_id
               AND x.target_uuid = o.uuid::text)
    OR EXISTS (SELECT 1 FROM pa_field_facts f WHERE f.namespace_id = o.namespace_id AND f.target_uuid = o.uuid::text
               AND f.source <> 'import')
]]

--- Remove the fixtures: only rows tagged as fixtures. Fixtures that real work points at are kept (untagged).
-- @return { removed, kept } opportunities
function FX.clear(ns)
    -- The sample story first: its rows aren't fixtures in themselves, so they'd otherwise count as real work.
    require("property_pa.story").clear(ns)
    local kept = db.query([[UPDATE pa_opportunities o SET metadata = o.metadata - 'fixture', updated_at = NOW()
        WHERE o.namespace_id = ? AND o.metadata ->> 'fixture' = ? AND (]] .. USED_OPP .. [[) RETURNING o.uuid]],
        ns, TAG)
    local removed = db.query([[DELETE FROM pa_opportunities WHERE namespace_id = ? AND metadata ->> 'fixture' = ?
        RETURNING uuid]], ns, TAG)
    local ids = {}
    for _, o in ipairs(removed) do ids[#ids + 1] = db.escape_literal(o.uuid) end
    if #ids > 0 then
        local list = table.concat(ids, ",")
        db.query("DELETE FROM pa_field_facts WHERE namespace_id = ? AND source = 'import' AND target_uuid IN (" .. list
            .. ")", ns)
        db.query("DELETE FROM crm_activities WHERE namespace_id = ? AND metadata ->> 'fixture' = ? "
            .. "AND opportunity_uuid::text IN (" .. list .. ")", ns, TAG)
    end
    -- A kept opportunity keeps its seeded history too.
    db.query([[UPDATE crm_activities SET metadata = metadata - 'fixture'
        WHERE namespace_id = ? AND metadata ->> 'fixture' = ?]], ns, TAG)
    -- People and properties: kept while anything that isn't a fixture still uses them.
    db.query([[UPDATE crm_contacts c SET metadata = c.metadata - 'fixture', updated_at = NOW()
        WHERE c.namespace_id = ? AND c.metadata ->> 'fixture' = ? AND (
            EXISTS (SELECT 1 FROM pa_opportunities o WHERE o.person_uuid = c.uuid)
            OR EXISTS (SELECT 1 FROM crm_activities a WHERE a.contact_id = c.id)
            OR EXISTS (SELECT 1 FROM pa_events e WHERE e.person_uuid = c.uuid)
            OR EXISTS (SELECT 1 FROM property_deals_buyer_profiles b WHERE b.contact_uuid = c.uuid)
            OR EXISTS (SELECT 1 FROM property_deals_deal_parties x WHERE x.contact_uuid = c.uuid)
            OR EXISTS (SELECT 1 FROM property_deals_compliance_checks x WHERE x.contact_uuid = c.uuid))]], ns, TAG)
    db.query([[UPDATE property_deals_properties p SET metadata = p.metadata - 'fixture', updated_at = NOW()
        WHERE p.namespace_id = ? AND p.metadata ->> 'fixture' = ? AND (
            EXISTS (SELECT 1 FROM pa_opportunities o WHERE o.property_uuid = p.uuid)
            OR EXISTS (SELECT 1 FROM pa_events e WHERE e.property_uuid = p.uuid)
            OR EXISTS (SELECT 1 FROM property_deals_deals x WHERE x.property_uuid = p.uuid)
            OR EXISTS (SELECT 1 FROM property_deals_documents x WHERE x.property_uuid = p.uuid)
            OR EXISTS (SELECT 1 FROM property_deals_compliance_checks x WHERE x.property_uuid = p.uuid))]], ns, TAG)
    db.query("DELETE FROM crm_contacts WHERE namespace_id = ? AND metadata ->> 'fixture' = ?", ns, TAG)
    db.query("DELETE FROM property_deals_properties WHERE namespace_id = ? AND metadata ->> 'fixture' = ?", ns, TAG)
    return { removed = #removed, kept = #kept }
end

local function contact(ns, owner, first, last, roles)
    local uuid = require("helper.global").generateUUID()
    db.insert("crm_contacts", { uuid = uuid, namespace_id = ns, first_name = first, last_name = last,
        email = (first .. "." .. last):lower() .. "@example.invalid", mobile = "07700 900" .. tostring(100 + #first * 7 + #last),
        owner_user_uuid = owner, status = "active", metadata = tag(),
        person_roles = db.raw(db.escape_literal(cjson.encode(roles)) .. "::jsonb"), preferred_channel = "call" })
    return uuid
end

local function property(ns, address, postcode, extra)
    local d = { namespace_id = ns, address_line1 = address, town = "Leicester", postcode = postcode, metadata = tag() }
    for k, v in pairs(extra or {}) do d[k] = v end
    return db.insert("property_deals_properties", d, { returning = { "uuid" } })[1].uuid
end

local function interaction(ns, owner, opp, person, days, channel, summary)
    db.insert("crm_activities", { uuid = require("helper.global").generateUUID(), namespace_id = ns,
        activity_type = channel, subject = channel .. ": " .. summary:sub(1, 80), description = summary,
        contact_id = db.raw("(SELECT id FROM crm_contacts WHERE uuid = " .. db.escape_literal(person) .. ")"),
        owner_user_uuid = owner, activity_date = ago(days), completed_at = ago(days), status = "completed",
        channel = channel, direction = "outbound", summary = summary, opportunity_uuid = opp, meaningful = true,
        source = "import", metadata = tag() })
end

--- Seed the fixtures (clearing old ones first). sophie / ashley = user uuids (members of the workspace).
-- story = true adds the sample history (property_pa.story) on top. settings = the PA's plugin settings.
-- @return { opportunities, sarah = { opportunity_uuid, person_uuid, property_uuid }, story?, ... }
function FX.reset(ns, sophie, ashley, story, settings)
    require("property_pa.setup").run(ns, ashley or sophie)
    local out = { cleared = 0, kept = 0, opportunities = 0 }
    U.tx(function()
        local c = FX.clear(ns)
        out.cleared, out.kept = c.removed, c.kept
        for i, s in ipairs(SELLERS) do
            local first, last, address, postcode, temp, price, motivation, days = (table.unpack or unpack)(s, 1, 8)
            local person = contact(ns, sophie, first, last, { "seller" })
            local prop = property(ns, address, postcode, i == 1 and { bedrooms = 3, tenure = "freehold",
                property_type = "semi_detached", condition = "fair", est_market_value = 230000 } or nil)
            local opp = db.insert("pa_opportunities", {
                namespace_id = ns, kind = "sell", person_uuid = person, property_uuid = prop, owner_user_uuid = sophie,
                title = first .. " " .. last .. " — " .. address, motivation = motivation,
                expectation_price = price or db.NULL, temperature = temp,
                decision_makers = db.raw(db.escape_literal(cjson.encode({ { name = first .. " " .. last, role = "owner" } }))
                    .. "::jsonb"),
                last_meaningful_contact_at = ago(days), metadata = tag(),
            }, { returning = { "uuid" } })[1].uuid
            for _, f in ipairs({ "motivation", "temperature" }) do
                require("property_pa.facts").record(ns, { target_table = "pa_opportunities", target_uuid = opp, field = f,
                    value = f == "motivation" and motivation or temp, action = "create", source = "import" })
            end
            interaction(ns, sophie, opp, person, days, "call", "Spoke to " .. first .. ": " .. motivation .. ".")
            out.opportunities = out.opportunities + 1
            if i == 1 then
                -- Sarah: second valuation yesterday; she said she'd decide after it (scene 1, P01).
                interaction(ns, sophie, opp, person, 3, "call", "Sarah said she would decide after the second "
                    .. "valuation on " .. os.date("!%A", os.time() - 86400) .. ".")
                db.insert("pa_events", { namespace_id = ns, kind = "valuation", at = ago(1), title = "Second agent's valuation",
                    details = tag(), person_uuid = person, property_uuid = prop,
                    opportunity_uuid = opp, done = true })
                db.insert("pa_events", { namespace_id = ns, kind = "promise", at = ago(0, 2),
                    title = "Sarah will decide after the second valuation", details = tag(), person_uuid = person,
                    opportunity_uuid = opp })
                out.sarah = { opportunity_uuid = opp, person_uuid = person, property_uuid = prop }
            elseif i == 2 then
                db.insert("pa_events", { namespace_id = ns, kind = "promise", at = db.raw("NOW() + INTERVAL '2 days'"),
                    title = "We promised Michael a follow-up with comparables this week", details = tag(),
                    person_uuid = person, opportunity_uuid = opp })
                out.michael = { opportunity_uuid = opp, person_uuid = person, property_uuid = prop }
            elseif i == 3 then
                out.rick = { opportunity_uuid = opp, person_uuid = person, property_uuid = prop }
            end
        end
        -- James, a buyer for 94 Milton Road.
        local james = contact(ns, sophie, "James", "Carter", { "buyer" })
        local milton = property(ns, "94 Milton Road", "LE11 1LL", { bedrooms = 2, tenure = "leasehold" })
        local jopp = db.insert("pa_opportunities", { namespace_id = ns, kind = "buy", person_uuid = james, property_uuid = milton,
            owner_user_uuid = sophie, title = "James Carter — buying 94 Milton Road", motivation = "First-time buyer, mortgage in principle",
            temperature = "warm", last_meaningful_contact_at = ago(5), metadata = tag() }, { returning = { "uuid" } })[1].uuid
        interaction(ns, sophie, jopp, james, 5, "call", "James viewed 94 Milton Road and liked it; checking his mortgage.")
        out.james = { opportunity_uuid = jopp, person_uuid = james, property_uuid = milton }
        out.opportunities = out.opportunities + 1
    end)
    out.users = { sophie = sophie, ashley = ashley }
    if story then out.story = require("property_pa.story").add(ns, sophie, ashley or sophie, settings) end
    return out
end

FX.TAG = TAG
return FX
