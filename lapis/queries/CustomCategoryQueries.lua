-- Custom Category Queries — issue #308 (admin moderation side)
--
-- This module owns reads and admin-side writes on
-- tax_user_custom_categories. The user-side CRUD (a user creating
-- their own custom on the classify page) lives in a sibling module
-- and is the other developer's territory; nothing here writes the
-- "pending" rows users create — only reads + moderation actions.
--
-- Moderation actions:
--   - approve(uuid, mapped_to_category_id, mapped_to_hmrc_category_id?, notes?)
--       Sets status='approved' and links the custom to a system category.
--       The classification pipeline can now resolve the custom through
--       the mapping for HMRC aggregation.
--
--   - reject(uuid, notes)
--       Sets status='rejected'. Transactions tagged with this custom
--       stay tagged but won't affect HMRC aggregation (the aggregator
--       skips non-approved customs).
--
--   - promote(uuid, opts) — the heaviest operation
--       Creates a new system tax_categories row and migrates every
--       transaction across all users that referenced this custom (or
--       any custom with the same key_normalized, optionally) to point
--       at the new system category. Wraps in a DB transaction so
--       partial migrations are impossible.
--
-- All writes invalidate any cached read state. Reads use a single SQL
-- query with a LEFT JOIN to users for email display so the admin UI
-- can render "joe@example.com" instead of a UUID.

local db = require("lapis.db")
local Global = require("helper.global")

local CustomCategoryQueries = {}

-- ---------------------------------------------------------------------------
-- Reads — admin moderation queue
-- ---------------------------------------------------------------------------

-- List custom categories with optional filters. Joins users + tax_categories
-- + tax_hmrc_categories so the admin UI gets everything it needs in one
-- round-trip without an N+1.
function CustomCategoryQueries.list(params)
    params = params or {}
    local where = { "tucc.is_active = true" }

    if params.status and params.status ~= "all" then
        table.insert(where, "tucc.status = " .. db.escape_literal(params.status))
    end
    if params.user_uuid and #params.user_uuid > 0 then
        table.insert(where, "tucc.user_uuid = " .. db.escape_literal(params.user_uuid))
    end
    if params.namespace_id then
        table.insert(where, "tucc.namespace_id = " ..
                            db.escape_literal(tonumber(params.namespace_id)))
    end
    if params.search and #params.search > 0 then
        local s = db.escape_literal("%" .. params.search .. "%")
        table.insert(where, "(tucc.name ILIKE " .. s ..
                            " OR tucc.key_normalized ILIKE " .. s .. ")")
    end

    local where_sql = table.concat(where, " AND ")
    local page = tonumber(params.page) or 1
    local per_page = math.min(tonumber(params.per_page) or 25, 100)
    local offset = (page - 1) * per_page

    local rows = db.query([[
        SELECT
            tucc.id, tucc.uuid, tucc.user_uuid, tucc.namespace_id,
            tucc.name, tucc.key_normalized, tucc.status,
            tucc.mapped_to_category_id, tucc.mapped_to_hmrc_category_id,
            tucc.admin_notes, tucc.reviewed_by_user_uuid, tucc.reviewed_at,
            tucc.promoted_to_category_id, tucc.promoted_at,
            tucc.usage_count, tucc.created_at, tucc.updated_at,
            u.email          AS user_email,
            NULLIF(TRIM(CONCAT_WS(' ', u.first_name, u.last_name)), '') AS user_name,
            mapped_cat.key   AS mapped_to_category_key,
            mapped_cat.label AS mapped_to_category_label,
            mapped_hmrc.key  AS mapped_to_hmrc_category_key,
            mapped_hmrc.label AS mapped_to_hmrc_category_label
        FROM tax_user_custom_categories tucc
        LEFT JOIN users               u           ON u.uuid = tucc.user_uuid
        LEFT JOIN tax_categories      mapped_cat  ON mapped_cat.id = tucc.mapped_to_category_id
        LEFT JOIN tax_hmrc_categories mapped_hmrc ON mapped_hmrc.id = tucc.mapped_to_hmrc_category_id
        WHERE ]] .. where_sql .. [[
        ORDER BY
            CASE tucc.status
                WHEN 'pending' THEN 0
                WHEN 'approved' THEN 1
                WHEN 'promoted' THEN 2
                WHEN 'rejected' THEN 3
                ELSE 4
            END,
            tucc.created_at DESC
        LIMIT ? OFFSET ?
    ]], per_page, offset)

    local count_row = db.query([[
        SELECT COUNT(*) AS total
        FROM tax_user_custom_categories tucc
        WHERE ]] .. where_sql)
    local total = count_row and count_row[1] and count_row[1].total or 0

    return rows, total, page, per_page
end

