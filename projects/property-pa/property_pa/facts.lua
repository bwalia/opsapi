-- Fact vs inference, and the AI change history (build prompt rules 5 + 7).
--
-- Every field the PA can write has an evidence trail in pa_field_facts: value, source (human / ai / import /
-- integration), confidence, is_inferred, model + prompt version + run, and who confirmed it. The live column on
-- the record holds the current value; the facts table keeps every value it ever had (corrections never lose
-- history, P11).
--
-- The PA never writes records directly. It proposes (pa_proposed_updates); a person confirms, corrects or
-- rejects; only then is the record written, in the same transaction as its fact row.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local F = {}

local function null(v) return v == nil or v == db.NULL end

-- What the PA may propose, per table: field -> kind. Anything else is refused (allow-list).
F.TARGETS = {
    pa_opportunities = { key = "uuid", cast = "::uuid", fields = {
        title = "text", motivation = "text", expectation_price = "money", our_position = "text",
        temperature = "enum:hot,warm,cold", decision_makers = "json", primary_concern = "text",
        status = "enum:open,won,lost,paused", last_meaningful_contact_at = "datetime" } },
    crm_contacts = { key = "uuid", cast = "", fields = {
        phone = "text", mobile = "text", email = "text", job_title = "text", preferred_channel = "text",
        person_roles = "json" } },
    property_deals_properties = { key = "uuid", cast = "::uuid", fields = {
        condition = "text", known_issues_note = "text", est_market_value = "money", bedrooms = "int",
        tenure = "text", notes = "text" } },
}
-- Pseudo-targets: confirming them creates a record instead of setting a field.
F.CREATES = { pa_events = true, next_action = true, pa_offers = true }

--- Is `field` on `table` material (always needs a person)? Settings list + offers/next actions.
function F.material(settings, table_name, field)
    if table_name == "next_action" or table_name == "pa_offers" then return true end
    local list = tostring((settings or {}).material_fields or "expectation_price,offer_amount,decision_makers,next_action_at")
    for f in list:gmatch("[^,%s]+") do
        if f == field then return true end
    end
    return false
end

local function encode(v)
    if v == nil or v == db.NULL then return db.NULL end
    return cjson.encode({ v = v })
end

local function check_value(kind, v)
    if v == nil or v == cjson.null then return true end
    if kind == "text" then return type(v) == "string" and #v <= 5000 end
    if kind == "money" then return tonumber(v) ~= nil and tonumber(v) >= 0 end
    if kind == "int" then return tonumber(v) ~= nil and tonumber(v) % 1 == 0 end
    if kind == "json" then return type(v) == "table" end
    if kind == "datetime" then return type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d") ~= nil end
    local enum = kind:match("^enum:(.+)$")
    if enum then
        for e in enum:gmatch("[^,]+") do if e == v then return true end end
        return false
    end
    return false
end

--- Validate one proposed update. @return true | nil, error
function F.validate(p)
    if F.CREATES[p.target_table] then
        if type(p.new_value) ~= "table" then return nil, p.target_table .. " needs new_value as an object" end
        return true
    end
    local t = F.TARGETS[p.target_table]
    if not t then return nil, "target_table must be one of: pa_opportunities, crm_contacts, property_deals_properties, "
        .. "pa_events, pa_offers, next_action" end
    local kind = t.fields[p.field or ""]
    if not kind then return nil, "field '" .. tostring(p.field) .. "' can't be proposed on " .. p.target_table end
    if not U.is_uuid(p.target_uuid) and not (p.target_table == "crm_contacts" and type(p.target_uuid) == "string") then
        return nil, "target_uuid is required"
    end
    if not check_value(kind, p.new_value) then return nil, "new_value is not a valid " .. kind end
    return true
end

--- Current value of a target field (namespace-checked). @return value | nil (missing) , exists
function F.current(ns, table_name, uuid, field)
    local t = F.TARGETS[table_name]
    local row = U.one("SELECT to_jsonb(x) -> ? AS v FROM " .. table_name .. " x WHERE namespace_id = ? AND "
        .. t.key .. " = ?" .. t.cast, field, ns, uuid)
    if not row then return nil, false end
    local v = row.v -- jsonb arrives decoded (pgmoon)
    if v == cjson.null then v = nil end
    return v, true
