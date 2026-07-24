--[[
    Employment Queries — user_profile_entities rows of entity_type 'employment'.

    An "employment" is the drill-down unit of the Salary income hub — one
    row per PAYE job the taxpayer held during the year. Each carries:
      * a user-facing label (nickname / employer name shown in the hub list)
      * entity-scoped Profile Builder answers via user_profile_answers.entity_uuid
        (the 42 fields seeded by migration 758)

    Unlike properties and businesses, employments have NO line items — every
    figure is one answer against a Profile Builder question, so there's no
    parallel to property_line_items / business_line_values here. Deliberately
    kept separate from PropertyQueries so this module never grows a
    "if entity_type == 'employment' then skip line items" shim.

    Every read/write is user-scoped. Soft-delete via is_archived so
    entity-scoped answers keep a resolvable parent for historical
    calculations.
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local EmploymentQueries = {}
local ENTITY_TYPE = "employment"
local AUDIT_LABEL = "EMPLOYMENT"

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
-- List — used by the hub. tax_year is accepted for API symmetry with the
-- other hubs but is ignored today: employments carry no per-year derived
-- totals (all figures are Profile Builder answers, not line-item sums).
-- ────────────────────────────────────────────────────────────────────────────
function EmploymentQueries.all(params, user)
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

    for _, r in ipairs(rows) do present(r) end
    return { data = rows, total = #rows }
end

function EmploymentQueries.show(employment_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local rows = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ?
        LIMIT 1
    ]], employment_uuid, internal_user_id, ENTITY_TYPE)
    if not rows or #rows == 0 then return nil end
    return present(rows[1])
end

function EmploymentQueries.create(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    if not data.label or data.label == "" then
        return nil, "label is required"
    end

    local uuid = Global.generateUUID()
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
        entity_type = AUDIT_LABEL,
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present(row)
end

function EmploymentQueries.update(employment_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? LIMIT 1
    ]], employment_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    local updates, args = {}, {}
    if data.label ~= nil then
        if data.label == "" then return nil, "label cannot be empty" end
        table.insert(updates, "label = ?"); table.insert(args, tostring(data.label))
    end
    if data.metadata_json ~= nil then
        table.insert(updates, "metadata_json = ?")
        table.insert(args, data.metadata_json ~= "" and data.metadata_json or db.NULL)
    end
    if data.display_order ~= nil then
        table.insert(updates, "display_order = ?"); table.insert(args, tonumber(data.display_order) or 0)
    end
    if #updates == 0 then return present(old) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, employment_uuid)
    table.insert(args, internal_user_id)
    db.query("UPDATE user_profile_entities SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM user_profile_entities WHERE uuid = ? LIMIT 1", employment_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = AUDIT_LABEL,
        entity_id = employment_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present(refreshed)
end

-- Soft-delete. Entity-scoped answers are LEFT in place so historical
-- calculations for prior tax years remain reproducible (matches the
-- Property / Business archive contract).
function EmploymentQueries.archive(employment_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? LIMIT 1
    ]], employment_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE user_profile_entities
           SET is_archived = true, archived_at = NOW(), updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], employment_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = AUDIT_LABEL,
        entity_id = employment_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

return EmploymentQueries