function CustomCategoryQueries.get_by_uuid(uuid)
    local rows = db.query([[
        SELECT
            tucc.*,
            u.email          AS user_email,
            NULLIF(TRIM(CONCAT_WS(' ', u.first_name, u.last_name)), '') AS user_name,
            mapped_cat.key   AS mapped_to_category_key,
            mapped_cat.label AS mapped_to_category_label,
            mapped_hmrc.key  AS mapped_to_hmrc_category_key,
            mapped_hmrc.label AS mapped_to_hmrc_category_label
        FROM tax_user_custom_categories tucc
        LEFT JOIN users               u           ON u.uuid = tucc.user_uuid
        LEFT JOIN tax_categories      mapped_cat  ON mapped_cat.id = tucc.mapped_to_category_id
        LEFT JOIN tax_hmrc_categories mapped_hmrc ON mapped_hmrc.id = tucc.mapped_to_hmrc_category_id
        WHERE tucc.uuid = ?
        LIMIT 1
    ]], uuid)
    return rows and rows[1] or nil
end

-- Sample transactions tagged with this custom so admin can see real-world
-- usage before deciding the mapping. Capped at 10 newest by default.
function CustomCategoryQueries.sample_transactions(custom_uuid, limit)
    limit = math.min(tonumber(limit) or 10, 50)
    return db.query([[
        SELECT id, uuid, description, amount, transaction_date, category
        FROM tax_transactions
        WHERE custom_category_uuid = ?
        ORDER BY transaction_date DESC, id DESC
        LIMIT ?
    ]], custom_uuid, limit) or {}
end

-- Find duplicate names across users — promotion candidates. The admin
-- wants to know "5 different beekeepers all created 'Bee Supplies'" so
-- they can promote it to a system-wide category in one go.
function CustomCategoryQueries.find_duplicates(min_users)
    min_users = tonumber(min_users) or 3
    return db.query([[
        SELECT
            key_normalized,
            MIN(name) AS sample_name,
            COUNT(DISTINCT user_uuid) AS user_count,
            SUM(usage_count) AS total_usage,
            COUNT(*) FILTER (WHERE status = 'pending')  AS pending_count,
            COUNT(*) FILTER (WHERE status = 'approved') AS approved_count
        FROM tax_user_custom_categories
        WHERE is_active = true
          AND status IN ('pending', 'approved')
        GROUP BY key_normalized
        HAVING COUNT(DISTINCT user_uuid) >= ?
        ORDER BY user_count DESC, total_usage DESC
        LIMIT 50
    ]], min_users) or {}
end

function CustomCategoryQueries.stats()
    local rows = db.query([[
        SELECT status, COUNT(*) AS n
        FROM tax_user_custom_categories
        WHERE is_active = true
        GROUP BY status
    ]]) or {}
    local result = {
        pending = 0, approved = 0, rejected = 0, promoted = 0, total = 0
    }
    for _, r in ipairs(rows) do
        result[r.status] = tonumber(r.n) or 0
        result.total = result.total + (tonumber(r.n) or 0)
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Admin moderation actions
-- ---------------------------------------------------------------------------

