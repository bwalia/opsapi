--[[
  Namespace Setup Script

  Automatically creates a namespace from PROJECT_CODE with a super admin user.
  This script is idempotent — safe to re-run on every deployment.

  Supports multi-project codes:
    - Single code:  PROJECT_CODE=tax_copilot      → creates one namespace
    - Multi code:   PROJECT_CODE=ecommerce,chat    → creates one namespace per code
    - All:          PROJECT_CODE=all               → creates "system" namespace

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

  Multi-project usage (recommended for combined project codes):
    docker exec opsapi lapis exec \
      "require('scripts.setup-namespace').runMulti({})"
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

--- Validate a project code against the registered list in ProjectConfig.
--- Returns true if known, or false + list of valid codes.
local function isKnownProjectCode(code)
    local ProjectConfig = require("helper.project-config")
    if not code or code == "" then
        return false, {}
    end
    local valid = {}
    for k, _ in pairs(ProjectConfig.PROJECT_FEATURES) do
        table.insert(valid, k)
    end
    table.sort(valid)
    return ProjectConfig.PROJECT_FEATURES[code] ~= nil, valid
end

--- Parse a potentially comma-separated project_code string.
--- Returns two lists: valid codes, invalid codes (for error reporting).
local function parseAndValidateCodes(project_code)
    local valid_codes, invalid_codes = {}, {}
    local seen = {}

    for raw in tostring(project_code or ""):gmatch("[^,]+") do
        local trimmed = raw:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 and not seen[trimmed] then
            seen[trimmed] = true
            local known, _ = isKnownProjectCode(trimmed)
            if known then
                table.insert(valid_codes, trimmed)
            else
                table.insert(invalid_codes, trimmed)
            end
        end
    end

    return valid_codes, invalid_codes
end

function SetupNamespace.run(config)
    config = config or {}

    local ProjectConfig = require("helper.project-config")
    local db = require("lapis.db")
    local MigrationUtils = require("helper.migration-utils")

    local project_code = resolve(config, "project_code", "PROJECT_CODE", "all")
    local admin_email = resolve(config, "admin_email", "ADMIN_EMAIL", "admin@opsapi.com")
    local admin_password = resolve(config, "admin_password", "ADMIN_PASSWORD", "Admin@123")

    -- Validate project code when run directly with a single code.
    -- Multi-code inputs are handled by runMulti(); if one slips through here, fail fast.
    if project_code:find(",") then
        error("SetupNamespace.run() received a multi-code project_code '" .. project_code
            .. "'. Use SetupNamespace.runMulti() for comma-separated codes.")
    end
    local known, valid = isKnownProjectCode(project_code)
    if not known then
        error("Unknown project_code '" .. tostring(project_code)
            .. "'. Valid codes: " .. table.concat(valid, ", "))
    end

    -- Basic sanity checks on admin inputs (fail early, not mid-DB insert)
    if type(admin_email) ~= "string" or not admin_email:find("@") then
        error("Invalid admin_email '" .. tostring(admin_email) .. "' — must be a valid email address")
    end
    if type(admin_password) ~= "string" or #admin_password < 6 then
        error("Invalid admin_password — must be at least 6 characters")
    end

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
    -- Uses UPSERT: creates if missing, updates if currently pointing to System namespace.
    -- Does NOT override if admin has intentionally switched to another project namespace.
    print("[Setup] Step 8: Setting default namespace...")
    local user_settings = db.select(
        "id, default_namespace_id FROM user_namespace_settings WHERE user_id = ?", admin_user[1].id
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
        -- Check if admin's default is the System namespace — if so, update to project namespace
        local system_ns = db.select("id FROM namespaces WHERE slug = 'system' LIMIT 1")
        local system_ns_id = (system_ns and #system_ns > 0) and system_ns[1].id or nil
        local current_default = user_settings[1].default_namespace_id

        if system_ns_id and tonumber(current_default) == tonumber(system_ns_id) then
            db.query([[
                UPDATE user_namespace_settings
                SET default_namespace_id = ?, last_active_namespace_id = ?, updated_at = NOW()
                WHERE user_id = ?
            ]], namespace[1].id, namespace[1].id, admin_user[1].id)
            print("  + Updated default from 'system' to '" .. ns_slug .. "'")
        else
            print("  Default namespace already configured (" .. tostring(current_default) .. ")")
        end
    end

    print("")
    print("=== Setup Complete ===")
    print("Namespace: " .. ns_name .. " (" .. ns_slug .. ")")
    print("Admin:     " .. admin_email)
    print("Modules:   " .. #project_modules .. " (" .. project_code .. ")")
    print("======================")
    print("")
end

--- Run namespace setup for one or more project codes.
--- Parses comma-separated PROJECT_CODE and creates one namespace per code.
--- For single codes (including "all"), delegates to run() directly.
--- This is the recommended entry point for Kubernetes bootstrap and CI/CD.
---
--- Error handling:
---  - Unknown codes are rejected up front. If ALL codes are invalid, aborts with error.
---  - If SOME codes are invalid, warns and continues with the valid ones.
---  - Each code's setup runs in an isolated pcall so one failure does not abort the rest.
---  - Prints a structured summary of successes + failures at the end.
---  - Re-raises with a consolidated error if any code failed, so CI/CD sees a non-zero exit.
---
--- @param config table Optional config overrides (admin_email, admin_password, etc.)
--- @return table Summary { total, succeeded, failed, failures = { {code, error} } }
function SetupNamespace.runMulti(config)
    config = config or {}

    local project_code = resolve(config, "project_code", "PROJECT_CODE", "all")

    -- Single code — delegate to run() (which also does its own validation)
    if not project_code:find(",") then
        SetupNamespace.run(config)
        return { total = 1, succeeded = 1, failed = 0, failures = {} }
    end

    local valid_codes, invalid_codes = parseAndValidateCodes(project_code)

    print("")
    print("=== Multi-Project Namespace Setup ===")
    print("PROJECT_CODE: " .. project_code)
    print("Valid codes:  " .. (#valid_codes > 0 and table.concat(valid_codes, ", ") or "(none)"))
    if #invalid_codes > 0 then
        print("INVALID codes (will be skipped): " .. table.concat(invalid_codes, ", "))
    end
    print("======================================")
    print("")

    if #valid_codes == 0 then
        local _, all_valid = isKnownProjectCode("all")
        error("No valid project codes in '" .. project_code .. "'. Known codes: "
            .. table.concat(all_valid, ", "))
    end

    local admin_email = resolve(config, "admin_email", "ADMIN_EMAIL", "admin@opsapi.com")
    local admin_password = resolve(config, "admin_password", "ADMIN_PASSWORD", "Admin@123")

    local failures = {}
    local succeeded = 0

    for i, code in ipairs(valid_codes) do
        local code_slug = code:gsub("_", "-")
        local code_name = code:gsub("_", " "):gsub("(%a)([%w_']*)", function(a, b)
            return a:upper() .. b
        end)

        print("--- [" .. i .. "/" .. #valid_codes .. "] Setting up namespace: "
            .. code_name .. " (" .. code_slug .. ") [project: " .. code .. "] ---")

        local per_code_config = {
            project_code = code,
            admin_email = admin_email,
            admin_password = admin_password,
            namespace_slug = code_slug,
            namespace_name = code_name,
        }

        local ok, err = pcall(SetupNamespace.run, per_code_config)
        if ok then
            succeeded = succeeded + 1
        else
            print("  !! FAILED setting up '" .. code .. "': " .. tostring(err))
            table.insert(failures, { code = code, error = tostring(err) })
        end
    end

    print("")
    print("=== Multi-Project Setup Summary ===")
    print("Total codes:  " .. #valid_codes)
    print("Succeeded:    " .. succeeded)
    print("Failed:       " .. #failures)
    if #invalid_codes > 0 then
        print("Skipped (unknown): " .. table.concat(invalid_codes, ", "))
    end
    if #failures > 0 then
        print("Failures:")
        for _, f in ipairs(failures) do
            print("  - " .. f.code .. ": " .. f.error)
        end
    end
    print("====================================")
    print("")

    local summary = {
        total = #valid_codes,
        succeeded = succeeded,
        failed = #failures,
        failures = failures,
        skipped = invalid_codes,
    }

    -- Re-raise if ANY code failed — so CI/CD pipelines fail loudly rather than silently.
    -- Unknown codes alone do NOT cause a failure (they were filtered up front with a warning).
    if #failures > 0 then
        error(string.format(
            "Multi-project setup failed for %d of %d codes: %s",
            #failures, #valid_codes,
            table.concat((function()
                local names = {}
                for _, f in ipairs(failures) do table.insert(names, f.code) end
                return names
            end)(), ", ")
        ))
    end

    return summary
end

return SetupNamespace
