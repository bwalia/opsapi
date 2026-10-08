--[[
    Auth hardening (core)
    =====================
      [1] auth_throttle  cluster-wide counters for per-account limits that a
                         client can't dodge by changing IP (helper/auth-throttle.lua):
                         failed passwords per account, OTP sends and failed OTP
                         checks per user.
      [2] admin_otp_codes: codes are stored as an HMAC, never in plain text
                         (code_hash); `code` is left NULL. peek_code holds a copy
                         only for E2E test mailboxes outside production
                         (routes/e2e-otp.lua).
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS auth_throttle (
                key TEXT PRIMARY KEY,
                count INTEGER NOT NULL DEFAULT 0,
                window_start TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS auth_throttle_window_idx ON auth_throttle (window_start)")
    end,

    [2] = function()
        db.query("ALTER TABLE admin_otp_codes ADD COLUMN IF NOT EXISTS code_hash TEXT")
        db.query("ALTER TABLE admin_otp_codes ADD COLUMN IF NOT EXISTS peek_code TEXT")
        db.query("ALTER TABLE admin_otp_codes ALTER COLUMN code DROP NOT NULL")
        -- Codes live 5 minutes: drop any plain ones left from before this migration.
        db.query("DELETE FROM admin_otp_codes WHERE code_hash IS NULL")
    end,
}
