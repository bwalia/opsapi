--[[
    Theme Queries
    =============

    Namespace-scoped data access for the theme catalog. All list/get functions
    enforce tenant isolation at the SQL level (WHERE namespace_id = ? OR
    platform-visible condition). Platform presets (namespace_id IS NULL,
    is_system = true) are readable by every namespace.

    This module is read-only. All mutations go through lib.theme-service so
    validation, sanitisation, revision tracking, and activation invariants
    are applied in one place.
]]

local db = require("lapis.db")

local ThemeQueries = {}

-- =============================================================================
-- Internal helpers
-- =============================================================================

local function clamp_page(params)
    local page = tonumber(params and params.page) or 1
    local per_page = tonumber(params and params.per_page) or 50
    if page < 1 then page = 1 end
    if per_page < 1 then per_page = 1 end
    if per_page > 200 then per_page = 200 end
    return page, per_page
end

--------------------------------------------------------------------------------
-- List themes visible to (namespace_id, project_code): the namespace's own
-- themes plus platform presets. Optionally filter by query, visibility, or
-- include deleted.
--------------------------------------------------------------------------------
function ThemeQueries.list(namespace_id, project_code, params)
    params = params or {}
    local page, per_page = clamp_page(params)
    local offset = (page - 1) * per_page

    local where = {
        "t.project_code = ?",
        "(t.namespace_id = ? OR (t.namespace_id IS NULL AND t.is_system = true))",
    }
    local vals = { project_code, namespace_id }

    if not params.include_deleted then
        table.insert(where, "t.deleted_at IS NULL")
    end

    if params.q and params.q ~= "" then
        table.insert(where, "(t.name ILIKE ? OR t.slug ILIKE ? OR t.description ILIKE ?)")
        local like = "%" .. params.q .. "%"
        table.insert(vals, like); table.insert(vals, like); table.insert(vals, like)
    end

    if params.visibility and params.visibility ~= "" then
        table.insert(where, "t.visibility = ?")
        table.insert(vals, params.visibility)
    end

    if params.only_system == true then
        table.insert(where, "t.is_system = true")
    elseif params.only_owned == true then
        table.insert(where, "t.namespace_id = ?")
        table.insert(vals, namespace_id)
    end

    local where_clause = table.concat(where, " AND ")

    local count_sql = "SELECT COUNT(*) AS total FROM themes t WHERE " .. where_clause
    local count_rows = db.query(count_sql, unpack(vals))
    local total = tonumber(count_rows and count_rows[1] and count_rows[1].total) or 0

    -- Active theme flag for display (left join on namespace_active_themes)
    local data_vals = {}
    for _, v in ipairs(vals) do table.insert(data_vals, v) end
    table.insert(data_vals, namespace_id)
    table.insert(data_vals, project_code)
    table.insert(data_vals, per_page)
    table.insert(data_vals, offset)

    local data_sql = [[
        SELECT t.*,
               CASE WHEN nat.theme_id IS NOT NULL THEN true ELSE false END AS is_active
        FROM themes t
        LEFT JOIN namespace_active_themes nat
               ON nat.theme_id = t.id
              AND nat.namespace_id = ?
              AND nat.project_code = ?
        WHERE ]] .. where_clause .. [[
        ORDER BY
            CASE WHEN nat.theme_id IS NOT NULL THEN 0 ELSE 1 END,
            t.is_system DESC,
            t.updated_at DESC
        LIMIT ? OFFSET ?
    ]]

    -- Reorder value slots: the LEFT JOIN placeholders come BEFORE the WHERE
    -- placeholders in the SQL above, so rebuild the final value list.
    local ordered = { namespace_id, project_code }
    for _, v in ipairs(vals) do table.insert(ordered, v) end
    table.insert(ordered, per_page)
    table.insert(ordered, offset)

    local rows = db.query(data_sql, unpack(ordered))

    return {
        items = rows or {},
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page),
        },
    }
end

--------------------------------------------------------------------------------
-- Fetch a single theme by UUID, scoped to what this namespace can see.
-- Returns nil if not found or not accessible.
--------------------------------------------------------------------------------
function ThemeQueries.getByUuid(uuid, namespace_id)
    if not uuid or uuid == "" then return nil end

    local rows = db.query([[
        SELECT t.*
        FROM themes t
        WHERE t.uuid = ?
          AND t.deleted_at IS NULL
          AND (t.namespace_id = ? OR (t.namespace_id IS NULL AND t.is_system = true)
               OR t.visibility = 'public')
        LIMIT 1
    ]], uuid, namespace_id)

    return rows and rows[1] or nil
end

--------------------------------------------------------------------------------
-- Fetch by internal id (service-layer use only; callers must have already
-- confirmed tenant access).
--------------------------------------------------------------------------------
function ThemeQueries.getById(id)
    if not id then return nil end
    local rows = db.query("SELECT * FROM themes WHERE id = ? AND deleted_at IS NULL LIMIT 1", id)
    return rows and rows[1] or nil
