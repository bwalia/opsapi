local db = require("lapis.db")

-- Phone-verification codes for delivery partners (routes/delivery-partner-verification.lua).
-- In Postgres so a code sent through one pod verifies on another; one live
-- code per user, stored as an HMAC.
return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS delivery_partner_otps (
                user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                phone TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                expires_at TIMESTAMP NOT NULL,
                created_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
    end,
}
