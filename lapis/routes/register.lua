local respond_to = require("lapis.application").respond_to
local UserQueries = require("queries.UserQueries")
local Validation = require("helper.validations")
local jwt = require("resty.jwt")
local Global = require("helper.global")
local db = require("lapis.db")
local Errors = require("lib.errors")
local NamespaceAssignment = require("helper.namespace_assignment")
local NamespaceResolver = require("helper.namespace-resolver")

--- Validate that a business profile key is acceptable.
-- @param profile_key string|nil The candidate key (e.g. "amazon_seller")
-- @return boolean ok      — true if valid OR if the value is empty/nil
--                           (caller decides whether the field is required)
-- @return string|nil error_reason — set when ok=false, one of:
--                           "inactive_profile_key" / "invalid_profile_key_format"
--
-- The canonical catalog is the union of two sources:
--   * classification_profiles table (admin-managed, namespace-scoped)
--   * filesystem profile rules under backend/app/profiles/ (FastAPI side)
-- Lapis can only read the DB half. So we use a tiered policy:
--   1. If the key matches a row in classification_profiles → trust it,
--      reject only when the row is explicitly inactive.
--   2. If the key isn't in the table → accept on a format check
--      (lower_snake_case ASCII). The frontend sources its dropdown
--      from /api/tax-profile/types which returns the FULL union, so
--      a key arriving here unrecognised in the DB came from the
--      filesystem half — also valid. The format check guards against
--      arbitrary user-supplied strings (SQL-safe via parameterised
--      queries elsewhere; this is just to keep the column tidy).
--
-- We deliberately don't enforce a DB-level FK to classification_profiles
-- (see migration #75 rationale). Validation lives here so the same
-- rule applies to every caller that accepts a profile key
-- (registration today; settings update + OAuth onboarding next).
local function validate_profile_key(profile_key)
    if not profile_key or profile_key == "" then
        return true  -- caller decides whether to treat empty as a hard error
    end

    -- Format check: lower_snake_case ASCII, 1-100 chars. Matches the
    -- shape every existing key in the codebase uses.
    if not profile_key:match("^[a-z][a-z0-9_]*$") or #profile_key > 100 then
        return false, "invalid_profile_key_format"
    end

    -- Soft DB check: only reject when we're certain (row exists AND
    -- is_active = false). Missing row falls through to "accept" so
    -- filesystem-only profiles work without a duplicate registry.
    local rows = db.query(
        "SELECT is_active FROM classification_profiles WHERE profile_key = ? LIMIT 1",
        profile_key
    )
    if rows and #rows > 0 then
        local is_active = rows[1].is_active
        -- Lapis pgmoon returns booleans as Lua booleans; older drivers
        -- as 't'/'f' strings. Accept both shapes.
        if is_active == false or is_active == 'f' or is_active == 0 then
            return false, "inactive_profile_key"
        end
    end
    return true
end

--- Persist the user's chosen default_profile_key into tax_user_profiles.
-- Called after the user row + namespace assignment exist so the
-- profile row exists too (assignUserToNamespace is responsible for
-- creating the row downstream of the namespace dispatch).
-- Idempotent via ON CONFLICT — safe even if the row was created
-- earlier in the request.
local function save_default_profile_key(user_id, user_uuid, profile_key)
    if not profile_key or profile_key == "" then return end
    local ok, err = pcall(function()
        -- tax_user_profiles.namespace_id is NOT NULL with no DB default —
        -- and NOT NULL is checked before ON CONFLICT, so we must set it
        -- here even if a row already exists for this user.
        local namespace_id = NamespaceResolver.getByUuid(user_uuid)
        db.query([[
            INSERT INTO tax_user_profiles (user_id, user_uuid, namespace_id, default_profile_key, created_at, updated_at)
            VALUES (?, ?, ?, ?, NOW(), NOW())
            ON CONFLICT (user_uuid) DO UPDATE
            SET default_profile_key = EXCLUDED.default_profile_key,
                updated_at = NOW()
        ]], user_id, user_uuid, namespace_id, profile_key)
    end)
    if not ok then
        ngx.log(ngx.ERR, "[Register] Failed to save default_profile_key: ", tostring(err))
    end
end

-- Auto-assignment of a fresh user to the project namespace lives in the
-- shared helper.namespace_assignment so the Google-OAuth sign-up flow in
-- routes/auth.lua can call the exact same code path.

