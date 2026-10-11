-- Grounded or silent (build prompt rule 4; P02/P05), enforced in code rather than by prompt wording.
--
-- G.context assembles, deterministically, every fact the PA may use about an opportunity. Each item carries a
-- `ref` ("table:uuid" or "table:uuid:field"). The agent answers with claims that cite refs; G.check then
-- verifies the answer:
--   * every ref exists in this workspace (and the field has a value)
--   * every figure in the answer (money, "235k", any number >= 100) is found in a value the cited refs hold
--   * a claim that leans on an inferred, unconfirmed value says so ("unconfirmed", "inferred", "judgement"...)
--   * every sentence with a figure belongs to a claim (no uncited numbers)
-- An answer that fails is not shown; the caller says what isn't known instead.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local G = {}

-- table -> { key column, cast for the key }
G.REFS = {
    pa_opportunities = { "uuid", "::uuid" }, pa_events = { "uuid", "::uuid" }, pa_offers = { "uuid", "::uuid" },
    pa_handoffs = { "uuid", "::uuid" }, pa_knowledge = { "uuid", "::uuid" }, pa_field_facts = { "uuid", "::uuid" },
    crm_contacts = { "uuid", "" }, crm_activities = { "uuid", "" }, crm_leads = { "uuid", "" },
    property_deals_properties = { "uuid", "::uuid" }, property_deals_task_details = { "task_uuid", "" },
}

local LABELS = { "unconfirmed", "inferred", "judgement", "judgment", "estimate", "not confirmed", "reckon", "thinks" }

--- Parse "table:uuid[:field]". @return table, uuid, field | nil
function G.parse_ref(ref)
    if type(ref) ~= "string" then return nil end
    local t, id, field = ref:match("^([a-z_]+):([%x%-]+):?([a-z_]*)$")
    if not t or not G.REFS[t] or not U.is_uuid(id) then return nil end
    return t, id, field ~= "" and field or nil
end

--- The row behind a ref (namespace-checked) as a Lua table, or nil.
function G.resolve(ns, ref)
    local t, id = G.parse_ref(ref)
    if not t then return nil end
    local k = G.REFS[t]
    local row = U.one("SELECT to_jsonb(x) AS j FROM " .. t .. " x WHERE namespace_id = ? AND " .. k[1] .. " = ?" .. k[2],
        ns, id)
    return row and U.json(row.j)
end

