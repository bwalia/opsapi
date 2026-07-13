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
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local IdentityLock = require("lib.identity_lock")

-- Load Mail helper lazily inside the announcement handler so the whole
-- admin-identity-lock module still boots on installs that don't have
-- lua-resty-mail installed (rare, but the file has been optional).
local function loadMail()
    local ok, Mail = pcall(require, "helper.mail")
    return ok and Mail or nil
end

-- Parse JSON body (mirrors the pattern in routes/profile-builder.lua).
local function parseJsonBody(self)
    local params = self.params or {}
    local ct = ngx.req.get_headers()["content-type"]
    if ct and ct:find("application/json") then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body then
            local ok, parsed = pcall(cjson.decode, body)
            if ok and parsed then
                for k, v in pairs(parsed) do params[k] = v end
            end
        end
    end
    return params
end

-- Return the settings row for this namespace, upserting a default row
-- if none exists yet (safer than returning nulls — the FE always sees a
-- populated shape).
local function getOrInitSettings(namespace_id)
    local rows = db.query([[
        SELECT * FROM identity_lock_settings WHERE namespace_id = ? LIMIT 1
    ]], namespace_id)
    if rows and #rows > 0 then
        return rows[1]
    end
    db.query([[
        INSERT INTO identity_lock_settings (namespace_id)
        VALUES (?)
        ON CONFLICT (namespace_id) DO NOTHING
    ]], namespace_id)
    rows = db.query([[
        SELECT * FROM identity_lock_settings WHERE namespace_id = ? LIMIT 1
    ]], namespace_id)
    return rows and rows[1] or nil
