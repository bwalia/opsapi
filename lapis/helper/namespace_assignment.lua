--[[
    Namespace auto-assignment for newly created users
    ==================================================

    Adds a freshly-created user to the active project namespace (configured
    via the `PROJECT_CODE` env var, default `tax_copilot`) with the default
    `member` role, and sets that namespace as their default in
    `user_namespace_settings`. Without this step the user has no namespace
    context and the frontend's billing / settings pages 404 with "Namespace
    not found" because `NamespaceMiddleware.requireNamespace` rejects them.

    Idempotent — every INSERT carries an `ON CONFLICT … DO NOTHING/UPDATE`
    clause, so repeating the call (e.g. after a partial earlier failure)
    leaves the user in the correct end state without dupes.

    Error-tolerant — the whole body runs in `pcall` and any failure is logged
    but never raised. Sign-up has already succeeded in creating the user
    by the time this is called; rolling back the user just because we
    couldn't add the membership row would be worse than the namespace
    being temporarily absent (an operator can backfill).

    Callers:
      - routes/register.lua  (email/password sign-up)
      - routes/auth.lua      (Google OAuth sign-up — both GET callback and
                              the POST sign-in-with-token variant)

    History: extracted from routes/register.lua after acc-2026-05-29 surfaced
    a Google-OAuth-only "Namespace not found" bug — the email/password flow
    auto-assigned correctly via the in-file helper; OAuth signup called
    UserQueries.createOAuthUser and stopped, leaving the user with zero
    membership rows.
]]

local db = require("lapis.db")

local M = {}

--- Auto-assign a newly-created user to the active project namespace.
-- @param user_id integer  users.id of the freshly-created user
-- @param user_uuid string users.uuid of the same user (for log breadcrumbs)
function M.assignUserToProjectNamespace(user_id, user_uuid)
    local ok, err = pcall(function()
        -- Resolve the target namespace by project_code, with a slug-based
        -- fallback so an environment that hasn't set PROJECT_CODE still
        -- gets the first non-system tenant.
        local project_code = os.getenv("PROJECT_CODE") or "tax_copilot"
        local ns = db.query([[
            SELECT id FROM namespaces
            WHERE status = 'active' AND project_code = ?
            ORDER BY id ASC LIMIT 1
        ]], project_code)

        if not ns or #ns == 0 then
            ns = db.query([[
                SELECT id FROM namespaces
                WHERE status = 'active' AND slug != 'system'
                ORDER BY id ASC LIMIT 1
            ]])
        end

        if not ns or #ns == 0 then return end
        local namespace_id = ns[1].id

        -- Membership (status = 'active', is_owner = false).
        db.query([[
            INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, 'active', false, NOW(), NOW(), NOW())
            ON CONFLICT (namespace_id, user_id) DO NOTHING
        ]], namespace_id, user_id)

        -- Default 'member' role binding (the namespace's own member role,
        -- not the global users.role). Without this the user is a member
        -- but has no permissions, and gated routes refuse them.
        local member_role = db.query([[
            SELECT nr.id as role_id, nm.id as member_id
            FROM namespace_roles nr
            JOIN namespace_members nm ON nm.namespace_id = nr.namespace_id AND nm.user_id = ?
            WHERE nr.namespace_id = ? AND nr.role_name = 'member'
            LIMIT 1
        ]], user_id, namespace_id)
        if member_role and #member_role > 0 then
            db.query([[
                INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
                VALUES (gen_random_uuid()::text, ?, ?, NOW(), NOW())
                ON CONFLICT (namespace_member_id, namespace_role_id) DO NOTHING
            ]], member_role[1].member_id, member_role[1].role_id)
        end

        -- Default namespace for the user's session — what the login
        -- response reads from to seed the frontend's X-Namespace-Id.
        db.query([[
            INSERT INTO user_namespace_settings (user_id, default_namespace_id, last_active_namespace_id, created_at, updated_at)
            VALUES (?, ?, ?, NOW(), NOW())
            ON CONFLICT (user_id) DO UPDATE SET
                default_namespace_id = EXCLUDED.default_namespace_id,
                last_active_namespace_id = EXCLUDED.last_active_namespace_id,
                updated_at = NOW()
        ]], user_id, namespace_id, namespace_id)

        ngx.log(ngx.NOTICE, "[Namespace] Auto-assigned user ", user_uuid, " to namespace ", namespace_id)
    end)
    if not ok then
        ngx.log(ngx.ERR, "[Namespace] Failed to assign user ", tostring(user_uuid), ": ", tostring(err))
    end
end

return M
