--[[
    Property Queries — user_profile_entities rows of entity_type 'property'.

    A "property" is the drill-down unit of the Rental income hub. Each
    property carries:
      * a user-facing label (nickname shown in the hub list)
      * entity-scoped Profile Builder answers (via user_profile_answers.entity_uuid)
      * income/expense line items (property_line_items — see PropertyLineQueries)

    Every read/write is scoped to the authenticated user. Soft-delete via
    is_archived so entity-scoped answers and line items keep a resolvable
    parent for historical calculations.

    Pattern: mirrors MyIncomeQueries (resolveUserId + uuid-as-id responses
    + tax_audit_logs rows on mutation).
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local PropertyQueries = {}

local ENTITY_TYPE = "property"

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

local function present(row)
    row.id = row.uuid
    row.user_id = nil
    return row
end

-- ────────────────────────────────────────────────────────────────────────────
-- List — optionally decorated with line-item totals for one tax year so the
-- hub can render "Income / Expenses / Net" per property in a single call.
-- ────────────────────────────────────────────────────────────────────────────
-- params: { tax_year?, include_archived? }
function PropertyQueries.all(params, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local where = { "user_id = ?", "entity_type = ?" }
    local args = { internal_user_id, ENTITY_TYPE }
    if params.include_archived ~= "true" and params.include_archived ~= true then
        table.insert(where, "is_archived = false")
    end

    local rows = db.query(
        "SELECT * FROM user_profile_entities WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY display_order ASC, created_at ASC",
        unpack(args)) or {}

    -- Per-property totals for the requested tax year (one grouped query,
    -- not N+1). Only when a tax_year is given — the list itself is
    -- year-agnostic.
    local totals = {}
    if params.tax_year and params.tax_year ~= "" and #rows > 0 then
        local t_rows = db.query([[
            SELECT property_uuid, kind, SUM(amount) AS total, COUNT(*) AS line_count
            FROM property_line_items
            WHERE user_id = ? AND tax_year = ? AND is_archived = false
            GROUP BY property_uuid, kind
        ]], internal_user_id, params.tax_year) or {}
        for _, t in ipairs(t_rows) do
            totals[t.property_uuid] = totals[t.property_uuid] or { income = 0, expense = 0, line_count = 0 }
            local bucket = totals[t.property_uuid]
            if t.kind == "income" then bucket.income = tonumber(t.total) or 0 end
            if t.kind == "expense" then bucket.expense = tonumber(t.total) or 0 end
            bucket.line_count = bucket.line_count + (tonumber(t.line_count) or 0)
        end
    end

    for _, r in ipairs(rows) do
        local t = totals[r.uuid]
        r.income_total = t and t.income or 0
        r.expense_total = t and t.expense or 0
        r.line_count = t and t.line_count or 0
        present(r)
    end
    return { data = rows, total = #rows }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Show (ownership-scoped). Used by routes AND by profile-builder's
-- entity-answer guard — keep the return shape stable.
-- ────────────────────────────────────────────────────────────────────────────
function PropertyQueries.show(property_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local rows = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ?
        LIMIT 1
    ]], property_uuid, internal_user_id, ENTITY_TYPE)
    if not rows or #rows == 0 then return nil end
    return present(rows[1])
end

-- ────────────────────────────────────────────────────────────────────────────
-- Create — label is the only required field; everything else about a
-- property is admin-driven questions answered later on its page.
-- ────────────────────────────────────────────────────────────────────────────
function PropertyQueries.create(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    if not data.label or data.label == "" then
        return nil, "label is required"
    end

    local uuid = Global.generateUUID()
    -- namespace_id is always resolved server-side — a client-supplied value
    -- would let callers stamp their rows into an arbitrary tenant.
    db.query([[
        INSERT INTO user_profile_entities
            (uuid, user_id, user_uuid, namespace_id, entity_type, label, metadata_json, display_order, is_archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, false, NOW(), NOW())
    ]],
        uuid,
        internal_user_id,
        tostring(user.uuid or user.id),
        resolveNamespaceId(internal_user_id) or db.NULL,
        ENTITY_TYPE,
        tostring(data.label),
        data.metadata_json or db.NULL,
        tonumber(data.display_order) or 0
    )
    local row = db.query("SELECT * FROM user_profile_entities WHERE uuid = ? LIMIT 1", uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PROPERTY",
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present(row)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Update (label / metadata / display_order)
-- ────────────────────────────────────────────────────────────────────────────
function PropertyQueries.update(property_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? LIMIT 1
    ]], property_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    local updates, args = {}, {}
    if data.label ~= nil then
        if data.label == "" then return nil, "label cannot be empty" end
        table.insert(updates, "label = ?"); table.insert(args, tostring(data.label))
    end
    if data.metadata_json ~= nil then
        -- "" clears (stored as NULL) — see description handling in
        -- PropertyLineQueries.update for the contract rationale.
        table.insert(updates, "metadata_json = ?")
        table.insert(args, data.metadata_json ~= "" and data.metadata_json or db.NULL)
    end
    if data.display_order ~= nil then
        table.insert(updates, "display_order = ?"); table.insert(args, tonumber(data.display_order) or 0)
    end
    if #updates == 0 then return present(old) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, property_uuid)
    table.insert(args, internal_user_id)
    db.query("UPDATE user_profile_entities SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM user_profile_entities WHERE uuid = ? LIMIT 1", property_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PROPERTY",
        entity_id = property_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present(refreshed)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Archive (soft delete) — also archives the property's line items so its
-- figures drop out of summaries; entity-scoped answers are left in place
-- (they're harmless once the parent is archived and keep history intact).
-- ────────────────────────────────────────────────────────────────────────────
function PropertyQueries.archive(property_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? LIMIT 1
    ]], property_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE user_profile_entities
           SET is_archived = true, archived_at = NOW(), updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], property_uuid, internal_user_id)
    db.query([[
        UPDATE property_line_items
           SET is_archived = true, archived_at = NOW(), archived_by = ?, updated_at = NOW()
         WHERE property_uuid = ? AND user_id = ? AND is_archived = false
    ]], internal_user_id, property_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PROPERTY",
        entity_id = property_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- Summary — the hub's read-only strip: business-wide totals for one tax
-- year plus the per-property breakdown.
-- ────────────────────────────────────────────────────────────────────────────
function PropertyQueries.summary(tax_year, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local list = PropertyQueries.all({ tax_year = tax_year }, user)
    local income, expense = 0, 0
    for _, p in ipairs(list.data) do
        income = income + (tonumber(p.income_total) or 0)
        expense = expense + (tonumber(p.expense_total) or 0)
    end
    return {
        tax_year = tax_year,
        property_count = list.total,
        income_total = income,
        expense_total = expense,
        profit = income - expense,
        properties = list.data,
    }
end

return PropertyQueries
