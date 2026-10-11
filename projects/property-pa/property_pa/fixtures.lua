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

--- Remove the fixtures (only rows tagged as fixtures, and what hangs off them).
function FX.clear(ns)
    local opps = db.query("SELECT uuid FROM pa_opportunities WHERE namespace_id = ? AND metadata ->> 'fixture' = ?", ns, TAG)
    local ids = {}
    for _, o in ipairs(opps) do ids[#ids + 1] = db.escape_literal(o.uuid) end
    if #ids > 0 then
        local list = table.concat(ids, ",")
        db.query("DELETE FROM kanban_tasks WHERE uuid IN (SELECT task_uuid FROM property_deals_task_details WHERE namespace_id = ? AND opportunity_uuid::text IN (" .. list .. "))", ns)
        db.query("DELETE FROM crm_activities WHERE namespace_id = ? AND opportunity_uuid::text IN (" .. list .. ")", ns)
        db.query("DELETE FROM pa_field_facts WHERE namespace_id = ? AND target_uuid IN (" .. list .. ")", ns)
        db.query("DELETE FROM pa_proposed_updates WHERE namespace_id = ? AND target_uuid IN (" .. list .. ")", ns)
        db.query("DELETE FROM pa_handoffs WHERE namespace_id = ? AND opportunity_uuid::text IN (" .. list .. ")", ns)
    end
    db.query("DELETE FROM pa_opportunities WHERE namespace_id = ? AND metadata ->> 'fixture' = ?", ns, TAG)
    local n = #opps
    db.query("DELETE FROM crm_contacts WHERE namespace_id = ? AND metadata ->> 'fixture' = ?", ns, TAG)
    db.query("DELETE FROM property_deals_properties WHERE namespace_id = ? AND metadata ->> 'fixture' = ?", ns, TAG)
    return n
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
-- @return { opportunities, sarah = { opportunity_uuid, person_uuid, property_uuid }, ... }
function FX.reset(ns, sophie, ashley)
    require("property_pa.setup").run(ns, ashley or sophie)
    local out = { cleared = 0, opportunities = 0 }
    U.tx(function()
        out.cleared = FX.clear(ns)
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
                    details = db.raw("'{\"by\":\"other agent\"}'::jsonb"), person_uuid = person, property_uuid = prop,
                    opportunity_uuid = opp, done = true })
                db.insert("pa_events", { namespace_id = ns, kind = "promise", at = ago(0, 2), title = "Sarah will decide after the second valuation",
                    person_uuid = person, opportunity_uuid = opp })
                out.sarah = { opportunity_uuid = opp, person_uuid = person, property_uuid = prop }
            elseif i == 2 then
                db.insert("pa_events", { namespace_id = ns, kind = "promise", at = db.raw("NOW() + INTERVAL '2 days'"),
                    title = "We promised Michael a follow-up with comparables this week", person_uuid = person, opportunity_uuid = opp })
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
    return out
end

FX.TAG = TAG
return FX
