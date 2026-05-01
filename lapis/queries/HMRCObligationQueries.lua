--[[
    HMRC Obligation Queries

    Caches quarterly obligation periods fetched from HMRC Obligations API.
    Tracks which quarters are Open vs Fulfilled for a given tax year.
]]

local db = require("lapis.db")

local HMRCObligationQueries = {}

-- Upsert an obligation (insert or update on user_uuid + business_id + period conflict)
function HMRCObligationQueries.upsert(data)
    db.query([[
        INSERT INTO hmrc_obligations (
            uuid, user_uuid, business_id, tax_year,
            period_start, period_end, due_date, status,
            received_date, period_key,
            fetched_at, created_at, updated_at
        ) VALUES (
            gen_random_uuid()::text, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?,
            NOW(), NOW(), NOW()
        )
        ON CONFLICT (user_uuid, business_id, period_start, period_end) DO UPDATE SET
            tax_year = EXCLUDED.tax_year,
            due_date = EXCLUDED.due_date,
            status = EXCLUDED.status,
            received_date = EXCLUDED.received_date,
            period_key = EXCLUDED.period_key,
            fetched_at = NOW(),
            updated_at = NOW()
    ]],
        data.user_uuid,
        data.business_id,
        data.tax_year,
        data.period_start,
        data.period_end,
        data.due_date,
        data.status or "Open",
        data.received_date,
        data.period_key
    )
end

-- Get all obligations for a user + business + tax year
function HMRCObligationQueries.forTaxYear(user_uuid, business_id, tax_year)
    return db.query([[
        SELECT * FROM hmrc_obligations
        WHERE user_uuid = ? AND business_id = ? AND tax_year = ?
        ORDER BY period_start ASC
    ]], user_uuid, business_id, tax_year)
end

-- Get all obligations for a user (all years)
function HMRCObligationQueries.allForUser(user_uuid)
    return db.query([[
        SELECT * FROM hmrc_obligations
        WHERE user_uuid = ?
        ORDER BY tax_year DESC, period_start ASC
    ]], user_uuid)
end

-- Get open (pending) obligations for a user
function HMRCObligationQueries.openForUser(user_uuid)
    return db.query([[
        SELECT * FROM hmrc_obligations
        WHERE user_uuid = ? AND status = 'Open'
        ORDER BY due_date ASC
    ]], user_uuid)
end

-- Delete all obligations for a user + business (used when refreshing from HMRC)
function HMRCObligationQueries.deleteForBusiness(user_uuid, business_id)
    db.query(
        "DELETE FROM hmrc_obligations WHERE user_uuid = ? AND business_id = ?",
        user_uuid, business_id
    )
end

return HMRCObligationQueries
