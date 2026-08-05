--[[
    Property Line Queries — property_line_items + property_line_categories.

    Line items are the user's per-property income/expense rows (description +
    admin-managed category + amount, per tax year). The category catalogue
    drives the dropdowns AND server-side validation, mirroring how
    income_types backs my_incomes.

    Ownership: every line item is scoped to the authenticated user AND must
    reference one of their non-archived properties on create. Category keys
    are stored as plain varchar (no FK) so retiring a category never breaks
    history; updates grandfather an unchanged key the same way my-incomes
    grandfathers a disabled income_type.
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local PropertyLineQueries = {}

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

local function present(row)
    row.id = row.uuid
    row.user_id = nil
    return row
end

-- ────────────────────────────────────────────────────────────────────────────
-- Catalogue
-- ────────────────────────────────────────────────────────────────────────────
-- schedule: which surface's catalogue — 'uk_property' (default, the UK
-- rental hub) or 'overseas_property' (Land and property abroad). The
-- default keeps every pre-existing caller's behaviour unchanged.
function PropertyLineQueries.categories(schedule)
    local rows = db.query([[
        SELECT uuid, kind, category_key, label, description, hmrc_mapping, display_order
        FROM property_line_categories
        WHERE is_active = true AND schedule = ?
        ORDER BY kind ASC, display_order ASC, label ASC
    ]], schedule or "uk_property") or {}
    return rows
end

-- Set of active keys for one kind — validation helper for routes.
function PropertyLineQueries.active_keys(kind, schedule)
    local rows = db.query([[
        SELECT category_key FROM property_line_categories
        WHERE is_active = true AND kind = ? AND schedule = ?
    ]], kind, schedule or "uk_property") or {}
    local set = {}
    for _, r in ipairs(rows) do set[r.category_key] = true end
    return set
end

-- ────────────────────────────────────────────────────────────────────────────
-- List for one property
-- ────────────────────────────────────────────────────────────────────────────
-- params: { tax_year?, kind?, include_archived? }
function PropertyLineQueries.all(property_uuid, params, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local where = { "user_id = ?", "property_uuid = ?" }
    local args = { internal_user_id, property_uuid }
    if params.tax_year and params.tax_year ~= "" then
        table.insert(where, "tax_year = ?"); table.insert(args, params.tax_year)
    end
    if params.kind and params.kind ~= "" then
        table.insert(where, "kind = ?"); table.insert(args, params.kind)
    end
    if params.include_archived ~= "true" and params.include_archived ~= true then
        table.insert(where, "is_archived = false")
    end

    local rows = db.query(
        "SELECT * FROM property_line_items WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY kind ASC, created_at ASC",
        unpack(args)) or {}
    for _, r in ipairs(rows) do present(r) end
    return { data = rows, total = #rows }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Create — route layer validates kind/category/amount/tax_year and property
-- ownership; re-checked defensively here.
-- ────────────────────────────────────────────────────────────────────────────
-- entity_type: 'property' (default) or 'overseas_property' — the parent
-- entity the line hangs off. Overseas lines also allow the extra kinds
-- ('finance_cost', 'adjustment') their catalogue defines.
function PropertyLineQueries.create(property_uuid, data, user, entity_type)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    -- The property must exist, belong to this user, and not be archived.
    local prop = db.query([[
        SELECT uuid, namespace_id FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? AND is_archived = false
        LIMIT 1
    ]], property_uuid, internal_user_id, entity_type or "property")
    if not prop or #prop == 0 then return nil, "Property not found" end

    if not data.amount or tonumber(data.amount) == nil or tonumber(data.amount) <= 0 then
        return nil, "amount must be a positive number"
    end
    local VALID_KINDS = { income = true, expense = true, finance_cost = true, adjustment = true }
    if not VALID_KINDS[data.kind] then
        return nil, "kind must be one of income, expense, finance_cost, adjustment"
    end
    if not data.category_key or data.category_key == "" then
        return nil, "category_key is required"
    end
    if not data.tax_year or data.tax_year == "" then
        return nil, "tax_year is required"
    end

    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO property_line_items
            (uuid, user_id, namespace_id, property_uuid, tax_year, kind, category_key, description, amount, disallowable_amount, is_archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, false, NOW(), NOW())
    ]],
        uuid,
        internal_user_id,
        prop[1].namespace_id or db.NULL,
        property_uuid,
        data.tax_year,
        data.kind,
        data.category_key,
        data.description or db.NULL,
        tonumber(data.amount),
        tonumber(data.disallowable_amount) or db.NULL
    )
    local row = db.query("SELECT * FROM property_line_items WHERE uuid = ? LIMIT 1", uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PROPERTY_LINE",
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present(row)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Show / Update / Archive — addressed by line uuid (globally unique), always
-- ownership-scoped.
-- ────────────────────────────────────────────────────────────────────────────
function PropertyLineQueries.show(line_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end
    local rows = db.query([[
        SELECT * FROM property_line_items WHERE uuid = ? AND user_id = ? LIMIT 1
    ]], line_uuid, internal_user_id)
    if not rows or #rows == 0 then return nil end
    return present(rows[1])
end

function PropertyLineQueries.update(line_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM property_line_items WHERE uuid = ? AND user_id = ? LIMIT 1
    ]], line_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    local updates, args = {}, {}
    if data.amount ~= nil then
        local n = tonumber(data.amount)
        if not n or n <= 0 then return nil, "amount must be a positive number" end
        table.insert(updates, "amount = ?"); table.insert(args, n)
    end
    if data.disallowable_amount ~= nil then
        table.insert(updates, "disallowable_amount = ?")
        table.insert(args, tonumber(data.disallowable_amount) or db.NULL)
    end
    if data.category_key then
        table.insert(updates, "category_key = ?"); table.insert(args, data.category_key)
    end
    if data.tax_year then
        table.insert(updates, "tax_year = ?"); table.insert(args, data.tax_year)
    end
    if data.description ~= nil then
        -- "" clears the description (stored as NULL, matching create):
        -- JSON null can't express "clear" here because body parsing strips
        -- cjson.null to keep it out of the SQL layer.
        table.insert(updates, "description = ?")
        table.insert(args, data.description ~= "" and data.description or db.NULL)
    end
    if #updates == 0 then return present(old) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, line_uuid)
    table.insert(args, internal_user_id)
    db.query("UPDATE property_line_items SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM property_line_items WHERE uuid = ? LIMIT 1", line_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PROPERTY_LINE",
        entity_id = line_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present(refreshed)
end

function PropertyLineQueries.archive(line_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM property_line_items WHERE uuid = ? AND user_id = ? LIMIT 1
    ]], line_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE property_line_items
           SET is_archived = true, archived_at = NOW(), archived_by = ?, updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], internal_user_id, line_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "PROPERTY_LINE",
        entity_id = line_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

return PropertyLineQueries
