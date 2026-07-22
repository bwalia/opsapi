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

-- Decode a section row's config_json into a table with a guaranteed
-- checkboxes array. Malformed/absent JSON degrades to an empty config
-- rather than erroring a read path.
function FormSectionQueries.decode_config(config_json)
    local config = {}
    if type(config_json) == "string" and config_json ~= "" then
        local ok, decoded = pcall(cjson.decode, config_json)
        if ok and type(decoded) == "table" then config = decoded end
    end
    if type(config.checkboxes) ~= "table" then config.checkboxes = {} end
    return config
end

-- Set of checkbox keys a section's config defines.
function FormSectionQueries.checkbox_keys(config)
    local set = {}
    for _, c in ipairs(config.checkboxes or {}) do
        if type(c) == "table" and type(c.key) == "string" then set[c.key] = true end
    end
    return set
end

local function present_section(r)
    return {
        key = r.section_key,
        income_type_key = r.income_type_key,
        label = r.label,
        description = r.description,
        hmrc_mapping = r.hmrc_mapping,
        config = FormSectionQueries.decode_config(r.config_json),
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
function FormSectionQueries.card_summary(user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT i.income_type_key,
               COALESCE(SUM(i.amount), 0) AS total,
               COUNT(*)                   AS row_count
        FROM tax_form_items i
        JOIN tax_form_sections s
          ON s.income_type_key = i.income_type_key
         AND s.section_key = i.section_key
         AND s.is_active = true
        WHERE i.user_id = ? AND i.is_archived = false
        GROUP BY i.income_type_key
    ]], internal_user_id) or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            income_type_key = r.income_type_key,
            total = tonumber(r.total) or 0,
            row_count = tonumber(r.row_count) or 0,
        }
    end
    return out
end

return FormSectionQueries
