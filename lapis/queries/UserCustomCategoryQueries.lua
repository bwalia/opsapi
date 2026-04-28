-- User Custom Category Queries — issue #308 (user side)
--
-- This module owns the read/write surface for a USER managing their
-- own custom categories. Every function takes `user_uuid` so it scopes
-- automatically — there's no path here that lets one user see or
-- modify another user's customs.
--
-- The admin-side moderation surface (approve, reject, promote, list-
-- across-users) lives in CustomCategoryQueries.lua and is intentionally
-- separated so a user-facing endpoint can never accidentally call an
-- admin-privileged function.
--
-- Validation rules enforced here (mirrors what the route layer also
-- checks; defence in depth):
--   - Name length 2-100 chars
--   - Name not empty after trim
--   - Slug uniqueness per user (UNIQUE constraint enforces; we 422
--     before hitting it for a clean error code)
--   - Per-user count cap read from tax_app_settings.max_custom_categories_per_user
--     (admin-tunable, default 20)
--
-- The cap query reads through AppSettingsQueries which is TTL-cached,
-- so it doesn't hit the DB on every create.

local db = require("lapis.db")
local AppSettingsQueries = require("queries.AppSettingsQueries")

local UserCustomCategoryQueries = {}

local DEFAULT_MAX_CUSTOMS_PER_USER = 20

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Slugify a user-provided name into a `key_normalized` suitable for the
-- UNIQUE(user_uuid, key_normalized) constraint. Mirrors the conventions
-- the existing tax_categories.key uses (lowercase, underscores).
--
--   "Bee Supplies"             -> "bee_supplies"
--   "  Auto-Repair! "          -> "auto_repair"
--   "Café — équipement"        -> "caf_quipement"   (non-ASCII stripped)
--
-- We deliberately keep the slug ASCII-only to avoid weird URL/query
-- escaping issues downstream. The user's original `name` is preserved
-- in the `name` column for display.
local function slugify(input)
    if not input then return "" end
    local s = tostring(input):lower()
    -- collapse anything not [a-z0-9] into a single underscore
    s = s:gsub("[^a-z0-9]+", "_")
    -- trim leading/trailing underscores
    s = s:gsub("^_+", ""):gsub("_+$", "")
    -- collapse runs (defensive; the substitution above already does this)
    s = s:gsub("__+", "_")
    return s
end

local function trim(input)
    if not input then return "" end
    local s = tostring(input)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_max_per_user()
    local row = AppSettingsQueries.get("max_custom_categories_per_user")
    if row and type(row.setting_value) == "number" then
        return row.setting_value
    end
    -- Some JSONB drivers surface integers as strings — handle defensively
    if row and tonumber(row.setting_value) then
        return tonumber(row.setting_value)
    end
    return DEFAULT_MAX_CUSTOMS_PER_USER
end

local function feature_enabled()
    return AppSettingsQueries.get_bool("allow_user_custom_categories", false)
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- List the current user's customs. Includes promoted + rejected so the
-- user can see the full lifecycle of what they've submitted; the UI can
-- filter to active ones if desired.
function UserCustomCategoryQueries.list_for_user(user_uuid, params)
    params = params or {}
    -- Every column reference must be qualified with the `tucc` alias —
    -- both `tax_user_custom_categories` and `tax_categories` have an
    -- `is_active` column, and the LEFT JOIN below would make the
    -- unqualified reference ambiguous. Postgres rejects with:
    --   ERROR: column reference "is_active" is ambiguous
    local where = { "tucc.user_uuid = " .. db.escape_literal(user_uuid),
                    "tucc.is_active = true" }
    if params.status and params.status ~= "all" then
        table.insert(where, "tucc.status = " .. db.escape_literal(params.status))
    end
    local where_sql = table.concat(where, " AND ")

    return db.query([[
        SELECT
            tucc.id, tucc.uuid, tucc.user_uuid, tucc.namespace_id,
            tucc.name, tucc.key_normalized, tucc.status,
            tucc.mapped_to_category_id, tucc.mapped_to_hmrc_category_id,
            tucc.admin_notes, tucc.reviewed_at,
            tucc.promoted_to_category_id, tucc.promoted_at,
            tucc.usage_count, tucc.is_active,
            tucc.created_at, tucc.updated_at,
            mapped_cat.key   AS mapped_to_category_key,
            mapped_cat.label AS mapped_to_category_label
        FROM tax_user_custom_categories tucc
        LEFT JOIN tax_categories mapped_cat
               ON mapped_cat.id = tucc.mapped_to_category_id
        WHERE ]] .. where_sql .. [[
        ORDER BY tucc.created_at DESC
    ]]) or {}
