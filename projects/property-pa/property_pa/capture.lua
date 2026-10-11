-- Week 2 capture: a voice note or typed note becomes an interaction, the PA (JobShout, mode capture) proposes the
-- changes, and the person sees one confirm sheet: every proposed field, stated or inferred, with the words it
-- came from. [Confirm] applies them all; [Change something] corrects or rejects single rows first.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local P = require("property_pa.updates")

local C = {}

-- How each proposed field reads on the sheet.
C.LABELS = {
    ["pa_opportunities.expectation_price"] = "Seller's stated minimum",
    ["pa_opportunities.our_position"] = "Price that might work",
    ["pa_opportunities.decision_makers"] = "Decision makers",
    ["pa_opportunities.motivation"] = "Motivation",
    ["pa_opportunities.temperature"] = "Temperature",
    ["pa_opportunities.primary_concern"] = "Main concern",
    ["pa_opportunities.status"] = "Status",
    ["pa_opportunities.title"] = "Title",
    ["pa_opportunities.last_meaningful_contact_at"] = "Last meaningful contact",
    ["crm_contacts.phone"] = "Phone", ["crm_contacts.mobile"] = "Mobile", ["crm_contacts.email"] = "Email",
    ["crm_contacts.preferred_channel"] = "Preferred channel", ["crm_contacts.person_roles"] = "Roles",
    ["property_deals_properties.condition"] = "Condition", ["property_deals_properties.known_issues_note"] = "Known issues",
    ["property_deals_properties.est_market_value"] = "Estimated value", ["property_deals_properties.bedrooms"] = "Bedrooms",
    ["property_deals_properties.tenure"] = "Tenure", ["property_deals_properties.notes"] = "Property notes",
    ["pa_events._create"] = "Event", ["pa_offers._create"] = "Offer", ["next_action._create"] = "Next action",
}

local function first_name(user_uuid)
    local u = user_uuid and U.one("SELECT first_name, email FROM users WHERE uuid = ?", user_uuid)
    if not u then return nil end
    local n = u.first_name ~= db.NULL and u.first_name or nil
    return (n and n ~= "") and n or (u.email and u.email:match("^[^@.]+")) or nil
end

--- How a row is typed on the sheet: stated (quoted from the note), inferred (someone's judgement, unconfirmed:
-- P09) or proposed (a new event / offer / next action).
local function kind_label(p, author)
    if p.is_inferred then
        return "inferred", ((author and (author:upper() .. "'S ") or "") .. "JUDGEMENT, UNCONFIRMED")
    end
    if p.target_table == "next_action" or p.field == "_create" then return "proposed", "Proposed" end
    return "stated", "Stated"
end

--- The confirm sheet for an interaction. @return { interaction, author, run, proposals, counts } | nil
function C.sheet(ns, interaction_uuid)
    local I = require("property_pa.interactions")
    local it = I.get(ns, interaction_uuid)
    if not it then return nil end
    -- The note's author: their own voice note / internal note -> "Sophie's judgement".
    local author = it.direction == "internal" and first_name(it.owner_user_uuid) or nil
    local rows = db.query(P.SELECT .. [[ WHERE namespace_id = ? AND source_interaction_uuid = ?
        ORDER BY CASE WHEN target_table = 'next_action' THEN 2 WHEN field = '_create' THEN 1 ELSE 0 END, id]],
        ns, interaction_uuid)
    local counts = { proposed = 0, confirmed = 0, corrected = 0, rejected = 0, material = 0 }
    for _, r in ipairs(rows) do
        if r.old_value == cjson.null then r.old_value = nil end
        if r.new_value == cjson.null then r.new_value = nil end
        r.kind, r.kind_label = kind_label(r, author)
        r.label = C.LABELS[r.target_table .. "." .. r.field] or (r.target_table .. "." .. r.field)
        if r.target_table == "next_action" and type(r.new_value) == "table" then
            local owner = r.new_value.owner_user_uuid
            if not owner and U.is_uuid(r.new_value.opportunity_uuid) then
                local o = U.one("SELECT owner_user_uuid FROM pa_opportunities WHERE namespace_id = ? AND uuid = ?::uuid",
                    ns, r.new_value.opportunity_uuid)
                owner = o and o.owner_user_uuid ~= db.NULL and o.owner_user_uuid or nil
            end
            owner = owner or it.owner_user_uuid
            r.owner = { user_uuid = owner, name = first_name(owner) }
        end
        counts[r.status] = (counts[r.status] or 0) + 1
        if r.material and r.status == "proposed" then counts.material = counts.material + 1 end
    end
    local run = U.one([[SELECT uuid, status, error, output, prompt_version, model FROM property_deals_agent_runs
        WHERE namespace_id = ? AND provider = 'jobshout-pa' AND input_snapshot ->> 'interaction_uuid' = ?
        ORDER BY id DESC LIMIT 1]], ns, interaction_uuid)
    if run then run.output = U.json(run.output) end
    return { interaction = it, author = author or cjson.null, run = run or cjson.null, proposals = U.array(rows),
        counts = counts }
end

--- Decide several rows of one sheet. decisions = [{ uuid, action = confirm|correct|reject, value? }];
-- confirm_rest = true confirms every row still proposed that isn't in the list.
-- Each row is its own transaction (one bad row doesn't undo the others). @return { results, sheet }
function C.decide(ns, interaction_uuid, decisions, confirm_rest, user_uuid, settings)
    local sheet = C.sheet(ns, interaction_uuid)
    if not sheet then U.fail(404, "Interaction not found") end
    local mine, todo = {}, {}
    for _, p in ipairs(sheet.proposals) do mine[p.uuid] = p end
    local seen = {}
    for i, d in ipairs(decisions or {}) do
        if type(d) ~= "table" or not mine[d.uuid] then
            U.fail(422, "Validation failed", { ["decisions." .. i] = "not a proposed update of this interaction" })
        end
        if d.action ~= "confirm" and d.action ~= "correct" and d.action ~= "reject" then
            U.fail(422, "Validation failed", { ["decisions." .. i] = "action must be confirm, correct or reject" })
        end
        if d.action == "correct" and d.value == nil then
            U.fail(422, "Validation failed", { ["decisions." .. i] = "a correction needs a value" })
        end
        seen[d.uuid] = true
        todo[#todo + 1] = d
    end
    if confirm_rest then
        for _, p in ipairs(sheet.proposals) do
            if p.status == "proposed" and not seen[p.uuid] then todo[#todo + 1] = { uuid = p.uuid, action = "confirm" } end
        end
    end
    local results = {}
    for _, d in ipairs(todo) do
        local ok, res = pcall(P.decide, ns, d.uuid, d.action, d.value, user_uuid, settings)
        if ok then
            results[#results + 1] = { uuid = d.uuid, action = d.action, ok = true, status = res.status,
                created = res.created or cjson.null }
        else
            local msg = type(res) == "table" and res.pd_error and res.message or "failed"
            if not (type(res) == "table" and res.pd_error) then ngx.log(ngx.ERR, "[property_pa] decide: ", tostring(res)) end
            results[#results + 1] = { uuid = d.uuid, action = d.action, ok = false, error = msg,
                details = type(res) == "table" and res.details or cjson.null }
        end
    end
    return { results = U.array(results), sheet = C.sheet(ns, interaction_uuid) }
end

return C
