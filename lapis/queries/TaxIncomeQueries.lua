--[[
    My Income queries — definition-driven income types + the user's records.

    Tables
      income_types                       catalogue (system rows: namespace_id NULL/0;
                                         a namespace's own types: namespace_id = ns,
                                         key "ns<id>_<slug>")
      income_type_namespace_overrides    per-namespace edits of a SYSTEM type
      user_profile_entities              the user's properties / jobs / businesses
                                         (shared with diy-tax-return-uk's hubs)
      tax_income_records                 one row per (namespace, user, tax year, type,
                                         entity?) holding the figures as JSONB
                                         (column `figures`, returned as `values`)

    Every user read/write is scoped by namespace_id AND user_id. Pure rules
    (validation, override merge, status, estimator mapping) live in lib/income-types.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local IncomeTypes = require("lib.income-types")

local Q = {}

local JSON_COLS = { "field_schema", "estimator_mapping", "required_documents", "hmrc_mapping",
    "category_affinity", "keyword_rules", "figures", "value_sources" }

local function decode_row(row)
    if not row then return row end
    for _, c in ipairs(JSON_COLS) do
        if type(row[c]) == "string" then
            local ok, v = pcall(cjson.decode, row[c])
            if ok then row[c] = v end
        end
    end
    -- tax_income_records.figures is exposed as `values` (VALUES is reserved in SQL).
    if row.figures ~= nil then row.values = row.figures; row.figures = nil end
    return row
end
local function decode_rows(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do out[#out + 1] = decode_row(r) end
    return out
end
Q.decode_row = decode_row

-- JSONB literal; empty tables as [] or {} by intent (cjson can't tell).
local function jsonb(v, as_array)
    if v == nil or (type(v) == "table" and next(v) == nil) then return as_array and "[]" or "{}" end
    return cjson.encode(v)
end
Q.jsonb = jsonb

local function uuid()
    return require("helper.global").generateUUID()
end

local function is_empty_schema(s)
    return type(s) ~= "table" or type(s.sections) ~= "table" or #s.sections == 0
end

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------

--- Resolved income types a namespace sees (system + its own + its overrides).
-- opts.include_inactive for the admin list.
function Q.types_for(namespace_id, opts)
    local rows = db.query([[
        SELECT * FROM income_types
        WHERE COALESCE(namespace_id, 0) = 0 OR namespace_id = ?
    ]], namespace_id)
    local overrides = db.query("SELECT * FROM income_type_namespace_overrides WHERE namespace_id = ?",
        namespace_id)
    local resolved = IncomeTypes.resolve(decode_rows(rows), decode_rows(overrides), namespace_id, opts)
    for _, t in ipairs(resolved) do
        if type(t.field_schema) ~= "table" then t.field_schema = { sections = {} } end
        if type(t.field_schema.sections) ~= "table" then t.field_schema.sections = {} end
        if type(t.estimator_mapping) ~= "table" then t.estimator_mapping = {} end
        t.has_form = not is_empty_schema(t.field_schema)
    end
    return resolved
end

function Q.type_for(namespace_id, key, opts)
    for _, t in ipairs(Q.types_for(namespace_id, opts)) do
        if t.income_type_key == key then return t end
    end
    return nil
end

function Q.by_key(list)
    local m = {}
    for _, t in ipairs(list or {}) do m[t.income_type_key] = t end
    return m
end

--- Set of active catalogue keys a namespace can use (agent validation).
function Q.active_key_set(namespace_id)
    local set = {}
    for _, t in ipairs(Q.types_for(namespace_id)) do set[t.income_type_key] = true end
    return set
end

-- ---------------------------------------------------------------------------
-- Entities (user_profile_entities — shared with the diy hubs)
-- ---------------------------------------------------------------------------

function Q.entities(namespace_id, user_id, entity_type)
    return db.query([[
        SELECT uuid, entity_type, label, metadata_json, display_order, created_at, updated_at
        FROM user_profile_entities
        WHERE namespace_id = ? AND user_id = ? AND entity_type = ? AND is_archived = false
        ORDER BY display_order ASC, created_at ASC, id ASC
    ]], namespace_id, user_id, entity_type)
end

function Q.entities_by_type(namespace_id, user_id)
    local rows = db.query([[
        SELECT uuid, entity_type, label FROM user_profile_entities
        WHERE namespace_id = ? AND user_id = ? AND is_archived = false
        ORDER BY display_order ASC, created_at ASC, id ASC
    ]], namespace_id, user_id)
    local out = {}
    for _, r in ipairs(rows or {}) do
        out[r.entity_type] = out[r.entity_type] or {}
        table.insert(out[r.entity_type], r)
    end
    return out
end

function Q.entity(namespace_id, user_id, entity_uuid)
    return db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND namespace_id = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], tostring(entity_uuid or ""), namespace_id, user_id)[1]
end

function Q.create_entity(namespace_id, user_id, user_uuid, entity_type, label)
    local id = uuid()
    local next_order = db.query([[
        SELECT COALESCE(MAX(display_order), 0) + 1 AS n FROM user_profile_entities
        WHERE namespace_id = ? AND user_id = ? AND entity_type = ?
    ]], namespace_id, user_id, entity_type)[1]
    db.query([[
        INSERT INTO user_profile_entities
            (uuid, user_id, user_uuid, namespace_id, entity_type, label, metadata_json,
             display_order, is_archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, '{}', ?, false, NOW(), NOW())
    ]], id, user_id, tostring(user_uuid), namespace_id, entity_type, label,
        tonumber(next_order and next_order.n) or 1)
    return Q.entity(namespace_id, user_id, id)
end

function Q.rename_entity(namespace_id, user_id, entity_uuid, label)
    db.query([[
        UPDATE user_profile_entities SET label = ?, updated_at = NOW()
        WHERE uuid = ? AND namespace_id = ? AND user_id = ? AND is_archived = false
    ]], label, entity_uuid, namespace_id, user_id)
    return Q.entity(namespace_id, user_id, entity_uuid)
end

-- Soft delete: historical records keep a resolvable parent (diy reports read them too).
function Q.archive_entity(namespace_id, user_id, entity_uuid)
    local res = db.query([[
        UPDATE user_profile_entities SET is_archived = true, archived_at = NOW(), updated_at = NOW()
        WHERE uuid = ? AND namespace_id = ? AND user_id = ? AND is_archived = false
    ]], entity_uuid, namespace_id, user_id)
    return (res and res.affected_rows or 0) > 0
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

function Q.records(namespace_id, user_id, tax_year, income_type_key)
    local rows
    if income_type_key then
        rows = db.query([[
            SELECT * FROM tax_income_records
            WHERE namespace_id = ? AND user_id = ? AND tax_year = ? AND income_type_key = ?
        ]], namespace_id, user_id, tax_year, income_type_key)
    else
        rows = db.query([[
            SELECT * FROM tax_income_records
            WHERE namespace_id = ? AND user_id = ? AND tax_year = ?
        ]], namespace_id, user_id, tax_year)
    end
    return decode_rows(rows)
end

--- Insert or update the one record for (ns, user, year, type, entity?).
function Q.upsert_record(namespace_id, user_id, tax_year, key, entity_uuid, values, sources, status)
    local rows = db.query([[
        INSERT INTO tax_income_records
            (uuid, namespace_id, user_id, tax_year, income_type_key, entity_uuid,
             figures, value_sources, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?, NOW(), NOW())
        ON CONFLICT (namespace_id, user_id, tax_year, income_type_key, (COALESCE(entity_uuid, '')))
        DO UPDATE SET figures = EXCLUDED.figures, value_sources = EXCLUDED.value_sources,
                      status = EXCLUDED.status, updated_at = NOW()
        RETURNING *
    ]], uuid(), namespace_id, user_id, tax_year, key, entity_uuid or db.NULL,
        jsonb(values, false), jsonb(sources, false), status)
    return decode_row(rows and rows[1])
end

--- "I don't have this income this year" (on) / undo (off). Only for the year-level
-- record (entity NULL); entity records are untouched.
function Q.set_not_applicable(namespace_id, user_id, tax_year, key, on)
    if on then
        return Q.upsert_record(namespace_id, user_id, tax_year, key, nil, {}, {}, "not_applicable")
    end
    db.query([[
        DELETE FROM tax_income_records
        WHERE namespace_id = ? AND user_id = ? AND tax_year = ? AND income_type_key = ?
          AND entity_uuid IS NULL AND status = 'not_applicable'
    ]], namespace_id, user_id, tax_year, key)
    return true
end

-- ---------------------------------------------------------------------------
-- Bank-statement suggestions (pre-fill)
-- ---------------------------------------------------------------------------

--- For each field with a prefill rule: the year's total of the user's classified
-- transactions in those categories. Same year rule as the estimate (the year
-- stamped on the statement). Returns { field_key = { amount, count, categories } }.
function Q.statement_suggestions(user_id, tax_year, schema)
    local out = {}
    for _, f in ipairs(IncomeTypes.fields(schema)) do
        local p = f.prefill
        if type(p) == "table" and type(p.categories) == "table" and #p.categories > 0 then
            -- category keys are admin-entered: escaped as literals, never concatenated raw
            local literals = {}
            for i, c in ipairs(p.categories) do literals[i] = db.escape_literal(tostring(c)) end
            local row = db.query([[
                SELECT COALESCE(SUM(t.amount), 0) AS amount, COUNT(*) AS n
                FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
                WHERE t.user_id = ? AND s.tax_year = ? AND t.transaction_type = ?
                  AND t.category IN (]] .. table.concat(literals, ",") .. ")",
                user_id, tax_year, p.direction == "debit" and "DEBIT" or "CREDIT")[1] or {}
            local n = tonumber(row.n) or 0
            if n > 0 then
                out[f.key] = { amount = math.floor((tonumber(row.amount) or 0) * 100 + 0.5) / 100,
                    count = n, categories = p.categories }
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Estimator
-- ---------------------------------------------------------------------------

--- The user's My Income figures as compute_full inputs for a year. Without a
-- namespace (legacy, non-namespaced report routes) the records of the user's most
-- recently edited namespace for that year are used — never summed across
-- namespaces, so nothing is counted twice.
function Q.estimator_inputs(user_id, tax_year, namespace_id)
    if not namespace_id then
        local r = db.query([[
            SELECT namespace_id FROM tax_income_records WHERE user_id = ? AND tax_year = ?
            ORDER BY updated_at DESC LIMIT 1
        ]], user_id, tax_year)
        namespace_id = r and r[1] and r[1].namespace_id
        if not namespace_id then return IncomeTypes.estimator_inputs({}, {}) end
    end
    -- include hidden types: hiding a type stops new entries, it doesn't drop figures
    -- the user already gave from their tax
    local types = Q.by_key(Q.types_for(namespace_id, { include_inactive = true }))
    return IncomeTypes.estimator_inputs(types, Q.records(namespace_id, user_id, tax_year))
end

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

--- Records per key in a namespace (how many people/years use a type).
function Q.usage_counts(namespace_id)
    local out = {}
    for _, r in ipairs(db.query([[
        SELECT income_type_key, COUNT(*)::int AS n FROM tax_income_records
        WHERE namespace_id = ? AND status <> 'not_applicable' GROUP BY income_type_key
    ]], namespace_id) or {}) do
        out[r.income_type_key] = tonumber(r.n) or 0
    end
    return out
end

local CATALOGUE_TEXT = { "display_name", "description", "help_text", "icon", "estimate_note",
    "entity_type", "entity_label", "linked_form_title", "linked_form_description", "linked_form_weblink" }

--- Create a namespace's own income type. body already validated by the route.
function Q.create_custom(namespace_id, body)
    local key = IncomeTypes.custom_key(namespace_id, body.key)
    if db.query("SELECT 1 FROM income_types WHERE income_type_key = ? LIMIT 1", key)[1] then
        return nil, "You already have an income type with that key.", 409
    end
    local order = tonumber(body.display_order)
    if not order then
        local m = db.query([[SELECT COALESCE(MAX(display_order), 0) + 10 AS n FROM income_types
            WHERE COALESCE(namespace_id, 0) = 0 OR namespace_id = ?]], namespace_id)[1]
        order = tonumber(m and m.n) or 100
    end
    db.query([[
        INSERT INTO income_types
            (uuid, income_type_key, display_name, description, required_documents, allows_manual_entry,
             keyword_rules, category_affinity, rules_markdown, hmrc_mapping, display_order, is_active,
             namespace_id, linked_form_title, linked_form_description, linked_form_weblink,
             icon, help_text, entity_type, entity_label, field_schema, estimator_mapping, estimate_note,
             created_at, updated_at)
        VALUES (?, ?, ?, ?, '[]'::jsonb, true, '[]'::jsonb, '{}'::jsonb, NULL, '{}'::jsonb, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?, NOW(), NOW())
    ]], uuid(), key, body.display_name, body.description or db.NULL, order, body.is_active ~= false,
        namespace_id,
        body.linked_form_title or db.NULL, body.linked_form_description or db.NULL,
        body.linked_form_weblink or db.NULL,
        body.icon or db.NULL, body.help_text or db.NULL,
        body.entity_type or db.NULL, body.entity_label or db.NULL,
        jsonb(body.field_schema, false), jsonb(body.estimator_mapping, true), body.estimate_note or db.NULL)
    return Q.type_for(namespace_id, key, { include_inactive = true })
end

--- Update a type as seen by a namespace:
--   custom type of this namespace → the row itself;
--   system type + scope "global" (platform admin only — the route checks) → the row;
--   system type otherwise → the namespace's override row (created on first edit).
function Q.update_type(namespace_id, key, body, scope)
    local raw = db.query([[SELECT * FROM income_types WHERE income_type_key = ?
        AND (COALESCE(namespace_id, 0) = 0 OR namespace_id = ?) LIMIT 1]], key, namespace_id)[1]
    if not raw then return nil, "Income type not found", 404 end
    local is_system = (tonumber(raw.namespace_id) or 0) == 0

    if not is_system or scope == "global" then
        local sets = {}
        local function add(col, val, kind)
            if val == nil then return end
            if type(val) == "userdata" then
                sets[#sets + 1] = db.escape_identifier(col) .. " = NULL"
            elseif kind then
                sets[#sets + 1] = db.escape_identifier(col) .. " = "
                    .. db.interpolate_query("?::jsonb", jsonb(val, kind == "array"))
            else
                sets[#sets + 1] = db.escape_identifier(col) .. " = " .. db.interpolate_query("?", val)
            end
        end
        for _, c in ipairs(CATALOGUE_TEXT) do add(c, body[c]) end
        add("field_schema", body.field_schema, "object")
        add("estimator_mapping", body.estimator_mapping, "array")
        if body.display_order ~= nil then add("display_order", tonumber(body.display_order) or 0) end
        if body.is_active ~= nil then add("is_active", body.is_active == true) end
        if #sets > 0 then
            sets[#sets + 1] = "updated_at = NOW()"
            db.query("UPDATE income_types SET " .. table.concat(sets, ", ") .. " WHERE id = ?", raw.id)
        end
        return Q.type_for(namespace_id, key, { include_inactive = true })
    end

    -- Namespace override of a system type: only the overridable columns.
    local existing = db.query([[SELECT id FROM income_type_namespace_overrides
        WHERE namespace_id = ? AND income_type_id = ?]], namespace_id, raw.id)[1]
    if not existing then
        db.query([[INSERT INTO income_type_namespace_overrides (namespace_id, income_type_id, created_at, updated_at)
            VALUES (?, ?, NOW(), NOW()) ON CONFLICT (namespace_id, income_type_id) DO NOTHING]],
            namespace_id, raw.id)
    end
    local sets = {}
    for _, col in ipairs(IncomeTypes.OVERRIDABLE) do
        local v = body[col]
        if v ~= nil then
            if type(v) == "userdata" then
                sets[#sets + 1] = db.escape_identifier(col) .. " = NULL" -- back to the default
            elseif col == "field_schema" then
                sets[#sets + 1] = "field_schema = " .. db.interpolate_query("?::jsonb", jsonb(v, false))
            elseif col == "estimator_mapping" then
                sets[#sets + 1] = "estimator_mapping = " .. db.interpolate_query("?::jsonb", jsonb(v, true))
            elseif col == "is_active" then
                sets[#sets + 1] = "is_active = " .. db.interpolate_query("?", v == true)
            elseif col == "display_order" then
                sets[#sets + 1] = "display_order = " .. db.interpolate_query("?", tonumber(v) or 0)
            else
                sets[#sets + 1] = db.escape_identifier(col) .. " = " .. db.interpolate_query("?", v)
            end
        end
    end
    if #sets > 0 then
        sets[#sets + 1] = "updated_at = NOW()"
        db.query("UPDATE income_type_namespace_overrides SET " .. table.concat(sets, ", ")
            .. " WHERE namespace_id = ? AND income_type_id = ?", namespace_id, raw.id)
    end
    return Q.type_for(namespace_id, key, { include_inactive = true })
end

--- Drop a namespace's override of a system type (back to the platform default).
function Q.reset_override(namespace_id, key)
    local raw = db.query([[SELECT id FROM income_types WHERE income_type_key = ?
        AND COALESCE(namespace_id, 0) = 0 LIMIT 1]], key)[1]
    if not raw then return nil, "Only a built-in income type can be reset.", 400 end
    db.query("DELETE FROM income_type_namespace_overrides WHERE namespace_id = ? AND income_type_id = ?",
        namespace_id, raw.id)
    return Q.type_for(namespace_id, key, { include_inactive = true })
end

--- Persist a new order: keys in display order → display_order 10, 20, 30…
-- (custom rows directly, system rows through the namespace's overrides).
function Q.reorder(namespace_id, keys)
    for i, key in ipairs(keys) do
        Q.update_type(namespace_id, key, { display_order = i * 10 })
    end
    return Q.types_for(namespace_id, { include_inactive = true })
end

return Q
