--[[
    Namespace auto-assignment for newly created users
    ==================================================

    Adds a freshly-created user to the tenant the request identified, with
    the default `member` role, and sets that namespace as their default in
    `user_namespace_settings`. Without this step the user has no namespace
    context and the frontend's billing / settings pages 404 with "Namespace
    not found" because `NamespaceMiddleware.requireNamespace` rejects them.

    Tenant resolution — the caller passes `project_code` (from the browser's
    `X-Project-Code` header at register.lua, or a query param at the OAuth
    callback). If the caller doesn't provide it, we fall back to the pod's
    `PROJECT_CODE` env var. If BOTH are missing (or the value doesn't match
    any active namespace) we return `nil, reason` and the caller MUST 400 —
    we deliberately do NOT fall back to "first active tenant" any more, as
    that was the exact silent-mis-routing behavior that put self-registered
    tax-copilot users into the `system` namespace on int.

    Idempotent — every INSERT carries an `ON CONFLICT … DO NOTHING/UPDATE`
    clause, so repeating the call (e.g. after a partial earlier failure)
    leaves the user in the correct end state without dupes.

    Error-tolerant — the DB work runs in `pcall`. A hard failure returns
    `nil, "internal_error:<err>"` so the caller can decide whether to roll
    back the user or surface a 5xx. This is a stricter contract than the
    previous fire-and-forget shape: silent success on a broken assignment
    left the user unable to reach any namespace-scoped page.

    Callers:
      - routes/register.lua  (email/password sign-up)
      - routes/auth.lua      (Google OAuth sign-up — both GET callback and
                              the POST sign-in-with-token variant)
]]

local db = require("lapis.db")

local M = {}

--- Auto-assign a newly-created user to the tenant identified by project_code.
-- @param user_id integer  users.id of the freshly-created user
-- @param user_uuid string users.uuid of the same user (for log breadcrumbs)
-- @param project_code string|nil  per-request tenant hint (from X-Project-Code
--                                 header, or OAuth query param). If nil or
--                                 empty, falls back to the PROJECT_CODE env
--                                 var. If both are missing / unresolvable,
--                                 returns nil + reason and does NOT insert.
-- @return integer|nil resolved namespace_id (nil on failure)
-- @return string|nil reason ("no_project_code" / "project_code_not_found:<code>"
--                             / "internal_error:<err>"), nil on success
function M.assignUserToProjectNamespace(user_id, user_uuid, project_code)
    local resolved_ns_id, resolved_reason
    local ok, err = pcall(function()
        local effective_code = project_code
        if not effective_code or effective_code == "" then
            effective_code = os.getenv("PROJECT_CODE")
        end
        if not effective_code or effective_code == "" or effective_code == "all" then
            resolved_reason = "no_project_code"
            return
        end

        local ns = db.query([[
            SELECT id FROM namespaces
            WHERE status = 'active' AND project_code = ?
            ORDER BY id ASC LIMIT 1
        ]], effective_code)

        if not ns or #ns == 0 then
            resolved_reason = "project_code_not_found:" .. tostring(effective_code)
            return
        end
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

        resolved_ns_id = namespace_id
        ngx.log(ngx.NOTICE, "[Namespace] Auto-assigned user ", user_uuid,
            " to namespace ", namespace_id,
            " (project_code=", tostring(effective_code), ")")
    end)
    if not ok then
        ngx.log(ngx.ERR, "[Namespace] Failed to assign user ", tostring(user_uuid), ": ", tostring(err))
        return nil, "internal_error:" .. tostring(err)
    end
    return resolved_ns_id, resolved_reason
end

return M
