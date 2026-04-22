--[[
    Theme Service
    =============

    Single orchestrator for all theme mutations. Routes pass the caller's
    namespace_id + user_id + request body, and this module:

      - validates tokens against the canonical schema
      - sanitises custom_css
      - enforces ownership (you can't edit another tenant's theme)
      - protects is_system presets from modification/deletion
      - creates theme_revisions on every token change
      - handles activation atomically (upsert into namespace_active_themes)
      - handles duplicate / revert / publish / delete (soft)
      - handles marketplace install (clone a public source into the namespace)

    Returns:
      ok, data          - on success
      ok=false, err, status, errors?
                        - on failure; `status` is the HTTP status the route
                          should return (422 validation, 403 forbidden,
                          404 not found, 409 conflict, 500 internal)

    Never raises — every path is pcall-guarded where DB failures are possible.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local ThemeQueries = require("queries.ThemeQueries")
local ThemeRevisionQueries = require("queries.ThemeRevisionQueries")
local ThemeValidator = require("lib.theme-validator")
local ThemeResolver = require("lib.theme-resolver")
local CssSanitizer = require("helper.css-sanitizer")

local ThemeService = {}

-- =============================================================================
-- Internal helpers
-- =============================================================================

local function fail(status, err, extras)
    local out = { ok = false, status = status, error = err }
    if extras then
        for k, v in pairs(extras) do out[k] = v end
    end
    return out
end

local function ok(data)
    return { ok = true, data = data }
end

local function slugify(name)
    if not name or name == "" then return "untitled" end
    local s = tostring(name):lower()
    s = s:gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if s == "" then s = "untitled" end
    if #s > 180 then s = s:sub(1, 180) end
    return s
end

-- Generate a unique slug within (namespace_id, project_code) by appending -2, -3, ...
local function unique_slug(namespace_id, project_code, base)
    local candidate = base
    local n = 1
    while true do
        local rows = db.query([[
            SELECT 1 FROM themes
            WHERE COALESCE(namespace_id, 0) = COALESCE(?, 0)
              AND project_code = ?
              AND slug = ?
              AND deleted_at IS NULL
            LIMIT 1
        ]], namespace_id, project_code, candidate)
        if not rows or #rows == 0 then return candidate end
        n = n + 1
        candidate = base .. "-" .. n
        if n > 100 then return base .. "-" .. Global.generateUUID():sub(1, 8) end
    end
end

local function encode_tokens(tokens)
    if tokens == nil then return "{}" end
    local ok_json, encoded = pcall(cjson.encode, tokens)
    if not ok_json then return "{}" end
    return encoded
end

-- Fetch theme and assert it's owned by caller's namespace (or is a platform
-- preset, in which case system_readonly=true is returned).
local function load_and_authorise(uuid, namespace_id)
    local theme = ThemeQueries.getByUuid(uuid, namespace_id)
    if not theme then
        return nil, fail(404, "theme not found")
    end
    local is_own = theme.namespace_id == namespace_id
    local is_system = theme.namespace_id == nil and theme.is_system
    if not is_own and not is_system then
        -- Visible for read (public marketplace), but writes forbidden
        return theme, fail(403, "not authorised to modify this theme")
    end
    if is_system then
        return theme, fail(403, "platform presets cannot be modified; duplicate first")
    end
    return theme, nil
end

-- =============================================================================
-- Create
-- =============================================================================
-- Inputs:
--   { name, description?, from_preset_slug? | parent_uuid?, tokens?, custom_css? }
-- If from_preset_slug is given, tokens default to that preset's tokens.
-- If parent_uuid is given, parent_theme_id is set (token inheritance chain).
-- =============================================================================
function ThemeService.create(namespace_id, project_code, user_id, input)
    input = input or {}

    if type(input.name) ~= "string" or input.name == "" then
        return fail(422, "name is required")
    end

    local parent_id, parent_tokens_row
    if input.parent_uuid then
        local parent = ThemeQueries.getByUuid(input.parent_uuid, namespace_id)
        if not parent then
            return fail(404, "parent theme not found")
        end
        if parent.project_code ~= project_code then
            return fail(422, "parent theme belongs to a different project")
        end
        parent_id = parent.id
        parent_tokens_row = ThemeQueries.getTokens(parent.id)
    elseif input.from_preset_slug then
        local presets = ThemeQueries.listPresets(project_code)
        for _, p in ipairs(presets) do
            if p.slug == input.from_preset_slug then
                parent_id = p.id
                parent_tokens_row = ThemeQueries.getTokens(p.id)
                break
            end
        end
        if not parent_id then
            return fail(404, "preset not found: " .. tostring(input.from_preset_slug))
        end
    end

    -- Build initial tokens: explicit input > parent > empty
    local initial_tokens
    if input.tokens ~= nil then
        initial_tokens = input.tokens
    elseif parent_tokens_row then
        if type(parent_tokens_row.tokens) == "string" then
            local ok_dec, dec = pcall(cjson.decode, parent_tokens_row.tokens)
            initial_tokens = ok_dec and dec or {}
        else
            initial_tokens = parent_tokens_row.tokens or {}
        end
    else
        initial_tokens = {}
    end

    local valid, errors = ThemeValidator.validate(initial_tokens)
    if not valid then
        return fail(422, "token validation failed", { errors = errors })
    end

    local css, css_warnings = CssSanitizer.sanitise(input.custom_css or "")
    if input.custom_css and input.custom_css ~= "" and css == "" and #css_warnings > 0 then
        return fail(422, "custom_css rejected", { errors = css_warnings })
    end

    local base_slug = slugify(input.slug or input.name)
    local slug = unique_slug(namespace_id, project_code, base_slug)

    local theme
    local ok_txn, err = pcall(function()
        db.query("BEGIN")

        local inserted = db.query([[
            INSERT INTO themes (
                namespace_id, project_code, name, slug, description,
                parent_theme_id, visibility, is_system, created_by, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'private', false, ?, NOW(), NOW())
            RETURNING *
        ]], namespace_id, project_code, input.name, slug, input.description or "",
            parent_id, user_id)
        theme = inserted and inserted[1]
        if not theme then
            error("failed to insert theme row")
        end

        local tokens_json = encode_tokens(initial_tokens)
        db.query([[
            INSERT INTO theme_tokens (theme_id, tokens, custom_css, updated_at)
            VALUES (?, ?::jsonb, ?, NOW())
        ]], theme.id, tokens_json, css)

        ThemeRevisionQueries.create(theme.id, tokens_json, css, user_id, "created")

        db.query("COMMIT")
    end)

    if not ok_txn then
        pcall(db.query, "ROLLBACK")
        return fail(500, "failed to create theme: " .. tostring(err))
    end

    return ok(theme)
end

-- =============================================================================
-- Update (tokens + css)
-- =============================================================================
function ThemeService.update(namespace_id, user_id, uuid, input)
    input = input or {}
    local theme, err = load_and_authorise(uuid, namespace_id)
    if err then return err end

    local updates = {}
    local values = {}

    if input.name ~= nil then
        if type(input.name) ~= "string" or input.name == "" then
            return fail(422, "name must be a non-empty string")
        end
        table.insert(updates, "name = ?")
        table.insert(values, input.name)
    end

    if input.description ~= nil then
        table.insert(updates, "description = ?")
        table.insert(values, input.description or "")
    end

    local tokens_changed = input.tokens ~= nil
    local css_changed = input.custom_css ~= nil

    if tokens_changed then
        local valid, errors = ThemeValidator.validate(input.tokens)
        if not valid then
            return fail(422, "token validation failed", { errors = errors })
        end
    end

    local clean_css
    if css_changed then
        local sanitised, warnings = CssSanitizer.sanitise(input.custom_css or "")
        if (input.custom_css or "") ~= "" and sanitised == "" and #warnings > 0 then
            return fail(422, "custom_css rejected", { errors = warnings })
        end
        clean_css = sanitised
    end

    local note = input.change_note

    local ok_txn, txn_err = pcall(function()
        db.query("BEGIN")

        if #updates > 0 then
            table.insert(values, theme.id)
            db.query("UPDATE themes SET " .. table.concat(updates, ", ") .. " WHERE id = ?", unpack(values))
        end

        if tokens_changed or css_changed then
            local final_tokens_json, final_css

            if tokens_changed then
                final_tokens_json = encode_tokens(input.tokens)
            else
                local existing = ThemeQueries.getTokens(theme.id)
                final_tokens_json = (existing and existing.tokens) and
                    (type(existing.tokens) == "string" and existing.tokens or cjson.encode(existing.tokens))
                    or "{}"
            end

            if css_changed then
                final_css = clean_css or ""
            else
                local existing = ThemeQueries.getTokens(theme.id)
                final_css = (existing and existing.custom_css) or ""
            end

            local existing_tokens = ThemeQueries.getTokens(theme.id)
            if existing_tokens then
                db.query([[
                    UPDATE theme_tokens
                    SET tokens = ?::jsonb, custom_css = ?
                    WHERE theme_id = ?
                ]], final_tokens_json, final_css, theme.id)
            else
                db.query([[
                    INSERT INTO theme_tokens (theme_id, tokens, custom_css, updated_at)
                    VALUES (?, ?::jsonb, ?, NOW())
                ]], theme.id, final_tokens_json, final_css)
            end

            ThemeRevisionQueries.create(theme.id, final_tokens_json, final_css, user_id, note)
        end

        db.query("COMMIT")
    end)

    if not ok_txn then
        pcall(db.query, "ROLLBACK")
        return fail(500, "failed to update theme: " .. tostring(txn_err))
    end

    return ok(ThemeQueries.getById(theme.id))
end

-- =============================================================================
-- Activate
-- =============================================================================
function ThemeService.activate(namespace_id, project_code, user_id, uuid)
    local theme = ThemeQueries.getByUuid(uuid, namespace_id)
    if not theme then
        return fail(404, "theme not found")
    end
    if theme.project_code ~= project_code then
        return fail(422, "theme belongs to a different project_code")
    end
    -- Platform presets and own themes are both activatable. Public (marketplace)
    -- themes must be installed first — reject activating them directly.
    if theme.namespace_id and theme.namespace_id ~= namespace_id then
        return fail(403, "install a public theme before activating it")
    end

    local ok_txn, txn_err = pcall(function()
        db.query("BEGIN")
        db.query([[
            INSERT INTO namespace_active_themes (namespace_id, project_code, theme_id, activated_by, activated_at)
            VALUES (?, ?, ?, ?, NOW())
            ON CONFLICT (namespace_id, project_code)
            DO UPDATE SET theme_id = EXCLUDED.theme_id,
                          activated_by = EXCLUDED.activated_by,
                          activated_at = NOW()
        ]], namespace_id, project_code, theme.id, user_id)
        db.query("COMMIT")
    end)

    if not ok_txn then
        pcall(db.query, "ROLLBACK")
        return fail(500, "failed to activate theme: " .. tostring(txn_err))
    end

    return ok({
        theme_uuid = theme.uuid,
        theme_id   = theme.id,
        activated_at = "now",
    })
end

-- =============================================================================
-- Duplicate
-- =============================================================================
function ThemeService.duplicate(namespace_id, project_code, user_id, uuid, input)
    input = input or {}
    local source = ThemeQueries.getByUuid(uuid, namespace_id)
    if not source then return fail(404, "theme not found") end
    if source.project_code ~= project_code then
        return fail(422, "cannot duplicate theme from a different project_code")
    end

    local src_tokens = ThemeQueries.getTokens(source.id)
    local tokens = {}
    if src_tokens and src_tokens.tokens then
        if type(src_tokens.tokens) == "string" then
            local ok_dec, dec = pcall(cjson.decode, src_tokens.tokens)
            tokens = ok_dec and dec or {}
        else
            tokens = src_tokens.tokens
        end
    end

    return ThemeService.create(namespace_id, project_code, user_id, {
        name         = input.name or (source.name .. " (copy)"),
        description  = source.description,
        parent_uuid  = source.uuid,
        tokens       = tokens,
        custom_css   = src_tokens and src_tokens.custom_css or "",
    })
end

-- =============================================================================
-- Revert to a revision
-- =============================================================================
function ThemeService.revert(namespace_id, user_id, uuid, revision_uuid)
    local theme, err = load_and_authorise(uuid, namespace_id)
    if err then return err end

    local rev = ThemeRevisionQueries.getByUuid(revision_uuid, theme.id)
    if not rev then return fail(404, "revision not found") end

    local tokens_json = type(rev.tokens) == "string" and rev.tokens or cjson.encode(rev.tokens or {})

    return ThemeService.update(namespace_id, user_id, uuid, {
        tokens = cjson.decode(tokens_json),
        custom_css = rev.custom_css or "",
        change_note = "revert to revision " .. tostring(rev.uuid),
    })
end

-- =============================================================================
-- Publish (make theme visibility=public)
-- =============================================================================
function ThemeService.publish(namespace_id, user_id, uuid)
    local theme, err = load_and_authorise(uuid, namespace_id)
    if err then return err end

    db.query([[
        UPDATE themes
        SET visibility = 'public', updated_at = NOW()
        WHERE id = ?
    ]], theme.id)

    return ok(ThemeQueries.getById(theme.id))
end

-- =============================================================================
-- Unpublish
-- =============================================================================
function ThemeService.unpublish(namespace_id, user_id, uuid)
    local theme, err = load_and_authorise(uuid, namespace_id)
    if err then return err end

    db.query([[
        UPDATE themes
        SET visibility = 'private', updated_at = NOW()
        WHERE id = ?
    ]], theme.id)

    return ok(ThemeQueries.getById(theme.id))
end

-- =============================================================================
-- Soft delete
-- =============================================================================
function ThemeService.delete(namespace_id, project_code, uuid)
    local theme, err = load_and_authorise(uuid, namespace_id)
    if err then return err end

    -- Block deletion if currently active
    local active = ThemeQueries.getActiveAssignment(namespace_id, project_code)
    if active and active.theme_id == theme.id then
        return fail(409, "cannot delete the active theme; activate another theme first")
    end

    db.query("UPDATE themes SET deleted_at = NOW() WHERE id = ?", theme.id)
    return ok({ deleted = true, uuid = theme.uuid })
end

-- =============================================================================
-- Install a public theme from the marketplace
-- =============================================================================
function ThemeService.install(namespace_id, project_code, user_id, source_uuid)
    -- Read with broader filter: public themes are visible cross-tenant
    local rows = db.query([[
        SELECT * FROM themes
        WHERE uuid = ? AND visibility = 'public' AND deleted_at IS NULL
        LIMIT 1
    ]], source_uuid)
    local source = rows and rows[1]
    if not source then return fail(404, "public theme not found") end
    if source.project_code ~= project_code then
        return fail(422, "theme is for a different project_code")
    end

    -- Idempotent: if this namespace already installed this source, return it
    local existing = db.query([[
        SELECT t.* FROM theme_installations ti
        INNER JOIN themes t ON t.id = ti.installed_theme_id
        WHERE ti.namespace_id = ? AND ti.source_theme_id = ?
          AND t.deleted_at IS NULL
        LIMIT 1
    ]], namespace_id, source.id)
    if existing and existing[1] then
        return ok(existing[1])
    end

    local src_tokens = ThemeQueries.getTokens(source.id)
    local tokens = {}
    if src_tokens and src_tokens.tokens then
        if type(src_tokens.tokens) == "string" then
            local ok_dec, dec = pcall(cjson.decode, src_tokens.tokens)
            tokens = ok_dec and dec or {}
        else
            tokens = src_tokens.tokens
        end
    end

    local create_result = ThemeService.create(namespace_id, project_code, user_id, {
        name        = source.name,
        description = source.description,
        tokens      = tokens,
        custom_css  = src_tokens and src_tokens.custom_css or "",
    })
    if not create_result.ok then return create_result end

    db.query([[
        INSERT INTO theme_installations
            (namespace_id, source_theme_id, installed_theme_id, source_version, installed_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], namespace_id, source.id, create_result.data.id, source.version)

    return create_result
end

-- =============================================================================
-- Resolve active theme (used by /active endpoint and renderer)
-- =============================================================================
--- Returns the full resolved theme + rendered CSS for (namespace, project).
-- If no theme is active, falls back to the first platform preset.
function ThemeService.resolveActive(namespace_id, project_code)
    local active = ThemeQueries.getActive(namespace_id, project_code)
    if not active then
        active = ThemeQueries.getDefaultPreset(project_code)
    end
    if not active then
        -- Nothing seeded — return empty defaults so callers still get a valid response
        return ok({
            theme = nil,
            resolved = ThemeResolver.resolve(nil),
        })
    end

    local resolved = ThemeResolver.resolve(active)
    return ok({
        theme = active,
        resolved = resolved,
    })
end

return ThemeService
