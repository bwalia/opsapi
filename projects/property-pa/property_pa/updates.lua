-- Proposed updates: what the PA extracted from a capture, one row per field, waiting for a person.
-- confirm  -> apply new_value (or create the record), fact row with confirmed_by
-- correct  -> apply the person's value instead; the AI's value stays in the history (P11)
-- reject   -> nothing applied
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local F = require("property_pa.facts")

local P = {}

local function null(v) return v == nil or v == db.NULL end
local function enc(v) return (v == nil or v == cjson.null) and db.NULL or db.raw(db.escape_literal(cjson.encode(v)) .. "::jsonb") end
-- jsonb arrives decoded (pgmoon); only JSON null needs mapping.
local function dec(v)
    if v == cjson.null then return nil end
    return v
end

P.SELECT = [[
    SELECT uuid, capture_uuid, target_table, target_uuid, field, old_value, new_value, confidence, is_inferred, material,
           source_interaction_uuid, source_quote, status, decided_by_user_uuid, decided_at, model, prompt_version, run_ref,
           created_at
    FROM pa_proposed_updates
]]

--- Store proposals. items: [{ target_table, target_uuid?, field?, new_value, confidence?, is_inferred?, source_quote? }]
-- meta: { capture_uuid?, source_interaction_uuid?, model?, prompt_version?, run_ref? }. @return rows | nil, errors
function P.propose(ns, items, meta, settings)
    meta = meta or {}
    local errors = {}
    for i, it in ipairs(items) do
        local ok, err = F.validate(it)
        if not ok then errors[tostring(i)] = err end
        if it.confidence ~= nil and (tonumber(it.confidence) == nil or tonumber(it.confidence) < 0
            or tonumber(it.confidence) > 1) then
            errors[tostring(i)] = "confidence must be between 0 and 1"
        end
    end
    if next(errors) then return nil, errors end
    local out = {}
    U.tx(function()
        for _, it in ipairs(items) do
            local old
            if not F.CREATES[it.target_table] then
                local v, exists = F.current(ns, it.target_table, it.target_uuid, it.field)
                if not exists then U.fail(422, "Validation failed", { target_uuid = it.target_table .. " " .. tostring(it.target_uuid) .. " not found" }) end
                old = v
            end
            local field = it.field or "_create"
            local r = db.insert("pa_proposed_updates", {
                namespace_id = ns, capture_uuid = meta.capture_uuid or db.NULL, target_table = it.target_table,
                target_uuid = it.target_uuid and tostring(it.target_uuid) or db.NULL, field = field,
                old_value = enc(old), new_value = enc(it.new_value),
                confidence = it.confidence and tonumber(it.confidence) or db.NULL, is_inferred = it.is_inferred == true,
                material = F.material(settings, it.target_table, field),
                source_interaction_uuid = meta.source_interaction_uuid or db.NULL,
                source_quote = it.source_quote and tostring(it.source_quote):sub(1, 1000) or db.NULL,
                model = meta.model or db.NULL, prompt_version = meta.prompt_version or db.NULL, run_ref = meta.run_ref or db.NULL,
            }, { returning = { "uuid" } })[1]
            out[#out + 1] = r.uuid
        end
    end)
    local rows = {}
    for _, id in ipairs(out) do rows[#rows + 1] = P.get(ns, id) end
    return U.array(rows)
end

function P.get(ns, id)
    if not U.is_uuid(id) then return nil end
    local r = U.one(P.SELECT .. " WHERE namespace_id = ? AND uuid = ?", ns, id)
    if r then r.old_value, r.new_value = dec(r.old_value), dec(r.new_value) end
    return r
end

--- Create the record behind a confirmed pseudo-target. @return created { table, uuid }
local function create(ns, p, value, user, settings)
    local meta = { source = "ai", source_ref = p.source_interaction_uuid, confidence = p.confidence,
        is_inferred = p.is_inferred, confirmed_by = user, model = p.model, prompt_version = p.prompt_version,
        run_ref = p.run_ref, action = "create" }
    local function fact(tbl, uuid)
        local f = {}
        for k, v in pairs(meta) do f[k] = v end
        f.target_table, f.target_uuid, f.field, f.value = tbl, uuid, "_create", value
        F.record(ns, f)
    end
    if p.target_table == "pa_events" then
        if type(value.kind) ~= "string" or type(value.at) ~= "string" or type(value.title) ~= "string" then
            U.fail(422, "Validation failed", { new_value = "an event needs kind, at and title" })
        end
        local r = db.insert("pa_events", { namespace_id = ns, kind = value.kind, at = value.at, title = value.title:sub(1, 255),
            details = enc(value.details or {}), person_uuid = value.person_uuid or db.NULL,
            property_uuid = value.property_uuid or db.NULL, opportunity_uuid = value.opportunity_uuid or db.NULL,
            deal_uuid = value.deal_uuid or db.NULL, source_interaction_uuid = p.source_interaction_uuid or db.NULL },
            { returning = { "uuid" } })[1]
        fact("pa_events", r.uuid)
        return { table = "pa_events", uuid = r.uuid }
    elseif p.target_table == "pa_offers" then
        if not tonumber(value.amount) then U.fail(422, "Validation failed", { new_value = "an offer needs an amount" }) end
        local r = db.insert("pa_offers", { namespace_id = ns, amount = tonumber(value.amount),
            opportunity_uuid = value.opportunity_uuid or db.NULL, deal_uuid = value.deal_uuid or db.NULL,
            conditions = value.conditions or db.NULL, authority_user_uuid = user }, { returning = { "uuid" } })[1]
        fact("pa_offers", r.uuid)
        return { table = "pa_offers", uuid = r.uuid }
    elseif p.target_table == "next_action" then
        local task = require("property_pa.actions").create(ns, value, user, settings, p.source_interaction_uuid)
        fact("next_action", task.task_uuid)
        return { table = "next_action", uuid = task.task_uuid }
    end
    U.fail(422, "Unknown create target")
end

--- Decide one proposal. action = confirm | correct | reject; value used for correct. @return row
function P.decide(ns, id, action, value, user, settings)
    if not U.is_uuid(id) then U.fail(404, "Proposed update not found") end
    local created
    U.tx(function()
        -- Locked, and checked inside the transaction: two people confirming at once can't both apply it.
        local p = U.one(P.SELECT .. " WHERE namespace_id = ? AND uuid = ? FOR UPDATE", ns, id)
        if not p then U.fail(404, "Proposed update not found") end
        if p.status ~= "proposed" then U.fail(409, "Already " .. p.status) end
        p.old_value, p.new_value = dec(p.old_value), dec(p.new_value)
        if action == "correct" then
            local check = { target_table = p.target_table, target_uuid = p.target_uuid,
                field = p.field ~= "_create" and p.field or nil, new_value = value }
            local ok, err = F.validate(check)
            if not ok then U.fail(422, "Validation failed", { value = err }) end
        end
        if action ~= "reject" then
            local v = action == "correct" and value or p.new_value
            if F.CREATES[p.target_table] then
                created = create(ns, p, v, user, settings)
            else
                if action == "correct" then
                    -- Keep what the AI proposed in the history, then the person's correction on top.
                    F.record(ns, { target_table = p.target_table, target_uuid = p.target_uuid, field = p.field,
                        value = p.new_value, action = "set", source = "ai", source_ref = p.source_interaction_uuid,
                        confidence = p.confidence, is_inferred = p.is_inferred, model = p.model,
                        prompt_version = p.prompt_version, run_ref = p.run_ref })
                end
                F.set(ns, { target_table = p.target_table, target_uuid = p.target_uuid, field = p.field, value = v,
                    action = action == "correct" and "correct" or "set",
                    source = action == "correct" and "human" or "ai", source_ref = p.source_interaction_uuid,
                    confidence = action == "correct" and 1 or p.confidence,
                    is_inferred = action ~= "correct" and p.is_inferred or false,
                    confirmed_by = user, model = action ~= "correct" and p.model or nil,
                    prompt_version = action ~= "correct" and p.prompt_version or nil,
                    run_ref = action ~= "correct" and p.run_ref or nil })
            end
        end
        db.update("pa_proposed_updates", {
            status = ({ confirm = "confirmed", correct = "corrected", reject = "rejected" })[action],
            new_value = action == "correct" and enc(value) or nil, decided_by_user_uuid = user,
            decided_at = db.raw("NOW()"), updated_at = db.raw("NOW()"),
        }, { namespace_id = ns, uuid = id })
    end)
    local row = P.get(ns, id)
    row.created = created
    return row
end

function P.list(ns, params)
    local where = { "namespace_id = " .. db.escape_literal(ns) }
    if params.status and params.status:match("^[a-z,]+$") then
        local ins = {}
        for s in params.status:gmatch("[^,]+") do ins[#ins + 1] = db.escape_literal(s) end
        where[#where + 1] = "status IN (" .. table.concat(ins, ",") .. ")"
    end
    if U.is_uuid(params.capture_uuid) then where[#where + 1] = "capture_uuid = " .. db.escape_literal(params.capture_uuid) end
    if params.target_uuid and params.target_uuid ~= "" then
        where[#where + 1] = "target_uuid = " .. db.escape_literal(params.target_uuid)
    end
    local rows = db.query(P.SELECT .. " WHERE " .. table.concat(where, " AND ") .. " ORDER BY created_at DESC, id LIMIT 200")
    for _, r in ipairs(rows) do r.old_value, r.new_value = dec(r.old_value), dec(r.new_value) end
    return U.array(rows)
end

P.null = null
return P
