--[[
    Theme System Migrations (Phase 1 — Data Model)
    ==============================================

    Multi-tenant WordPress-style theming. Designed so non-technical users
    can create, customize, activate, and share themes without any developer
    involvement. Schema supports:

    - Per-namespace theme ownership with FK isolation (no cross-tenant leaks)
    - Platform-provided system presets (namespace_id IS NULL, is_system=true)
    - Parent/child theme inheritance (duplicate chain, no cross-namespace)
    - Exactly one active theme per (namespace, project_code) via partial unique index
    - Revision history for undo/revert
    - Soft-delete for recovery and audit
    - Marketplace-ready visibility flag (private | namespace | public)
    - Asset uploads (logos, favicons, images) tracked separately

    Tables:
    =======
    1. themes                    - Catalog of themes (tenant-owned + platform presets)
    2. theme_tokens              - Current tokens + custom_css for each theme (1:1)
    3. theme_revisions           - Append-only version history for undo/revert
    4. namespace_active_themes   - One active theme per (namespace, project_code)
    5. theme_installations       - Marketplace install tracking (source -> installed copy)
    6. theme_assets              - Uploaded assets (logos, favicons) via MinIO
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query(
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) AS exists",
        name
    )
    return result and result[1] and result[1].exists
end

local function index_exists(name)
    local result = db.query(
        "SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = ?) AS exists",
        name
    )
    return result and result[1] and result[1].exists
end

return {
    -- =========================================================================
    -- [1] themes — catalog table
    -- =========================================================================
    [1] = function()
        if table_exists("themes") then return end

        db.query([[
            CREATE TABLE themes (
                id                SERIAL PRIMARY KEY,
                uuid              UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                namespace_id      INTEGER REFERENCES namespaces(id) ON DELETE CASCADE,
                project_code      VARCHAR(100) NOT NULL,
                name              VARCHAR(200) NOT NULL,
                slug              VARCHAR(200) NOT NULL,
                description       TEXT,
                parent_theme_id   INTEGER REFERENCES themes(id) ON DELETE SET NULL,
                version           VARCHAR(20) NOT NULL DEFAULT '1.0.0',
                visibility        VARCHAR(20) NOT NULL DEFAULT 'private'
                                  CHECK (visibility IN ('private','namespace','public')),
                is_system         BOOLEAN NOT NULL DEFAULT false,
                preview_image_url TEXT,
                created_by        INTEGER REFERENCES users(id) ON DELETE SET NULL,
                created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                deleted_at        TIMESTAMPTZ
            )
        ]])

        -- Slug uniqueness per (namespace, project). Platform presets use namespace_id=NULL;
        -- PostgreSQL treats NULL as distinct in UNIQUE, so we need a partial unique index
        -- with COALESCE to enforce uniqueness across platform rows too.
        db.query([[
            CREATE UNIQUE INDEX idx_themes_slug_unique
            ON themes (COALESCE(namespace_id, 0), project_code, slug)
            WHERE deleted_at IS NULL
        ]])

        db.query([[
            CREATE INDEX idx_themes_namespace_project
            ON themes (namespace_id, project_code)
            WHERE deleted_at IS NULL
        ]])

        db.query([[
            CREATE INDEX idx_themes_visibility
            ON themes (visibility)
            WHERE deleted_at IS NULL AND visibility IN ('namespace','public')
        ]])

        db.query([[
            CREATE INDEX idx_themes_is_system
            ON themes (is_system)
            WHERE is_system = true AND deleted_at IS NULL
        ]])

        db.query([[
            CREATE INDEX idx_themes_created_at
            ON themes USING BRIN (created_at)
        ]])
    end,

    -- =========================================================================
    -- [2] theme_tokens — current tokens + custom_css (1:1 with themes)
    -- Separated from themes so UPDATE on token edits doesn't rewrite metadata
    -- and so deep JSONB indexing stays focused.
    -- =========================================================================
    [2] = function()
        if table_exists("theme_tokens") then return end

        db.query([[
            CREATE TABLE theme_tokens (
                id          SERIAL PRIMARY KEY,
                theme_id    INTEGER NOT NULL UNIQUE REFERENCES themes(id) ON DELETE CASCADE,
                tokens      JSONB NOT NULL DEFAULT '{}'::jsonb,
                custom_css  TEXT NOT NULL DEFAULT '',
                updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE INDEX idx_theme_tokens_gin
            ON theme_tokens USING GIN (tokens)
        ]])
    end,

    -- =========================================================================
    -- [3] theme_revisions — append-only history for undo/revert
    -- =========================================================================
    [3] = function()
        if table_exists("theme_revisions") then return end

        db.query([[
            CREATE TABLE theme_revisions (
                id          SERIAL PRIMARY KEY,
                uuid        UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                theme_id    INTEGER NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
                tokens      JSONB NOT NULL,
                custom_css  TEXT NOT NULL DEFAULT '',
                changed_by  INTEGER REFERENCES users(id) ON DELETE SET NULL,
                change_note TEXT,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE INDEX idx_theme_revisions_theme
            ON theme_revisions (theme_id, created_at DESC)
        ]])
    end,

    -- =========================================================================
    -- [4] namespace_active_themes — one active theme per (namespace, project_code)
    -- Not a column on namespaces/themes because a namespace can run multiple
    -- project_codes simultaneously (see multi-project CLAUDE.md docs).
    -- =========================================================================
    [4] = function()
        if table_exists("namespace_active_themes") then return end

        db.query([[
            CREATE TABLE namespace_active_themes (
                namespace_id  INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                project_code  VARCHAR(100) NOT NULL,
                theme_id      INTEGER NOT NULL REFERENCES themes(id) ON DELETE RESTRICT,
                activated_by  INTEGER REFERENCES users(id) ON DELETE SET NULL,
                activated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (namespace_id, project_code)
            )
        ]])

        db.query([[
            CREATE INDEX idx_namespace_active_themes_theme
            ON namespace_active_themes (theme_id)
        ]])
    end,

    -- =========================================================================
    -- [5] theme_installations — marketplace install tracking
    -- Records which public themes a namespace has installed. Install = snapshot
    -- copy; updates to source do not auto-propagate (shown as "update available").
    -- =========================================================================
    [5] = function()
        if table_exists("theme_installations") then return end

        db.query([[
            CREATE TABLE theme_installations (
                id                  SERIAL PRIMARY KEY,
                namespace_id        INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                source_theme_id     INTEGER NOT NULL REFERENCES themes(id) ON DELETE RESTRICT,
                installed_theme_id  INTEGER NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
                source_version      VARCHAR(20),
                installed_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE(namespace_id, source_theme_id)
            )
        ]])

        db.query([[
            CREATE INDEX idx_theme_installations_source
            ON theme_installations (source_theme_id)
        ]])
    end,

    -- =========================================================================
    -- [6] theme_assets — logos, favicons, fonts, images
    -- Stored in MinIO via the existing opsapi-node upload service. This table
    -- records metadata + the storage key; references to asset UUIDs live in
    -- theme tokens (e.g., branding.logo_asset_id).
    -- =========================================================================
    [6] = function()
        if table_exists("theme_assets") then return end

        db.query([[
            CREATE TABLE theme_assets (
                id           SERIAL PRIMARY KEY,
                uuid         UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                theme_id     INTEGER NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
                asset_type   VARCHAR(50) NOT NULL
                             CHECK (asset_type IN ('logo','favicon','background','font','image')),
                storage_key  VARCHAR(500) NOT NULL,
                mime_type    VARCHAR(100),
                file_size    INTEGER,
                width        INTEGER,
                height       INTEGER,
                created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE INDEX idx_theme_assets_theme
            ON theme_assets (theme_id)
        ]])

        db.query([[
            CREATE INDEX idx_theme_assets_type
            ON theme_assets (asset_type)
        ]])
    end,

    -- =========================================================================
    -- [7] updated_at auto-touch trigger for themes & theme_tokens
    -- Cheap to maintain, keeps the cache-busting version query reliable even
    -- when writes come from raw SQL outside the service layer.
    -- =========================================================================
    [7] = function()
        db.query([[
            CREATE OR REPLACE FUNCTION theme_touch_updated_at()
            RETURNS TRIGGER AS $$
            BEGIN
                NEW.updated_at := NOW();
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql
        ]])

        -- Drop-then-create pattern so this step is re-runnable if the function
        -- signature ever changes (DROP TRIGGER IF EXISTS is cheap).
        db.query("DROP TRIGGER IF EXISTS trg_themes_touch_updated_at ON themes")
        db.query([[
            CREATE TRIGGER trg_themes_touch_updated_at
            BEFORE UPDATE ON themes
            FOR EACH ROW EXECUTE FUNCTION theme_touch_updated_at()
        ]])

        db.query("DROP TRIGGER IF EXISTS trg_theme_tokens_touch_updated_at ON theme_tokens")
        db.query([[
            CREATE TRIGGER trg_theme_tokens_touch_updated_at
            BEFORE UPDATE ON theme_tokens
            FOR EACH ROW EXECUTE FUNCTION theme_touch_updated_at()
        ]])
    end,

    -- =========================================================================
    -- [8] Seed platform presets (idempotent upsert)
    -- Reads from helper.theme-presets so adding new presets needs no new migration.
    -- Runs for every project_code that has the THEMES feature enabled. Presets
    -- with project_code="*" are seeded once per enabled project_code.
    -- =========================================================================
    [8] = function()
        local ok_presets, ThemePresets = pcall(require, "helper.theme-presets")
        if not ok_presets then
            print("[theme-system] theme-presets helper not found; skipping preset seed")
            return
        end

        local ok_cfg, ProjectConfig = pcall(require, "helper.project-config")
        if not ok_cfg then
            print("[theme-system] project-config not found; skipping preset seed")
            return
        end

        local cjson = require("cjson")

        -- Determine which project_codes the platform presets apply to.
        -- "*" presets are fanned out across every parsed project code.
        local project_codes = ProjectConfig.parseProjectCodes()
        if #project_codes == 0 then
            project_codes = { "default" }
        end

        for _, preset in ipairs(ThemePresets.getAll()) do
            local targets = {}
            if preset.project_code == "*" then
                for _, code in ipairs(project_codes) do
                    table.insert(targets, code)
                end
            else
                table.insert(targets, preset.project_code)
            end

            for _, project_code in ipairs(targets) do
                -- Upsert the theme row. ON CONFLICT hits our partial unique index;
                -- we scope the target to (namespace_id IS NULL, project_code, slug).
                local existing = db.query([[
                    SELECT id FROM themes
                    WHERE namespace_id IS NULL
                      AND project_code = ?
                      AND slug = ?
                      AND deleted_at IS NULL
                    LIMIT 1
                ]], project_code, preset.slug)

                local theme_id
                if existing and existing[1] then
                    theme_id = existing[1].id
                    db.query([[
                        UPDATE themes
                        SET name = ?, description = ?, preview_image_url = ?,
                            visibility = 'public', is_system = true, updated_at = NOW()
                        WHERE id = ?
                    ]], preset.name, preset.description or "",
                        preset.preview_image_url, theme_id)
                else
                    local inserted = db.query([[
                        INSERT INTO themes (
                            namespace_id, project_code, name, slug, description,
                            visibility, is_system, preview_image_url, created_at, updated_at
                        ) VALUES (
                            NULL, ?, ?, ?, ?, 'public', true, ?, NOW(), NOW()
                        )
                        RETURNING id
                    ]], project_code, preset.name, preset.slug,
                        preset.description or "", preset.preview_image_url)
                    theme_id = inserted and inserted[1] and inserted[1].id
                end

                if theme_id then
                    local tokens_json = cjson.encode(preset.tokens or {})
                    local custom_css = preset.custom_css or ""

                    local token_row = db.query(
                        "SELECT id FROM theme_tokens WHERE theme_id = ? LIMIT 1",
                        theme_id
                    )

                    if token_row and token_row[1] then
                        db.query([[
                            UPDATE theme_tokens
                            SET tokens = ?::jsonb, custom_css = ?, updated_at = NOW()
                            WHERE theme_id = ?
                        ]], tokens_json, custom_css, theme_id)
                    else
                        db.query([[
                            INSERT INTO theme_tokens (theme_id, tokens, custom_css, updated_at)
                            VALUES (?, ?::jsonb, ?, NOW())
                        ]], theme_id, tokens_json, custom_css)
                    end
                end
            end
        end
    end,
}