end

--- Record one fact row. `f` = { target_table, target_uuid, field, value, action, source, source_ref, confidence,
-- is_inferred, confirmed_by, model, prompt_version, run_ref }. Supersedes the previous fact for that field.
function F.record(ns, f)
    local row = db.insert("pa_field_facts", {
        namespace_id = ns, target_table = f.target_table, target_uuid = tostring(f.target_uuid), field = f.field,
        value = db.raw(db.escape_literal(encode(f.value)) .. "::jsonb"), action = f.action or "set",
        source = f.source or "human", source_ref = f.source_ref or db.NULL,
        confidence = f.confidence or db.NULL, is_inferred = f.is_inferred == true,
        confirmed_by_user_uuid = f.confirmed_by or db.NULL,
        confirmed_at = f.confirmed_by and db.raw("NOW()") or db.NULL,
        model = f.model or db.NULL, prompt_version = f.prompt_version or db.NULL, run_ref = f.run_ref or db.NULL,
    }, { returning = { "uuid" } })[1]
    db.query([[
        UPDATE pa_field_facts SET superseded_by = ?::uuid, updated_at = NOW()
        WHERE namespace_id = ? AND target_table = ? AND target_uuid = ? AND field = ? AND superseded_by IS NULL
          AND uuid <> ?::uuid
    ]], row.uuid, ns, f.target_table, tostring(f.target_uuid), f.field, row.uuid)
    return row.uuid
end

--- Write a field on a target record + its fact (one call; caller wraps in a transaction).
function F.set(ns, f)
    local t = F.TARGETS[f.target_table]
    local col = f.field
    local v = f.value
    local sql_v
    if v == nil or v == cjson.null then sql_v = "NULL"
    elseif type(v) == "table" then sql_v = db.escape_literal(cjson.encode(v)) .. "::jsonb"
    else sql_v = db.escape_literal(tostring(v)) end
    local res = db.query("UPDATE " .. f.target_table .. " SET " .. db.escape_identifier(col) .. " = " .. sql_v
        .. ", updated_at = NOW() WHERE namespace_id = ? AND " .. t.key .. " = ?" .. t.cast .. " RETURNING id",
        ns, f.target_uuid)
    if #res == 0 then U.fail(404, "The record to update was not found in this workspace") end
    return F.record(ns, f)
end

--- The fact history of one record (newest first), optionally one field.
function F.history(ns, table_name, uuid, field)
    return U.array(db.query([[
        SELECT uuid, field, value -> 'v' AS value, action, source, source_ref, confidence, is_inferred,
               confirmed_by_user_uuid, confirmed_at, model, prompt_version, run_ref, superseded_by, created_at
        FROM pa_field_facts WHERE namespace_id = ? AND target_table = ? AND target_uuid = ?
          AND (?::text IS NULL OR field = ?) ORDER BY created_at DESC, id DESC LIMIT 500
    ]], ns, table_name, tostring(uuid), field or db.NULL, field or db.NULL))
end

--- The live fact (not superseded) per field for a record: { field = { value, is_inferred, confirmed, source } }.
function F.current_facts(ns, table_name, uuid)
    local out = {}
    for _, r in ipairs(db.query([[
        SELECT field, value -> 'v' AS value, is_inferred, confirmed_by_user_uuid, source, confidence, created_at
        FROM pa_field_facts WHERE namespace_id = ? AND target_table = ? AND target_uuid = ? AND superseded_by IS NULL
    ]], ns, table_name, tostring(uuid))) do
        local v = r.value
        if v == cjson.null then v = nil end
        out[r.field] = { value = v, is_inferred = r.is_inferred, confirmed = not null(r.confirmed_by_user_uuid),
            source = r.source, confidence = r.confidence }
    end
    return out
end

F.null = null
return F
