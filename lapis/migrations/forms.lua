--[[
    Form builder (docs/FORMS.md, design: docs/FORM_BUILDER_PLAN.md)
    ===============================================================

    forms                  one row per form; the builder edits draft_schema
    form_versions          immutable snapshot taken at each publish; responses
                           point at the version they answered, so editing a
                           live form never relabels old answers
    form_submissions       the answers ("responses" in the UI), one JSON
                           document per response keyed by field key
    form_submission_links  what each response created or matched (customer,
                           lead, workspace invitation, ...)

    Gated on FEATURES.FORMS. Every step is idempotent (IF NOT EXISTS / guarded
    inserts) so a re-run is a no-op.
]]

local db = require("lapis.db")

local MENU_KEY = "forms"
local MENU_PATH = "/dashboard/forms"

local function table_exists(name)
    return db.query("SELECT to_regclass(?) IS NOT NULL AS ok", name)[1].ok
end

-- Add the `forms` permission to the named roles that don't already have it.
local function grant(role_names, actions)
    local cjson = require("cjson")
    for _, role in ipairs(db.select("* FROM namespace_roles WHERE role_name IN ?", db.list(role_names))) do
        local perms = {}
        if role.permissions and role.permissions ~= "" then
            local ok, decoded = pcall(cjson.decode, role.permissions)
            if ok and type(decoded) == "table" then perms = decoded end
        end
        if not perms[MENU_KEY] then
            perms[MENU_KEY] = actions
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
            -- Members' permission maps are cached (≤5 min): drop them so owners
            -- see Forms right after the deploy. Fails open without Redis.
            pcall(function() require("helper.permission-cache").invalidateRole(role.id) end)
        end
    end
end