return function(app)
    app:match("register", "/api/v2/register", respond_to({
        POST = function(self)
            local params = self.params

            -- Tenant hint from the browser: NEXT_PUBLIC_PROJECT_CODE is baked
            -- into the frontend build per env and rides on every auth call as
            -- X-Project-Code. Preferred over the pod's PROJECT_CODE env var
            -- because it's request-scoped and survives the two overlapping
            -- opsapi releases the int cluster runs (which can silently drift
            -- on their env-var config). Passed down into UserQueries.create
            -- AND NamespaceAssignment so both resolve the same tenant.
            local hdrs = self.req.headers or {}
            local project_code = hdrs["x-project-code"] or hdrs["X-Project-Code"]
            if project_code then
                project_code = tostring(project_code):gsub("^%s+", ""):gsub("%s+$", "")
                if project_code == "" then project_code = nil end
            end

            -- Accept common registration roles; default to "member" if not provided
            local allowed_roles = {
                member = true, buyer = true, seller = true,
                delivery_partner = true, tax_client = true
            }
            if not params.role or params.role == "" then
                params.role = "member"
            end
            if not allowed_roles[params.role] then
                return Errors.response(self, "VALIDATION_400", {
                    context = {
                        field = "role",
                        reason = "invalid_value",
                        provided = params.role,
                    },
                })
            end

            local success, err = pcall(function()
                Validation.createUser(params)
            end)

            if not success then
                -- ``err`` here is the message thrown by Validation.createUser
                -- (e.g. "Email is required" / "Password must be ..."). We
                -- don't have a dedicated catalog code per validation
                -- subtype yet, so wrap the human message in
                -- ``context.detail`` — the frontend's parseAppError reads
                -- the catalog message; if the toast needs the specific
                -- reason we can render context.detail inline.
                return Errors.response(self, "VALIDATION_400", {
                    context = {
                        reason = "validation_failed",
                        detail = tostring(err),
                    },
                })
            end

            local existing_user = UserQueries.findByEmail(params.email)
            if existing_user then
                -- 409 Conflict via the catalog so the frontend toast +
                -- the inline-field error highlighter both have what
                -- they need (code + context.field). action_url lets
                -- the UI render a "Sign in instead" button.
                return Errors.response(self, "AUTH_EMAIL_TAKEN", {
                    context = {
                        field = "email",
                        reason = "already_registered",
                        action = "sign_in",
                        action_url = "/login",
                    },
                })
            end

            -- Capture the optional business profile key BEFORE creating
            -- the user — if the value is malformed we fail fast without
            -- leaving an orphan user record. Empty / nil is allowed
            -- (legacy clients that don't send the field continue to
            -- work; the user picks one later in /onboarding or Settings).
            local default_profile_key = params.default_profile_key
            if default_profile_key and default_profile_key ~= "" then
                local ok, reason = validate_profile_key(default_profile_key)
                if not ok then
                    return Errors.response(self, "VALIDATION_400", {
                        context = {
                            field = "default_profile_key",
                            reason = reason,
                            provided = default_profile_key,
                            user_message = (reason == "inactive_profile_key")
                                and "That business profile is no longer offered. Please pick another."
                                or  "Unknown business profile. Please pick from the list.",
                        },
                    })
                end
            end

            -- Build the users-table payload as a fresh shallow copy
            -- minus our new field. This avoids depending on caller
            -- mutations to ``self.params`` (which Lapis may wrap with
            -- a metatable that treats ``= nil`` as a no-op) and keeps
            -- the contract with UserQueries.create explicit: it
            -- receives only fields valid for the users table.
            local user_create_params = {}
            for k, v in pairs(params) do
                if k ~= "default_profile_key" then
                    user_create_params[k] = v
                end
            end
            -- Pass project_code so UserQueries.create's internal namespace
            -- resolver uses the same value as NamespaceAssignment below —
            -- otherwise the two paths could pick different tenants on a
            -- pod whose PROJECT_CODE env differs from the request header.
            user_create_params.project_code = project_code

            -- Atomic: user INSERT + namespace assignment run in one transaction
            -- so a failed assignment rolls back the user row. Without this
            -- wrap, an assignment failure leaves an orphan `users` row that
            -- (a) permanently blocks retry (findByEmail returns AUTH_EMAIL_TAKEN)
            -- and (b) is invisible in the failure envelope. Assignment throws
            -- (via `error(...)`) rather than returning `(nil, reason)` so the
            -- transaction rolls back — Lapis' db.transaction commits on
            -- normal return, aborts on any raised error.
            local user, ns_id, ns_reason
            local tx_ok, tx_err = pcall(function()
                db.query("BEGIN")
                user = UserQueries.create(user_create_params)
                user.password = nil
                local id, reason = NamespaceAssignment.assignUserToProjectNamespace(
                    user.id, user.uuid, project_code
                )
                if not id then
                    ns_reason = reason
                    error({ kind = "assignment_failed", reason = reason })
                end
                ns_id = id
                db.query("COMMIT")
            end)
            if not tx_ok then
                pcall(db.query, "ROLLBACK")
                -- tx_err is either the structured table we raised on
                -- assignment failure, or a raw string from an unexpected
                -- exception (validation, DB constraint, etc).
                local kind = type(tx_err) == "table" and tx_err.kind or "internal_error"
                local reason = type(tx_err) == "table" and tx_err.reason or tostring(tx_err)
                ngx.log(ngx.ERR, "[Register] Transaction rolled back for ",
                    tostring(params.email), " kind=", kind, " reason=", reason)

                if kind == "assignment_failed"
                   and reason
                   and not reason:find("^internal_error:") then
                    -- Genuinely client-actionable: they gave us a project_code
                    -- that doesn't exist, or omitted it AND the pod has no
                    -- PROJECT_CODE env. Public 400 shape carries the reason
                    -- code but NOT the raw provided value (that becomes an
                    -- enumeration oracle for valid project_codes).
                    return Errors.response(self, "VALIDATION_400", {
                        context = {
                            field = "project_code",
                            reason = "namespace_unresolvable",
                            detail = reason,
                        },
                    })
                end
                -- Everything else — internal_error from pcall on a DB fault,
                -- validation exception, constraint violation — is a server
                -- problem. Raw pcall text (may contain Postgres schema detail,
                -- stack fragments, bcrypt errors) is logged, NOT surfaced to
                -- the client.
                return Errors.response(self, "SYSTEM_500", {
                    cause = "user_registration_failed",
                })
            end

            -- Persist the validated profile key onto tax_user_profiles.
            -- Runs after assignUserToNamespace so the profile row's
            -- creation race is owned by the namespace setup; this
            -- call is an idempotent UPSERT either way.
            save_default_profile_key(user.id, user.uuid, default_profile_key)

            -- Generate JWT token for immediate authentication
            local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
            if not JWT_SECRET_KEY then
                ngx.log(ngx.ERR, "JWT_SECRET_KEY not configured")
                return Errors.response(self, "SYSTEM_500", {
                    cause = "JWT_SECRET_KEY not configured",
                })
            end

            -- Match the login token's userinfo shape (helper/jwt-helper.lua).
            -- Without a name claim, a freshly-registered user has no display name
            -- in their session and consumers fall back to showing their email.
            local full_name = ((user.first_name or "") .. " " .. (user.last_name or ""))
                :gsub("^%s*(.-)%s*$", "%1")

            local jwt_payload = {
                userinfo = {
                    uuid = user.uuid,
                    id = user.id,
                    email = user.email,
                    username = user.username,
                    role = user.role,
                    -- Additive: lenient consumers (tax_copilot) ignore unknown claims.
                    name = full_name,
                    first_name = user.first_name,
                    last_name = user.last_name,
                    -- Surface the freshly-saved business profile key
                    -- so the frontend can render the right onboarding
                    -- state and pre-fill classify without a second
                    -- /api/tax-profile fetch on the very next page.
                    -- Always set explicitly to a string-or-nil for
                    -- consumer parsers; cjson omits nils on encode.
                    default_profile_key = default_profile_key,
                },
                -- Issuer claim so strict verifiers (e.g. the academy frontend's
                -- jose jwtVerify, which requires issuer "opsapi") accept the
                -- sign-up token, matching the login/jwt-helper token shape. A
                -- lenient verifier simply ignores it, so existing consumers
                -- (tax_copilot) are unaffected.
                iss = "opsapi",
                exp = ngx.time() + (60 * 60) -- 1 hour expiry (matches DEFAULT_EXPIRATION)
            }

            local jwt_token = jwt:sign(JWT_SECRET_KEY, {
                header = { typ = "JWT", alg = "HS256" },
                payload = jwt_payload
            })

            return {
                json = {
                    user = user,
                    token = jwt_token,
                    message = "Registration successful"
                },
                status = 201
            }
        end
    }))
end
