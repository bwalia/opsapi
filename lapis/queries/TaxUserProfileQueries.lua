--[[
    Tax User Profile Queries

    Manages tax_user_profiles table — stores user's HMRC profile info.
    NINO is stored as a bcrypt hash for security; only last 4 chars kept in plaintext.
    Even admins cannot see the full NINO.
]]

local db = require("lapis.db")
local bcrypt = require("bcrypt")
local Global = require("helper.global")

local TaxUserProfileQueries = {}

local BCRYPT_ROUNDS = 12

-- Get or create profile for a user
function TaxUserProfileQueries.getOrCreate(user_uuid, user_id)
    local rows = db.query(
        "SELECT * FROM tax_user_profiles WHERE user_uuid = ? LIMIT 1",
        user_uuid
    )
    if rows and #rows > 0 then
        return rows[1]
    end

    -- Resolve user_id if not provided
    if not user_id then
        local user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
        if not user_record or #user_record == 0 then
            return nil, "User not found"
        end
        user_id = user_record[1].id
    end

    -- Create empty profile
    db.query([[
        INSERT INTO tax_user_profiles (uuid, user_id, user_uuid, created_at, updated_at)
        VALUES (gen_random_uuid()::text, ?, ?, NOW(), NOW())
        ON CONFLICT (user_uuid) DO NOTHING
    ]], user_id, user_uuid)

    -- Re-fetch to get generated fields
    rows = db.query(
        "SELECT * FROM tax_user_profiles WHERE user_uuid = ? LIMIT 1",
        user_uuid
    )
    return rows and rows[1] or nil
end

-- Get profile (read-only, returns masked data)
function TaxUserProfileQueries.get(user_uuid)
    local rows = db.query(
        "SELECT * FROM tax_user_profiles WHERE user_uuid = ? LIMIT 1",
        user_uuid
    )
    if rows and #rows > 0 then
        return rows[1]
    end
    return nil
end

-- Save NINO (hashed) for a user
-- @param user_uuid  string  User UUID
-- @param nino       string  Full NINO (e.g. "QQ123456C")
function TaxUserProfileQueries.saveNino(user_uuid, nino)
    -- Normalize: uppercase, remove spaces
    nino = nino:upper():gsub("%s+", "")

    -- Validate NINO format: 2 letters + 6 digits + 1 letter
    if not nino:match("^%a%a%d%d%d%d%d%d%a$") then
        return nil, "Invalid NINO format. Expected: 2 letters + 6 digits + 1 letter (e.g. QQ123456C)"
    end

    -- Hash with bcrypt
    local hash = bcrypt.digest(nino, BCRYPT_ROUNDS)

    -- Extract last 4 characters for masked display
    local last4 = nino:sub(-4)

    -- Ensure profile exists
    local profile, err = TaxUserProfileQueries.getOrCreate(user_uuid)
    if not profile then
        return nil, err or "Failed to create profile"
    end

    db.query([[
        UPDATE tax_user_profiles
        SET nino_hash = ?, nino_last4 = ?, has_nino = true, updated_at = NOW()
        WHERE user_uuid = ?
    ]], hash, last4, user_uuid)

    return { success = true, nino_last4 = last4 }
end

-- Verify a NINO against the stored hash
-- @param user_uuid  string
-- @param nino       string  Full NINO to verify
-- @return boolean
function TaxUserProfileQueries.verifyNino(user_uuid, nino)
    local profile = TaxUserProfileQueries.get(user_uuid)
    if not profile or not profile.nino_hash then
        return false
    end

    nino = nino:upper():gsub("%s+", "")
    return bcrypt.verify(nino, profile.nino_hash)
end

-- Remove NINO from profile
function TaxUserProfileQueries.removeNino(user_uuid)
    db.query([[
        UPDATE tax_user_profiles
        SET nino_hash = NULL, nino_last4 = NULL, has_nino = false, updated_at = NOW()
        WHERE user_uuid = ?
    ]], user_uuid)
    return { success = true }
end

-- Update default business ID
function TaxUserProfileQueries.setDefaultBusiness(user_uuid, business_id)
    db.query([[
        UPDATE tax_user_profiles
        SET default_business_id = ?, updated_at = NOW()
        WHERE user_uuid = ?
    ]], business_id, user_uuid)
    return { success = true }
end

-- Update default tax year
function TaxUserProfileQueries.setDefaultTaxYear(user_uuid, tax_year)
    db.query([[
        UPDATE tax_user_profiles
        SET default_tax_year = ?, updated_at = NOW()
        WHERE user_uuid = ?
    ]], tax_year, user_uuid)
    return { success = true }
end

-- Update HMRC connected status
function TaxUserProfileQueries.setHmrcConnected(user_uuid, connected)
    db.query([[
        UPDATE tax_user_profiles
        SET hmrc_connected = ?, updated_at = NOW()
        WHERE user_uuid = ?
    ]], connected, user_uuid)
    return { success = true }
end

return TaxUserProfileQueries
