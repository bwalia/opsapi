--[[
    Business Queries — user_profile_entities rows of entity_type 'business'.

    A "business" is the drill-down unit of the Self-employment hub (one row
    per sole-trader trade). Each business carries:
      * a user-facing label (the business name shown in the hub list)
      * entity-scoped Profile Builder answers (context='business')
      * fixed-box SA103 values (business_line_values — see BusinessValueQueries)
      * Capital Allowances grid cells (business_ca_values)

    Mirrors PropertyQueries exactly: every read/write scoped to the
    authenticated user, soft-delete via is_archived, uuid-as-id responses,
    tax_audit_logs rows on mutation.
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local BusinessQueries = {}

local ENTITY_TYPE = "business"

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
-- List — optionally decorated with income/expense totals for one tax year so
-- the hub can render per-business figures in a single call.
-- ────────────────────────────────────────────────────────────────────────────
-- params: { tax_year?, include_archived? }
function BusinessQueries.all(params, user)
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

    -- Per-business totals for the requested tax year (one grouped query,
    -- not N+1). value_count spans ALL kinds so the hub can tell "untouched"
    -- from "no income yet". Values whose category was deactivated are
    -- excluded — the trade form no longer renders their box, so counting
    -- them would make the hub disagree with the form forever.
    local totals = {}
    if params.tax_year and params.tax_year ~= "" and #rows > 0 then
        local t_rows = db.query([[
            SELECT business_uuid, kind,
                   SUM(COALESCE(amount, 0)) AS total,
                   COUNT(*) AS value_count
            FROM business_line_values
            WHERE user_id = ? AND tax_year = ?
              AND category_key IN (
                  SELECT category_key FROM business_line_categories WHERE is_active = true
              )
            GROUP BY business_uuid, kind
        ]], internal_user_id, params.tax_year) or {}
        for _, t in ipairs(t_rows) do
            totals[t.business_uuid] = totals[t.business_uuid] or { income = 0, expense = 0, value_count = 0 }
            local bucket = totals[t.business_uuid]
            if t.kind == "income" then bucket.income = tonumber(t.total) or 0 end
            if t.kind == "expense" then bucket.expense = tonumber(t.total) or 0 end
            bucket.value_count = bucket.value_count + (tonumber(t.value_count) or 0)
        end
    end

    for _, r in ipairs(rows) do
        local t = totals[r.uuid]
        r.income_total = t and t.income or 0
        r.expense_total = t and t.expense or 0
        r.value_count = t and t.value_count or 0
        present(r)
    end
    return { data = rows, total = #rows }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Show (ownership-scoped). Also used as the ownership guard by the values /
-- CA-grid routes — keep the return shape stable.
-- ────────────────────────────────────────────────────────────────────────────
function BusinessQueries.show(business_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local rows = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ?
        LIMIT 1
    ]], business_uuid, internal_user_id, ENTITY_TYPE)
    if not rows or #rows == 0 then return nil end
    return present(rows[1])
end

-- ────────────────────────────────────────────────────────────────────────────
-- Create — label (the business name) is the only required field; everything
-- else is admin-driven questions + fixed-box values entered later.
-- ────────────────────────────────────────────────────────────────────────────
function BusinessQueries.create(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    if not data.label or data.label == "" then
        return nil, "label is required"
    end
    -- A JSON-object metadata_json decodes to a Lua table, which the db
    -- layer can't escape (unhandled 500) — encode it, matching the
    -- crm-accounts convention.
    if type(data.metadata_json) == "table" then
        data.metadata_json = cjson.encode(data.metadata_json)
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
        entity_type = "BUSINESS",
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present(row)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Update (label / metadata / display_order)
-- ────────────────────────────────────────────────────────────────────────────
function BusinessQueries.update(business_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    -- is_archived = false: every other write path 404s on archived
    -- businesses, so rename must too — otherwise an archived page looks
    -- half-alive (rename works, figures don't).
    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? AND is_archived = false LIMIT 1
    ]], business_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    if type(data.metadata_json) == "table" then
        data.metadata_json = cjson.encode(data.metadata_json)
    end

    local updates, args = {}, {}
    if data.label ~= nil then
        if data.label == "" then return nil, "label cannot be empty" end
        table.insert(updates, "label = ?"); table.insert(args, tostring(data.label))
    end
    if data.metadata_json ~= nil then
        -- "" clears (stored as NULL) — same contract as PropertyQueries.
        table.insert(updates, "metadata_json = ?")
        table.insert(args, data.metadata_json ~= "" and data.metadata_json or db.NULL)
    end
    if data.display_order ~= nil then
        table.insert(updates, "display_order = ?"); table.insert(args, tonumber(data.display_order) or 0)
    end
    if #updates == 0 then return present(old) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, business_uuid)
    table.insert(args, internal_user_id)
    db.query("UPDATE user_profile_entities SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM user_profile_entities WHERE uuid = ? LIMIT 1", business_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "BUSINESS",
        entity_id = business_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present(refreshed)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Archive (soft delete) — hard-deletes nothing: fixed-box values and CA
-- cells stay in place (they drop out of summaries because the business list
-- excludes archived entities), and entity-scoped answers keep history.
-- ────────────────────────────────────────────────────────────────────────────
function BusinessQueries.archive(business_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? LIMIT 1
    ]], business_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE user_profile_entities
           SET is_archived = true, archived_at = NOW(), updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], business_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "BUSINESS",
        entity_id = business_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- Summary — the hub's read-only strip: totals for one tax year plus the
-- per-business breakdown. profit is the naive income − expenses derivation
-- (same contract as the rental summary); the tax engine applies allowances
-- and adjustments properly downstream.
-- ────────────────────────────────────────────────────────────────────────────
function BusinessQueries.summary(tax_year, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local list = BusinessQueries.all({ tax_year = tax_year }, user)
    local income, expense = 0, 0
    for _, b in ipairs(list.data) do
        income = income + (tonumber(b.income_total) or 0)
        expense = expense + (tonumber(b.expense_total) or 0)
    end
    return {
        tax_year = tax_year,
        business_count = list.total,
        income_total = income,
        expense_total = expense,
        profit = income - expense,
        businesses = list.data,
    }
end

return BusinessQueries
