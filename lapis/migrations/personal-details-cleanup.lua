--[[
    Personal Details section cleanup.

    Two symptoms drove this:
      1. The wizard-tree seed (`dynamic-profile-builder.lua` [35])
         added `surname` and `ni_number` on top of the earlier seed's
         `last_name` and `nino`. Both pairs sit in the same category,
         which meant every /profile page rendered TWO family-name
         inputs and TWO NINO inputs. Users typed each with a different
         value, both went into the same save batch, and the schema-
         level ambiguity was the root cause of the IDENTITY_LOCK_ACTIVE
         batch failure fixed in the profile-builder route change of
         2026-07-29 (see routes/profile-builder.lua).
      2. NINO fields accepted arbitrary strings — "472", "abc", etc.
         The identity-lock was stamping on any first save, even one
         with garbage in it. Once garbage was stored the whole field
         was frozen forever with no valid value on record.

    Fix (all changes are idempotent):
      [1] Backfill validation_json + is_required on the canonical
          `nino` question so garbage is rejected at /answers/validate
          time and the frontend can render an inline format hint.
          Only rewrites rows where validation_json is NULL/'' so an
          admin's tightening (e.g. a stricter suffix rule) is
          preserved on re-run.

      [2] Soft-delete `surname` (is_active=false + is_archived=true).
          Not a hard DELETE — user_profile_answers rows carrying past
          surname values remain in the database, unreachable through
          the /schema and /answers endpoints but recoverable by an
          admin unarchiving via the admin UI if a tenant genuinely
          needs the distinction. `last_name` remains as the canonical
          family-name question.

      [3] Soft-delete `ni_number`, same treatment. `nino` (with the
          validation added in [1]) is now the sole NINO write path.
          The anti-fraud lock (nino_locked_at) still applies — that's
          per-user, not per-question_key — and the profile-builder
          route's per-answer error path handles any stale client that
          still ships an ni_number value in the payload during the
          rollout window.

    Rollback: an admin can un-archive either question via
    /admin/profile-builder/questions/<uuid> (PATCH is_archived=false,
    is_active=true) — no schema change needed. See routes/profile-
    builder.lua:2492 for the whitelisted admin update fields.

    A companion change trims `surname` + `ni_number` out of the
    wizard-tree seed's ensure_question list in
    dynamic-profile-builder.lua so fresh installs never introduce the
    duplicates in the first place. That prevents ensure_question's
    UPDATE branch from re-activating them on any future re-run of the
    seed migration.
--]]

local db = require "lapis.db"
local cjson = require "cjson"

-- UK NINO format. Applied by the profile-builder /answers/validate
-- endpoint via Lua's string.match, so this is a LUA pattern (not a
-- PCRE regex). Accepts either the compact "QQ123456C" or the spaced
-- forms HMRC's own site suggests ("QQ 12 34 56 C" / "QQ 123456 C").
-- Case-insensitive by construction ([A-Za-z] covers both).
--
-- Deliberately does NOT enforce the tighter HMRC rules (excluded
-- prefixes like DFIQUV / trailing letter restricted to A/B/C/D) —
-- those change over time and are safer left to admin tightening than
-- baked into the seed. Format-shape rejection catches the actual
-- garbage users have been submitting.
local NINO_PATTERN = "^%s*[A-Za-z][A-Za-z]%s*%d%s*%d%s*%d%s*%d%s*%d%s*%d%s*[A-Za-z]%s*$"

local NINO_VALIDATION = cjson.encode({
    pattern         = NINO_PATTERN,
    pattern_message = "Please enter a valid National Insurance Number (2 letters + 6 digits + 1 letter, e.g. QQ 12 34 56 C).",
    -- 9 canonical chars, up to 4 spaces if the user pastes it with
    -- HMRC's own formatting.
    min_length      = 9,
    max_length      = 13,
})

