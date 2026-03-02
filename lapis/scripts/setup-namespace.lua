--[[
  Namespace Setup Script

  Automatically creates a namespace from PROJECT_CODE with a super admin user.
  This script is idempotent — safe to re-run on every deployment.

  Configuration priority: function args > environment variables > defaults

  Usage (via lapis exec — pass config inline to bypass nginx env limitation):
    docker exec opsapi lapis exec \
      "require('scripts.setup-namespace').run({
        project_code='tax_copilot',
        admin_email='admin@test.com',
        admin_password='MyPass123',
        namespace_name='UK Tax Return',
        namespace_slug='uk-tax-return'
      })"
]]

local SetupNamespace = {}

--- Helper: read value from config table, then env var, then default
local function resolve(config, key, env_key, default)
    if config and config[key] and config[key] ~= "" then
        return config[key]
    end
    local env_val = os.getenv(env_key)
    if env_val and env_val ~= "" then
        return env_val
    end
    return default
end

function SetupNamespace.run(config)
    config = config or {}

    local ProjectConfig = require("helper.project-config")
    local db = require("lapis.db")
    local MigrationUtils = require("helper.migration-utils")

    local project_code = resolve(config, "project_code", "PROJECT_CODE", "all")
    local admin_email = resolve(config, "admin_email", "ADMIN_EMAIL", "admin@opsapi.com")
    local admin_password = resolve(config, "admin_password", "ADMIN_PASSWORD", "Admin@123")

    -- Derive default namespace name/slug from project code
    local default_slug = project_code:gsub("_", "-")
    local default_name = project_code:gsub("_", " "):gsub("(%a)([%w_']*)", function(a, b)
        return a:upper() .. b
    end)
    if project_code == "all" then
        default_slug = "system"
        default_name = "System"
    end

    local ns_slug_preview = resolve(config, "namespace_slug", "NAMESPACE_SLUG", default_slug)
    local ns_name_preview = resolve(config, "namespace_name", "NAMESPACE_NAME", default_name)

    print("")
    print("=== Namespace Setup ===")
    print("PROJECT_CODE: " .. project_code)
    print("NAMESPACE:    " .. ns_name_preview .. " (" .. ns_slug_preview .. ")")
    print("ADMIN_EMAIL:  " .. admin_email)
    print("=======================")
    print("")

    -- Step 1: Seed project-specific modules into the modules table
    print("[Setup] Step 1: Seeding project modules...")
    local project_modules = ProjectConfig.getProjectModules()
    local modules_created = 0

    for _, m in ipairs(project_modules) do
        local exists = db.select("id FROM modules WHERE machine_name = ?", m.machine_name)
        if not exists or #exists == 0 then
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(),
                machine_name = m.machine_name,
                name = m.name,
                description = m.description or (m.name .. " module"),
                category = m.category or "General",
                is_system = m.is_system or false,
                is_active = true,
                default_actions = "create,read,update,delete,manage",
                priority = "0",
                created_at = MigrationUtils.getCurrentTimestamp(),
                updated_at = MigrationUtils.getCurrentTimestamp(),
            })
            modules_created = modules_created + 1
            print("  + Created module: " .. m.machine_name)
        end
    end

    if modules_created == 0 then
        print("  (all " .. #project_modules .. " modules already exist)")
    else
        print("  Created " .. modules_created .. " new modules (" .. #project_modules .. " total)")
    end

    -- Step 2: Create or find the admin user
    print("[Setup] Step 2: Setting up admin user...")
    local admin_user = db.select("* FROM users WHERE email = ?", admin_email)

    if not admin_user or #admin_user == 0 then
        local hashed = MigrationUtils.hashPassword(admin_password)
        db.insert("users", {
            uuid = MigrationUtils.generateUUID(),
            first_name = "Super",
            last_name = "Admin",
            email = admin_email,
            username = admin_email,
            password = hashed,
            active = true,
            created_at = MigrationUtils.getCurrentTimestamp(),
            updated_at = MigrationUtils.getCurrentTimestamp(),
        })
        admin_user = db.select("* FROM users WHERE email = ?", admin_email)
        print("  + Created admin user: " .. admin_email)
    else
        print("  Admin user already exists: " .. admin_email)
    end

    -- Step 3: Ensure admin has the platform "administrative" role
    print("[Setup] Step 3: Assigning platform admin role...")
    local admin_role = db.select("id FROM roles WHERE role_name = ?", "administrative")

    if admin_role and #admin_role > 0 then
        local has_role = db.select(
            "id FROM user__roles WHERE user_id = ? AND role_id = ?",
            admin_user[1].id, admin_role[1].id
        )
        if not has_role or #has_role == 0 then
            db.insert("user__roles", {
                uuid = MigrationUtils.generateUUID(),
                user_id = admin_user[1].id,
                role_id = admin_role[1].id,
                created_at = MigrationUtils.getCurrentTimestamp(),
                updated_at = MigrationUtils.getCurrentTimestamp(),
            })
            print("  + Assigned 'administrative' role to user")
        else
            print("  Already has 'administrative' role")
        end
    else
        print("  WARNING: 'administrative' role not found in roles table")
    end

    -- Step 4: Create namespace (from config/env, or derive from PROJECT_CODE)
    print("[Setup] Step 4: Creating namespace...")
    local ns_slug = ns_slug_preview
    local ns_name = ns_name_preview

    local namespace = db.select("* FROM namespaces WHERE slug = ?", ns_slug)

    if not namespace or #namespace == 0 then
        db.insert("namespaces", {
            uuid = MigrationUtils.generateUUID(),
            name = ns_name,
            slug = ns_slug,
            description = ns_name .. " project namespace",
            status = "active",
            plan = "enterprise",
            settings = "{}",
            max_users = 1000,
            max_stores = 100,
            project_code = project_code,
            owner_user_id = admin_user[1].id,
            created_at = MigrationUtils.getCurrentTimestamp(),
            updated_at = MigrationUtils.getCurrentTimestamp(),
        })
        namespace = db.select("* FROM namespaces WHERE slug = ?", ns_slug)
        print("  + Created namespace: " .. ns_name .. " (" .. ns_slug .. ") [project: " .. project_code .. "]")
    else
        -- Update project_code if namespace exists but project_code differs
        if namespace[1].project_code ~= project_code then
            db.update("namespaces", { project_code = project_code }, { id = namespace[1].id })
            namespace[1].project_code = project_code
            print("  Updated project_code to: " .. project_code)
        end
        print("  Namespace already exists: " .. ns_slug)
    end

    -- Step 5: Add admin as namespace owner member
    print("[Setup] Step 5: Adding admin to namespace...")
    local member = db.select(
        "* FROM namespace_members WHERE namespace_id = ? AND user_id = ?",
        namespace[1].id, admin_user[1].id
    )

    if not member or #member == 0 then
        db.insert("namespace_members", {
            uuid = MigrationUtils.generateUUID(),
            namespace_id = namespace[1].id,
            user_id = admin_user[1].id,
            status = "active",
            is_owner = true,
            joined_at = MigrationUtils.getCurrentTimestamp(),
            created_at = MigrationUtils.getCurrentTimestamp(),
            updated_at = MigrationUtils.getCurrentTimestamp(),
        })
        member = db.select(
            "* FROM namespace_members WHERE namespace_id = ? AND user_id = ?",
            namespace[1].id, admin_user[1].id
        )
        print("  + Added admin as namespace owner")
    else
        print("  Admin is already a namespace member")
    end

    -- Step 6: Create default roles (owner, admin, member) with DB-driven permissions
    print("[Setup] Step 6: Creating namespace roles...")
    local existing_roles = db.select(
        "id FROM namespace_roles WHERE namespace_id = ?", namespace[1].id
    )

    if not existing_roles or #existing_roles == 0 then
        local NamespaceRoleQueries = require("queries.NamespaceRoleQueries")
        NamespaceRoleQueries.createDefaultRoles(namespace[1].id, project_code)
        print("  + Created default roles (owner, admin, member) [project: " .. project_code .. "]")
    else
        print("  Roles already exist (" .. #existing_roles .. " roles)")
    end

    -- Assign owner role to admin user (always ensure this, even if roles existed)
    local owner_role = db.select(
        "id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'owner'",
        namespace[1].id
    )
    if owner_role and #owner_role > 0 and member and #member > 0 then
        local existing_assignment = db.select(
            "id FROM namespace_user_roles WHERE namespace_member_id = ? AND namespace_role_id = ?",
            member[1].id, owner_role[1].id
        )
        if not existing_assignment or #existing_assignment == 0 then
            db.insert("namespace_user_roles", {
                uuid = MigrationUtils.generateUUID(),
                namespace_member_id = member[1].id,
                namespace_role_id = owner_role[1].id,
                created_at = MigrationUtils.getCurrentTimestamp(),
                updated_at = MigrationUtils.getCurrentTimestamp(),
            })
            print("  + Assigned 'owner' role to admin")
        else
            print("  Admin already has 'owner' role")
        end
    end

    -- Step 7: Add the original platform super admin to namespace (if different from -A admin)
    print("[Setup] Step 7: Ensuring platform super admin has namespace access...")
    local platform_admins = db.query([[
        SELECT u.id, u.email FROM users u
        JOIN user__roles ur ON ur.user_id = u.id
        JOIN roles r ON r.id = ur.role_id
        WHERE r.role_name = 'administrative'
    ]])

    for _, pa in ipairs(platform_admins or {}) do
        if pa.id ~= admin_user[1].id then
            -- This platform admin is not the one we already added
            local pa_member = db.select(
                "id FROM namespace_members WHERE namespace_id = ? AND user_id = ?",
                namespace[1].id, pa.id
            )
            if not pa_member or #pa_member == 0 then
                db.insert("namespace_members", {
                    uuid = MigrationUtils.generateUUID(),
                    namespace_id = namespace[1].id,
                    user_id = pa.id,
                    status = "active",
                    is_owner = false,
                    joined_at = MigrationUtils.getCurrentTimestamp(),
                    created_at = MigrationUtils.getCurrentTimestamp(),
                    updated_at = MigrationUtils.getCurrentTimestamp(),
                })
                pa_member = db.select(
                    "id FROM namespace_members WHERE namespace_id = ? AND user_id = ?",
                    namespace[1].id, pa.id
                )
                print("  + Added platform admin '" .. pa.email .. "' to namespace")
            end

            -- Assign admin role (not owner, since the -A user is the owner)
            if pa_member and #pa_member > 0 then
                local admin_ns_role = db.select(
                    "id FROM namespace_roles WHERE namespace_id = ? AND role_name = 'admin'",
                    namespace[1].id
                )
                if admin_ns_role and #admin_ns_role > 0 then
                    local has_assignment = db.select(
                        "id FROM namespace_user_roles WHERE namespace_member_id = ? AND namespace_role_id = ?",
                        pa_member[1].id, admin_ns_role[1].id
                    )
                    if not has_assignment or #has_assignment == 0 then
                        db.insert("namespace_user_roles", {
                            uuid = MigrationUtils.generateUUID(),
                            namespace_member_id = pa_member[1].id,
                            namespace_role_id = admin_ns_role[1].id,
                            created_at = MigrationUtils.getCurrentTimestamp(),
                            updated_at = MigrationUtils.getCurrentTimestamp(),
                        })
                        print("  + Assigned 'admin' role to platform admin '" .. pa.email .. "'")
                    end
                end
            end
        end
    end

    -- Step 8: Set as default namespace for admin user
    print("[Setup] Step 8: Setting default namespace...")
    local user_settings = db.select(
        "id FROM user_namespace_settings WHERE user_id = ?", admin_user[1].id
    )

    if not user_settings or #user_settings == 0 then
        db.insert("user_namespace_settings", {
            user_id = admin_user[1].id,
            default_namespace_id = namespace[1].id,
            last_active_namespace_id = namespace[1].id,
            created_at = MigrationUtils.getCurrentTimestamp(),
            updated_at = MigrationUtils.getCurrentTimestamp(),
        })
        print("  + Set '" .. ns_slug .. "' as default namespace")
    else
        print("  Default namespace already configured")
    end

    print("")
    print("=== Setup Complete ===")
    print("Namespace: " .. ns_name .. " (" .. ns_slug .. ")")
    print("Admin:     " .. admin_email)
    print("Modules:   " .. #project_modules .. " (" .. project_code .. ")")
    print("======================")
    print("")
end

return SetupNamespace
