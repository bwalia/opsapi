--[[
    HMRC Token Queries

    Stores and retrieves HMRC OAuth tokens for users.
    Used by the tax_copilot feature to authenticate HMRC MTD API calls.

    Table: hmrc_tokens
      user_uuid   TEXT (unique — one active token per user)
      access_token  TEXT
      refresh_token TEXT (optional — HMRC sandbox may not return one)
      scope         TEXT
      expires_at    TIMESTAMP
      created_at    TIMESTAMP
      updated_at    TIMESTAMP
]]

local db = require("lapis.db")

local HMRCTokenQueries = {}

-- Ensure the hmrc_tokens table exists (idempotent).
-- Called once from the route handlers.
function HMRCTokenQueries.ensureTable()
    db.query([[
        CREATE TABLE IF NOT EXISTS hmrc_tokens (
            id           SERIAL PRIMARY KEY,
            user_uuid    TEXT        NOT NULL UNIQUE,
            access_token TEXT        NOT NULL,
            refresh_token TEXT,
            scope        TEXT,
            expires_at   TIMESTAMP   NOT NULL,
            created_at   TIMESTAMP   NOT NULL DEFAULT NOW(),
            updated_at   TIMESTAMP   NOT NULL DEFAULT NOW()
        )
    ]])
end

-- Upsert (insert or update) a token for a user.
-- @param user_uuid   string  User UUID
-- @param access_token  string
-- @param refresh_token string or nil
-- @param scope         string or nil
-- @param expires_in    number  Seconds until expiry
function HMRCTokenQueries.upsert(user_uuid, access_token, refresh_token, scope, expires_in)
    local expires_at_sql = string.format("NOW() + INTERVAL '%d seconds'", expires_in or 14400)

    db.query([[
        INSERT INTO hmrc_tokens (user_uuid, access_token, refresh_token, scope, expires_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ]] .. expires_at_sql .. [[, NOW(), NOW())
        ON CONFLICT (user_uuid) DO UPDATE SET
            access_token  = EXCLUDED.access_token,
            refresh_token = EXCLUDED.refresh_token,
            scope         = EXCLUDED.scope,
            expires_at    = EXCLUDED.expires_at,
            updated_at    = NOW()
    ]], user_uuid, access_token, refresh_token or ngx.null, scope or ngx.null)
end

-- Get a valid (non-expired) token for a user.
-- Returns the row or nil.
function HMRCTokenQueries.getValid(user_uuid)
    local rows = db.query(
        "SELECT * FROM hmrc_tokens WHERE user_uuid = ? AND expires_at > NOW() LIMIT 1",
        user_uuid
    )
    if rows and #rows > 0 then
        return rows[1]
    end
    return nil
end

-- Delete a user's token (disconnect from HMRC).
function HMRCTokenQueries.delete(user_uuid)
    db.query("DELETE FROM hmrc_tokens WHERE user_uuid = ?", user_uuid)
end

return HMRCTokenQueries
