--[[
    Identity lock — default posture flip (client ask, 2026-08-06).

    The original anti-fraud requirement ("NINO/UTR freeze after first
    save", PR #464) has been reversed by the client: users must be able
    to correct their own NINO and UTR from profile setup and settings.

    This migration flips the per-namespace policy to "editable":
      - existing identity_lock_settings rows get both lock flags off;
      - the column DEFAULTs flip so rows created later by the admin
        settings page start unlocked too;
      - lib/identity_lock.lua's no-row fallback was flipped in the same
        PR, covering namespaces with no settings row at all.

    NOTHING else is removed. Lock stamps (nino_locked_at /
    utr_locked_at) stay on tax_user_profiles for audit; the enforcement
    library, admin unlock route and RBAC module are intact. A tenant
    that wants the freeze back re-enables nino_lock_enabled /
    utr_lock_enabled in the identity-lock admin settings and every
    existing stamp bites again immediately (the read/write paths gate
    on policy, not on this migration).

    nino_uniqueness_enforced is deliberately untouched — the
    same-NINO-in-two-accounts check guards a different fraud vector
    and doesn't stop a user correcting their own record.
--]]

local db = require "lapis.db"

return {
    [1] = function()
        db.query([[
            UPDATE identity_lock_settings
            SET nino_lock_enabled = false,
                utr_lock_enabled  = false,
                updated_at        = NOW()
            WHERE nino_lock_enabled = true OR utr_lock_enabled = true
        ]])
        db.query([[
            ALTER TABLE identity_lock_settings
            ALTER COLUMN nino_lock_enabled SET DEFAULT false
        ]])
        db.query([[
            ALTER TABLE identity_lock_settings
            ALTER COLUMN utr_lock_enabled SET DEFAULT false
        ]])
        print("[Tax Copilot] Identity lock disabled by default (NINO/UTR user-editable)")
    end,
}
