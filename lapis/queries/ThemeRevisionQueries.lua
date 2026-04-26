--[[
    Theme Revision Queries
    ======================

    Append-only history for theme edits. Every token/CSS update writes a row;
    the theme editor's revision panel reads from list(); revert() in the
    service layer reads a single revision via get() and writes the captured
    tokens back to theme_tokens.
]]

local db = require("lapis.db")

local ThemeRevisionQueries = {}

local MAX_KEEP = 50 -- soft cap per theme; older rows are pruned during create()

--- List revisions for a theme (most recent first). Always scope tenant access
-- via ThemeQueries.getByUuid before calling this.
function ThemeRevisionQueries.list(theme_id, params)
    params = params or {}
    local limit = tonumber(params.limit) or 25
    if limit < 1 then limit = 1 end
    if limit > 100 then limit = 100 end

    local rows = db.query([[
        SELECT r.id, r.uuid, r.theme_id, r.change_note, r.changed_by,
               r.created_at,
               u.email AS changed_by_email,
               u.first_name AS changed_by_first_name,
               u.last_name AS changed_by_last_name
        FROM theme_revisions r
        LEFT JOIN users u ON u.id = r.changed_by
        WHERE r.theme_id = ?
        ORDER BY r.created_at DESC, r.id DESC
        LIMIT ?
    ]], theme_id, limit)
    return rows or {}
end

--- Fetch a single revision by UUID (includes tokens + css; used for revert).
function ThemeRevisionQueries.getByUuid(uuid, theme_id)
    if not uuid or not theme_id then return nil end
    local rows = db.query([[
        SELECT * FROM theme_revisions
        WHERE uuid = ? AND theme_id = ?
        LIMIT 1
    ]], uuid, theme_id)
    return rows and rows[1] or nil
end

--- Append a new revision. Returns the inserted row. Prunes oldest rows beyond
-- MAX_KEEP so revision tables don't grow unbounded for noisy editors.
function ThemeRevisionQueries.create(theme_id, tokens_json, custom_css, user_id, note)
    if not theme_id then return nil end
    local rows = db.query([[
        INSERT INTO theme_revisions (theme_id, tokens, custom_css, changed_by, change_note)
        VALUES (?, ?::jsonb, ?, ?, ?)
        RETURNING *
    ]], theme_id, tokens_json or "{}", custom_css or "", user_id or db.NULL, note or "")

    -- Prune older rows beyond the cap
    db.query([[
        DELETE FROM theme_revisions
        WHERE theme_id = ?
          AND id NOT IN (
              SELECT id FROM theme_revisions
              WHERE theme_id = ?
              ORDER BY created_at DESC, id DESC
              LIMIT ?
          )
    ]], theme_id, theme_id, MAX_KEEP)

    return rows and rows[1] or nil
end

return ThemeRevisionQueries
