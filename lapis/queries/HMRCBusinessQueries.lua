--[[
    HMRC Business Queries

    Caches HMRC business details fetched via MTD Business Details API.
    Avoids repeated API calls — data changes rarely.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local HMRCBusinessQueries = {}

-- Upsert a business (insert or update on user_uuid + business_id conflict)
function HMRCBusinessQueries.upsert(data)
    db.query([[
        INSERT INTO hmrc_businesses (
            uuid, user_uuid, business_id, type_of_business,
            trading_name, accounting_type,
            first_accounting_period_start, first_accounting_period_end,
            raw_response, fetched_at, created_at, updated_at
        ) VALUES (
            gen_random_uuid()::text, ?, ?, ?,
            ?, ?,
            ?, ?,
            ?, NOW(), NOW(), NOW()
        )
        ON CONFLICT (user_uuid, business_id) DO UPDATE SET
            type_of_business = EXCLUDED.type_of_business,
            trading_name = EXCLUDED.trading_name,
            accounting_type = EXCLUDED.accounting_type,
            first_accounting_period_start = EXCLUDED.first_accounting_period_start,
            first_accounting_period_end = EXCLUDED.first_accounting_period_end,
            raw_response = EXCLUDED.raw_response,
            fetched_at = NOW(),
            updated_at = NOW()
    ]],
        data.user_uuid,
        data.business_id,
        data.type_of_business or "self-employment",
        data.trading_name,
        data.accounting_type,
        data.first_accounting_period_start,
        data.first_accounting_period_end,
        data.raw_response
    )
end

-- Get all businesses for a user
function HMRCBusinessQueries.allForUser(user_uuid)
    return db.query(
        "SELECT * FROM hmrc_businesses WHERE user_uuid = ? ORDER BY created_at ASC",
        user_uuid
    )
end

-- Get a specific business by business_id
function HMRCBusinessQueries.getByBusinessId(user_uuid, business_id)
    local rows = db.query(
        "SELECT * FROM hmrc_businesses WHERE user_uuid = ? AND business_id = ? LIMIT 1",
        user_uuid, business_id
    )
    if rows and #rows > 0 then
        return rows[1]
    end
    return nil
end

-- Delete all businesses for a user (used when refreshing from HMRC)
function HMRCBusinessQueries.deleteAllForUser(user_uuid)
    db.query("DELETE FROM hmrc_businesses WHERE user_uuid = ?", user_uuid)
end

return HMRCBusinessQueries
