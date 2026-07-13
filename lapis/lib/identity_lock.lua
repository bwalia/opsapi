--[[
    Identity Lock — anti-fraud enforcement for NINO / UTR.

    Purpose
    -------
    Client requirement (2026-07-13): one subscriber must not be able to
    file for multiple identities from a single account. Concrete rule:

        NINO becomes non-editable once the user first saves it.
        UTR  becomes non-editable once the user first successfully writes it.

    Support can UNLOCK on request via the admin panel; every lock/unlock
    action goes to tax_audit_logs.

    Data model (established by migrations [88] + [89])
    --------------------------------------------------
        tax_user_profiles.nino_locked_at TIMESTAMP  -- per-user lock state
        tax_user_profiles.utr_locked_at  TIMESTAMP
        identity_lock_settings           -- per-namespace policy (kill switch,
                                            confirmation modal, backfill dates,
                                            uniqueness enforcement, etc.)

    Guards defined here are called from:
        - queries/TaxUserProfileQueries.saveNino / removeNino  (dedicated NINO path)
        - routes/tax-hmrc-data.lua POST /nino + sandbox provisioner
        - routes/profile-builder.lua POST /answers (back-door for nino/ni_number/utr_number)

    Errors raised
    -------------
    Uses Errors.raise() → catalog envelope. See migration [90] for the
    IDENTITY_LOCK_ACTIVE + NINO_ALREADY_REGISTERED catalog rows.

    Design principles
    -----------------
    1. Namespace scoping is MANDATORY. Every read/write here takes
       namespace_id and includes it in the WHERE clause. Cross-tenant
       leakage would be a P0 anti-fraud incident.
    2. Uniqueness enforcement uses a PostgreSQL advisory transaction
       lock keyed by (namespace_id, nino_last4) so two concurrent saves
       of the same NINO serialize safely — the second sees the first's
       committed row and gets rejected. Cheaper than serializable
       txn isolation; released automatically at txn end.
    3. All error responses include a `support_url` and `support_email`
       so the FE can render a "way out" per client's professional-site
       requirement. No dead-end 403s.
    4. Every write path calls these helpers defensively — even if the
       route is thought to be admin-only, the helpers guard everything.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Errors = require("lib.errors")

local IdentityLock = {}

-- ─── Configuration ──────────────────────────────────────────────────────
-- Support surfaces baked into every locked-field error response. Kept as
-- module-level defaults so the FE always gets at least SOMETHING to
-- render; per-tenant overrides can be added later via the settings row
-- (announcement_banner_message is the closest existing knob).
local DEFAULT_SUPPORT_URL   = "/support"
local DEFAULT_SUPPORT_EMAIL = "support@diytaxreturn.co.uk"

-- ─── Helpers ────────────────────────────────────────────────────────────

--- Look up the policy row for a namespace. Returns a table (possibly
--- with all-default values if no row exists yet — admins may not have
--- visited the settings page yet). Never nil.
--- @param namespace_id integer
--- @return table
function IdentityLock.getPolicy(namespace_id)
    local rows = db.query([[
        SELECT nino_lock_enabled, nino_confirmation_required,
               nino_backfill_scheduled_at, nino_uniqueness_enforced,
               utr_lock_enabled, utr_backfill_enabled,
               utr_backfill_scheduled_at
        FROM identity_lock_settings
        WHERE namespace_id = ?
        LIMIT 1
    ]], namespace_id)
    if rows and #rows > 0 then
        return rows[1]
    end
    -- Sane defaults matching the migration's DEFAULT clauses. If the
    -- settings row is missing (tenant hasn't opened the admin UI yet),
    -- we STILL enforce the lock — the client's whole ask is anti-fraud,
    -- so the default posture is "protected".
    return {
        nino_lock_enabled           = true,
        nino_confirmation_required  = true,
        nino_backfill_scheduled_at  = nil,
        nino_uniqueness_enforced    = true,
        utr_lock_enabled            = true,
        utr_backfill_enabled        = false,
        utr_backfill_scheduled_at   = nil,
    }
end

--- Read the current lock state for a user. Returns { nino_locked_at,
--- utr_locked_at, has_nino } — any may be nil.
--- @param user_uuid string
--- @param namespace_id integer
--- @return table|nil
function IdentityLock.getState(user_uuid, namespace_id)
    local rows = db.query([[
        SELECT nino_locked_at, utr_locked_at, has_nino, nino_last4
        FROM tax_user_profiles
        WHERE user_uuid = ? AND namespace_id = ?
        LIMIT 1
    ]], user_uuid, namespace_id)
    return (rows and rows[1]) or nil
end

--- Build the "way out" fields every locked-field error carries. Client's
--- ask (2026-07-13): "user should know the valid reason and there must
--- be always a way out". Same structure regardless of NINO vs UTR.
--- @param field string  "nino" or "utr"
--- @param locked_at string|nil  ISO timestamp
--- @return table
local function buildLockContext(field, locked_at)
    local pretty_field = (field == "nino") and "National Insurance Number (NINO)" or "UTR (Unique Taxpayer Reference)"
    return {
        field         = field,
        locked_at     = locked_at,
        support_url   = DEFAULT_SUPPORT_URL,
        support_email = DEFAULT_SUPPORT_EMAIL,
        user_message  = string.format(
            "Your %s is on file and cannot be changed. To correct it, please chat with support (%s) or email %s.",
            pretty_field, DEFAULT_SUPPORT_URL, DEFAULT_SUPPORT_EMAIL
        ),
    }
end

--- Raise a 403 with the IDENTITY_LOCK_ACTIVE code. See migration [90]
--- for the catalog row. `field` is "nino" or "utr".
--- @param field string
--- @param locked_at string|nil
local function raiseLocked(field, locked_at)
    local ctx = buildLockContext(field, locked_at)
    Errors.raise("IDENTITY_LOCK_ACTIVE", ctx)
end

-- ─── Public API ─────────────────────────────────────────────────────────

--- Assert that the given field is NOT locked for this user. Idempotent
--- — safe to call before every write. Raises catalog error if locked.
---
--- Also acts as the JIT-backfill trigger: if policy has a
--- `<field>_backfill_scheduled_at` in the past AND the user's lock
--- timestamp is currently NULL AND they have the field on file, this
--- stamps the lock timestamp before raising. That means a scheduled
--- backfill kicks in as soon as the user next TRIES to edit, without
--- needing a separate cron sweeper.
---
--- @param user_uuid string
--- @param namespace_id integer
--- @param field string  "nino" or "utr"
function IdentityLock.assertNotLocked(user_uuid, namespace_id, field)
    assert(field == "nino" or field == "utr", "field must be 'nino' or 'utr'")

    local policy = IdentityLock.getPolicy(namespace_id)
    -- Master kill-switch per tenant. If the admin turned off lock
    -- enforcement for this namespace, skip the guard entirely.
    local enabled_flag = (field == "nino") and policy.nino_lock_enabled or policy.utr_lock_enabled
    if not enabled_flag then
        return
    end

    local state = IdentityLock.getState(user_uuid, namespace_id)
    if not state then
        -- No profile row yet → nothing to be locked. First save creates
        -- the row (via getOrCreate) and stamps the lock in the same txn.
        return
    end

    local locked_at_field = (field == "nino") and "nino_locked_at" or "utr_locked_at"
    local current_lock = state[locked_at_field]

    if current_lock then
        raiseLocked(field, tostring(current_lock))
    end

    -- JIT backfill: policy says "lock all existing entries at time T".
    -- If we're past T and the user has the field on file, stamp now.
    -- Kept-here-not-in-a-cron: admin sets scheduled_at once, and it
    -- takes effect naturally on the user's next write attempt. No
    -- cron/worker infrastructure needed.
    local scheduled_col = (field == "nino") and "nino_backfill_scheduled_at" or "utr_backfill_scheduled_at"
    local scheduled_at  = policy[scheduled_col]
    if scheduled_at then
        -- Backfill only makes sense if the user actually has the field.
        -- For NINO this is easy: has_nino=true. For UTR the presence
        -- signal lives in user_profile_answers (question_key='utr_number')
        -- — checked below on demand.
        local should_backfill = false
        if field == "nino" then
            should_backfill = state.has_nino
        else
            -- UTR — has to peek at profile_builder answers.
            local utr_rows = db.query([[
                SELECT 1 FROM user_profile_answers upa
                JOIN profile_questions pq ON pq.id = upa.question_id
                WHERE upa.user_uuid = ?
                  AND upa.namespace_id = ?
                  AND pq.question_key = 'utr_number'
                  AND upa.answer_text IS NOT NULL
                LIMIT 1
            ]], user_uuid, namespace_id)
            should_backfill = utr_rows and #utr_rows > 0
        end

        if should_backfill then
            -- Two conditions must BOTH hold to actually stamp:
            --   1. scheduled_at is in the past (or now)
            --   2. Current lock is still NULL
            -- Idempotent CTE UPDATE handles both in one round-trip.
            db.query(string.format([[
                UPDATE tax_user_profiles
                SET %s = NOW(), updated_at = NOW()
                WHERE user_uuid = ?
                  AND namespace_id = ?
                  AND %s IS NULL
                  AND ? <= NOW()
            ]], locked_at_field, locked_at_field), user_uuid, namespace_id, scheduled_at)

            -- Now re-read to see if we just stamped. If yes, raise.
            local restate = IdentityLock.getState(user_uuid, namespace_id)
            if restate and restate[locked_at_field] then
                raiseLocked(field, tostring(restate[locked_at_field]))
            end
        end
    end
end

--- Stamp the lock timestamp in the same transaction as the successful
--- write. Idempotent — if `<field>_locked_at` is already set, this is
--- a no-op (preserving the ORIGINAL lock time in perpetuity, which is
--- the correct audit semantic).
---
--- Call this AFTER the write query succeeds, not before.
---
--- @param user_uuid string
--- @param namespace_id integer
--- @param field string
function IdentityLock.stampLock(user_uuid, namespace_id, field)
    assert(field == "nino" or field == "utr", "field must be 'nino' or 'utr'")

    -- Respect the master switch. If the admin disabled lock enforcement
    -- for this tenant, we don't stamp either (so re-enabling later starts
    -- fresh from the next-first-write, not a historical event).
    local policy = IdentityLock.getPolicy(namespace_id)
    local enabled_flag = (field == "nino") and policy.nino_lock_enabled or policy.utr_lock_enabled
    if not enabled_flag then
        return
    end

    local locked_at_field = (field == "nino") and "nino_locked_at" or "utr_locked_at"
    db.query(string.format([[
        UPDATE tax_user_profiles
        SET %s = COALESCE(%s, NOW()), updated_at = NOW()
        WHERE user_uuid = ?
          AND namespace_id = ?
    ]], locked_at_field, locked_at_field), user_uuid, namespace_id)
end

--- Enforce NINO uniqueness within a namespace. Prevents the second-
--- account-same-NINO fraud vector: someone creating a new subscription
--- and re-using an already-registered NINO.
---
--- Algorithm (see design PR body for rationale):
---   1. Acquire an advisory transaction lock keyed by
---      (namespace_id, nino_last4). Cheap; serializes only the tiny
---      fraction of writes that share the same last4.
---   2. Fetch every OTHER user's profile in this namespace where
---      nino_last4 matches the submitted last4.
---   3. For each candidate, decrypt nino_encrypted and compare against
---      the submitted plaintext.
---   4. If any match → raise NINO_ALREADY_REGISTERED (409).
---
--- MUST be called INSIDE a transaction, otherwise the advisory lock is
--- released immediately and provides no ordering guarantee. Callers use
--- `db.query("BEGIN")` / `db.query("COMMIT")` around the guard + write.
---
--- @param current_user_id integer  the acting user's id (excluded from candidates)
--- @param namespace_id integer
--- @param submitted_nino_normalized string  Already uppercased/space-stripped
--- @param Global table  helper.global (dependency-injected to avoid circular require)
function IdentityLock.assertNinoUniqueInNamespace(current_user_id, namespace_id, submitted_nino_normalized, Global)
    -- Skip when tenant disabled uniqueness (admin toggle).
    local policy = IdentityLock.getPolicy(namespace_id)
    if not policy.nino_uniqueness_enforced then
        return
    end

    local submitted_last4 = submitted_nino_normalized:sub(-4)

    -- 1. Advisory lock (PG advisory_xact_lock takes int8; hashtext() is
    -- deterministic and fast). Composite key = namespace_id + last4.
    db.query(
        "SELECT pg_advisory_xact_lock(hashtext(? || ':' || ?))",
        tostring(namespace_id), submitted_last4
    )

    -- 2. Find candidates (usually 0 or 1 — collisions on 4-char last4
    -- within a single tenant are rare).
    local candidates = db.query([[
        SELECT user_id, nino_encrypted
        FROM tax_user_profiles
        WHERE namespace_id = ?
          AND nino_last4 = ?
          AND user_id != ?
          AND has_nino = true
    ]], namespace_id, submitted_last4, current_user_id)

    if not candidates or #candidates == 0 then
        return
    end

    -- 3. Decrypt each candidate and compare. Rare path (last4 collision)
    -- so the cost of AES decrypt here is negligible on the aggregate.
    for _, row in ipairs(candidates) do
        if row.nino_encrypted then
            local existing = Global.decryptSecret(row.nino_encrypted)
            if existing and existing:upper() == submitted_nino_normalized:upper() then
                Errors.raise("NINO_ALREADY_REGISTERED", {
                    support_url   = DEFAULT_SUPPORT_URL,
                    support_email = DEFAULT_SUPPORT_EMAIL,
                    user_message  = "This National Insurance Number is already registered on another account. If this is your NINO, please chat with support (" .. DEFAULT_SUPPORT_URL .. ") or email " .. DEFAULT_SUPPORT_EMAIL .. ".",
                })
            end
        end
    end
end

--- Write an audit-log row for a lock/unlock event. Uses tax_audit_logs
--- with entity_type='TAX_USER_PROFILE'. Wraps db.insert in a pcall so
--- an audit failure NEVER blocks the primary action (loud logs, but
--- unlock still succeeds — auditing is defence-in-depth, not the
--- primary control).
---
--- @param opts table  { user_id, admin_user_id, namespace_id, action, old_values, new_values, reason, request_ip }
function IdentityLock.emitAuditRow(opts)
    local ok, err = pcall(function()
        db.insert("tax_audit_logs", {
            uuid          = db.raw("gen_random_uuid()::text"),
            entity_type   = "TAX_USER_PROFILE",
            entity_id     = tostring(opts.user_id or ""),
            action        = opts.action,
            user_id       = opts.admin_user_id or opts.user_id,
            old_values    = opts.old_values and cjson.encode(opts.old_values) or db.NULL,
            new_values    = opts.new_values and cjson.encode(opts.new_values) or db.NULL,
            change_reason = opts.reason or db.NULL,
            ip_address    = opts.request_ip or db.NULL,
            created_at    = db.raw("NOW()"),
        })
    end)
    if not ok then
        ngx.log(ngx.ERR, "[IdentityLock] audit write failed: ", tostring(err))
    end
end

return IdentityLock
