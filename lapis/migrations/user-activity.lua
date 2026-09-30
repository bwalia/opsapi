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
}
