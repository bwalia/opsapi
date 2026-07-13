--[[
    Admin — Identity Lock Unlock Endpoint

    Route: POST /api/v2/admin/tax-user-profiles/:user_uuid/unlock

    Support flow: user hits a locked field (NINO / UTR), can't edit; the
    frontend surfaces "Chat with support" (which reaches an admin) or
    "Email support". Admin verifies the request out-of-band, then calls
    this endpoint to clear the lock. User's next save re-locks in the
    same transaction as the write.

    Authorization
    -------------
    Requires the `identity_lock.unlock` permission (module + action).
    Registered in migration [89] via the modules table so the existing
    RBAC editor UI can grant it. Platform admins and namespace owners
    bypass permission checks (see middleware/namespace.lua:322-347).

    Namespace scoping
    -----------------
    The target user's namespace_id MUST equal the admin's active
    namespace. Cross-tenant unlocks are a P0 anti-fraud incident — an
    admin from tenant A cannot unlock a user in tenant B.

    Request
    -------
    Body: { field: "nino" | "utr", reason: string }
      • field  — required. Which lock to clear.
      • reason — required. Min 10 chars. Recorded in tax_audit_logs.

    Response
    --------
    200 { success: true, unlocked_at: null, previous_lock_at: "..." }
    400 { code: "INVALID_UNLOCK_REQUEST", user_message: ... }
    403 { code: "IDENTITY_LOCK_UNLOCK_FORBIDDEN", user_message: ... }
    404 { code: "USER_NOT_FOUND", user_message: ... }

    Audit
    -----
    Every unlock writes to tax_audit_logs with:
      entity_type   = 'TAX_USER_PROFILE'
      entity_id     = <target user_uuid>
      action        = 'UNLOCK_NINO' | 'UNLOCK_UTR'
      user_id       = <admin's user_id>
      old_values    = { locked_at: "<ISO ts>" }
      new_values    = { locked_at: null }
      change_reason = <admin's reason>
      ip_address    = <admin's IP>
]]

local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local IdentityLock = require("lib.identity_lock")

-- opsapi's `safe_load_routes` calls this module as `route_module(app)`.
-- Return a function that takes `app` and registers the routes — matches
-- the convention used by routes.tax-hmrc-data / routes.tax-profile / etc.
return function(app)
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

            -- ─── 2. RBAC — identity_lock.unlock permission ─────────────────
            -- Platform admins + namespace owners bypass (see
            -- middleware/namespace.lua:322-347). Other roles need the
            -- explicit grant via the existing RBAC UI.
            local allowed = self.is_platform_admin
                or self.is_namespace_owner
                or NamespaceMiddleware.hasPermission(self, "identity_lock", "unlock")
            if not allowed then
                return { status = 403, json = {
                    code = "IDENTITY_LOCK_UNLOCK_FORBIDDEN",
                    user_message = "Your role does not have permission to unlock identity fields. Ask a namespace owner to grant the `identity_lock.unlock` permission via the RBAC settings.",
                } }
            end

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

            -- Cross-tenant unlock guard. self.namespace_id is set by the
            -- namespace middleware for authenticated requests.
            local admin_namespace_id = NamespaceMiddleware.getNamespaceId(self)
            if not admin_namespace_id or admin_namespace_id ~= profile.namespace_id then
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
end
