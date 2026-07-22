--[[
    Namespace Resolver

    Ensures every authenticated user has a default namespace assignment.
    Called from the auth middleware after successful authentication.

    On first call for a user without namespace settings:
    1. Finds the project's default namespace (by PROJECT_CODE)
    2. Creates a namespace_members entry (if not exists)
    3. Assigns the default "member" role
    4. Creates user_namespace_settings with the default namespace

    Subsequent calls are a single SELECT (fast path).
    Result is cached on ngx.ctx.user.namespace_id for the request lifetime.
]]

local db = require("lapis.db")
local Global = require("helper.global")

local _M = {}

--- Look up a user's namespace_id by their UUID — read-only, no side effects.
-- Use this in INSERT paths where the row needs a NOT-NULL namespace_id but
-- the calling context only has the user UUID (e.g. HMRC OAuth callback,
-- queries module functions that take user_uuid).
--
-- Unlike _M.resolve() this does NOT assign a default namespace if missing —
-- it just returns 0, matching the legacy column default for grandfathered
-- rows. That keeps INSERTs safe even for edge users who somehow lack a
-- namespace_members or user_namespace_settings row.
--
-- @param user_uuid string The user UUID
-- @return number The namespace_id, or 0 if not found
function _M.getByUuid(user_uuid)
    if not user_uuid or user_uuid == "" then return 0 end
    -- Preferred source: user_namespace_settings.default_namespace_id, but
    -- only when the pointer still corresponds to an ACTIVE membership.
    -- Without the join a user who was removed from their default namespace
    -- (nm.status='left'|'removed'|'suspended') would still have INSERTs
    -- landing in that tenant via the settings pointer.
    local row = db.query([[
        SELECT uns.default_namespace_id
        FROM user_namespace_settings uns
        JOIN namespace_members nm
          ON nm.user_id = uns.user_id
         AND nm.namespace_id = uns.default_namespace_id
         AND nm.status = 'active'
        WHERE uns.user_id = (SELECT id FROM users WHERE uuid = ? LIMIT 1)
        LIMIT 1
    ]], user_uuid)
    if row and #row > 0 and row[1].default_namespace_id and row[1].default_namespace_id > 0 then
        return tonumber(row[1].default_namespace_id) or 0
    end
    -- Fallback source: first ACTIVE namespace_members row (covers users
    -- whose settings row hasn't been written yet but who are a member of
    -- at least one ns).
    row = db.query([[
        SELECT namespace_id FROM namespace_members
        WHERE user_id = (SELECT id FROM users WHERE uuid = ? LIMIT 1)
          AND status = 'active'
        ORDER BY id ASC
        LIMIT 1
    ]], user_uuid)
    if row and #row > 0 and row[1].namespace_id and row[1].namespace_id > 0 then
        return tonumber(row[1].namespace_id) or 0
    end
    return 0
end

--- Resolve and attach namespace_id to the current user context.
-- Idempotent: safe to call on every request.
-- @param user table The authenticated user (ngx.ctx.user)
-- @return number|nil The namespace_id, or nil if resolution failed
function _M.resolve(user)
    if not user or not user.uuid then
        return nil
    end

    -- Already resolved in this request
    if user.namespace_id and user.namespace_id > 0 then
        return user.namespace_id
    end

    -- Look up internal user ID
    local user_row = db.select("id FROM users WHERE uuid = ? LIMIT 1", user.uuid)
    if not user_row or #user_row == 0 then
        return nil
    end
    local user_id = user_row[1].id

    -- Fast path: user already has namespace settings AND is still an active
    -- member of that namespace. The membership JOIN blocks a stale pointer
    -- from silently keeping a removed user attached to the tenant they lost
    -- access to; fall through to _assignDefaultNamespace in that case.
    local settings = db.query([[
        SELECT uns.default_namespace_id
        FROM user_namespace_settings uns
        JOIN namespace_members nm
          ON nm.user_id = uns.user_id
         AND nm.namespace_id = uns.default_namespace_id
         AND nm.status = 'active'
        WHERE uns.user_id = ?
        LIMIT 1
    ]], user_id)
    if settings and #settings > 0 and settings[1].default_namespace_id and settings[1].default_namespace_id > 0 then
        user.namespace_id = settings[1].default_namespace_id
        return user.namespace_id
    end

    -- Slow path: first time (or stale settings pointer) — resolve the
    -- project's default namespace.
    local ok, ns_id = pcall(_M._assignDefaultNamespace, user_id, user.uuid)
    if ok and ns_id then
        user.namespace_id = ns_id
        return ns_id
    end

    return nil
