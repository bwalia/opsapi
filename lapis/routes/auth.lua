local http = require("resty.http")
local cJson = require("cjson")
local UserQueries = require "queries.UserQueries"
local Global = require "helper.global"
local JWTHelper = require "helper.jwt-helper"
local NamespaceQueries = require "queries.NamespaceQueries"
local NamespaceMemberQueries = require "queries.NamespaceMemberQueries"

return function(app)
    ----------------- Auth Routes --------------------

    -- Helper function to parse JSON body
    local function parse_json_body()
        local ok, result = pcall(function()
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cJson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    app:post("/auth/login", function(self)
        local identifier = self.params.username or self.params.identifier
        local password = self.params.password

        if not identifier or not password then
            return {
                status = 400,
                json = {
                    error = "Email/Username and password are required"
                }
            }
        end

        local user = UserQueries.verify(identifier, password)

        if not user then
            return {
                status = 401,
                json = {
                    error = "Invalid email/username or password"
                }
            }
        end

        -- Get user with roles
        local userWithRoles = UserQueries.show(user.uuid)
        if not userWithRoles then
            return {
                status = 500,
                json = {
                    error = "Failed to load user data"
                }
            }
        end

        -- Build roles array with proper structure for frontend
        local rolesArray = {}
        if userWithRoles.roles then
            for _, role in ipairs(userWithRoles.roles) do
                table.insert(rolesArray, {
                    id = role.id,
                    role_id = role.role_id,
                    role_name = role.name or role.role_name,
                    name = role.name or role.role_name
                })
            end
        end

        -- USER-FIRST: Get user's namespaces and their default/last active namespace
        local namespaces = NamespaceQueries.getForUser(userWithRoles.uuid) or {}
        local db = require("lapis.db")
        local user_record = db.select("id FROM users WHERE uuid = ?", userWithRoles.uuid)
        local user_id = user_record and user_record[1] and user_record[1].id

        -- Get user's default/last active namespace
        local default_namespace = nil
        local namespace_membership = nil

        if user_id then
            -- First try to get user's configured default or last active namespace
            default_namespace = NamespaceQueries.getUserDefaultNamespace(user_id)
        end

        -- If no default found, fall back to first available namespace
        if not default_namespace then
            for _, ns in ipairs(namespaces) do
                if ns.status == "active" and ns.member_status == "active" then
                    default_namespace = NamespaceQueries.show(ns.id)
                    -- Also set this as the user's last active namespace
                    if user_id then
                        NamespaceQueries.updateLastActiveNamespace(user_id, ns.id)
                    end
                    break
                end
            end
        else
            -- Update last active namespace
            if user_id then
                NamespaceQueries.updateLastActiveNamespace(user_id, default_namespace.id)
            end
        end

        -- If user has a namespace, get membership details
        if default_namespace then
            namespace_membership = NamespaceMemberQueries.findByUserAndNamespace(
                userWithRoles.uuid,
                default_namespace.id
            )
        end

        -- Generate token with namespace context if available
        local token
        if default_namespace and namespace_membership then
            local namespace_permissions = NamespaceMemberQueries.getPermissions(namespace_membership.id)
            token = JWTHelper.generateNamespaceToken(userWithRoles, default_namespace, namespace_membership, {
                user_roles = rolesArray,
                namespace_permissions = namespace_permissions
            })
        else
            token = JWTHelper.generateToken(userWithRoles, {
                roles = rolesArray
            })
        end

        -- Build namespaces array for response
        local namespacesArray = {}
        for _, ns in ipairs(namespaces) do
            table.insert(namespacesArray, {
                id = ns.id,
                uuid = ns.uuid,
                name = ns.name,
                slug = ns.slug,
                logo_url = ns.logo_url,
                is_owner = ns.is_owner,
                status = ns.status,
                member_status = ns.member_status
            })
        end

        return {
            status = 200,
            json = {
                user = {
                    id = userWithRoles.internal_id,
                    uuid = userWithRoles.uuid or userWithRoles.id,
                    email = userWithRoles.email,
                    username = userWithRoles.username,
                    first_name = userWithRoles.first_name or "",
                    last_name = userWithRoles.last_name or "",
                    active = userWithRoles.active,
                    created_at = userWithRoles.created_at,
                    updated_at = userWithRoles.updated_at,
                    roles = rolesArray
                },
                token = token,
                namespaces = namespacesArray,
                current_namespace = default_namespace and {
                    id = default_namespace.id,
                    uuid = default_namespace.uuid,
                    name = default_namespace.name,
                    slug = default_namespace.slug,
                    is_owner = default_namespace.is_owner
                } or nil
            }
        }
    end)

    -- Google OAuth Routes
    app:get("/auth/google", function(self)
        local google_client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local google_redirect_uri = Global.getEnvVar("GOOGLE_REDIRECT_URI")

        if not google_client_id or not google_redirect_uri then
            return {
                status = 500,
                json = {
                    error = "Google OAuth not configured"
                }
            }
        end

        local redirect_from = self.params.from or "/"

        local auth_url = string.format(
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=%s&redirect_uri=%s" ..
            "&response_type=code&scope=openid+profile+email&state=%s",
            google_client_id, ngx.escape_uri(google_redirect_uri), ngx.escape_uri(redirect_from)
        )

        return {
            redirect_to = auth_url
        }
    end)

    app:get("/auth/google/callback", function(self)
        local code = self.params.code
        local redirect_from = self.params.state or "/"

        if not code then
            return {
                status = 400,
                json = {
                    error = "Authorization code not provided"
                }
            }
        end

        local google_client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local google_client_secret = Global.getEnvVar("GOOGLE_CLIENT_SECRET")
        local google_redirect_uri = Global.getEnvVar("GOOGLE_REDIRECT_URI")

        local httpc = http.new()

        -- Exchange code for access token
        local token_res, token_err = httpc:request_uri("https://oauth2.googleapis.com/token", {
            method = "POST",
            body = ngx.encode_args({
                client_id = google_client_id,
                client_secret = google_client_secret,
                code = code,
                grant_type = "authorization_code",
                redirect_uri = google_redirect_uri
            }),
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded"
            },
            ssl_verify = false
        })

        if not token_res then
            return {
                status = 500,
                json = {
                    error = "Failed to exchange code for token: " .. (token_err or "unknown")
                }
            }
        end

        local token_data = cJson.decode(token_res.body)
        if not token_data.access_token then
            return {
                status = 500,
                json = {
                    error = "No access token received"
                }
            }
        end

        -- Get user info from Google
        local user_res, user_err = httpc:request_uri("https://www.googleapis.com/oauth2/v2/userinfo", {
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token_data.access_token
            },
            ssl_verify = false
        })

        if not user_res then
            return {
                status = 500,
                json = {
                    error = "Failed to get user info: " .. (user_err or "unknown")
                }
            }
        end

        local google_user = cJson.decode(user_res.body)
        if not google_user.email then
            return {
                status = 500,
                json = {
                    error = "No email received from Google"
                }
            }
        end

        -- Find or create user
        local user = UserQueries.findByEmail(google_user.email)
        if not user then
            local names = {}
            if google_user.name then
                names = Global.splitName(google_user.name)
            end

            user = UserQueries.createOAuthUser({
                uuid = Global.generateUUID(),
                email = google_user.email,
                username = google_user.email,
                first_name = names.first_name or google_user.given_name or "",
                last_name = names.last_name or google_user.family_name or "",
                password = Global.generateRandomPassword(),
                role = "buyer",
                oauth_provider = "google",
                oauth_id = google_user.id,
                active = true
            })
        end

        -- Get user with roles
        local userWithRoles = UserQueries.show(user.uuid)
        if not userWithRoles then
            return {
                status = 500,
                json = {
                    error = "Failed to load user data"
                }
            }
        end

        -- Build roles array
        local rolesArray = {}
        if userWithRoles.roles then
            for _, role in ipairs(userWithRoles.roles) do
                table.insert(rolesArray, {
                    id = role.id,
                    role_id = role.role_id,
                    role_name = role.name or role.role_name,
                    name = role.name or role.role_name
                })
            end
        end

        -- Get user's namespaces
        local namespaces = NamespaceQueries.getForUser(userWithRoles.uuid) or {}
        local default_namespace = nil
        local namespace_membership = nil

        -- Find first active namespace
        for _, ns in ipairs(namespaces) do
            if ns.status == "active" and ns.member_status == "active" then
                default_namespace = ns
                break
            end
        end

        -- Get namespace membership if available
        if default_namespace then
            namespace_membership = NamespaceMemberQueries.findByUserAndNamespace(
                userWithRoles.uuid,
                default_namespace.id
            )
        end

        -- Generate JWT token with namespace context
        local token
        if default_namespace and namespace_membership then
            local namespace_permissions = NamespaceMemberQueries.getPermissions(namespace_membership.id)
            token = JWTHelper.generateNamespaceToken(userWithRoles, default_namespace, namespace_membership, {
                user_roles = rolesArray,
                namespace_permissions = namespace_permissions
            })
        else
            token = JWTHelper.generateToken(userWithRoles, {
                roles = rolesArray
            })
        end

        -- Redirect to frontend with token
        local frontend_url = Global.getEnvVar("FRONTEND_URL") or "http://localhost:3033"
        local final_url = string.format("%s/auth/callback?token=%s&redirect=%s",
            frontend_url, ngx.escape_uri(token), ngx.escape_uri(redirect_from))

        return {
            redirect_to = final_url
        }
    end)

    -- Logout endpoint
    app:post("/auth/logout", function(self)
        -- Clear any session data
        if self.session then
            for k, _ in pairs(self.session) do
                self.session[k] = nil
            end
        end

        -- Clear user's cart from database
        local user_uuid = ngx.var.http_x_user_id
        if user_uuid and user_uuid ~= "guest" then
            local db = require("lapis.db")
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if user_result and #user_result > 0 then
                db.delete("cart_items", "user_id = ?", user_result[1].id)
            end
        end

        return {
            json = {
                message = "Logged out successfully"
            },
            status = 200
        }
    end)

    -- OAuth token validation endpoint
    app:post("/auth/oauth/validate", function(self)
        local token = self.params.token
        if not token then
            return {
                status = 400,
                json = {
                    error = "Token is required"
                }
            }
        end

        local result = JWTHelper.verifyToken(token)

        if not result.valid then
            return {
                status = 401,
                json = {
                    error = "Invalid token"
                }
            }
        end

        local userinfo = result.payload.userinfo
        return {
            status = 200,
            json = {
                user = {
                    id = userinfo.uuid,
                    email = userinfo.email,
                    name = userinfo.name,
                    role = userinfo.roles,
                    namespace = userinfo.namespace
                },
                token = token
            }
        }
    end)

    -- Token refresh endpoint with namespace support
    app:post("/auth/refresh", function(self)
        local auth_header = self.req.headers["authorization"]
        if not auth_header then
            return {
                status = 401,
                json = { error = "Authorization header required" }
            }
        end

        local token = auth_header:match("Bearer%s+(.+)")
        if not token then
            return {
                status = 401,
                json = { error = "Invalid Authorization format" }
            }
        end

        local new_token = JWTHelper.refreshToken(token)
        if not new_token then
            return {
                status = 401,
                json = { error = "Invalid or expired token" }
            }
        end

        return {
            status = 200,
            json = {
                token = new_token,
                message = "Token refreshed successfully"
            }
        }
    end)

    -- Get current user info (includes namespace)
    app:get("/auth/me", function(self)
        if not self.current_user then
            return {
                status = 401,
                json = { error = "Not authenticated" }
            }
        end

        -- Get full user data
        local user = UserQueries.show(self.current_user.uuid)
        if not user then
            return {
                status = 404,
                json = { error = "User not found" }
            }
        end

        -- Build roles array
        local rolesArray = {}
        if user.roles then
            for _, role in ipairs(user.roles) do
                table.insert(rolesArray, {
                    id = role.id,
                    role_id = role.role_id,
                    role_name = role.name or role.role_name,
                    name = role.name or role.role_name
                })
            end
        end

        -- Get user's namespaces
        local namespaces = NamespaceQueries.getForUser(user.uuid) or {}
        local namespacesArray = {}
        for _, ns in ipairs(namespaces) do
            table.insert(namespacesArray, {
                id = ns.id,
                uuid = ns.uuid,
                name = ns.name,
                slug = ns.slug,
                logo_url = ns.logo_url,
                is_owner = ns.is_owner,
                status = ns.status,
                member_status = ns.member_status
            })
        end

        -- Get current namespace from token
        local current_namespace = self.current_user.namespace

        return {
            status = 200,
            json = {
                user = {
                    id = user.internal_id,
                    uuid = user.uuid,
                    email = user.email,
                    username = user.username,
                    first_name = user.first_name or "",
                    last_name = user.last_name or "",
                    active = user.active,
                    created_at = user.created_at,
                    updated_at = user.updated_at,
                    roles = rolesArray
                },
                namespaces = namespacesArray,
                current_namespace = current_namespace
            }
        }
    end)
end