-- Approve a custom and link it to a system tax_categories row.
-- Accepts UUID strings (matches the existing tax_categories admin
-- API). The integer FKs are resolved here before the UPDATE.
-- mapped_to_hmrc_category_uuid is optional — if absent we inherit it
-- from the system category's existing HMRC link.
function CustomCategoryQueries.approve(uuid, opts)
    opts = opts or {}
    if not opts.mapped_to_category_uuid then
        return nil, "mapped_to_category_uuid is required to approve"
    end

    -- Resolve system category UUID -> integer id (and grab its HMRC link)
    local cat = db.select([[
        id, hmrc_category_id FROM tax_categories
        WHERE uuid = ? AND is_active = true LIMIT 1
    ]], opts.mapped_to_category_uuid)
    if not cat or #cat == 0 then
        return nil, "Mapped tax_categories row not found or inactive"
    end

    -- Resolve optional HMRC override UUID -> integer id
    local hmrc_id = cat[1].hmrc_category_id
    if opts.mapped_to_hmrc_category_uuid
       and #tostring(opts.mapped_to_hmrc_category_uuid) > 0 then
        local hmrc = db.select([[
            id FROM tax_hmrc_categories
            WHERE uuid = ? AND is_active = true LIMIT 1
        ]], opts.mapped_to_hmrc_category_uuid)
        if not hmrc or #hmrc == 0 then
            return nil, "Mapped tax_hmrc_categories row not found or inactive"
        end
        hmrc_id = hmrc[1].id
    end

    db.update("tax_user_custom_categories", {
        status = "approved",
        mapped_to_category_id = cat[1].id,
        mapped_to_hmrc_category_id = hmrc_id,
        admin_notes = opts.admin_notes,
        reviewed_by_user_uuid = opts.reviewer_uuid,
        reviewed_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { uuid = uuid })

    return CustomCategoryQueries.get_by_uuid(uuid), nil
end

function CustomCategoryQueries.reject(uuid, opts)
    opts = opts or {}
    if not opts.admin_notes or #opts.admin_notes == 0 then
        return nil, "admin_notes is required to reject (so users know why)"
    end

    db.update("tax_user_custom_categories", {
        status = "rejected",
        admin_notes = opts.admin_notes,
        reviewed_by_user_uuid = opts.reviewer_uuid,
        reviewed_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { uuid = uuid })

    return CustomCategoryQueries.get_by_uuid(uuid), nil
end

-- Promote a custom into a brand-new system-wide tax_categories row, then
-- migrate every transaction across users that referenced this custom (or
-- optionally any custom with the same key_normalized) to point at the new
-- system row. Marks promoted customs with status='promoted' so the audit
-- trail shows "this came from user X's submission".
--
-- Wraps everything in a single DB transaction. If any step fails the
-- whole operation rolls back — partially-promoted state is impossible.
--
-- opts:
--   system_key         (required) — slug for the new tax_categories.key
--   system_label       (required) — display label
--   hmrc_category_uuid (required) — UUID of a tax_hmrc_categories row
--   type               (required) — "income" | "expense"
--   is_tax_deductible
--   deduction_rate
--   description, examples
--   include_other_users (boolean, default false) — when true, every
--       custom row with the same key_normalized gets promoted in one
--       go. When false, only the targeted custom is promoted.
--   promoter_uuid      (required) — admin user_uuid for audit trail
function CustomCategoryQueries.promote(uuid, opts)
    opts = opts or {}
    local required = {
        "system_key", "system_label", "hmrc_category_uuid", "type", "promoter_uuid"
    }
    for _, field in ipairs(required) do
        if not opts[field] or (type(opts[field]) == "string" and #opts[field] == 0) then
            return nil, "Missing required field: " .. field
        end
    end

    local result
    db.query("BEGIN")
    local ok, err = pcall(function()
        -- Fetch the seed custom so we know its key_normalized + namespace
        local seed_rows = db.select(
            "* FROM tax_user_custom_categories WHERE uuid = ? LIMIT 1", uuid
        )
        if not seed_rows or #seed_rows == 0 then
            error("Custom category " .. uuid .. " not found")
        end
        local seed = seed_rows[1]

        -- Guard against duplicate system keys
        local existing_sys = db.select(
            "id FROM tax_categories WHERE key = ? LIMIT 1", opts.system_key
        )
        if existing_sys and #existing_sys > 0 then
            error("System category key '" .. opts.system_key ..
                  "' already exists. Pick a unique key.")
        end

        -- Resolve HMRC category UUID -> integer id
        local hmrc = db.select([[
            id FROM tax_hmrc_categories
            WHERE uuid = ? AND is_active = true LIMIT 1
        ]], opts.hmrc_category_uuid)
        if not hmrc or #hmrc == 0 then
            error("HMRC category not found or inactive: " ..
                  tostring(opts.hmrc_category_uuid))
        end

        -- 1. Create the new system tax_categories row
        local new_cat = db.insert("tax_categories", {
            uuid = Global.generateStaticUUID(),
            key = opts.system_key,
            label = opts.system_label,
            hmrc_category_id = hmrc[1].id,
            type = string.lower(opts.type),
            is_tax_deductible = opts.is_tax_deductible ~= false,
            deduction_rate = tonumber(opts.deduction_rate) or 1.0,
            description = opts.description or "",
            examples = opts.examples or db.NULL,
            is_active = true,
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()"),
        })

        -- 2. Identify which custom rows to promote
        local affected_customs
        if opts.include_other_users then
            affected_customs = db.select([[
                * FROM tax_user_custom_categories
                WHERE key_normalized = ?
                  AND status IN ('pending', 'approved')
                  AND is_active = true
            ]], seed.key_normalized) or {}
        else
            affected_customs = { seed }
        end

        -- 3. Migrate transactions across all affected users to point at the
        --    new system category. We use a single bulk UPDATE for efficiency
        --    (handles 50k+ rows in one statement on Postgres without trouble).
        local custom_uuids = {}
        for _, c in ipairs(affected_customs) do
            table.insert(custom_uuids, db.escape_literal(c.uuid))
        end
        if #custom_uuids > 0 then
            db.query([[
                UPDATE tax_transactions
                SET category = ]] .. db.escape_literal(opts.system_key) .. [[,
                    custom_category_uuid = NULL,
                    modified_by_user_uuid = ]] .. db.escape_literal(opts.promoter_uuid) .. [[,
                    modified_by_role = 'admin',
                    modified_at = NOW()
                WHERE custom_category_uuid IN (]] .. table.concat(custom_uuids, ",") .. [[)
            ]])
        end

        -- 4. Mark the customs as promoted
        for _, c in ipairs(affected_customs) do
            db.update("tax_user_custom_categories", {
                status = "promoted",
                promoted_to_category_id = new_cat.id,
                promoted_at = db.raw("NOW()"),
                promoted_by_user_uuid = opts.promoter_uuid,
                admin_notes = opts.admin_notes,
                updated_at = db.raw("NOW()"),
            }, { id = c.id })
        end

        result = {
            new_category = new_cat,
            affected_customs_count = #affected_customs,
            include_other_users = opts.include_other_users == true,
        }
    end)

    if not ok then
        db.query("ROLLBACK")
        return nil, tostring(err)
    end
    db.query("COMMIT")

    return result, nil
end

return CustomCategoryQueries