return {
    -- [1] Tables
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS forms (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                public_id VARCHAR(16) NOT NULL UNIQUE,
                title VARCHAR(200) NOT NULL,
                description TEXT,
                status VARCHAR(16) NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'published', 'closed', 'archived')),
                draft_schema JSONB NOT NULL DEFAULT '{"fields": []}'::jsonb,
                targets JSONB NOT NULL DEFAULT '[]'::jsonb,
                settings JSONB NOT NULL DEFAULT '{}'::jsonb,
                published_version_id BIGINT,
                public_origin TEXT,
                submission_count INTEGER NOT NULL DEFAULT 0,
                last_submission_at TIMESTAMPTZ,
                created_by_uuid TEXT,
                updated_by_uuid TEXT,
                published_by_uuid TEXT,
                published_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                deleted_at TIMESTAMPTZ
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS forms_ns_updated_idx
            ON forms (namespace_id, updated_at DESC, id DESC) WHERE deleted_at IS NULL]])

        db.query([[
            CREATE TABLE IF NOT EXISTS form_versions (
                id BIGSERIAL PRIMARY KEY,
                form_id BIGINT NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
                namespace_id BIGINT NOT NULL,
                version INTEGER NOT NULL,
                schema JSONB NOT NULL,
                targets JSONB NOT NULL DEFAULT '[]'::jsonb,
                published_by_uuid TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (form_id, version)
            )
        ]])
        db.query([[
            DO $$ BEGIN
                ALTER TABLE forms ADD CONSTRAINT forms_published_version_fk
                    FOREIGN KEY (published_version_id) REFERENCES form_versions(id) ON DELETE SET NULL;
            EXCEPTION WHEN duplicate_object THEN NULL;
            END $$
        ]])

        db.query([[
            CREATE TABLE IF NOT EXISTS form_submissions (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                form_id BIGINT NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
                version_id BIGINT NOT NULL REFERENCES form_versions(id) ON DELETE CASCADE,
                data JSONB NOT NULL,
                respondent_email TEXT,
                status VARCHAR(20) NOT NULL DEFAULT 'complete'
                    CHECK (status IN ('complete', 'needs_attention', 'spam')),
                idempotency_key VARCHAR(64),
                meta JSONB NOT NULL DEFAULT '{}'::jsonb,
                notifications JSONB NOT NULL DEFAULT '{}'::jsonb,
                processed_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        -- Keyset pagination of a form's responses (newest first), never OFFSET.
        db.query([[CREATE INDEX IF NOT EXISTS form_submissions_form_time_idx
            ON form_submissions (form_id, created_at DESC, id DESC)]])
        -- A double-clicked submit (same Idempotency-Key) is stored once.
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS form_submissions_idem_idx
            ON form_submissions (form_id, idempotency_key) WHERE idempotency_key IS NOT NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS form_submissions_ns_email_idx
            ON form_submissions (namespace_id, respondent_email) WHERE respondent_email IS NOT NULL]])
        -- The daily purge of old spam.
        db.query([[CREATE INDEX IF NOT EXISTS form_submissions_spam_idx
            ON form_submissions (created_at) WHERE status = 'spam']])

        db.query([[
            CREATE TABLE IF NOT EXISTS form_submission_links (
                submission_id BIGINT NOT NULL REFERENCES form_submissions(id) ON DELETE CASCADE,
                namespace_id BIGINT NOT NULL,
                target VARCHAR(32) NOT NULL,
                entity_type VARCHAR(32),
                entity_uuid TEXT,
                outcome VARCHAR(16) NOT NULL
                    CHECK (outcome IN ('created', 'matched', 'invited', 'failed')),
                error_code VARCHAR(64),
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (submission_id, target)
            )
        ]])
        -- "Form responses" of a customer / lead / user.
        db.query([[CREATE INDEX IF NOT EXISTS form_submission_links_entity_idx
            ON form_submission_links (namespace_id, entity_type, entity_uuid)]])
        print("[Forms] Created forms, form_versions, form_submissions, form_submission_links")
    end,

    -- [2] RBAC module, menu item, owner/admin grants, menu enabled everywhere.
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        if table_exists("modules") and #db.select("id FROM modules WHERE machine_name = ?", MENU_KEY) == 0 then
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(),
                machine_name = MENU_KEY,
                name = "Forms",
                description = "Build forms, share a public link and collect responses",
                category = "Content",
                priority = 45,
                created_at = timestamp,
                updated_at = timestamp,
            })
        end

        grant({ "Owner", "owner", "Namespace Owner" }, { "create", "read", "update", "delete", "manage" })
        grant({ "Admin", "admin", "Namespace Admin" }, { "create", "read", "update", "delete" })

        if not table_exists("menu_items") then return end
        local menu = db.select("* FROM menu_items WHERE key = ?", MENU_KEY)[1]
        if not menu then
            menu = db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = MENU_KEY,
                name = "Forms",
                icon = "ClipboardList",
                path = MENU_PATH,
                module = MENU_KEY,
                required_action = "read",
                priority = 45,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = timestamp,
                updated_at = timestamp,
            }, { returning = "*" })[1]
        end
        if table_exists("namespace_menu_config") then
            db.query([[
                INSERT INTO namespace_menu_config (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
                SELECT gen_random_uuid()::text, n.id, ?, true, NOW(), NOW() FROM namespaces n
                WHERE NOT EXISTS (SELECT 1 FROM namespace_menu_config c
                                  WHERE c.namespace_id = n.id AND c.menu_item_id = ?)
            ]], menu.id, menu.id)
        end
        print("[Forms] Registered the forms module and menu item")
    end,

    -- [3] Lookup indexes for "find the existing record by email" (each
    -- response looks its email up in the targets' tables).
    [3] = function()
        local function index(tbl, sql)
            if table_exists(tbl) then db.query(sql) end
        end
        index("crm_leads", [[CREATE INDEX IF NOT EXISTS crm_leads_ns_lower_email_idx
            ON crm_leads (namespace_id, lower(email)) WHERE deleted_at IS NULL]])
        index("customers", [[CREATE INDEX IF NOT EXISTS customers_ns_lower_email_idx
            ON customers (namespace_id, lower(email))]])
        index("namespace_invitations", [[CREATE INDEX IF NOT EXISTS namespace_invitations_ns_lower_email_idx
            ON namespace_invitations (namespace_id, lower(email)) WHERE status = 'pending']])
        index("users", [[CREATE INDEX IF NOT EXISTS users_lower_email_idx ON users (lower(email))]])
    end,

    -- [4] Phase 2: uploaded files and daily analytics.
    [4] = function()
        -- A file goes up before the response: submission_id stays NULL until
        -- the response claims it. The hourly purge deletes files never claimed
        -- within a day and files whose response is gone (lib/forms/jobs.lua),
        -- so there's no foreign key: the row must outlive its response long
        -- enough to delete the object in storage.
        db.query([[
            CREATE TABLE IF NOT EXISTS form_uploads (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL,
                form_id BIGINT NOT NULL,
                field_key VARCHAR(40) NOT NULL,
                submission_id BIGINT,
                object_key TEXT NOT NULL,
                filename VARCHAR(255) NOT NULL,
                content_type VARCHAR(120) NOT NULL,
                size_bytes INTEGER NOT NULL,
                ip_hash VARCHAR(32),
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS form_uploads_submission_idx ON form_uploads (submission_id)]])
        db.query([[CREATE INDEX IF NOT EXISTS form_uploads_unclaimed_idx ON form_uploads (created_at)
            WHERE submission_id IS NULL]])

        -- Views / starts / steps reached per form per day (UTC). Counted in
        -- each worker's memory and added here every 30 s (lib/forms/stats.lua);
        -- responses are counted from form_submissions itself.
        db.query([[
            CREATE TABLE IF NOT EXISTS form_daily_stats (
                form_id BIGINT NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
                day DATE NOT NULL,
                views INTEGER NOT NULL DEFAULT 0,
                starts INTEGER NOT NULL DEFAULT 0,
                steps JSONB NOT NULL DEFAULT '{}'::jsonb,
                PRIMARY KEY (form_id, day)
            )
        ]])
    end,

    -- [5] Phase 2: workspace-wide forms settings (Cloudflare Turnstile keys;
    -- the secret encrypted) and the index the monthly response count uses.
    [5] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS form_workspace_settings (
                namespace_id BIGINT PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
                turnstile_site_key VARCHAR(100),
                turnstile_secret_encrypted TEXT,
                updated_by_uuid TEXT,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS form_submissions_ns_time_idx
            ON form_submissions (namespace_id, created_at) WHERE status <> 'spam']])
    end,

    -- [6] A workspace's custom domain for its form links (lib/forms/domains.lua).
    -- One per workspace; a domain is active in at most one workspace at a time.
    [6] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS form_domains (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL UNIQUE REFERENCES namespaces(id) ON DELETE CASCADE,
                domain VARCHAR(253) NOT NULL,
                token VARCHAR(64) NOT NULL,
                status VARCHAR(16) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active')),
                last_error TEXT,
                checked_at TIMESTAMPTZ,
                verified_at TIMESTAMPTZ,
                created_by_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS form_domains_active_idx
            ON form_domains (domain) WHERE status = 'active']])
    end,
}
