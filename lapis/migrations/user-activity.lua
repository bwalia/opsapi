--[[
    User activity & login tracking (core)
    =====================================
    Storage behind lib/user-activity.lua:

      [1] user_login_stats  one row per user: last login (when / IP / method /
                            browser), login count, consecutive failed logins,
                            last seen. Kept OUT of `users` on purpose: user rows
                            are returned whole (minus secrets) by many APIs, so
                            new columns there would leak IPs.
          auth_events       every sign-in success/failure, 2FA, refresh, logout,
                            password change … (retention 1 year by default).
      [2] user_activity     what signed-in users did, partitioned by month
                            (retention 90 days by default: whole partitions are
                            dropped, no row-by-row deletes).
      [3] opsapi_reporting  views for Grafana (only the columns reports need —
                            never passwords, tokens or other tables) and the
                            NOLOGIN role opsapi_reporting_reader that may read
                            them. The Grafana login is created by ops:
                            see USER_ACTIVITY.md.
      [4] erase on delete   deleting a user row deletes their activity and
                            auth events (UK GDPR erasure), whatever path
                            deleted it; user_login_stats cascades via its FK.
      [5] user_activity_daily  per workspace × day × user × action counters,
                            kept up to date by the same statement that writes
                            the activity rows. The in-app Activity page reads
                            this instead of scanning months of raw rows.
      [6] Activity module   RBAC module `activity` + "Activity" menu item for
                            workspace owners/admins.

    Idempotent; gated on FEATURES.CORE so every deployment gets it.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS user_login_stats (
                user_uuid VARCHAR(255) PRIMARY KEY REFERENCES users(uuid) ON DELETE CASCADE,
                last_login_at TIMESTAMPTZ,
                last_login_ip VARCHAR(64),
                last_login_method VARCHAR(20),
                last_login_user_agent VARCHAR(255),
                login_count INTEGER NOT NULL DEFAULT 0,
                last_failed_login_at TIMESTAMPTZ,
                failed_login_count INTEGER NOT NULL DEFAULT 0,
                last_seen_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_user_login_stats_last_seen ON user_login_stats (last_seen_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS idx_user_login_stats_last_login ON user_login_stats (last_login_at DESC)")

        db.query([[
            CREATE TABLE IF NOT EXISTS auth_events (
                id BIGSERIAL PRIMARY KEY,
                occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                event VARCHAR(40) NOT NULL,
                result VARCHAR(16) NOT NULL,
                method VARCHAR(20),
                user_uuid VARCHAR(255),
                email VARCHAR(255),
                namespace_id INTEGER,
                ip VARCHAR(64),
                user_agent VARCHAR(255),
                reason VARCHAR(64),
                request_id VARCHAR(64)
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_auth_events_user ON auth_events (user_uuid, occurred_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS idx_auth_events_ip ON auth_events (ip, occurred_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS idx_auth_events_event ON auth_events (event, result, occurred_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS idx_auth_events_time ON auth_events USING BRIN (occurred_at)")
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS user_activity (
                id BIGSERIAL,
                occurred_at TIMESTAMPTZ NOT NULL,
                user_uuid VARCHAR(255) NOT NULL,
                namespace_id INTEGER,
                via VARCHAR(10) NOT NULL DEFAULT 'jwt',
                api_key_uuid VARCHAR(64),
                method VARCHAR(8) NOT NULL,
                route VARCHAR(255) NOT NULL,
                action VARCHAR(120) NOT NULL,
                entity_id VARCHAR(64),
                status SMALLINT NOT NULL,
                hits INTEGER NOT NULL DEFAULT 1,
                duration_ms INTEGER,
                ip VARCHAR(64),
                user_agent VARCHAR(255),
                request_id VARCHAR(64),
                PRIMARY KEY (id, occurred_at)
            ) PARTITION BY RANGE (occurred_at)
        ]])
        -- Partitioned indexes: created on every partition automatically.
        db.query("CREATE INDEX IF NOT EXISTS idx_user_activity_user ON user_activity (user_uuid, occurred_at DESC)")
        db.query([[CREATE INDEX IF NOT EXISTS idx_user_activity_namespace
                   ON user_activity (namespace_id, occurred_at DESC)]])
        db.query("CREATE INDEX IF NOT EXISTS idx_user_activity_time ON user_activity USING BRIN (occurred_at)")
        require("lib.user-activity").ensurePartitions()
    end,

    [3] = function()
        db.query("CREATE SCHEMA IF NOT EXISTS opsapi_reporting")
        db.query([[
            CREATE OR REPLACE VIEW opsapi_reporting.users AS
            SELECT u.uuid AS user_uuid, u.email,
                   NULLIF(trim(coalesce(u.first_name, '') || ' ' || coalesce(u.last_name, '')), '') AS name,
                   u.active, u.created_at,
                   s.last_login_at, s.last_login_ip, s.last_login_method, s.last_login_user_agent,
                   coalesce(s.login_count, 0) AS login_count, s.last_failed_login_at,
                   coalesce(s.failed_login_count, 0) AS failed_login_count, s.last_seen_at
            FROM users u LEFT JOIN user_login_stats s ON s.user_uuid = u.uuid
        ]])
        db.query([[
            CREATE OR REPLACE VIEW opsapi_reporting.namespaces AS
            SELECT id AS namespace_id, uuid AS namespace_uuid, slug, name, status FROM namespaces
        ]])
        db.query([[
            CREATE OR REPLACE VIEW opsapi_reporting.memberships AS
            SELECT u.uuid AS user_uuid, nm.namespace_id, n.slug AS namespace_slug, nm.status, nm.is_owner,
                   nm.joined_at
            FROM namespace_members nm JOIN users u ON u.id = nm.user_id JOIN namespaces n ON n.id = nm.namespace_id
        ]])
        db.query([[
            CREATE OR REPLACE VIEW opsapi_reporting.user_activity AS
            SELECT a.occurred_at, a.user_uuid, u.email, a.namespace_id, n.slug AS namespace_slug, a.via,
                   a.api_key_uuid, a.method, a.route, a.action, a.entity_id, a.status, a.hits, a.duration_ms,
                   a.ip, a.user_agent, a.request_id
            FROM user_activity a
            LEFT JOIN users u ON u.uuid = a.user_uuid
            LEFT JOIN namespaces n ON n.id = a.namespace_id
        ]])
        db.query([[
            CREATE OR REPLACE VIEW opsapi_reporting.auth_events AS
            SELECT e.occurred_at, e.event, e.result, e.method, e.user_uuid, coalesce(u.email, e.email) AS email,
                   e.namespace_id, e.ip, e.user_agent, e.reason, e.request_id
            FROM auth_events e LEFT JOIN users u ON u.uuid = e.user_uuid
        ]])

        -- Reader role: SELECT on these views only. Creating roles needs
        -- CREATEROLE, which a managed app user often lacks — then a DBA runs
        -- the printed statements once.
        local ok, err = pcall(db.query, [[
            DO $$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'opsapi_reporting_reader') THEN
                    CREATE ROLE opsapi_reporting_reader NOLOGIN;
                END IF;
            END $$
        ]])
        if ok then
            db.query("GRANT USAGE ON SCHEMA opsapi_reporting TO opsapi_reporting_reader")
            db.query("GRANT SELECT ON ALL TABLES IN SCHEMA opsapi_reporting TO opsapi_reporting_reader")
            db.query([[ALTER DEFAULT PRIVILEGES IN SCHEMA opsapi_reporting
                       GRANT SELECT ON TABLES TO opsapi_reporting_reader]])
            print("[UserActivity] opsapi_reporting views ready; role opsapi_reporting_reader granted")
        else
            print("[UserActivity] Could not create role opsapi_reporting_reader (" .. tostring(err):sub(1, 120)
                .. "). As a DBA run: CREATE ROLE opsapi_reporting_reader NOLOGIN; "
                .. "GRANT USAGE ON SCHEMA opsapi_reporting TO opsapi_reporting_reader; "
                .. "GRANT SELECT ON ALL TABLES IN SCHEMA opsapi_reporting TO opsapi_reporting_reader;")
        end
    end,

    [4] = function()
        db.query([[
            CREATE OR REPLACE FUNCTION opsapi_forget_user_activity() RETURNS trigger LANGUAGE plpgsql AS $fn$
            BEGIN
                DELETE FROM user_activity WHERE user_uuid = OLD.uuid;
                DELETE FROM auth_events WHERE user_uuid = OLD.uuid;
                RETURN NULL;
            END
            $fn$
        ]])
        db.query("DROP TRIGGER IF EXISTS trg_users_forget_activity ON users")
        db.query([[
            CREATE TRIGGER trg_users_forget_activity AFTER DELETE ON users
            FOR EACH ROW EXECUTE FUNCTION opsapi_forget_user_activity()
        ]])
    end,

    [5] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS user_activity_daily (
                namespace_id INTEGER NOT NULL,
                day DATE NOT NULL,
                user_uuid VARCHAR(255) NOT NULL,
                action VARCHAR(120) NOT NULL,
                changes INTEGER NOT NULL DEFAULT 0,
                requests INTEGER NOT NULL DEFAULT 0,
                errors INTEGER NOT NULL DEFAULT 0,
                last_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY (namespace_id, day, user_uuid, action)
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_user_activity_daily_day ON user_activity_daily (day)")
        db.query([[CREATE INDEX IF NOT EXISTS idx_user_activity_daily_user
                   ON user_activity_daily (namespace_id, user_uuid, day DESC)]])
        -- Backfill from rows already recorded (a no-op on a fresh install).
        db.query([[
            INSERT INTO user_activity_daily (namespace_id, day, user_uuid, action, changes, requests, errors, last_at)
            SELECT namespace_id, (occurred_at AT TIME ZONE 'UTC')::date, user_uuid, action,
                   COUNT(*) FILTER (WHERE method NOT IN ('GET', 'HEAD')), SUM(hits),
                   COALESCE(SUM(hits) FILTER (WHERE status >= 400), 0), MAX(occurred_at)
            FROM user_activity WHERE namespace_id IS NOT NULL
            GROUP BY 1, 2, 3, 4
            ON CONFLICT DO NOTHING
        ]])
        db.query([[
            CREATE OR REPLACE FUNCTION opsapi_forget_user_activity() RETURNS trigger LANGUAGE plpgsql AS $fn$
            BEGIN
                DELETE FROM user_activity WHERE user_uuid = OLD.uuid;
                DELETE FROM user_activity_daily WHERE user_uuid = OLD.uuid;
                DELETE FROM auth_events WHERE user_uuid = OLD.uuid;
                RETURN NULL;
            END
            $fn$
        ]])
    end,

    [6] = function()
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()
        if #db.select("1 FROM modules WHERE machine_name = 'activity'") == 0 then
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(),
                machine_name = "activity",
                name = "Activity",
                description = "Who signed in and what they did in this workspace",
                category = "Core",
                priority = 99,
                allowed_actions = '["read"]',
                created_at = ts,
                updated_at = ts,
            })
        end
        if #db.select("1 FROM menu_items WHERE key = 'activity'") == 0 then
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = "activity",
                name = "Activity",
                icon = "Activity",
                path = "/dashboard/namespace/activity",
                module = "activity",
                required_action = "read",
                priority = 99,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = ts,
                updated_at = ts,
            })
        end
        -- Owners and admins of every existing workspace; new workspaces get it
        -- from the modules table when their default roles are seeded.
        require("queries.ModuleQueries").propagateToNamespaceAdmins("activity")
    end,
}