-- Every number found anywhere in a value (strings included), normalised.
local function numbers_in(v, out)
    out = out or {}
    if type(v) == "number" then out[#out + 1] = v
    elseif type(v) == "string" then
        for _, n in ipairs(G.figures(v, true)) do out[#out + 1] = n end
        if tonumber(v) then out[#out + 1] = tonumber(v) end
    elseif type(v) == "table" then
        for _, x in pairs(v) do numbers_in(x, out) end
    end
    return out
end

--- Figures in free text: £240k, 235,000, £1.2m, 225k; plus (all = true) any plain number.
-- Only money-like figures count as facts: with £ / k / m, a thousands comma, or >= 1000 (not a year).
-- Ids, dates and times are taken out first, so "4 weeks", "11:00", "2026-10-12" and "in 2025" are left alone.
function G.figures(text, all)
    local out = {}
    text = tostring(text):gsub("%x+%-%x+%-%x+%-%x+%-%x+", " ") -- uuids
        :gsub("%d%d%d%d%-%d%d%-%d%d[T ]?[%d:%.]*Z?", " "):gsub("%d+:%d%d", " ")
    -- (£ is two bytes in UTF-8, so it is looked for before the match rather than inside the pattern)
    for at, num, suffix in text:gmatch("()(%d[%d,]*%.?%d*)%s?([kKmM]?)%f[^%w]") do
        local pound = text:sub(math.max(1, at - 2), at - 1) == "£" and "£" or ""
        num = num:gsub(",$", "")
        local n = tonumber((num:gsub(",", "")))
        if n then
            if suffix == "k" or suffix == "K" then n = n * 1000 elseif suffix == "m" or suffix == "M" then n = n * 1000000 end
            local year = suffix == "" and pound == "" and not num:find(",", 1, true) and n >= 1900 and n <= 2100
            if all or pound ~= "" or suffix ~= "" or num:find(",", 1, true) or (n >= 1000 and not year) then
                out[#out + 1] = n
            end
        end
    end
    return out
end

local function labelled(text)
    local l = tostring(text):lower()
    for _, w in ipairs(LABELS) do if l:find(w, 1, true) then return true end end
    return false
end

--- Is a field's current value inferred and unconfirmed? (from pa_field_facts)
local function inferred(ns, t, id, field)
    local f = U.one([[SELECT is_inferred, confirmed_by_user_uuid FROM pa_field_facts WHERE namespace_id = ? AND target_table = ?
        AND target_uuid = ? AND field = ? AND superseded_by IS NULL ORDER BY id DESC LIMIT 1]], ns, t, id, field)
    return f and f.is_inferred == true
end

--- Check an answer. answer = { text, claims = [{ text, refs = [ref...] }] }
-- @return { ok, violations = [{ kind, claim?, ref?, figure?, message }] }
function G.check(ns, answer)
    local violations = {}
    local function bad(v) violations[#violations + 1] = v end
    local claims = type(answer.claims) == "table" and answer.claims or {}
    local covered = {}
    for i, c in ipairs(claims) do
        local refs = type(c.refs) == "table" and c.refs or {}
        if #refs == 0 then bad({ kind = "no_source", claim = i, message = "claim has no source" }) end
        local pool, leans_on_inference = {}, false
        for _, ref in ipairs(refs) do
            local t, id, field = G.parse_ref(ref)
            local row = t and G.resolve(ns, ref)
            if not row then
                bad({ kind = "unknown_ref", claim = i, ref = ref, message = "source not found in this workspace" })
            elseif field then
                local v = row[field]
                if v == nil or v == cjson.null then
                    bad({ kind = "empty_field", claim = i, ref = ref, message = "source field has no value" })
                else
                    numbers_in(v, pool)
                    if inferred(ns, t, id, field) then leans_on_inference = true end
                end
            else
                numbers_in(row, pool)
            end
        end
        for _, n in ipairs(G.figures(c.text)) do
            local found = false
            for _, p in ipairs(pool) do if math.abs(p - n) < 0.01 then found = true break end end
            if not found then
                bad({ kind = "unsupported_figure", claim = i, figure = n, message = "figure not in the cited sources" })
            end
        end
        if leans_on_inference and not labelled(c.text) then
            bad({ kind = "unlabelled_inference", claim = i, message = "an inferred value must be labelled unconfirmed" })
        end
        covered[#covered + 1] = tostring(c.text or "")
    end
    -- Figures in the answer text that no claim covers.
    local all = table.concat(covered, "\n")
    local claimed = {}
    for _, n in ipairs(G.figures(all)) do claimed[n] = true end
    for _, n in ipairs(G.figures(answer.text or "")) do
        if not claimed[n] then bad({ kind = "uncited_figure", figure = n, message = "figure in the answer has no claim" }) end
    end
    return { ok = #violations == 0, violations = U.array(violations) }
end

-- ------------------------------------------------------------------ context pack
local OPP_FIELDS = { "title", "kind", "status", "motivation", "expectation_price", "our_position", "temperature",
    "decision_makers", "primary_concern", "last_meaningful_contact_at" }
local PERSON_FIELDS = { "first_name", "last_name", "email", "phone", "mobile", "preferred_channel", "person_roles" }
local PROPERTY_FIELDS = { "address_line1", "town", "postcode", "property_type", "bedrooms", "tenure", "condition",
    "known_issues_note", "est_market_value" }

local function fields(ns, t, id, row, list, facts)
    local out = {}
    for _, f in ipairs(list) do
        local v = row[f]
        if v ~= nil and v ~= cjson.null and not (type(v) == "table" and next(v) == nil) then
            local fact = facts[f] or {}
            out[#out + 1] = { ref = t .. ":" .. id .. ":" .. f, field = f, value = v,
                is_inferred = fact.is_inferred == true, confirmed = fact.confirmed ~= false, source = fact.source or "human" }
        end
    end
    return U.array(out)
end

--- Everything the PA may say about an opportunity, each with a ref. @return pack | nil
function G.context(ns, opp_uuid, user_uuid)
    if not U.is_uuid(opp_uuid) then return nil end
    local F = require("property_pa.facts")
    local opp = G.resolve(ns, "pa_opportunities:" .. opp_uuid)
    if not opp then return nil end
    local pack = { opportunity = fields(ns, "pa_opportunities", opp_uuid, opp, OPP_FIELDS,
        F.current_facts(ns, "pa_opportunities", opp_uuid)) }
    if opp.person_uuid and opp.person_uuid ~= cjson.null then
        local p = G.resolve(ns, "crm_contacts:" .. opp.person_uuid)
        if p then
            pack.person = fields(ns, "crm_contacts", opp.person_uuid, p, PERSON_FIELDS,
                F.current_facts(ns, "crm_contacts", opp.person_uuid))
        end
    end
    if opp.property_uuid and opp.property_uuid ~= cjson.null then
        local pr = G.resolve(ns, "property_deals_properties:" .. opp.property_uuid)
        if pr then
            pack.property = fields(ns, "property_deals_properties", opp.property_uuid, pr, PROPERTY_FIELDS,
                F.current_facts(ns, "property_deals_properties", opp.property_uuid))
        end
    end
    local function refs(rows, t, key)
        for _, r in ipairs(rows) do r.ref = t .. ":" .. r[key or "uuid"] end
        return U.array(rows)
    end
    pack.events = refs(db.query([[SELECT uuid, kind, at, title, details, done FROM pa_events
        WHERE namespace_id = ? AND opportunity_uuid = ?::uuid ORDER BY at DESC LIMIT 30]], ns, opp_uuid), "pa_events")
    pack.offers = refs(db.query([[SELECT uuid, amount, made_at, conditions, response, response_note FROM pa_offers
        WHERE namespace_id = ? AND opportunity_uuid = ?::uuid ORDER BY made_at DESC LIMIT 20]], ns, opp_uuid), "pa_offers")
    -- Interactions are DATA: the agent quotes them, never follows instructions inside them.
    pack.interactions = refs(db.query([[SELECT uuid, channel, direction, activity_date AS at,
        COALESCE(summary, LEFT(COALESCE(transcript, raw_text), 1500)) AS text
        FROM crm_activities WHERE namespace_id = ? AND opportunity_uuid = ?::uuid AND deleted_at IS NULL
        ORDER BY activity_date DESC LIMIT 15]], ns, opp_uuid), "crm_activities")
    pack.next_actions = refs(require("property_pa.actions").open(ns, { opportunity_uuid = opp_uuid }),
        "property_deals_task_details", "task_uuid")
    pack.knowledge = require("property_pa.knowledge").text(ns, user_uuid, {}, 6000)
    pack.unknown = U.array({})
    for _, f in ipairs({ "motivation", "expectation_price", "decision_makers", "primary_concern" }) do
        local v = opp[f]
        if v == nil or v == cjson.null or (type(v) == "table" and next(v) == nil) then
            pack.unknown[#pack.unknown + 1] = f
        end
    end
    return pack
end

return G