end

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

    -- ═════════════════════════════════════════════════════════════════════
    -- GET /api/v2/admin/identity-lock/settings
    --
    -- Read the identity_lock_settings row for the caller's namespace. The
    -- FE admin dashboard's "Security & Compliance → Identity Lock" page
    -- calls this to hydrate its form.
    --
    -- Auth: identity_lock.unlock (same permission — anyone who can unlock
    -- can also read/edit the policy for that namespace). Platform admins
    -- + namespace owners bypass.
    --
    -- Auto-upserts a default row if none exists — FE always sees a
    -- populated shape, no null-checking needed on the client side.
    -- ═════════════════════════════════════════════════════════════════════
    app:get("/api/v2/admin/identity-lock/settings",
        AuthMiddleware.requireAuth(function(self)
            local allowed = self.is_platform_admin
                or self.is_namespace_owner
                or NamespaceMiddleware.hasPermission(self, "identity_lock", "unlock")
            if not allowed then
                return { status = 403, json = {
                    code = "IDENTITY_LOCK_ADMIN_FORBIDDEN",
                    user_message = "Your role does not have permission to read identity-lock settings.",
                } }
            end

            local ns_id = NamespaceMiddleware.getNamespaceId(self)
            if not ns_id then
                return { status = 400, json = { error = "No namespace resolved for this request." } }
            end

            local row = getOrInitSettings(ns_id)
            if not row then
                return { status = 500, json = { error = "Failed to load settings" } }
            end

            return { status = 200, json = row }
        end)
    )

    -- ═════════════════════════════════════════════════════════════════════
    -- PATCH /api/v2/admin/identity-lock/settings
    --
    -- Update policy fields for the caller's namespace. Only the fields
    -- present in the body are updated (SQL COALESCE), so the FE can send
    -- one-field patches without re-sending the whole row.
    --
    -- Whitelisted fields (matches the migration [89] schema — any
    -- unrecognised key in the body is silently ignored, so the endpoint
    -- is resistant to schema drift):
    --   nino_lock_enabled, nino_confirmation_required,
    --   nino_backfill_scheduled_at, nino_uniqueness_enforced,
    --   utr_lock_enabled, utr_backfill_enabled,
    --   utr_backfill_scheduled_at,
    --   announcement_email_enabled, announcement_banner_enabled,
    --   announcement_banner_message
    --
    -- Also stamps updated_by + updated_at + writes an audit row so we
    -- can see who changed what and when.
    -- ═════════════════════════════════════════════════════════════════════
    app:match("/api/v2/admin/identity-lock/settings",
        require("lapis.application").respond_to({
            PATCH = AuthMiddleware.requireAuth(function(self)
                local allowed = self.is_platform_admin
                    or self.is_namespace_owner
                    or NamespaceMiddleware.hasPermission(self, "identity_lock", "unlock")
                if not allowed then
                    return { status = 403, json = {
                        code = "IDENTITY_LOCK_ADMIN_FORBIDDEN",
                        user_message = "Your role does not have permission to modify identity-lock settings.",
                    } }
                end

                local ns_id = NamespaceMiddleware.getNamespaceId(self)
                if not ns_id then
                    return { status = 400, json = { error = "No namespace resolved for this request." } }
                end

                -- Ensure the row exists — first PATCH also creates the row.
                getOrInitSettings(ns_id)

                local params = parseJsonBody(self)
                local admin_uid = self.current_user
                    and (self.current_user.user_id or self.current_user.id)
                    or nil

                -- Whitelist: allow-list what can be patched. Any key not
                -- here is silently dropped.
                local allow_bool = {
                    nino_lock_enabled = true,
                    nino_confirmation_required = true,
                    nino_uniqueness_enforced = true,
                    utr_lock_enabled = true,
                    utr_backfill_enabled = true,
                    announcement_email_enabled = true,
                    announcement_banner_enabled = true,
                }
                local allow_ts = {
                    nino_backfill_scheduled_at = true,
                    utr_backfill_scheduled_at = true,
                }
                local allow_text = {
                    announcement_banner_message = true,
                }

                local before_row = getOrInitSettings(ns_id)
                local updates = {}
                local values = {}

                for k, v in pairs(params) do
                    if allow_bool[k] then
                        table.insert(updates, k .. " = ?")
                        -- Accept boolean or "true"/"false" strings for HTTP form-safe input.
                        table.insert(values, v == true or v == "true" or v == "1")
                    elseif allow_ts[k] then
                        table.insert(updates, k .. " = ?")
                        -- NULL clears a schedule; otherwise treat as ISO timestamp string.
                        if v == nil or v == "" or v == cjson.null then
                            table.insert(values, db.NULL)
                        else
                            table.insert(values, tostring(v))
                        end
                    elseif allow_text[k] then
                        table.insert(updates, k .. " = ?")
                        table.insert(values, v == cjson.null and db.NULL or tostring(v))
                    end
                end

                if #updates == 0 then
                    return { status = 400, json = {
                        code = "INVALID_PATCH",
                        user_message = "No known settings fields in the request body.",
                    } }
                end

                -- Always stamp who made the change and when.
                table.insert(updates, "updated_by = ?")
                table.insert(values, admin_uid or db.NULL)
                table.insert(updates, "updated_at = NOW()")

                table.insert(values, ns_id)  -- WHERE param
                local sql = "UPDATE identity_lock_settings SET " .. table.concat(updates, ", ")
                          .. " WHERE namespace_id = ?"
                db.query(sql, unpack(values))

                local after_row = getOrInitSettings(ns_id)

                -- Audit-log the change with before + after so support has full trace.
                IdentityLock.emitAuditRow({
                    admin_user_id = admin_uid,
                    namespace_id  = ns_id,
                    action        = "IDENTITY_LOCK_SETTINGS_UPDATED",
                    old_values    = before_row,
                    new_values    = after_row,
                    request_ip    = ngx.var.remote_addr,
                })

                return { status = 200, json = after_row }
            end)
        })
    )

    -- ═════════════════════════════════════════════════════════════════════
    -- POST /api/v2/admin/identity-lock/announce
    --
    -- Trigger the "your NINO is about to be locked" announcement. Reads
    -- announcement_email_enabled / announcement_banner_enabled from the
    -- settings row to decide which channels to fire. The BANNER channel
    -- is effectively passive — the FE reads announcement_banner_message
    -- from the settings row directly, so all this endpoint does for the
    -- banner is confirm it's enabled + non-empty.
    --
    -- The EMAIL channel iterates every user in the namespace who has
    -- has_nino=true AND nino_locked_at IS NULL (i.e. would be affected
    -- by an upcoming backfill), and sends via helper/mail.lua async
    -- (ngx.timer.at inside Mail.send). Runs to completion in the
    -- background; the endpoint returns 202 with a summary.
    --
    -- Idempotency + cost control: each user is emailed AT MOST ONCE per
    -- announcement — enforced by a per-user "announcement fired" flag
    -- we drop into user_profile_answers via a synthetic question_key
    -- (LATER — for the MVP we simply log the count and let the caller
    -- re-trigger only if they mean to).
    -- ═════════════════════════════════════════════════════════════════════
    app:post("/api/v2/admin/identity-lock/announce",
        AuthMiddleware.requireAuth(function(self)
            local allowed = self.is_platform_admin
                or self.is_namespace_owner
                or NamespaceMiddleware.hasPermission(self, "identity_lock", "unlock")
            if not allowed then
                return { status = 403, json = {
                    code = "IDENTITY_LOCK_ADMIN_FORBIDDEN",
                    user_message = "Your role does not have permission to trigger identity-lock announcements.",
                } }
            end

            local ns_id = NamespaceMiddleware.getNamespaceId(self)
            if not ns_id then
                return { status = 400, json = { error = "No namespace resolved for this request." } }
            end

            local settings = getOrInitSettings(ns_id)
            if not settings then
                return { status = 500, json = { error = "Failed to load settings" } }
            end

            local Mail = loadMail()
            local email_enabled = settings.announcement_email_enabled and Mail and Mail.isConfigured and Mail.isConfigured()

            -- Query recipients — users in this namespace with a NINO on
            -- file but not yet locked. That's the population that would
            -- be affected by a scheduled backfill.
            local recipients = db.query([[
                SELECT u.email, u.name, tp.user_uuid
                FROM tax_user_profiles tp
                JOIN users u ON u.id = tp.user_id
                WHERE tp.namespace_id = ?
                  AND tp.has_nino = TRUE
                  AND tp.nino_locked_at IS NULL
                  AND u.email IS NOT NULL
                  AND u.email <> ''
            ]], ns_id)

            local recipient_count = recipients and #recipients or 0
            local email_sent = 0

            if email_enabled and recipient_count > 0 then
                local scheduled_at = settings.nino_backfill_scheduled_at
                local banner_msg   = settings.announcement_banner_message
                    or "From the date below, the NINO you have on file will become permanent and can only be changed by contacting support. Please review your NINO now and correct it if needed."

                for _, r in ipairs(recipients) do
                    local ok = pcall(Mail.send, {
                        to      = r.email,
                        subject = "Important: Your NINO on file is about to become permanent",
                        html    = string.format([[
                            <p>Hi %s,</p>
                            <p>%s</p>
                            <p><strong>Change deadline:</strong> %s</p>
                            <p>To review your NINO, sign in and visit your Settings page.</p>
                            <p>If you have questions, chat with support at <a href="/support">/support</a>.</p>
                        ]],
                            r.name or "there",
                            banner_msg,
                            scheduled_at and tostring(scheduled_at) or "Not scheduled yet — check your Settings page"
                        ),
                    })
                    if ok then email_sent = email_sent + 1 end
                end
            end

            -- Audit row for the trigger.
            IdentityLock.emitAuditRow({
                admin_user_id = self.current_user and (self.current_user.user_id or self.current_user.id) or nil,
                namespace_id  = ns_id,
                action        = "IDENTITY_LOCK_ANNOUNCEMENT_SENT",
                new_values    = {
                    recipient_count = recipient_count,
                    email_sent      = email_sent,
                    email_channel_enabled = email_enabled and true or false,
                    banner_channel_enabled = settings.announcement_banner_enabled and true or false,
                },
                request_ip    = ngx.var.remote_addr,
            })

            return { status = 202, json = {
                success                = true,
                recipient_count        = recipient_count,
                email_sent             = email_sent,
                email_channel_enabled  = email_enabled and true or false,
                banner_channel_enabled = settings.announcement_banner_enabled and true or false,
                mail_configured        = Mail and Mail.isConfigured and Mail.isConfigured() or false,
            } }
        end)
    )
end
