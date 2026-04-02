local respond_to = require("lapis.application").respond_to
local UserQueries = require("queries.UserQueries")
local Validation = require("helper.validations")
local jwt = require("resty.jwt")
local Global = require("helper.global")
local db = require("lapis.db")

-- Auto-assign new user to the active project namespace
local function assignUserToNamespace(user_id, user_uuid)
    local ok, err = pcall(function()
        -- Find the active project namespace (not "system")
        local project_code = os.getenv("PROJECT_CODE") or "tax_copilot"
        local ns = db.query([[
            SELECT id FROM namespaces
            WHERE status = 'active' AND project_code = ?
            ORDER BY id ASC LIMIT 1
        ]], project_code)

        -- Fallback: first non-system active namespace
        if not ns or #ns == 0 then
            ns = db.query([[
                SELECT id FROM namespaces
                WHERE status = 'active' AND slug != 'system'
                ORDER BY id ASC LIMIT 1
            ]])
        end

        if not ns or #ns == 0 then return end
        local namespace_id = ns[1].id

        -- Add as namespace member (with "member" role)
        db.query([[
            INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, 'active', false, NOW(), NOW(), NOW())
            ON CONFLICT (namespace_id, user_id) DO NOTHING
        ]], namespace_id, user_id)

        -- Assign default "member" namespace role
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

        -- Set as default namespace
        db.query([[
            INSERT INTO user_namespace_settings (user_id, default_namespace_id, last_active_namespace_id, created_at, updated_at)
            VALUES (?, ?, ?, NOW(), NOW())
            ON CONFLICT (user_id) DO UPDATE SET
                default_namespace_id = EXCLUDED.default_namespace_id,
                last_active_namespace_id = EXCLUDED.last_active_namespace_id,
                updated_at = NOW()
        ]], user_id, namespace_id, namespace_id)

        ngx.log(ngx.NOTICE, "[Register] Auto-assigned user ", user_uuid, " to namespace ", namespace_id)
    end)
    if not ok then
        ngx.log(ngx.ERR, "[Register] Failed to assign namespace: ", tostring(err))
    end
end

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
                return { json = { error = "Invalid registration role" }, status = 400 }
            end

            local success, err = pcall(function()
                Validation.createUser(params)
            end)

            if not success then
                return { json = { error = "Validation failed: " .. tostring(err) }, status = 400 }
            end

            local existing_user = UserQueries.findByEmail(params.email)
            if existing_user then
                return { json = { error = "Email already registered" }, status = 409 }
            end

            local user = UserQueries.create(params)
            user.password = nil

            -- Auto-assign to project namespace (member role + default namespace)
            assignUserToNamespace(user.id, user.uuid)

            -- Generate JWT token for immediate authentication
            local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
            if not JWT_SECRET_KEY then
                ngx.log(ngx.ERR, "JWT_SECRET_KEY not configured")
                return { json = { error = "Server configuration error" }, status = 500 }
            end

            local jwt_payload = {
                userinfo = {
                    uuid = user.uuid,
                    id = user.id,
                    email = user.email,
                    username = user.username,
                    role = user.role
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
