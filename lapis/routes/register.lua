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
            local user = UserQueries.create(user_create_params)
            user.password = nil

            -- Auto-assign to project namespace (member role + default namespace)
            NamespaceAssignment.assignUserToProjectNamespace(user.id, user.uuid)

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

            local jwt_payload = {
                userinfo = {
                    uuid = user.uuid,
                    id = user.id,
                    email = user.email,
                    username = user.username,
                    role = user.role,
                    -- Surface the freshly-saved business profile key
                    -- so the frontend can render the right onboarding
                    -- state and pre-fill classify without a second
                    -- /api/tax-profile fetch on the very next page.
                    -- Always set explicitly to a string-or-nil for
                    -- consumer parsers; cjson omits nils on encode.
                    default_profile_key = default_profile_key,
                },
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