end

function UserCustomCategoryQueries.get_for_user(user_uuid, custom_uuid)
    local rows = db.query([[
        SELECT
            tucc.*,
            mapped_cat.key   AS mapped_to_category_key,
            mapped_cat.label AS mapped_to_category_label
        FROM tax_user_custom_categories tucc
        LEFT JOIN tax_categories mapped_cat
               ON mapped_cat.id = tucc.mapped_to_category_id
        WHERE tucc.uuid = ? AND tucc.user_uuid = ? AND tucc.is_active = true
        LIMIT 1
    ]], custom_uuid, user_uuid)
    return rows and rows[1] or nil
end

function UserCustomCategoryQueries.count_active_for_user(user_uuid)
    -- Count only "active" customs from the user's perspective: pending +
    -- approved. Rejected/promoted shouldn't count toward the cap because
    -- the user can no longer use them.
    local result = db.query([[
        SELECT COUNT(*) AS n
        FROM tax_user_custom_categories
        WHERE user_uuid = ? AND is_active = TRUE
          AND status IN ('pending', 'approved')
    ]], user_uuid)
    return result and result[1] and tonumber(result[1].n) or 0
end

-- ---------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------

-- Create a new custom for `user_uuid`. Returns (row, nil) on success or
-- (nil, error_message, http_status) on failure so the route layer can map
-- to the right HTTP response.
function UserCustomCategoryQueries.create_for_user(user_uuid, namespace_id, params)
    params = params or {}

    if not feature_enabled() then
        return nil,
            "Custom categories are currently disabled. Ask your administrator to enable them in App Settings.",
            403
    end

    local raw_name = trim(params.name or "")
    if #raw_name < 2 then
        return nil, "Name must be at least 2 characters", 400
    end
    if #raw_name > 100 then
        return nil, "Name must be at most 100 characters", 400
    end

    local key = slugify(raw_name)
    if #key < 2 then
        return nil, "Name must contain at least 2 letters or digits", 400
    end
    if #key > 120 then
        -- key_normalized column is varchar(120); slugify shouldn't grow
        -- past that but be defensive
        key = key:sub(1, 120)
    end

    -- Per-user cap (admin-tunable via tax_app_settings).
    --
    -- Known race: if a user fires two concurrent POSTs from different
    -- tabs/devices we may briefly accept (cap+1) rows before either
    -- transaction commits its count. The check-then-insert window is
    -- tiny (single round trip) and the worst case is one extra row over
    -- the cap. Worth-fixing-only-when only if the cap becomes a
    -- compliance limit (it's a UX guardrail today). Mitigations available
    -- if needed:
    --   - SELECT ... FOR UPDATE on a per-user lock row
    --   - INSERT ... WHERE (SELECT COUNT(*) ...) < max in a CTE
    -- For now we accept the +/-1 imprecision.
    local existing = UserCustomCategoryQueries.count_active_for_user(user_uuid)
    local max_allowed = get_max_per_user()
    if existing >= max_allowed then
        return nil,
            ("You've reached the limit of %d custom categories. Delete or wait for admin moderation on existing ones."):format(max_allowed),
            422
    end

    -- Pre-flight uniqueness check for a clean error code (the UNIQUE
    -- constraint will also enforce, but raising IntegrityError gives a
    -- worse client experience).
    local dup = db.query([[
        SELECT id FROM tax_user_custom_categories
        WHERE user_uuid = ? AND key_normalized = ? AND is_active = TRUE
        LIMIT 1
    ]], user_uuid, key)
    if dup and #dup > 0 then
        return nil,
            ("You already have a custom category named %q."):format(raw_name),
            422
    end

    -- Use RETURNING * so the response includes the DB-generated columns
    -- (uuid via gen_random_uuid() default, the integer id, exact server
    -- timestamps). Without this `db.insert` returns only the affected-rows
    -- count and the frontend gets `undefined` for `name` / `uuid` /
    -- `status` — which would render an empty row in the picker.
    local result = db.insert("tax_user_custom_categories", {
        user_uuid = user_uuid,
        namespace_id = tonumber(namespace_id) or 0,
        name = raw_name,
        key_normalized = key,
        status = "pending",
        usage_count = 0,
        is_active = true,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })

    if not result or not result[1] then
        return nil, "Failed to create custom category", 500
    end
    return result[1], nil, 201
end

-- Rename a pending custom. Approved/rejected/promoted customs cannot be
-- renamed by the user — once admin has touched it, the name is part of
-- the moderation record and changing it would invalidate the audit trail.
function UserCustomCategoryQueries.rename_for_user(user_uuid, custom_uuid, new_name)
    local row = UserCustomCategoryQueries.get_for_user(user_uuid, custom_uuid)
    if not row then
        return nil, "Custom category not found", 404
    end
    if row.status ~= "pending" then
        return nil,
            "Only pending custom categories can be renamed",
            422
    end

    local raw_name = trim(new_name or "")
    if #raw_name < 2 then
        return nil, "Name must be at least 2 characters", 400
    end
    if #raw_name > 100 then
        return nil, "Name must be at most 100 characters", 400
    end

    local key = slugify(raw_name)
    if #key < 2 then
        return nil, "Name must contain at least 2 letters or digits", 400
    end

    if key ~= row.key_normalized then
        local dup = db.query([[
            SELECT id FROM tax_user_custom_categories
            WHERE user_uuid = ? AND key_normalized = ?
              AND uuid <> ? AND is_active = TRUE
            LIMIT 1
        ]], user_uuid, key, custom_uuid)
        if dup and #dup > 0 then
            return nil,
                ("You already have a custom category named %q."):format(raw_name),
                422
        end
    end

    db.update("tax_user_custom_categories", {
        name = raw_name,
        key_normalized = key,
        updated_at = db.raw("NOW()"),
    }, { uuid = custom_uuid, user_uuid = user_uuid })

    return UserCustomCategoryQueries.get_for_user(user_uuid, custom_uuid), nil, 200
end

-- Delete (soft, sets is_active = false) a pending custom. Refuses if any
-- transaction is currently tagged with it — the user must clear the
-- transaction tag first. Approved/promoted customs cannot be deleted by
-- the user; only admin can do that via the moderation surface.
function UserCustomCategoryQueries.delete_for_user(user_uuid, custom_uuid)
    local row = UserCustomCategoryQueries.get_for_user(user_uuid, custom_uuid)
    if not row then
        return nil, "Custom category not found", 404
    end
    if row.status ~= "pending" then
        return nil,
            "Only pending custom categories can be deleted by the user. " ..
            "Approved or promoted ones must be removed by an admin.",
            422
    end
    if tonumber(row.usage_count or 0) > 0 then
        return nil,
            "Cannot delete: " .. tostring(row.usage_count) ..
            " transaction(s) are currently tagged with this category. " ..
            "Re-categorise those transactions first.",
            422
    end

    db.update("tax_user_custom_categories", {
        is_active = false,
        updated_at = db.raw("NOW()"),
    }, { uuid = custom_uuid, user_uuid = user_uuid })

    return { uuid = custom_uuid, deleted = true }, nil, 200
end

return UserCustomCategoryQueries
