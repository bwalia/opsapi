--[[
    VAT management (VAT plan phase 6): vat_reminders — which deadline reminders were
    sent (14 days, 3 days, overdue), so each goes out once. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_reminders (
                id SERIAL PRIMARY KEY,
                registration_id INTEGER NOT NULL,
                period_end DATE NOT NULL,
                kind VARCHAR(20) NOT NULL,
                sent_at TIMESTAMP NOT NULL DEFAULT NOW(),
                UNIQUE (registration_id, period_end, kind)
            )
        ]])
    end,
}
