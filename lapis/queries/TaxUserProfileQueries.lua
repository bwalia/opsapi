--[[
    Tax User Profile Queries

    Manages tax_user_profiles table — stores user's HMRC profile info.
    NINO is stored as a bcrypt hash for security; only last 4 chars kept in plaintext.
    Even admins cannot see the full NINO.
]]

local db = require("lapis.db")
local bcrypt = require("bcrypt")
local Global = require("helper.global")
local NamespaceResolver = require("helper.namespace-resolver")
local IdentityLock = require("lib.identity_lock")

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

    -- Create empty profile. tax_user_profiles.namespace_id is NOT NULL
    -- with no DB default — must be set on the INSERT. NOT NULL is checked
    -- BEFORE the ON CONFLICT path fires, so it can't be skipped just
    -- because a row already exists.
    local namespace_id = NamespaceResolver.getByUuid(user_uuid)
    db.query([[
        INSERT INTO tax_user_profiles (uuid, user_id, user_uuid, namespace_id, created_at, updated_at)
        VALUES (gen_random_uuid()::text, ?, ?, ?, NOW(), NOW())
        ON CONFLICT (user_uuid) DO NOTHING
    ]], user_id, user_uuid, namespace_id)

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

    -- Ensure profile exists (creates the namespace-scoped row if missing)
    local profile, err = TaxUserProfileQueries.getOrCreate(user_uuid)
    if not profile then
        return nil, err or "Failed to create profile"
    end
    local namespace_id = profile.namespace_id

    -- ─── Anti-fraud guards (see lapis/lib/identity_lock.lua for design) ───
    -- 1. If the field is already locked (previous first-save), this raises
    --    a catalog 403 with support_url / support_email — the caller's
    --    error middleware surfaces it to the FE.
    IdentityLock.assertNotLocked(user_uuid, namespace_id, "nino")

    -- Hash + encrypt + last4 (compute BEFORE opening the txn so cheap
    -- work isn't inside the advisory-lock hold).
    local hash      = bcrypt.digest(nino, BCRYPT_ROUNDS)
    local encrypted = Global.encryptSecret(nino)
    local last4     = nino:sub(-4)

    -- 2. + 3. Uniqueness check + write must be one transaction so the
    --    advisory lock the guard takes covers the write. Any concurrent
    --    save of the same NINO in the same namespace serializes here.
    db.query("BEGIN")
    local ok, txn_err = pcall(function()
        IdentityLock.assertNinoUniqueInNamespace(profile.user_id, namespace_id, nino, Global)

        db.query([[
            UPDATE tax_user_profiles
            SET nino_hash = ?, nino_last4 = ?, nino_encrypted = ?,
                has_nino = true, updated_at = NOW()
            WHERE user_uuid = ? AND namespace_id = ?
        ]], hash, last4, encrypted, user_uuid, namespace_id)

        -- 4. Stamp the lock in the SAME txn as the successful save so
        --    "saved but forgot to lock" is impossible.
        IdentityLock.stampLock(user_uuid, namespace_id, "nino")
    end)
    if not ok then
        db.query("ROLLBACK")
        error(txn_err)  -- re-raise (may be a catalog Errors.raise or a Lua error)
    end
    db.query("COMMIT")

    -- 5. Audit-log entry for the first save. Failures are logged but
    --    do NOT block success (see IdentityLock.emitAuditRow's pcall).
    IdentityLock.emitAuditRow({
        user_id      = profile.user_id,
        namespace_id = namespace_id,
        action       = "NINO_SAVED_AND_LOCKED",
        new_values   = { nino_last4 = last4 },
    })

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

-- Decrypt and return NINO for server-side HMRC API calls
-- This should NEVER be exposed to the frontend
function TaxUserProfileQueries.getNinoDecrypted(user_uuid)
    local rows = db.query(
        "SELECT nino_encrypted FROM tax_user_profiles WHERE user_uuid = ? AND has_nino = true LIMIT 1",
        user_uuid
    )
    if rows and #rows > 0 and rows[1].nino_encrypted then
        return Global.decryptSecret(rows[1].nino_encrypted)
    end
    return nil
end

-- Remove NINO from profile.
--
-- Blocked when nino_locked_at IS NOT NULL — a locked NINO is
-- permanent per HMRC record-keeping expectations (the filed return
-- carries this NINO). To reset, admin must UNLOCK first via
-- POST /api/v2/admin/tax-user-profiles/{uuid}/unlock — that endpoint
-- writes an audit row with the admin's reason.
function TaxUserProfileQueries.removeNino(user_uuid)
    local profile = TaxUserProfileQueries.get(user_uuid)
    if not profile then
        return { success = true }  -- Idempotent: nothing to remove
    end
    local namespace_id = profile.namespace_id

    -- Guards the "sneaky delete then re-save" workaround for the lock.
    IdentityLock.assertNotLocked(user_uuid, namespace_id, "nino")

    db.query([[
        UPDATE tax_user_profiles
        SET nino_hash = NULL, nino_last4 = NULL, nino_encrypted = NULL,
            has_nino = false, updated_at = NOW()
        WHERE user_uuid = ? AND namespace_id = ?
    ]], user_uuid, namespace_id)

    IdentityLock.emitAuditRow({
        user_id      = profile.user_id,
        namespace_id = namespace_id,
        action       = "NINO_REMOVED",
        old_values   = { nino_last4 = profile.nino_last4 },
    })

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

-- Update the user's default business profile key (e.g. "sole_trader", "amazon_seller").
function TaxUserProfileQueries.setDefaultProfileKey(user_uuid, profile_key)
    db.query([[
        UPDATE tax_user_profiles
        SET default_profile_key = ?, updated_at = NOW()
        WHERE user_uuid = ?
    ]], profile_key, user_uuid)
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
