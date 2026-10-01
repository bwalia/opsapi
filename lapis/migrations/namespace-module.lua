--[[
    The `namespace` RBAC module: workspace settings, API keys and ownership.

    Routes check namespace.manage / namespace.update (routes/api-keys.lua,
    routes/namespaces.lua) and default roles are built from the `modules`
    table — but `namespace` was never a row there, so owner roles lacked it
    and workspace owners got "Permission denied" on their own API keys and
    settings. This registers the module and backfills existing roles:
    owner -> manage, admin -> read (as NamespaceRoleQueries.getAdminPermissions
    already intends). Roles that already have a `namespace` entry are left alone.
]]

local db = require("lapis.db")

-- Role permissions are JSON text. Empty and the old quoted-default '{}' count
-- as {}; anything that isn't a JSON object becomes NULL, so that role is
-- skipped instead of failing the cast (a WHERE guard wouldn't short-circuit).
local PERMS = [[(CASE WHEN COALESCE(permissions, '') IN ('', '''{}''') THEN '{}'
                      WHEN permissions ~ '^\s*\{' THEN permissions END)::jsonb]]

local function grant(role_name, actions)
    return db.query([[
        UPDATE namespace_roles
        SET permissions = (]] .. PERMS .. [[ || ]] .. db.escape_literal('{"namespace": ' .. actions .. '}') .. [[::jsonb)::text,
            updated_at = NOW()
        WHERE role_name = ]] .. db.escape_literal(role_name) .. [[ AND NOT (]] .. PERMS .. [[ ? 'namespace')
    ]]).affected_rows or 0
end

return {
    [1] = function()
        db.query([[
            INSERT INTO modules (uuid, machine_name, name, description, category, priority,
                                 is_active, is_system, default_actions, created_at, updated_at)
            VALUES (gen_random_uuid()::text, 'namespace', 'Workspace',
                    'Workspace settings, API keys and ownership', 'Core', '0',
                    true, true, 'create,read,update,delete,manage', NOW(), NOW())
            ON CONFLICT (machine_name) DO NOTHING
        ]])
        local owners = grant("owner", '["manage"]')
        local admins = grant("admin", '["read"]')
        print(("[NamespaceModule] owner roles granted namespace.manage: %d, admin roles granted namespace.read: %d")
            :format(owners, admins))
    end,
}
