--[[
    Form Section Queries — tax_form_sections (admin catalogue) +
    tax_form_items (user rows) for the generic sections/sub-forms engine.

    A "section" is one repeating-row sub-form on an income type's page:
    description + amount + the checkboxes its config_json defines. Items
    are user-scoped rows against a section + tax year.

    Conventions carried from the pension implementation this engine
    replaces (all review-hardened):
      - MAX_AMOUNT bound up front (numeric(15,2) overflow → 400, not 500)
      - typed string filters (repeated query keys arrive as Lua tables)
      - archived rows are readable history but immutable (update/archive
        404 on them)
      - checkbox values validated against the section's config; unknown
        keys stripped; frozen when the section has been retired
      - section/type keys stored as plain varchar (no FK) so retiring a
        section never breaks history; totals only count ACTIVE sections
      - audit-logged writes
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local FormSectionQueries = {}

local MAX_AMOUNT = 9999999999999.99
FormSectionQueries.MAX_AMOUNT = MAX_AMOUNT

local function resolveUserId(user)
    if not user then return nil, "User not authenticated" end
    local user_uuid = user.uuid or user.id
    local rows
    if user.uuid then
        rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        rows = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not rows or #rows == 0 then return nil, "User not found" end
    return rows[1].id
end

local function resolveNamespaceId(internal_user_id)
    local rows = db.query([[
        SELECT default_namespace_id FROM user_namespace_settings
        WHERE user_id = ? LIMIT 1
    ]], internal_user_id)
    if rows and #rows > 0 and rows[1].default_namespace_id then
        return tonumber(rows[1].default_namespace_id)
    end
    return nil
end

-- Decode a section row's config_json into a table with guaranteed
-- checkboxes + fields arrays. Malformed/absent JSON degrades to an empty
-- config rather than erroring a read path.
function FormSectionQueries.decode_config(config_json)
    local config = {}
    if type(config_json) == "string" and config_json ~= "" then
        local ok, decoded = pcall(cjson.decode, config_json)
        if ok and type(decoded) == "table" then config = decoded end
    end
    if type(config.checkboxes) ~= "table" then config.checkboxes = {} end
    if type(config.fields) ~= "table" then config.fields = {} end
    return config
end

-- Set of checkbox keys a section's config defines. checkboxes may be the
-- cjson.empty_array sentinel (lightuserdata, set by present_section for
-- clean JSON) — ipairs would error on it, so type-guard first.
function FormSectionQueries.checkbox_keys(config)
    local set = {}
    local boxes = config and config.checkboxes
    if type(boxes) ~= "table" then return set end
    for _, c in ipairs(boxes) do
        if type(c) == "table" and type(c.key) == "string" then set[c.key] = true end
    end
    return set
end

-- Typed field definitions of a section's config (record mode). Same
-- sentinel guard as checkbox_keys.
function FormSectionQueries.field_defs(config)
    local out = {}
    local fields = config and config.fields
    if type(fields) ~= "table" then return out end
    for _, f in ipairs(fields) do
        if type(f) == "table" and type(f.key) == "string" then out[#out + 1] = f end
    end
    return out
end

-- All field definitions across a type's ACTIVE sections, in section
-- order — the validation catalogue for one record's data document.
-- Empty result ⇒ the type is not in record mode.
function FormSectionQueries.collect_fields(income_type_key)
    local defs = {}
    for _, s in ipairs(FormSectionQueries.sections_for_type(income_type_key)) do
        for _, f in ipairs(FormSectionQueries.field_defs(s.config)) do
            defs[#defs + 1] = f
        end
    end
    return defs
end

-- Truthy-boolean normalisation shared with the routes: JSON bodies carry
-- real booleans, form bodies carry strings ("on" is a bare HTML checkbox).
local function truthy(v)
    return v == true or v == "true" or v == "1" or v == 1 or v == "on"
end

local function valid_iso_date(s)
    if type(s) ~= "string" then return false end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return false end
    m, d = tonumber(m), tonumber(d)
    return m >= 1 and m <= 12 and d >= 1 and d <= 31
end

-- Named formats an admin can attach to a text field. Deliberately a
-- fixed whitelist — free-form admin regexes are a footgun (Lua patterns
-- aren't PCRE, and a bad one would 500 every save).
local FORMAT_CHECKS = {
    paye_reference = {
        check = function(v) return #v <= 14 and v:match("^%d%d%d/%w+$") ~= nil end,
        message = "must look like 123/AB456 (three digits, a slash, then letters/numbers)",
    },
}
FormSectionQueries.FORMAT_NAMES = { paye_reference = true }

-- Validate one record's submitted `data` object against the type's field
-- catalogue. Unknown keys are dropped; empty/zero/false values are
-- dropped (absence == not filled in); required fields must survive.
-- Returns validated_table, total (sum of money fields flagged
-- summary:true) — or nil, err.
function FormSectionQueries.validate_record_data(defs, data)
    if type(data) ~= "table" then
        return nil, "data must be an object of field values"
    end
    local out, total = {}, 0
    for _, f in ipairs(defs) do
        local v = data[f.key]
        -- Body parsing only strips cjson.null at the TOP level of the
        -- request body; inside the nested data object a JSON null must
        -- also read as "not set", not as a bad value.
        if v == cjson.null then v = nil end
        if v ~= nil then
            if f.type == "money" or f.type == "number" then
                -- Skip blanks; a blank input submits "" and means "not set".
                if v ~= "" then
                    local n = tonumber(v)
                    if not n or n ~= n or n < 0 then
                        return nil, f.label .. " must be a number of 0 or more"
                    end
                    if n > MAX_AMOUNT then
                        return nil, f.label .. " is too large"
                    end
                    if n > 0 then
                        out[f.key] = n
                        if f.type == "money" and f.summary == true then
                            total = total + n
                        end
                    end
                end
            elseif f.type == "boolean" then
                if truthy(v) then out[f.key] = true end
            elseif f.type == "date" then
                if v ~= "" then
                    if not valid_iso_date(v) then
                        return nil, f.label .. " must be a date (YYYY-MM-DD)"
                    end
                    out[f.key] = v
                end
            elseif f.type == "textarea" then
                if type(v) ~= "string" then
                    return nil, f.label .. " must be text"
                end
                if #v > 2000 then
                    return nil, f.label .. " must be 2000 characters or fewer"
                end
                if v ~= "" then out[f.key] = v end
            else -- text
                if type(v) ~= "string" then
                    return nil, f.label .. " must be text"
                end
                if #v > 200 then
                    return nil, f.label .. " must be 200 characters or fewer"
                end
                if v ~= "" then
                    local fmt = f.format and FORMAT_CHECKS[f.format]
                    if fmt and not fmt.check(v) then
                        return nil, f.label .. " " .. fmt.message
                    end
                    out[f.key] = v
                end
            end
        end
    end
    for _, f in ipairs(defs) do
        if f.required == true and out[f.key] == nil then
            return nil, f.label .. " is required"
        end
    end
    -- Each amount is bounded above, but their SUM lands in a
    -- numeric(15,2) column too — without this it overflows to a 500.
    if total > MAX_AMOUNT then
        return nil, "the amounts add up to a total that is too large"
    end
    return out, total
end

local function present_section(r)
    local config = FormSectionQueries.decode_config(r.config_json)
    -- An EMPTY decoded array re-encodes as {} (object) through cjson,
    -- which crashes frontend .map()/for..of consumers — substitute the
    -- empty-array sentinel so the wire always carries "checkboxes":[]
    -- and "fields":[]. (The *_keys/field helpers type-guard against the
    -- sentinel, which is lightuserdata.)
    if #config.checkboxes == 0 then config.checkboxes = cjson.empty_array end
    if #config.fields == 0 then config.fields = cjson.empty_array end
    return {
        key = r.section_key,
        income_type_key = r.income_type_key,
        label = r.label,
        description = r.description,
        hmrc_mapping = r.hmrc_mapping,
        config = config,
        display_order = r.display_order,
        is_active = r.is_active == true,
        uuid = r.uuid,
    }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Catalogue — user reads
-- ────────────────────────────────────────────────────────────────────────────
function FormSectionQueries.sections_for_type(income_type_key)
    local rows = db.query([[
        SELECT * FROM tax_form_sections
        WHERE is_active = true AND income_type_key = ?
        ORDER BY display_order ASC, label ASC
    ]], income_type_key) or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = present_section(r) end
    return out
end

-- Active section row for validation — nil when unknown/retired.
function FormSectionQueries.active_section(income_type_key, section_key)
    local rows = db.query([[
        SELECT * FROM tax_form_sections
        WHERE is_active = true AND income_type_key = ? AND section_key = ?
        LIMIT 1
    ]], income_type_key, section_key)
    if not rows or #rows == 0 then return nil end
    return present_section(rows[1])
end

-- ────────────────────────────────────────────────────────────────────────────
-- Catalogue — admin CRUD (route layer enforces the admin gate + validation)
-- ────────────────────────────────────────────────────────────────────────────
function FormSectionQueries.admin_list(params)
    local where, args = {}, {}
    if type(params.income_type) == "string" and params.income_type ~= "" then
        table.insert(where, "income_type_key = ?"); table.insert(args, params.income_type)
    end
    if params.include_inactive ~= "true" and params.include_inactive ~= true then
        table.insert(where, "is_active = true")
    end
    local sql = "SELECT * FROM tax_form_sections"
    if #where > 0 then sql = sql .. " WHERE " .. table.concat(where, " AND ") end
    sql = sql .. " ORDER BY income_type_key ASC, display_order ASC, label ASC"
    local rows = db.query(sql, unpack(args)) or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = present_section(r) end
    return out
end

function FormSectionQueries.admin_create(data)
    local exists = db.select(
        "id FROM tax_form_sections WHERE income_type_key = ? AND section_key = ?",
        data.income_type_key, data.section_key)
    if exists and #exists > 0 then
        return nil, "A section with this key already exists for this income type"
    end
    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO tax_form_sections
            (uuid, income_type_key, section_key, label, description,
             hmrc_mapping, config_json, display_order, is_active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, true, NOW(), NOW())
    ]], uuid, data.income_type_key, data.section_key, data.label,
        data.description or db.NULL, data.hmrc_mapping or db.NULL,
        data.config_json or db.NULL, tonumber(data.display_order) or 0)
    local row = db.query("SELECT * FROM tax_form_sections WHERE uuid = ? LIMIT 1", uuid)[1]
    return present_section(row)
end

function FormSectionQueries.admin_update(uuid, data)
    local rows = db.query("SELECT * FROM tax_form_sections WHERE uuid = ? LIMIT 1", uuid)
    if not rows or #rows == 0 then return nil end

    local updates, args = {}, {}
    if data.label ~= nil then
        table.insert(updates, "label = ?"); table.insert(args, data.label)
    end
    if data.description ~= nil then
        table.insert(updates, "description = ?")
        table.insert(args, data.description ~= "" and data.description or db.NULL)
    end
    if data.hmrc_mapping ~= nil then
        table.insert(updates, "hmrc_mapping = ?")
        table.insert(args, data.hmrc_mapping ~= "" and data.hmrc_mapping or db.NULL)
    end
    if data.config_json ~= nil then
        table.insert(updates, "config_json = ?")
        table.insert(args, data.config_json ~= "" and data.config_json or db.NULL)
    end
    if data.display_order ~= nil then
        table.insert(updates, "display_order = ?"); table.insert(args, tonumber(data.display_order) or 0)
    end
    if data.is_active ~= nil then
        table.insert(updates, "is_active = ?"); table.insert(args, data.is_active == true)
    end
    if #updates == 0 then return present_section(rows[1]) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, uuid)
    db.query("UPDATE tax_form_sections SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ?", unpack(args))
    local row = db.query("SELECT * FROM tax_form_sections WHERE uuid = ? LIMIT 1", uuid)[1]
    return present_section(row)
end

-- Soft disable — history stays reproducible, rows become "orphans" on the
-- user page (listed, deletable, excluded from totals).
function FormSectionQueries.admin_disable(uuid)
    local rows = db.query("SELECT id FROM tax_form_sections WHERE uuid = ? LIMIT 1", uuid)
    if not rows or #rows == 0 then return nil end
    db.query("UPDATE tax_form_sections SET is_active = false, updated_at = NOW() WHERE uuid = ?", uuid)
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- Items
-- ────────────────────────────────────────────────────────────────────────────
local function present_item(row)
    row.id = row.uuid
    row.user_id = nil
    local extra = {}
    if type(row.extra_json) == "string" and row.extra_json ~= "" then
        local ok, decoded = pcall(cjson.decode, row.extra_json)
        if ok and type(decoded) == "table" then extra = decoded end
    end
    row.extra = extra
    row.extra_json = nil
    return row
end

-- params: { income_type?, section?, tax_year?, include_archived? }
function FormSectionQueries.items(params, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local where = { "user_id = ?" }
    local args = { internal_user_id }
    -- type() guards: repeated query-string keys arrive as Lua tables.
    if type(params.income_type) == "string" and params.income_type ~= "" then
        table.insert(where, "income_type_key = ?"); table.insert(args, params.income_type)
    end
    if type(params.section) == "string" and params.section ~= "" then
        table.insert(where, "section_key = ?"); table.insert(args, params.section)
    end
    if type(params.tax_year) == "string" and params.tax_year ~= "" then
        table.insert(where, "tax_year = ?"); table.insert(args, params.tax_year)
    end
    if params.include_archived ~= "true" and params.include_archived ~= true then
        table.insert(where, "is_archived = false")
    end

    local rows = db.query(
        "SELECT * FROM tax_form_items WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY created_at ASC",
        unpack(args)) or {}
    for _, r in ipairs(rows) do present_item(r) end
    return { data = rows, total = #rows }
end

-- data: { income_type_key, section_key, tax_year, amount, description?, extra_json? }
-- The route resolves + validates the ACTIVE section and pre-encodes
-- extra_json from the section's checkbox config.
function FormSectionQueries.create_item(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local n = tonumber(data.amount)
    if not n or n ~= n or n <= 0 or n > MAX_AMOUNT then
        return nil, "amount must be a positive number"
    end

    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO tax_form_items
            (uuid, user_id, namespace_id, income_type_key, section_key, tax_year,
             description, amount, extra_json, is_archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, false, NOW(), NOW())
    ]],
        uuid,
        internal_user_id,
        resolveNamespaceId(internal_user_id) or db.NULL,
        data.income_type_key,
        data.section_key,
        data.tax_year,
        (type(data.description) == "string" and data.description ~= "") and data.description or db.NULL,
        n,
        data.extra_json or db.NULL
    )
    local row = db.query("SELECT * FROM tax_form_items WHERE uuid = ? LIMIT 1", uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "FORM_ITEM",
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present_item(row)
end

-- Archived rows are readable history via items(include_archived=true) but
-- immutable: show/update/archive all treat them as gone.
function FormSectionQueries.show_item(item_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT * FROM tax_form_items
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], item_uuid, internal_user_id)
    if not rows or #rows == 0 then return nil end
    return present_item(rows[1])
end

-- data: { amount?, description?, extra_json? } — income_type_key,
-- section_key and tax_year are immutable (delete + re-add to move a row).
function FormSectionQueries.update_item(item_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM tax_form_items
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], item_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    local updates, args = {}, {}
    if data.amount ~= nil then
        local n = tonumber(data.amount)
        if not n or n ~= n or n <= 0 or n > MAX_AMOUNT then
            return nil, "amount must be a positive number"
        end
        table.insert(updates, "amount = ?"); table.insert(args, n)
    end
    if data.description ~= nil then
        -- "" clears (stored as NULL) — JSON null is stripped at the body
        -- boundary so it can't express "clear".
        table.insert(updates, "description = ?")
        table.insert(args, data.description ~= "" and data.description or db.NULL)
    end
    if data.extra_json ~= nil then
        table.insert(updates, "extra_json = ?")
        table.insert(args, data.extra_json ~= "" and data.extra_json or db.NULL)
    end
    if #updates == 0 then return present_item(old) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, item_uuid)
    table.insert(args, internal_user_id)
    db.query("UPDATE tax_form_items SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM tax_form_items WHERE uuid = ? LIMIT 1", item_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "FORM_ITEM",
        entity_id = item_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present_item(refreshed)
end

function FormSectionQueries.archive_item(item_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM tax_form_items
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], item_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE tax_form_items
           SET is_archived = true, archived_at = NOW(), archived_by = ?, updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], internal_user_id, item_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "FORM_ITEM",
        entity_id = item_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- Records (record mode) — one row per record (e.g. one employment), the
-- whole field-form stored as a JSON document validated by the route.
-- Same archived-rows-are-immutable convention as items.
-- ────────────────────────────────────────────────────────────────────────────
local function present_record(row)
    row.id = row.uuid
    row.user_id = nil
    local data = {}
    if type(row.data_json) == "string" and row.data_json ~= "" then
        local ok, decoded = pcall(cjson.decode, row.data_json)
        if ok and type(decoded) == "table" then data = decoded end
    end
    -- data is a MAP — an empty one correctly encodes as {} (object).
    row.data = data
    row.data_json = nil
    row.total = tonumber(row.total) or 0
    return row
end

-- params: { income_type?, tax_year?, include_archived? }
function FormSectionQueries.records(params, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local where = { "user_id = ?" }
    local args = { internal_user_id }
    if type(params.income_type) == "string" and params.income_type ~= "" then
        table.insert(where, "income_type_key = ?"); table.insert(args, params.income_type)
    end
    if type(params.tax_year) == "string" and params.tax_year ~= "" then
        table.insert(where, "tax_year = ?"); table.insert(args, params.tax_year)
    end
    if params.include_archived ~= "true" and params.include_archived ~= true then
        table.insert(where, "is_archived = false")
    end

    local rows = db.query(
        "SELECT * FROM tax_form_records WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY created_at ASC",
        unpack(args)) or {}
    for _, r in ipairs(rows) do present_record(r) end
    return { data = rows, total = #rows }
end

-- data: { income_type_key, tax_year, data_json, total } — the route has
-- already validated the document against the field catalogue.
function FormSectionQueries.create_record(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO tax_form_records
            (uuid, user_id, namespace_id, income_type_key, tax_year,
             data_json, total, is_archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, false, NOW(), NOW())
    ]],
        uuid,
        internal_user_id,
        resolveNamespaceId(internal_user_id) or db.NULL,
        data.income_type_key,
        data.tax_year,
        data.data_json,
        data.total or 0
    )
    local row = db.query("SELECT * FROM tax_form_records WHERE uuid = ? LIMIT 1", uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "FORM_RECORD",
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present_record(row)
end

function FormSectionQueries.show_record(record_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT * FROM tax_form_records
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], record_uuid, internal_user_id)
    if not rows or #rows == 0 then return nil end
    return present_record(rows[1])
end

-- PUT is a full-document replace: { data_json, total }. income_type_key
-- and tax_year are immutable (delete + re-add to move a record).
function FormSectionQueries.update_record(record_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM tax_form_records
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], record_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    db.query([[
        UPDATE tax_form_records
           SET data_json = ?, total = ?, updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], data.data_json, data.total or 0, record_uuid, internal_user_id)

    local refreshed = db.query("SELECT * FROM tax_form_records WHERE uuid = ? LIMIT 1", record_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "FORM_RECORD",
        entity_id = record_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present_record(refreshed)
end

function FormSectionQueries.archive_record(record_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM tax_form_records
        WHERE uuid = ? AND user_id = ? AND is_archived = false LIMIT 1
    ]], record_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE tax_form_records
           SET is_archived = true, archived_at = NOW(), archived_by = ?, updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], internal_user_id, record_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "FORM_RECORD",
        entity_id = record_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- Summaries — derived, read-only. Only ACTIVE sections count; rows in a
-- retired section stay listed via items() but drop out of these numbers.
-- ────────────────────────────────────────────────────────────────────────────
function FormSectionQueries.summary(income_type_key, tax_year, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local totals = db.query([[
        SELECT section_key,
               COALESCE(SUM(amount), 0) AS total,
               COUNT(*)                 AS row_count
        FROM tax_form_items
        WHERE user_id = ? AND income_type_key = ? AND tax_year = ? AND is_archived = false
        GROUP BY section_key
    ]], internal_user_id, income_type_key, tax_year) or {}
    local by_key = {}
    for _, t in ipairs(totals) do by_key[t.section_key] = t end

    local sections = {}
    local grand_total = 0
    for _, s in ipairs(FormSectionQueries.sections_for_type(income_type_key)) do
        local t = by_key[s.key]
        local total = t and tonumber(t.total) or 0
        sections[#sections + 1] = {
            key = s.key,
            label = s.label,
            total = total,
            row_count = t and tonumber(t.row_count) or 0,
        }
        grand_total = grand_total + total
    end

    return {
        income_type_key = income_type_key,
        tax_year = tax_year,
        total = grand_total,
        sections = sections,
    }
end

-- All-years per-type totals for the /my-income overview cards, restricted
-- to rows whose section is still active (matching summary()'s rule).
-- Starts from the SECTIONS side so every sectioned type appears even with
-- zero rows — the card needs to know "this type uses the engine" to show
-- the right call-to-action before anything is recorded.
function FormSectionQueries.card_summary(user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT s.income_type_key,
               COALESCE(SUM(i.amount), 0) AS total,
               COUNT(i.id)                AS row_count
        FROM tax_form_sections s
        LEFT JOIN tax_form_items i
          ON i.income_type_key = s.income_type_key
         AND i.section_key = s.section_key
         AND i.user_id = ?
         AND i.is_archived = false
        WHERE s.is_active = true
        GROUP BY s.income_type_key
    ]], internal_user_id) or {}
    local out, by_type = {}, {}
    for _, r in ipairs(rows) do
        local entry = {
            income_type_key = r.income_type_key,
            total = tonumber(r.total) or 0,
            row_count = tonumber(r.row_count) or 0,
        }
        out[#out + 1] = entry
        by_type[entry.income_type_key] = entry
    end

    -- Record-mode types: fold in the records' denormalised totals. Their
    -- section side contributes the zero-row presence (needed for the CTA),
    -- items contribute 0, so plain addition is correct either way.
    local recs = db.query([[
        SELECT income_type_key,
               COALESCE(SUM(total), 0) AS total,
               COUNT(id)               AS row_count
        FROM tax_form_records
        WHERE user_id = ? AND is_archived = false
        GROUP BY income_type_key
    ]], internal_user_id) or {}
    for _, r in ipairs(recs) do
        local entry = by_type[r.income_type_key]
        if not entry then
            entry = { income_type_key = r.income_type_key, total = 0, row_count = 0 }
            out[#out + 1] = entry
            by_type[r.income_type_key] = entry
        end
        entry.total = entry.total + (tonumber(r.total) or 0)
        entry.row_count = entry.row_count + (tonumber(r.row_count) or 0)
    end

    -- Profile-builder-sourced totals for types whose data lives in
    -- user_profile_answers rather than tax_form_*. Three cases today:
    --
    --   salary            entity-scoped answers under emp_pay_*,
    --                     emp_tips_*, emp_ben_*  (Phase 1 migration)
    --   pension_payments  year-scoped repeating_group JSON arrays
    --                     (Phase 2 migration)
    --   dividends         year-scoped currency answers (never used the
    --                     Form Sections engine — always inline via the
    --                     [type]/page.tsx PROFILE_BUILDER_CONTEXTS
    --                     map, so card_summary never saw them until
    --                     this branch existed).
    --
    -- Both `total` AND `row_count` need to be set — the /my-income
    -- overview card renders "Nothing recorded yet" when row_count = 0
    -- regardless of what total says. Post-cutover for salary/pension
    -- there are no tax_form_* rows to source row_count from, so
    -- reading it from the pb store's natural row concept (entities
    -- for salary, array-element count for pension, answered-question
    -- count for dividends) is the only way to make hasEntries true.
    --
    -- Kept in this function rather than the route so every caller of
    -- card_summary (route, future scheduled jobs, integration tests)
    -- gets consistent totals — one source of truth for the aggregate.

    -- ── Salary ──────────────────────────────────────────────────────
    -- Total = pay + tips + benefits across every non-archived
    -- employment. Count = number of employments (matches the
    -- "N entries" concept from the legacy FormRecordsPage — one
    -- record was one employment there too).
    local salary_row = db.query([[
        SELECT
          COALESCE(SUM(CASE
            WHEN q.question_key IN ('emp_pay_before_tax','emp_tips_not_on_p60')
              OR q.question_key LIKE 'emp_ben_%'
            THEN a.answer_number ELSE 0 END), 0) AS total
        FROM user_profile_answers a
        JOIN profile_questions q ON q.id = a.question_id
        JOIN user_profile_entities e ON e.uuid = a.entity_uuid
        WHERE a.user_id = ?
          AND e.entity_type = 'employment'
          AND e.is_archived = false
          AND a.answer_number IS NOT NULL
    ]], internal_user_id)
    local salary_count = db.query([[
        SELECT COUNT(*) AS n FROM user_profile_entities
        WHERE user_id = ? AND entity_type = 'employment' AND is_archived = false
    ]], internal_user_id)
    if salary_row and salary_row[1] then
        local salary_entry = by_type["salary"]
        if not salary_entry then
            salary_entry = { income_type_key = "salary", total = 0, row_count = 0 }
            out[#out + 1] = salary_entry
            by_type["salary"] = salary_entry
        end
        salary_entry.total = tonumber(salary_row[1].total) or 0
        salary_entry.row_count = tonumber((salary_count[1] or {}).n) or 0
    end

    -- ── Pension payments ────────────────────────────────────────────
    -- Total = SUM amount across every element of every answer_json
    -- array for the three pp_*_payments questions.
    -- Count = total number of individual payment rows the user has
    -- entered (SUM of array lengths across all 3 sections × all years).
    -- jsonb_typeof guard: other question types can store objects in
    -- answer_json; jsonb_array_elements throws on non-arrays.
    local pension_row = db.query([[
        SELECT
          COALESCE(SUM((elem->>'amount')::numeric), 0) AS total,
          COUNT(*)                                    AS row_count
        FROM user_profile_answers a
        JOIN profile_questions q ON q.id = a.question_id
        CROSS JOIN LATERAL jsonb_array_elements(a.answer_json::jsonb) elem
        WHERE a.user_id = ?
          AND q.question_key IN
              ('pp_registered_payments','pp_employer_payments','pp_overseas_payments')
          AND a.answer_json IS NOT NULL
          AND a.answer_json <> ''
          AND jsonb_typeof(a.answer_json::jsonb) = 'array'
    ]], internal_user_id)
    if pension_row and pension_row[1] then
        local pension_entry = by_type["pension_payments"]
        if not pension_entry then
            pension_entry = { income_type_key = "pension_payments", total = 0, row_count = 0 }
            out[#out + 1] = pension_entry
            by_type["pension_payments"] = pension_entry
        end
        pension_entry.total = tonumber(pension_row[1].total) or 0
        pension_entry.row_count = tonumber(pension_row[1].row_count) or 0
    end

    -- ── Generic profile-builder totals (dividends, SA110, and any
    --    future admin-added income type) ─────────────────────────────
    -- Previously this was a hardcoded per-type branch: dividends
    -- explicit, plus a comment "add SA110 here later, etc". That
    -- broke the "admin adds a section and it ships" promise the
    -- frontend just delivered via auto-discovery (feat/sa110-...
    -- retired PROFILE_BUILDER_CONTEXTS). This is the backend
    -- companion — one query that covers every income_type whose key
    -- matches a profile_categories.context, so a new type + category
    -- combination lands on /my-income overview automatically.
    --
    -- What's summed
    --   total     SUM(answer_number) — every numeric answer under
    --             the type's categories. Adminstrictly-numeric
    --             questions (currency / number / percentage) are the
    --             only ones with answer_number populated; text /
    --             boolean / date answers are naturally excluded.
    --   row_count number of distinct question_ids with a non-null
    --             numeric answer. Value isn't user-surfaced beyond
    --             the hasEntries threshold; 1 or more means "this
    --             type has data".
    --
    -- What's excluded
    --   salary + pension_payments — handled by explicit branches
    --   above with type-specific sum logic (entity-scoped for
    --   salary, aggregated JSON arrays for pension). Skipped in the
    --   NOT IN filter so their pb totals aren't overwritten by this
    --   generic sum, which would double-count for salary (already
    --   summed by employment_type) or be zero for pension (numeric
    --   values live in answer_json, not answer_number).
    --
    --   capital_gains — handled by the explicit branch below. The
    --   generic sum-every-numeric-answer is wrong for SA108: it
    --   would add disposal proceeds, allowable costs, losses,
    --   tax-already-paid and disposal counts into one meaningless
    --   figure. Its branch sums only the six "gains in the year,
    --   before losses" boxes.
    --
    --   other — same reasoning for SA101 (Additional information):
    --   the generic sum would add tax reliefs, deductions,
    --   tax-taken-off, pension charges and policy-years counts into
    --   the "other income" headline. Its explicit branch below sums
    --   only the income boxes.
    --
    --   Per-entity contexts (property, business, overseas_property,
    --   rental_business, employment) — these DON'T correspond 1:1 to
    --   an income_type_key (rental hub is 'rental', not
    --   'rental_business'; self-employment hub is 'self_employment',
    --   not 'business'; etc.). They're joined via the entity's own
    --   income type, not the context string. Filter by requiring
    --   the join on income_types to succeed.
    --
    -- Categories with no matching income_types row are skipped by
    -- the JOIN — admin creating a profile_categories.context that
    -- doesn't match an income_type_key won't leak orphan rows here.
    local generic_rows = db.query([[
        SELECT it.income_type_key,
               COALESCE(SUM(a.answer_number), 0) AS total,
               COUNT(DISTINCT a.question_id)    AS row_count
        FROM user_profile_answers a
        JOIN profile_questions q  ON q.id = a.question_id
        JOIN profile_categories c ON c.id = q.category_id
        JOIN income_types it      ON it.income_type_key = c.context
        WHERE a.user_id = ?
          AND it.income_type_key NOT IN ('salary', 'pension_payments', 'capital_gains', 'other')
          AND c.is_active = true
          AND c.is_archived = false
          AND it.is_active = true
          AND a.answer_number IS NOT NULL
        GROUP BY it.income_type_key
    ]], internal_user_id) or {}
    for _, r in ipairs(generic_rows) do
        local entry = by_type[r.income_type_key]
        if not entry then
            entry = { income_type_key = r.income_type_key, total = 0, row_count = 0 }
            out[#out + 1] = entry
            by_type[r.income_type_key] = entry
        end
        entry.total = tonumber(r.total) or 0
        entry.row_count = tonumber(r.row_count) or 0
    end

    -- ── Capital gains ───────────────────────────────────────────────
    -- SA108 boxes, year-scoped, rendered by the profile-builder panel
    -- like dividends. Excluded from the generic branch above because
    -- summing every numeric answer would add proceeds, allowable
    -- costs, losses and tax-already-paid into one meaningless number.
    --
    -- Total = SUM of the six "gains in the year, before losses" boxes
    -- (SA108 boxes 6, 13B, 13.4, 17, 26, 34 — disjoint asset classes;
    -- box 6 explicitly excludes the carried interest counted by 13B).
    -- The seed marks these with config_json.card_total=true, but the
    -- SQL matches on question_key like the salary branch does:
    -- config_json is a text column an admin can free-edit, and a
    -- malformed-JSON ::jsonb cast would 500 every /my-income load.
    -- Keep this list in step with the card_total flags in
    -- migrations/sa108-capital-gains-questions.lua.
    --
    -- Count = number of SA108 boxes with ANY answer (text, number,
    -- boolean, date or json) — box 54 free text alone still counts as
    -- "something recorded", flipping the card off "Nothing recorded
    -- yet". The number itself isn't user-surfaced beyond hasEntries.
    local capital_gains_row = db.query([[
        SELECT
          COALESCE(SUM(CASE
            WHEN q.question_key IN
                ('sa108_res_gains_before_losses',
                 'sa108_ci_gains_in_year',
                 'sa108_crypto_gains_before_losses',
                 'sa108_other_gains_before_losses',
                 'sa108_listed_gains_before_losses',
                 'sa108_unlisted_gains_before_losses')
            THEN a.answer_number ELSE 0 END), 0) AS total,
          COUNT(a.id)                            AS row_count
        FROM user_profile_answers a
        JOIN profile_questions q  ON q.id = a.question_id
        JOIN profile_categories c ON c.id = q.category_id
        WHERE a.user_id = ?
          AND c.context = 'capital_gains'
          AND c.is_active = true
          AND c.is_archived = false
          AND (COALESCE(a.answer_text, '') <> ''
               OR a.answer_number IS NOT NULL
               OR a.answer_boolean IS NOT NULL
               OR a.answer_date IS NOT NULL
               OR COALESCE(a.answer_json, '') <> '')
    ]], internal_user_id)
    if capital_gains_row and capital_gains_row[1] then
        local cg_entry = by_type["capital_gains"]
        if not cg_entry then
            cg_entry = { income_type_key = "capital_gains", total = 0, row_count = 0 }
            out[#out + 1] = cg_entry
            by_type["capital_gains"] = cg_entry
        end
        cg_entry.total = tonumber(capital_gains_row[1].total) or 0
        cg_entry.row_count = tonumber(capital_gains_row[1].row_count) or 0
    end

    -- ── Other income (SA101 Additional information) ─────────────────
    -- Same shape as the capital_gains branch above, same reason to be
    -- excluded from the generic sum: SA101 mixes income with tax
    -- reliefs, deductions, tax-taken-off, MCA, losses and pension
    -- charges. Total = SUM of the INCOME boxes only (flagged
    -- config_json.card_total in the seed; keys hardcoded here for the
    -- same malformed-config_json reason): gilt gross interest (box 3),
    -- life policy gains (4, 6, 8), stock dividends (12), bonus issues
    -- (13), close company loans written off (13.1), business receipts
    -- (14), and the employment-section income boxes (1, 3, 4, 5).
    -- Keep this list in step with the card_total flags in
    -- migrations/sa101-additional-information-questions.lua.
    -- Count = number of SA101 boxes with ANY answer, so a
    -- reliefs-only or MCA-only entry still flips the card off
    -- "Nothing recorded yet".
    local other_row = db.query([[
        SELECT
          COALESCE(SUM(CASE
            WHEN q.question_key IN
                ('sa101_gilt_gross_before_tax',
                 'sa101_lip_gains_tax_treated_paid',
                 'sa101_lip_gains_no_tax_treated',
                 'sa101_lip_gains_voided_isas',
                 'sa101_sd_stock_dividends',
                 'sa101_sd_bonus_issues',
                 'sa101_sd_close_company_loans',
                 'sa101_bri_amount',
                 'sa101_emp_share_schemes',
                 'sa101_emp_taxable_lump_sums',
                 'sa101_emp_efrbs_lump_sums',
                 'sa101_emp_redundancy_above_30k')
            THEN a.answer_number ELSE 0 END), 0) AS total,
          COUNT(a.id)                            AS row_count
        FROM user_profile_answers a
        JOIN profile_questions q  ON q.id = a.question_id
        JOIN profile_categories c ON c.id = q.category_id
        WHERE a.user_id = ?
          AND c.context = 'other'
          AND c.is_active = true
          AND c.is_archived = false
          AND (COALESCE(a.answer_text, '') <> ''
               OR a.answer_number IS NOT NULL
               OR a.answer_boolean IS NOT NULL
               OR a.answer_date IS NOT NULL
               OR COALESCE(a.answer_json, '') <> '')
    ]], internal_user_id)
    if other_row and other_row[1] then
        local other_entry = by_type["other"]
        if not other_entry then
            other_entry = { income_type_key = "other", total = 0, row_count = 0 }
            out[#out + 1] = other_entry
            by_type["other"] = other_entry
        end
        other_entry.total = tonumber(other_row[1].total) or 0
        other_entry.row_count = tonumber(other_row[1].row_count) or 0
    end

    return out
end

return FormSectionQueries
