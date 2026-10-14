--[[
    ATS and AI first-round interviews (docs/plans/PROMPT_ATS_INTERVIEWS.md)
    =======================================================================

    Gated on FEATURES.ATS. Every step is idempotent (IF NOT EXISTS / guarded
    inserts). The tables don't depend on the tax/billing tables, so `ats`
    works with any preset.

    [1] tables   [2] RBAC modules, role grants and the "Hiring" menu item
]]

local db = require("lapis.db")

local MENU_KEY = "ats"
local MENU_PATH = "/dashboard/ats"

local MODULES = {
    { "ats_jobs", "Hiring: jobs", "Jobs and their hiring pipeline" },
    { "ats_candidates", "Hiring: candidates", "Candidates, applications, notes and files" },
    { "ats_interviews", "Hiring: interviews", "AI first-round interviews, review and decisions" },
    { "ats_kits", "Hiring: interview kits", "Interview kits: competencies, rubrics and questions" },
    { "ats_reports", "Hiring: reports", "Fairness reports and the audit log" },
    { "ats_settings", "Hiring: settings", "Activation, retention, decline reasons and integration tokens" },
}

local function table_exists(name)
    return db.query("SELECT to_regclass(?) IS NOT NULL AS ok", name)[1].ok
end

local function grant(role_names, actions)
    local cjson = require("cjson")
    for _, role in ipairs(db.select("* FROM namespace_roles WHERE role_name IN ?", db.list(role_names))) do
        local perms = {}
        if role.permissions and role.permissions ~= "" then
            local ok, decoded = pcall(cjson.decode, role.permissions)
            if ok and type(decoded) == "table" then perms = decoded end
        end
        local changed = false
        for _, m in ipairs(MODULES) do
            if not perms[m[1]] then
                perms[m[1]] = actions
                changed = true
            end
        end
        if changed then
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
            pcall(function() require("helper.permission-cache").invalidateRole(role.id) end)
        end
    end
end