end

--- Internal: assign user to the project's default namespace.
-- Creates namespace_members, namespace_user_roles, and user_namespace_settings.
-- @param user_id number Internal user ID
-- @param user_uuid string User UUID (for logging)
-- @return number The assigned namespace_id
function _M._assignDefaultNamespace(user_id, user_uuid)
    -- Find the project namespace by PROJECT_CODE
    local project_code = os.getenv("PROJECT_CODE") or "tax_copilot"
    local namespace = db.select(
        "id FROM namespaces WHERE project_code = ? AND status = 'active' ORDER BY id ASC LIMIT 1",
        project_code
    )

    -- Fallback: find any active non-system namespace
    if not namespace or #namespace == 0 then
        namespace = db.select(
            "id FROM namespaces WHERE slug != 'system' AND status = 'active' ORDER BY id ASC LIMIT 1"
        )
    end

    if not namespace or #namespace == 0 then
        ngx.log(ngx.WARN, "[Namespace] No active namespace found for project_code=", project_code)
        return nil
    end

    local ns_id = namespace[1].id

    -- Add as namespace member (if not already)
    local member = db.select(
        "id FROM namespace_members WHERE namespace_id = ? AND user_id = ? LIMIT 1",
        ns_id, user_id
    )
    local member_id
    if not member or #member == 0 then
        db.query([[
            INSERT INTO namespace_members (namespace_id, user_id, is_owner, status, joined_at, created_at, updated_at)
            VALUES (?, ?, false, 'active', NOW(), NOW(), NOW())
        ]], ns_id, user_id)
        local new_member = db.select(
            "id FROM namespace_members WHERE namespace_id = ? AND user_id = ? LIMIT 1",
            ns_id, user_id
        )
        member_id = new_member and #new_member > 0 and new_member[1].id or nil
    else
        member_id = member[1].id
    end

    -- Assign default "member" role (if member was created and role exists)
    if member_id then
        local member_role = db.select(
            "id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'member' LIMIT 1",
            ns_id
        )
        if member_role and #member_role > 0 then
            local has_role = db.select(
                "id FROM namespace_user_roles WHERE namespace_member_id = ? AND namespace_role_id = ? LIMIT 1",
                member_id, member_role[1].id
            )
            if not has_role or #has_role == 0 then
                db.query([[
                    INSERT INTO namespace_user_roles (namespace_member_id, namespace_role_id, created_at, updated_at)
                    VALUES (?, ?, NOW(), NOW())
                ]], member_id, member_role[1].id)
            end
        end
    end

    -- Create user_namespace_settings
    local existing_settings = db.select(
        "id FROM user_namespace_settings WHERE user_id = ? LIMIT 1",
        user_id
    )
    if not existing_settings or #existing_settings == 0 then
        db.query([[
            INSERT INTO user_namespace_settings (user_id, default_namespace_id, last_active_namespace_id, created_at, updated_at)
            VALUES (?, ?, ?, NOW(), NOW())
        ]], user_id, ns_id, ns_id)
    end

    ngx.log(ngx.INFO, "[Namespace] Auto-assigned user ", user_uuid, " to namespace ", ns_id)
    return ns_id
end

return _M