end

--------------------------------------------------------------------------------
-- Fetch a theme's token row. Returns nil if none (caller should treat as empty
-- overrides and fall back to defaults via the resolver).
--------------------------------------------------------------------------------
function ThemeQueries.getTokens(theme_id)
    if not theme_id then return nil end
    local rows = db.query("SELECT * FROM theme_tokens WHERE theme_id = ? LIMIT 1", theme_id)
    return rows and rows[1] or nil
end

--------------------------------------------------------------------------------
-- List platform presets for the given project_code. Used by the /presets
-- endpoint and the "start from preset" editor wizard.
--------------------------------------------------------------------------------
function ThemeQueries.listPresets(project_code)
    local rows = db.query([[
        SELECT * FROM themes
        WHERE namespace_id IS NULL
          AND is_system = true
          AND project_code = ?
          AND deleted_at IS NULL
        ORDER BY id ASC
    ]], project_code)
    return rows or {}
end

--------------------------------------------------------------------------------
-- List publicly published themes (marketplace). Pagination + optional search.
--------------------------------------------------------------------------------
function ThemeQueries.listMarketplace(project_code, params)
    params = params or {}
    local page, per_page = clamp_page(params)
    local offset = (page - 1) * per_page

    local where = { "project_code = ?", "visibility = 'public'", "deleted_at IS NULL" }
    local vals = { project_code }

    if params.q and params.q ~= "" then
        table.insert(where, "(name ILIKE ? OR description ILIKE ?)")
        local like = "%" .. params.q .. "%"
        table.insert(vals, like); table.insert(vals, like)
    end

    local where_clause = table.concat(where, " AND ")

    local count_rows = db.query("SELECT COUNT(*) AS total FROM themes WHERE " .. where_clause, unpack(vals))
    local total = tonumber(count_rows and count_rows[1] and count_rows[1].total) or 0

    local data_vals = {}
    for _, v in ipairs(vals) do table.insert(data_vals, v) end
    table.insert(data_vals, per_page)
    table.insert(data_vals, offset)

    local rows = db.query([[
        SELECT * FROM themes
        WHERE ]] .. where_clause .. [[
        ORDER BY updated_at DESC
        LIMIT ? OFFSET ?
    ]], unpack(data_vals))

    return {
        items = rows or {},
        meta = {
            total = total, page = page, per_page = per_page,
            total_pages = math.ceil(total / per_page),
        },
    }
end

--------------------------------------------------------------------------------
-- Resolve the ACTIVE theme for (namespace, project_code). Returns a combined
-- row with the theme + its tokens, or nil if none active. Callers should fall
-- back to listPresets()[1] if nil is returned.
--------------------------------------------------------------------------------
function ThemeQueries.getActive(namespace_id, project_code)
    if not namespace_id or not project_code then return nil end
    local rows = db.query([[
        SELECT t.*,
               tt.tokens AS tokens,
               tt.custom_css AS custom_css,
               tt.updated_at AS tokens_updated_at
        FROM namespace_active_themes nat
        INNER JOIN themes t ON t.id = nat.theme_id
        LEFT JOIN theme_tokens tt ON tt.theme_id = t.id
        WHERE nat.namespace_id = ?
          AND nat.project_code = ?
          AND t.deleted_at IS NULL
        LIMIT 1
    ]], namespace_id, project_code)
    return rows and rows[1] or nil
end

--------------------------------------------------------------------------------
-- Fallback for namespaces with no active theme: the first platform preset.
-- Used by the renderer to always have something to serve at /active/styles.css.
--------------------------------------------------------------------------------
function ThemeQueries.getDefaultPreset(project_code)
    local rows = db.query([[
        SELECT t.*,
               tt.tokens AS tokens,
               tt.custom_css AS custom_css,
               tt.updated_at AS tokens_updated_at
        FROM themes t
        LEFT JOIN theme_tokens tt ON tt.theme_id = t.id
        WHERE t.namespace_id IS NULL
          AND t.is_system = true
          AND t.project_code = ?
          AND t.deleted_at IS NULL
        ORDER BY t.id ASC
        LIMIT 1
    ]], project_code)
    return rows and rows[1] or nil
end

--------------------------------------------------------------------------------
-- Lookup a theme assignment row (without joining the theme itself).
--------------------------------------------------------------------------------
function ThemeQueries.getActiveAssignment(namespace_id, project_code)
    local rows = db.query([[
        SELECT * FROM namespace_active_themes
        WHERE namespace_id = ? AND project_code = ?
        LIMIT 1
    ]], namespace_id, project_code)
    return rows and rows[1] or nil
end

return ThemeQueries