local function base(name, columns)
    db.query(([[
        CREATE TABLE IF NOT EXISTS %s (
            id BIGSERIAL PRIMARY KEY,
            uuid TEXT NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            %s,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]]):format(name, columns))
    db.query(("CREATE INDEX IF NOT EXISTS %s_ns_idx ON %s (namespace_id, created_at DESC)"):format(name, name))
end

return {
    [1] = function()
        base("ats_kits", [[
            job_id BIGINT,
            title VARCHAR(200) NOT NULL,
            kit JSONB NOT NULL DEFAULT '{}'::jsonb,
            version INTEGER NOT NULL DEFAULT 0,
            approved_at TIMESTAMPTZ,
            approved_by TEXT,
            created_by_uuid TEXT,
            external_kit_id TEXT,
            source VARCHAR(32) NOT NULL DEFAULT 'dashboard',
            deleted_at TIMESTAMPTZ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ats_kits_external_idx
            ON ats_kits (namespace_id, external_kit_id, version) WHERE external_kit_id IS NOT NULL]])

        base("ats_jobs", [[
            title VARCHAR(200) NOT NULL,
            department VARCHAR(120),
            location VARCHAR(200),
            employment_type VARCHAR(40),
            description TEXT,
            status VARCHAR(16) NOT NULL DEFAULT 'open' CHECK (status IN ('draft', 'open', 'paused', 'closed')),
            kit_id BIGINT REFERENCES ats_kits(id) ON DELETE SET NULL,
            external_kit_id TEXT,
            created_by_uuid TEXT,
            deleted_at TIMESTAMPTZ]])
        db.query([[CREATE INDEX IF NOT EXISTS ats_jobs_external_kit_idx ON ats_jobs (namespace_id, external_kit_id)]])

        base("ats_candidates", [[
            name VARCHAR(200) NOT NULL,
            email VARCHAR(254),
            phone VARCHAR(40),
            reference VARCHAR(200),
            links JSONB NOT NULL DEFAULT '[]'::jsonb,
            source VARCHAR(64),
            tags JSONB NOT NULL DEFAULT '[]'::jsonb,
            delete_after TIMESTAMPTZ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ats_candidates_email_idx
            ON ats_candidates (namespace_id, lower(email)) WHERE email IS NOT NULL AND email <> '']])

        base("ats_applications", [[
            job_id BIGINT NOT NULL REFERENCES ats_jobs(id) ON DELETE CASCADE,
            candidate_id BIGINT NOT NULL REFERENCES ats_candidates(id) ON DELETE CASCADE,
            stage VARCHAR(16) NOT NULL DEFAULT 'applied' CHECK (stage IN
                ('applied', 'screening', 'interview', 'review', 'offer', 'hired', 'rejected', 'withdrawn')),
            stage_changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            decision_reason TEXT,
            decided_by_uuid TEXT,
            decided_by_name TEXT,
            decided_at TIMESTAMPTZ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ats_applications_pair_idx ON ats_applications (job_id, candidate_id)]])
        db.query([[CREATE INDEX IF NOT EXISTS ats_applications_stage_idx ON ats_applications (namespace_id, job_id, stage)]])

        base("ats_notes", [[
            candidate_id BIGINT NOT NULL REFERENCES ats_candidates(id) ON DELETE CASCADE,
            application_id BIGINT REFERENCES ats_applications(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            author_uuid TEXT,
            author_name TEXT]])

        base("ats_attachments", [[
            candidate_id BIGINT NOT NULL REFERENCES ats_candidates(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL,
            content_type VARCHAR(120),
            size BIGINT,
            object_key TEXT NOT NULL]])

        base("ats_interviews", [[
            application_id BIGINT NOT NULL REFERENCES ats_applications(id) ON DELETE CASCADE,
            kit_id BIGINT REFERENCES ats_kits(id) ON DELETE SET NULL,
            kit_version INTEGER NOT NULL DEFAULT 0,
            source VARCHAR(32) NOT NULL DEFAULT 'hosted',
            external_id TEXT,
            state VARCHAR(20) NOT NULL DEFAULT 'invited',
            session JSONB NOT NULL DEFAULT '{}'::jsonb,
            link_token_hash CHAR(64) UNIQUE,
            link_expires_at TIMESTAMPTZ,
            started_at TIMESTAMPTZ,
            ended_at TIMESTAMPTZ,
            evaluation JSONB,
            evaluation_status VARCHAR(16) NOT NULL DEFAULT 'none',
            review JSONB,
            reviewed_at TIMESTAMPTZ,
            self_id_key TEXT,
            invited_by_uuid TEXT,
            delete_after TIMESTAMPTZ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ats_interviews_external_idx
            ON ats_interviews (namespace_id, external_id) WHERE external_id IS NOT NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS ats_interviews_state_idx ON ats_interviews (namespace_id, state)]])
        db.query([[CREATE INDEX IF NOT EXISTS ats_interviews_delete_idx ON ats_interviews (delete_after)]])

        -- Self-ID: no link to interviews except the opaque key the interview row holds.
        db.query([[
            CREATE TABLE IF NOT EXISTS ats_self_id (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                key TEXT NOT NULL UNIQUE,
                answers JSONB NOT NULL DEFAULT '{}'::jsonb,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])

        base("ats_audit_log", [[
            actor TEXT NOT NULL,
            action VARCHAR(64) NOT NULL,
            entity VARCHAR(32) NOT NULL,
            entity_uuid TEXT,
            detail JSONB NOT NULL DEFAULT '{}'::jsonb]])
        db.query([[CREATE INDEX IF NOT EXISTS ats_audit_entity_idx ON ats_audit_log (namespace_id, entity_uuid)]])

        db.query([[
            CREATE TABLE IF NOT EXISTS ats_module_activations (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL UNIQUE REFERENCES namespaces(id) ON DELETE CASCADE,
                status VARCHAR(16) NOT NULL DEFAULT 'lapsed' CHECK (status IN ('active', 'lapsed')),
                source VARCHAR(16) NOT NULL DEFAULT 'stripe' CHECK (source IN ('stripe', 'manual')),
                stripe_customer_id TEXT,
                stripe_subscription_id TEXT,
                activated_at TIMESTAMPTZ,
                expires_at TIMESTAMPTZ,
                payment_failed_at TIMESTAMPTZ,
                lapsed_at TIMESTAMPTZ,
                updated_by TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS ats_activations_sub_idx ON ats_module_activations (stripe_subscription_id)]])

        db.query([[
            CREATE TABLE IF NOT EXISTS ats_settings (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL UNIQUE REFERENCES namespaces(id) ON DELETE CASCADE,
                retention_days INTEGER NOT NULL DEFAULT 180 CHECK (retention_days BETWEEN 1 AND 3650),
                ratings_enabled BOOLEAN NOT NULL DEFAULT TRUE,
                decline_reasons JSONB NOT NULL DEFAULT
                    '["Doesn''t meet a requirement", "Other candidates were a closer match", "Role filled", "Candidate withdrew", "Other"]'::jsonb,
                legal_notice TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE TABLE IF NOT EXISTS ats_stripe_events (
                event_id TEXT PRIMARY KEY,
                type TEXT,
                received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])

        -- Tokens for the Snazzy Pro desktop app (snz_…); only the SHA-256 is kept.
        base("ats_integration_tokens", [[
            name VARCHAR(120) NOT NULL,
            token_hash CHAR(64) NOT NULL UNIQUE,
            token_prefix VARCHAR(16) NOT NULL,
            created_by_uuid TEXT,
            last_used_at TIMESTAMPTZ,
            revoked_at TIMESTAMPTZ]])
    end,

    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()
        if table_exists("modules") then
            for i, m in ipairs(MODULES) do
                if #db.select("id FROM modules WHERE machine_name = ?", m[1]) == 0 then
                    db.insert("modules", {
                        uuid = MigrationUtils.generateUUID(), machine_name = m[1], name = m[2], description = m[3],
                        category = "Hiring", priority = 50 + i, created_at = timestamp, updated_at = timestamp,
                    })
                end
            end
        end
        grant({ "Owner", "owner", "Namespace Owner" }, { "create", "read", "update", "delete", "manage" })
        grant({ "Admin", "admin", "Namespace Admin" }, { "create", "read", "update", "delete" })

        if not table_exists("menu_items") then return end
        local menu = db.select("* FROM menu_items WHERE key = ?", MENU_KEY)[1]
        if not menu then
            menu = db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(), key = MENU_KEY, name = "Hiring", icon = "Briefcase",
                path = MENU_PATH, module = "ats_jobs", required_action = "read", priority = 46, is_active = true,
                is_admin_only = false, always_show = false, settings = "{}", created_at = timestamp,
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
        print("[ATS] Registered the hiring modules and menu item")
    end,
}