return {
    -- =========================================================================
    -- 1. Backfill validation + required flag on the canonical `nino`.
    -- =========================================================================
    [1] = function()
        db.query([[
            UPDATE profile_questions
            SET validation_json = ?,
                is_required     = true,
                updated_at      = NOW()
            WHERE question_key = 'nino'
              AND (validation_json IS NULL OR validation_json = '')
        ]], NINO_VALIDATION)
        print("[Personal Details] Backfilled NINO format validation on `nino` question")
    end,

    -- =========================================================================
    -- 2. Deactivate the duplicate `surname` question.
    --    `last_name` (from the earlier seed) is the canonical family-name.
    -- =========================================================================
    [2] = function()
        db.query([[
            UPDATE profile_questions
            SET is_active   = false,
                is_archived = true,
                updated_at  = NOW()
            WHERE question_key = 'surname'
              AND (is_active = true OR is_archived = false)
        ]])
        print("[Personal Details] Deactivated redundant `surname` question (last_name is canonical)")
    end,

    -- =========================================================================
    -- 3. Copy ni_number answer_text into nino for users who only have the
    --    value stored under the deprecated key. Prevents user-visible data
    --    loss when the frontend flips to the `nino` question: without this,
    --    a user whose canonical NINO lives under `ni_number` sees an empty
    --    (locked) nino input instead of the value they'd entered.
    --
    --    Idempotent: NOT EXISTS guards against re-insert on re-run and
    --    against overwriting a nino answer the user already has (in which
    --    case that answer is trusted and we leave ni_number's stale copy
    --    alone). Only user-scope answers are copied (entity_uuid IS NULL
    --    AND tax_year IS NULL — identity questions live in the classic
    --    per-user scope; the profile-builder route enforces the same
    --    invariant on writes via `not entity_uuid and not tax_year` around
    --    stampLock).
    --
    --    Values that fail the NINO regex added in step [1] still get
    --    copied — the goal here is data continuity, not automated
    --    cleanup. Users with historically invalid data will see it in
    --    the (locked) input and can request an admin unlock via /support
    --    to correct it; the format regex will then reject the retry until
    --    they enter a valid NINO.
    -- =========================================================================
    [3] = function()
        db.query([[
            INSERT INTO user_profile_answers (
                uuid, user_id, user_uuid, namespace_id,
                question_id, question_version,
                answer_text, is_draft, answered_at, updated_at
            )
            SELECT
                gen_random_uuid()::text,
                src.user_id, src.user_uuid, src.namespace_id,
                nino_q.id, COALESCE(nino_q.version, 1),
                src.answer_text, false, NOW(), NOW()
            FROM user_profile_answers src
            JOIN profile_questions ni_q  ON ni_q.id  = src.question_id AND ni_q.question_key  = 'ni_number'
            CROSS JOIN (SELECT id, version FROM profile_questions WHERE question_key = 'nino' LIMIT 1) nino_q
            WHERE src.entity_uuid IS NULL
              AND src.tax_year    IS NULL
              AND src.answer_text IS NOT NULL
              AND src.answer_text <> ''
              AND NOT EXISTS (
                  SELECT 1
                  FROM user_profile_answers dst
                  WHERE dst.user_id     = src.user_id
                    AND dst.question_id = nino_q.id
                    AND dst.entity_uuid IS NULL
                    AND dst.tax_year    IS NULL
              )
        ]])
        print("[Personal Details] Migrated ni_number → nino answers for users without a canonical nino row")
    end,

    -- =========================================================================
    -- 4. Deactivate the duplicate `ni_number` question. Must run AFTER
    --    step [3] — soft-deleting before copying would still expose the
    --    values via ni_q lookups in [3], but keeping the intended order
    --    makes the intent obvious for future readers.
    -- =========================================================================
    [4] = function()
        db.query([[
            UPDATE profile_questions
            SET is_active   = false,
                is_archived = true,
                updated_at  = NOW()
            WHERE question_key = 'ni_number'
              AND (is_active = true OR is_archived = false)
        ]])
        print("[Personal Details] Deactivated redundant `ni_number` question (nino is canonical)")
    end,
}
