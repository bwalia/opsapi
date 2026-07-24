--[[
    Income Type Queries

    Read + admin-CRUD on the income_types catalogue (migrations/income-types-system.lua).
    The catalogue is the single source of truth for:
      - the My Income dropdown + create/update validation (routes/my-incomes.lua)
      - the admin catalogue manager (routes/tax-admin-income-types.lua)
      - FastAPI's IncomeTypeLoader (backend/app/services/income_type_loader.py)

    Mirrors the classification_profiles admin pattern (raw db.query, JSONB rule
    columns) — see routes/tax-admin-profiles.lua. No in-process cache: the read
    paths here (dropdown, validation) are low-frequency; the per-classification
    hot path lives on the FastAPI side which has its own TTL cache.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local IncomeTypeQueries = {}

-- JSONB columns are returned by pgmoon as raw strings; decode them so API
-- consumers get real arrays/objects (matches what FastAPI's SQLModel sees).
local JSON_COLS = { "required_documents", "keyword_rules", "category_affinity", "hmrc_mapping" }
local function decode_row(row)
    if not row then return row end
    for _, c in ipairs(JSON_COLS) do
        if type(row[c]) == "string" then
            local ok, v = pcall(cjson.decode, row[c])
            if ok then row[c] = v end
        end
    end
    return row
end

local function decode_rows(rows)
    for _, r in ipairs(rows or {}) do decode_row(r) end
    return rows or {}
end

-- Encode a Lua value for a JSONB column, forcing the right empty literal
-- ("[]" for arrays, "{}" for objects) since cjson can't tell them apart.
local function enc_json(v, is_array)
    if v == nil or (type(v) == "table" and next(v) == nil) then
        return is_array and "[]" or "{}"
    end
    return cjson.encode(v)
end

-- Count of non-archived my_incomes rows referencing a catalogue key. Used to
-- warn admins before they disable a type — disabling is non-destructive (the
-- key stays on historical rows), so this is advisory, not a hard block.
local function usage_count(income_type_key)
    local rows = db.query([[
        SELECT COUNT(*)::int AS n FROM my_incomes
        WHERE income_type = ? AND is_archived = false
    ]], income_type_key)
    return (rows and rows[1] and rows[1].n) or 0
end

-- ── Catalogue reads (consumed by routes/my-incomes.lua) ──────────────────────

-- Active types ordered for the dropdown.
function IncomeTypeQueries.list_active()
    local rows = db.query([[
        SELECT * FROM income_types
        WHERE is_active = true
        ORDER BY display_order ASC, display_name ASC
    ]])
    return decode_rows(rows)
end

-- Set of active keys for O(1) validation: { salary = true, ... }
function IncomeTypeQueries.active_keys()
    local rows = db.query("SELECT income_type_key FROM income_types WHERE is_active = true")
    local set = {}
    for _, r in ipairs(rows or {}) do set[r.income_type_key] = true end
    return set
end

-- Active keys that may be WRITTEN as my_incomes rows. Catalogue rows with
-- allows_manual_entry = false (e.g. 'pension_payments' — a RELIEF whose
-- amounts must never be summed as income) stay selectable in the profile
-- questionnaire and visible in /types, but my-incomes create/type-change
-- validates against THIS set.
function IncomeTypeQueries.manual_entry_keys()
    local rows = db.query(
        "SELECT income_type_key FROM income_types WHERE is_active = true AND allows_manual_entry = true")
    local set = {}
    for _, r in ipairs(rows or {}) do set[r.income_type_key] = true end
    return set
end

-- ── Admin CRUD (consumed by routes/tax-admin-income-types.lua) ───────────────

-- params: { include_inactive? = "false" }. Each row carries usage_count.
function IncomeTypeQueries.admin_list(params)
    params = params or {}
    local where = ""
    if params.include_inactive ~= "true" and params.include_inactive ~= true then
        where = "WHERE is_active = true"
    end
    local rows = db.query([[
        SELECT it.*,
            (SELECT COUNT(*)::int FROM my_incomes
             WHERE income_type = it.income_type_key AND is_archived = false) AS usage_count
        FROM income_types it ]] .. where .. [[
        ORDER BY it.display_order ASC, it.display_name ASC
    ]])
    local data = decode_rows(rows)
    -- Force [] (not {}) when empty so the admin page's `data.filter/.sort`
    -- doesn't blow up on an all-inactive / empty catalogue.
    return { data = #data > 0 and data or cjson.empty_array, total = #data }
end

function IncomeTypeQueries.show(uuid)
    local rows = db.query("SELECT * FROM income_types WHERE uuid = ? LIMIT 1", uuid)
    if not rows or #rows == 0 then return nil end
    local row = decode_row(rows[1])
    row.usage_count = usage_count(row.income_type_key)
    return row
end

-- Returns (row, err, status). 409 on duplicate key, 400 on missing fields.
function IncomeTypeQueries.create(body)
    if not body.income_type_key or body.income_type_key == ""
        or not body.display_name or body.display_name == "" then
        return nil, "income_type_key and display_name are required", 400
    end

    local existing = db.query("SELECT id FROM income_types WHERE income_type_key = ?", body.income_type_key)
    if existing and #existing > 0 then
        return nil, "Income type key already exists", 409
    end

    local uuid = Global.generateUUID()
    -- linked_form_* columns are admin-configurable metadata pointing at
    -- the HMRC reference form for this income type (SA100/SA110/SA108/
    -- etc). All three optional — nil coerces to db.NULL. Rendered by
    -- the frontend as a small reference card on /my-income/[type].
    db.query([[
        INSERT INTO income_types
            (uuid, income_type_key, display_name, description,
             required_documents, allows_manual_entry,
             keyword_rules, category_affinity, rules_markdown,
             hmrc_mapping, display_order, is_active, namespace_id,
             linked_form_title, linked_form_description, linked_form_weblink,
             created_at, updated_at)
        VALUES (?, ?, ?, ?, ?::jsonb, ?, ?::jsonb, ?::jsonb, ?, ?::jsonb, ?, ?, ?, ?, ?, ?, NOW(), NOW())
    ]],
        uuid,
        body.income_type_key,
        body.display_name,
        body.description or db.NULL,
        enc_json(body.required_documents, true),
        body.allows_manual_entry ~= false,          -- default true
        enc_json(body.keyword_rules, true),
        enc_json(body.category_affinity, false),
        body.rules_markdown or db.NULL,
        enc_json(body.hmrc_mapping, false),
        body.display_order or 100,
        body.is_active ~= false,                     -- default true
        body.namespace_id or db.NULL,
        body.linked_form_title or db.NULL,
        body.linked_form_description or db.NULL,
        body.linked_form_weblink or db.NULL
    )

    local created = db.query("SELECT * FROM income_types WHERE uuid = ?", uuid)
    return decode_row(created and created[1] or nil)
end

-- Returns (row, err, status). income_type_key is immutable (ignored if sent).
function IncomeTypeQueries.update(uuid, body)
    local existing = db.query("SELECT id FROM income_types WHERE uuid = ?", uuid)
    if not existing or #existing == 0 then
        return nil, "Income type not found", 404
    end

    local sets = {}
    local function add(col, val, kind)
        if val == nil then return end
        if kind == "array" or kind == "object" then
            table.insert(sets, col .. " = " ..
                db.interpolate_query("?::jsonb", enc_json(val, kind == "array")))
        else
            table.insert(sets, col .. " = " .. db.interpolate_query("?", val))
        end
    end

    add("display_name", body.display_name)
    add("description", body.description)
    add("required_documents", body.required_documents, "array")
    add("keyword_rules", body.keyword_rules, "array")
    add("category_affinity", body.category_affinity, "object")
    add("hmrc_mapping", body.hmrc_mapping, "object")
    add("rules_markdown", body.rules_markdown)
    add("display_order", body.display_order)
    -- Linked-form metadata — admin renames the reference form (SA110 →
    -- SA103) via the /admin/income-types edit modal and this catches
    -- it. Empty string is a valid "clear" operation (add() only skips
    -- when the field is nil, not when it's ""), so a partial payload
    -- doesn't accidentally wipe a value the admin didn't touch.
    add("linked_form_title", body.linked_form_title)
    add("linked_form_description", body.linked_form_description)
    add("linked_form_weblink", body.linked_form_weblink)
    -- Booleans handled explicitly: Lua truthiness would coerce a JSON false.
    if body.allows_manual_entry ~= nil then
        table.insert(sets, "allows_manual_entry = " ..
            db.interpolate_query("?", body.allows_manual_entry and true or false))
    end
    if body.is_active ~= nil then
        table.insert(sets, "is_active = " ..
            db.interpolate_query("?", body.is_active and true or false))
    end
    table.insert(sets, "updated_at = NOW()")

    db.query("UPDATE income_types SET " .. table.concat(sets, ", ") .. " WHERE uuid = ?", uuid)
    local updated = db.query("SELECT * FROM income_types WHERE uuid = ?", uuid)
    return decode_row(updated and updated[1] or nil)
end

-- Soft delete (disable). Non-destructive: historical my_incomes rows keep
-- their key. Returns (true) or (nil, err, status).
function IncomeTypeQueries.soft_delete(uuid)
    local existing = db.query("SELECT id FROM income_types WHERE uuid = ?", uuid)
    if not existing or #existing == 0 then
        return nil, "Income type not found", 404
    end
    db.query("UPDATE income_types SET is_active = false, updated_at = NOW() WHERE uuid = ?", uuid)
    return true
end

function IncomeTypeQueries.usage(uuid)
    local rows = db.query("SELECT income_type_key FROM income_types WHERE uuid = ? LIMIT 1", uuid)
    if not rows or #rows == 0 then return nil, "Income type not found", 404 end
    local key = rows[1].income_type_key
    return { income_type_key = key, usage_count = usage_count(key) }
end

return IncomeTypeQueries
