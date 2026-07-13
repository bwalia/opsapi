--[[
    Admin — Identity Lock endpoints (PR #464 unlock + PR #465 settings/announce)

    Routes registered here
    ----------------------
        POST  /api/v2/admin/tax-user-profiles/:user_uuid/unlock
        GET   /api/v2/admin/identity-lock/settings
        PATCH /api/v2/admin/identity-lock/settings
        POST  /api/v2/admin/identity-lock/announce

    Support flow: user hits a locked field (NINO / UTR), can't edit; the
    frontend surfaces "Chat with support" (which reaches an admin) or
    "Email support". Admin verifies the request out-of-band, then calls
    the unlock endpoint to clear the lock. User's next save re-locks in
    the same transaction as the write.

    Authorization
    -------------
    Every route requires the `identity_lock.unlock` permission (module +
    action). Registered in migration [89] via the modules table so the
    existing RBAC editor UI can grant it. Platform admins and namespace
    owners bypass permission checks (see middleware/namespace.lua:322-347).

    Namespace scoping
    -----------------
    The target user's namespace_id MUST equal the admin's active
    namespace. Cross-tenant unlocks are a P0 anti-fraud incident — an
    admin from tenant A cannot unlock a user in tenant B.

    Namespace resolution: we resolve the admin's namespace from their
    JWT user_uuid via helper.namespace-resolver (same pattern as
    routes/tax-profile.lua). NamespaceMiddleware.getNamespaceId(self)
    relies on requireNamespace() having run first — but these routes
    use requireAuth alone, so the middleware helper returns nil.

    Audit
    -----
    Every unlock + settings-write writes to tax_audit_logs with the
    admin's user_id, IP, and a change reason. See lib/identity_lock.lua
    emitAuditRow.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local NamespaceResolver = require("helper.namespace-resolver")
local AdminCheck = require("helper.admin-check")
local IdentityLock = require("lib.identity_lock")

-- Merge JSON/form body into self.params so PATCH/POST bodies are
-- accessible the same way as query-string params. Same pattern as
-- routes/tax-statements.lua.
local function mergeBodyParams(self)
    ngx.req.read_body()
    local body_params
    local content_type = ngx.var.content_type or ""
    if content_type:find("application/json", 1, true) then
        local data = ngx.req.get_body_data()
        if not data or data == "" then
            local body_file = ngx.req.get_body_file()
            if body_file then
                local f = io.open(body_file, "r")
                if f then data = f:read("*a") ; f:close() end
            end
        end
        if data and data ~= "" then
            local ok, parsed = pcall(cjson.decode, data)
            if ok and type(parsed) == "table" then body_params = parsed end
        end
    else
        body_params = ngx.req.get_post_args()
    end
    if body_params then
        for k, v in pairs(body_params) do
            if self.params[k] == nil then self.params[k] = v end
        end
    end
end

-- ─── Shared authorization helpers ───────────────────────────────────────

-- Resolve the admin's namespace from their JWT user_uuid. This mirrors
-- the pattern used by routes/tax-profile.lua because these admin routes
-- run under AuthMiddleware.requireAuth only — the middleware doesn't
-- populate self.namespace.
local function resolveAdminNamespaceId(self)
    local admin_uuid = self.current_user
        and (self.current_user.uuid or self.current_user.sub)
    if not admin_uuid then return nil end
    local nsid = NamespaceResolver.getByUuid(admin_uuid)
    if nsid and nsid > 0 then return nsid end
    return nil
end

-- Check whether the JWT-authenticated user owns the given namespace.
-- Uses namespace_members.is_owner rather than trusting a token flag.
-- namespace_members keys on integer user_id (not uuid), so we JOIN through
-- users for a clean lookup when we only have the JWT uuid.
local function isOwnerOf(user_uuid, namespace_id)
    if not user_uuid or not namespace_id then return false end
    local rows = db.query([[
        SELECT nm.is_owner
        FROM namespace_members nm
        JOIN users u ON u.id = nm.user_id
        WHERE u.uuid = ? AND nm.namespace_id = ?
        LIMIT 1
    ]], user_uuid, namespace_id)
    if not rows or not rows[1] then return false end
    local raw = rows[1].is_owner
    return raw == true or raw == "t" or raw == 1
end

-- Uniform RBAC gate for every identity-lock admin route. Returns:
--   allowed?  boolean
--   err_resp? table   (only when allowed is false — includes the 403 body)
--   admin_namespace_id? integer
--
-- These routes wrap only requireAuth (no requireNamespace), so
-- self.is_platform_admin / self.is_namespace_owner aren't populated.
-- We compute them locally against the JWT + DB so the bypass rules
-- from middleware/namespace.lua:322-347 still apply here.
local function requireIdentityLockAdmin(self)
    local admin_ns = resolveAdminNamespaceId(self)
    if not admin_ns then
        return false, { status = 403, json = {
            code = "IDENTITY_LOCK_UNLOCK_FORBIDDEN",
            user_message = "Could not resolve your namespace. Sign out and back in, then try again.",
        } }
    end

    local admin_uuid = self.current_user
        and (self.current_user.uuid or self.current_user.sub)

    -- Populate flags so downstream calls to NamespaceMiddleware.hasPermission
    -- see a consistent context (its internal checks also read these).
    if self.is_platform_admin == nil then
        self.is_platform_admin = AdminCheck.isPlatformAdmin(self.current_user)
    end
    if self.is_namespace_owner == nil then
        self.is_namespace_owner = isOwnerOf(admin_uuid, admin_ns)
    end

    local allowed = self.is_platform_admin
        or self.is_namespace_owner
        or NamespaceMiddleware.hasPermission(self, "identity_lock", "unlock")
    if not allowed then
        return false, { status = 403, json = {
            code = "IDENTITY_LOCK_UNLOCK_FORBIDDEN",
            user_message = "Your role does not have permission to manage identity-lock policy. Ask a namespace owner to grant the `identity_lock.unlock` permission via the RBAC settings.",
        } }
    end

    return true, nil, admin_ns
end

-- Fetch the settings row for a namespace, creating it lazily with the
-- DB-default values if it doesn't exist yet. Every admin who visits the
-- settings page triggers this at least once, which is why the fields
-- default to the same values as the CREATE TABLE clauses in migration
-- [89] — otherwise a fresh tenant would see empty toggles.
local function getOrCreateSettings(namespace_id)
    local rows = db.query([[
        SELECT namespace_id,
               nino_lock_enabled, nino_confirmation_required,
               nino_backfill_scheduled_at, nino_backfill_completed_at,
               nino_uniqueness_enforced,
               utr_lock_enabled, utr_backfill_enabled,
               utr_backfill_scheduled_at, utr_backfill_completed_at,
               announcement_email_enabled, announcement_banner_enabled,
               announcement_banner_message,
               updated_by, updated_at, created_at
        FROM identity_lock_settings
        WHERE namespace_id = ?
        LIMIT 1
    ]], namespace_id)
    if rows and rows[1] then return rows[1] end

    -- No row yet — seed one with defaults. Idempotent via ON CONFLICT
    -- so two concurrent first-loads don't collide.
    db.query([[
        INSERT INTO identity_lock_settings (namespace_id)
        VALUES (?)
        ON CONFLICT (namespace_id) DO NOTHING
    ]], namespace_id)

    local seeded = db.query([[
        SELECT namespace_id,
               nino_lock_enabled, nino_confirmation_required,
               nino_backfill_scheduled_at, nino_backfill_completed_at,
               nino_uniqueness_enforced,
               utr_lock_enabled, utr_backfill_enabled,
               utr_backfill_scheduled_at, utr_backfill_completed_at,
               announcement_email_enabled, announcement_banner_enabled,
               announcement_banner_message,
               updated_by, updated_at, created_at
        FROM identity_lock_settings
        WHERE namespace_id = ?
        LIMIT 1
    ]], namespace_id)
    return seeded and seeded[1]
end

-- opsapi's `safe_load_routes` calls this module as `route_module(app)`.
-- Return a function that takes `app` and registers the routes — matches
-- the convention used by routes.tax-hmrc-data / routes.tax-profile / etc.
return function(app)
    -- ================================================================
    -- POST /api/v2/admin/tax-user-profiles/:user_uuid/unlock
    -- ================================================================
    app:post("/api/v2/admin/tax-user-profiles/:user_uuid/unlock",
        AuthMiddleware.requireAuth(function(self)
            -- ─── 1. Parse + validate the request body ──────────────────────
            local target_user_uuid = self.params.user_uuid
            local field  = self.params.field
            local reason = self.params.reason

            if not target_user_uuid or target_user_uuid == "" then
                return { status = 400, json = {
                    code = "INVALID_UNLOCK_REQUEST",
                    user_message = "Missing user_uuid.",
                } }
            end
            if field ~= "nino" and field ~= "utr" then
                return { status = 400, json = {
                    code = "INVALID_UNLOCK_REQUEST",
                    user_message = "field must be 'nino' or 'utr'.",
                } }
            end
            if not reason or #reason < 10 then
                return { status = 400, json = {
                    code = "INVALID_UNLOCK_REQUEST",
                    user_message = "reason is required (min 10 chars). Every unlock is audited.",
                } }
            end

            -- ─── 2. RBAC + admin namespace ─────────────────────────────────
            local ok, err_resp, admin_namespace_id = requireIdentityLockAdmin(self)
            if not ok then return err_resp end

            -- ─── 3. Resolve target + verify same-namespace ─────────────────
            local rows = db.query([[
                SELECT id, user_id, user_uuid, namespace_id, nino_locked_at, utr_locked_at, nino_last4
                FROM tax_user_profiles
                WHERE user_uuid = ? LIMIT 1
            ]], target_user_uuid)
            local profile = rows and rows[1]
            if not profile then
                return { status = 404, json = {
                    code = "USER_NOT_FOUND",
                    user_message = "No tax profile exists for that user_uuid.",
                } }
            end

            if admin_namespace_id ~= profile.namespace_id then
                return { status = 403, json = {
                    code = "IDENTITY_LOCK_UNLOCK_FORBIDDEN",
                    user_message = "You can only unlock users in your own namespace.",
                } }
            end

            -- ─── 4. Idempotency: already unlocked? ─────────────────────────
            local locked_at_col = (field == "nino") and "nino_locked_at" or "utr_locked_at"
            local previous_lock = profile[locked_at_col]
            if not previous_lock then
                return { status = 200, json = {
                    success        = true,
                    already_unlocked = true,
                    field          = field,
                    user_message   = "This field is not currently locked.",
                } }
            end

            -- ─── 5. Clear the lock timestamp ───────────────────────────────
            db.query(string.format([[
                UPDATE tax_user_profiles
                SET %s = NULL, updated_at = NOW()
                WHERE user_uuid = ? AND namespace_id = ?
            ]], locked_at_col), target_user_uuid, admin_namespace_id)

            -- ─── 6. Write the audit row ────────────────────────────────────
            local admin_user_id = self.current_user
                and (self.current_user.user_id or self.current_user.id)
                or nil
            local client_ip = ngx.var.remote_addr

            IdentityLock.emitAuditRow({
                user_id        = profile.user_id,
                admin_user_id  = admin_user_id,
                namespace_id   = profile.namespace_id,
                action         = (field == "nino") and "UNLOCK_NINO" or "UNLOCK_UTR",
                old_values     = { [locked_at_col] = tostring(previous_lock) },
                new_values     = { [locked_at_col] = nil },
                reason         = reason,
                request_ip     = client_ip,
            })

            return { status = 200, json = {
                success           = true,
                field             = field,
                previous_lock_at  = tostring(previous_lock),
                unlocked_at       = nil,  -- literal null in JSON
                user_uuid         = target_user_uuid,
            } }
        end)
    )

    -- ================================================================
    -- GET   /api/v2/admin/identity-lock/settings
    -- PATCH /api/v2/admin/identity-lock/settings
    --
    -- GET returns the policy row for the caller's namespace (lazily
    -- created with defaults on first access).
    --
    -- PATCH is a whitelisted partial update — any field not on the
    -- whitelist is silently dropped (never let clients set namespace_id,
    -- updated_by, or timestamps directly).
    --
    -- Both verbs share one respond_to() so a single route entry claims
    -- the URL path. Lapis has no `app:patch` verb; registering a second
    -- app:match(..., {PATCH=...}) on the same path would swallow GET
    -- too (returning "don't know how to respond to GET"). Same pattern
    -- as routes/tax-statements.lua for the workflow patch.
    -- ================================================================
    app:match("/api/v2/admin/identity-lock/settings", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local ok, err_resp, admin_namespace_id = requireIdentityLockAdmin(self)
            if not ok then return err_resp end

            local row = getOrCreateSettings(admin_namespace_id)
            if not row then
                return { status = 500, json = {
                    code = "IDENTITY_LOCK_SETTINGS_UNAVAILABLE",
                    user_message = "Could not load identity-lock settings. Please retry.",
                } }
            end
            return { status = 200, json = row }
        end),
        PATCH = AuthMiddleware.requireAuth(function(self)
            mergeBodyParams(self)
            local ok, err_resp, admin_namespace_id = requireIdentityLockAdmin(self)
            if not ok then return err_resp end

            -- Ensure the row exists (defaults) before we UPDATE.
            local before = getOrCreateSettings(admin_namespace_id)
            if not before then
                return { status = 500, json = {
                    code = "IDENTITY_LOCK_SETTINGS_UNAVAILABLE",
                    user_message = "Could not load identity-lock settings. Please retry.",
                } }
            end

            -- Whitelist of admin-writable columns. Each entry maps the
            -- JSON key → the SQL type coercer for the incoming value.
            -- Anything not on this list is dropped (namespace_id,
            -- *_completed_at, updated_by, timestamps are all system-managed).
            local BOOLEAN_FIELDS = {
                "nino_lock_enabled", "nino_confirmation_required",
                "nino_uniqueness_enforced", "utr_lock_enabled",
                "utr_backfill_enabled", "announcement_email_enabled",
                "announcement_banner_enabled",
            }
            local TIMESTAMP_FIELDS = {
                "nino_backfill_scheduled_at", "utr_backfill_scheduled_at",
            }
            local TEXT_FIELDS = { "announcement_banner_message" }

            local sets  = {}       -- SQL fragments "col = ?"
            local args  = {}       -- values for the ? placeholders
            local changes = {}     -- { key = { old, new } } for audit

            local function coerceBool(v)
                if type(v) == "boolean" then return v end
                if type(v) == "string" then
                    v = v:lower()
                    if v == "true" or v == "1" then return true end
                    if v == "false" or v == "0" then return false end
                end
                return nil
            end

            local function includeField(col, sql_value, incoming, prev)
                table.insert(sets, col .. " = ?")
                table.insert(args, sql_value)
                changes[col] = { old = prev, new = incoming }
            end

            for _, col in ipairs(BOOLEAN_FIELDS) do
                if self.params[col] ~= nil then
                    local v = coerceBool(self.params[col])
                    if v ~= nil and v ~= before[col] then
                        includeField(col, v, v, before[col])
                    end
                end
            end

            for _, col in ipairs(TIMESTAMP_FIELDS) do
                if self.params[col] ~= nil then
                    local v = self.params[col]
                    if type(v) == "userdata" then v = nil end -- cjson.null
                    local sql_value
                    if v == nil or v == "" then
                        sql_value = db.NULL
                    else
                        sql_value = tostring(v)
                    end
                    -- Only mark as changed if it actually differs. Simple
                    -- string equality is fine here — inputs come as ISO
                    -- strings from datetime-local.
                    local prev = before[col]
                    local prev_str = prev and tostring(prev) or nil
                    if tostring(sql_value) ~= tostring(prev_str or db.NULL) then
                        includeField(col, sql_value, v, prev)
                    end
                end
            end

            for _, col in ipairs(TEXT_FIELDS) do
                if self.params[col] ~= nil then
                    local v = self.params[col]
                    if type(v) == "userdata" then v = nil end
                    local sql_value = (v == nil or v == "") and db.NULL or tostring(v)
                    if tostring(sql_value) ~= tostring(before[col] or db.NULL) then
                        includeField(col, sql_value, v, before[col])
                    end
                end
            end

            if #sets == 0 then
                -- Idempotent no-op: return the current row.
                return { status = 200, json = before }
            end

            local admin_user_id = self.current_user
                and (self.current_user.user_id or self.current_user.id)
                or nil

            table.insert(sets, "updated_at = NOW()")
            table.insert(sets, "updated_by = ?")
            table.insert(args, admin_user_id or db.NULL)

            -- Append the WHERE arg last.
            table.insert(args, admin_namespace_id)

            local sql = "UPDATE identity_lock_settings SET " ..
                table.concat(sets, ", ") ..
                " WHERE namespace_id = ?"
            db.query(sql, unpack(args))

            -- Re-read to return the canonical shape (with NOW() timestamps).
            local after = getOrCreateSettings(admin_namespace_id)

            -- Audit: one row for the batch, with the diff in change_reason
            -- context. Keeps the audit log lean.
            IdentityLock.emitAuditRow({
                user_id       = admin_user_id,
                admin_user_id = admin_user_id,
                namespace_id  = admin_namespace_id,
                action        = "IDENTITY_LOCK_SETTINGS_UPDATED",
                old_values    = changes,      -- includes old + new per field
                new_values    = nil,
                reason        = "Admin updated identity-lock policy",
                request_ip    = ngx.var.remote_addr,
            })

            return { status = 200, json = after }
        end),
    }))

    -- ================================================================
    -- POST /api/v2/admin/identity-lock/announce
    -- Compute the audience for the "your NINO will be locked" heads-up.
    -- Returns the count now; email fan-out is a follow-up (email_sent=0).
    -- The frontend surfaces recipient_count so admins can gauge blast
    -- radius before wiring the fan-out into Mail.send.
    -- ================================================================
    app:post("/api/v2/admin/identity-lock/announce",
        AuthMiddleware.requireAuth(function(self)
            local ok, err_resp, admin_namespace_id = requireIdentityLockAdmin(self)
            if not ok then return err_resp end

            local settings = getOrCreateSettings(admin_namespace_id)
            if not settings then
                return { status = 500, json = {
                    code = "IDENTITY_LOCK_SETTINGS_UNAVAILABLE",
                    user_message = "Could not load identity-lock settings. Please retry.",
                } }
            end

            -- Audience: users in this namespace who have a NINO on file
            -- (has_nino = true) but haven't been locked yet. Those are
            -- the people who'll be affected the next time they save.
            local rows = db.query([[
                SELECT COUNT(*) AS n
                FROM tax_user_profiles
                WHERE namespace_id = ?
                  AND has_nino = true
                  AND nino_locked_at IS NULL
            ]], admin_namespace_id)
            local recipient_count = tonumber(rows and rows[1] and rows[1].n) or 0

            -- Whether Mail.send() can actually deliver depends on
            -- SMTP_HOST + SMTP_USERNAME + SMTP_PASSWORD being set. We
            -- surface that so the admin isn't misled into thinking
            -- emails went out when they didn't.
            local smtp_host = os.getenv("SMTP_HOST")
            local smtp_user = os.getenv("SMTP_USERNAME")
            local smtp_pass = os.getenv("SMTP_PASSWORD")
            local mail_configured = smtp_host and smtp_host ~= ""
                and smtp_user and smtp_user ~= ""
                and smtp_pass and smtp_pass ~= ""

            -- Audit even a dry-run — clients see this in the audit trail.
            local admin_user_id = self.current_user
                and (self.current_user.user_id or self.current_user.id)
                or nil
            IdentityLock.emitAuditRow({
                user_id       = admin_user_id,
                admin_user_id = admin_user_id,
                namespace_id  = admin_namespace_id,
                action        = "IDENTITY_LOCK_ANNOUNCE_TRIGGERED",
                old_values    = nil,
                new_values    = {
                    recipient_count       = recipient_count,
                    email_channel_enabled = settings.announcement_email_enabled,
                    banner_channel_enabled= settings.announcement_banner_enabled,
                    mail_configured       = mail_configured and true or false,
                },
                reason        = "Admin triggered identity-lock announcement",
                request_ip    = ngx.var.remote_addr,
            })

            return { status = 200, json = {
                success                = true,
                recipient_count        = recipient_count,
                email_sent             = 0,
                email_channel_enabled  = settings.announcement_email_enabled and true or false,
                banner_channel_enabled = settings.announcement_banner_enabled and true or false,
                mail_configured        = mail_configured and true or false,
            } }
        end)
    )
end
