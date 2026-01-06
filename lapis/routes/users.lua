--[[
    User Routes

    API endpoints for namespace-scoped user management.

    Security Architecture:
    ======================
    - All endpoints require authentication
    - User operations are namespace-scoped (X-Namespace-Id header required)
    - Only users with 'users' permission can manage users
    - 'manage' permission grants full access
    - 'create', 'read', 'update', 'delete' are granular permissions

    Endpoints:
    - GET    /api/v2/users/search           - Search users (requires users.read)
    - GET    /api/v2/users                  - List users (requires users.read)
    - GET    /api/v2/users/:id              - Get user details (requires users.read)
    - POST   /api/v2/users                  - Create user (requires users.create)
    - PUT    /api/v2/users/:id              - Update user (requires users.update)
    - DELETE /api/v2/users/:id              - Delete user (requires users.delete)
]]

local respond_to = require("lapis.application").respond_to
local UserQueries = require "queries.UserQueries"
local RequestParser = require "helper.request_parser"
local Global = require "helper.global"
local cjson = require "cjson"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Users API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    -- Helper to get user permissions for response
    local function get_user_permissions(self)
        local is_owner = self.is_namespace_owner
        local perms = self.namespace_permissions or {}
        local user_perms = perms.users or {}

        local function has_perm(action)
            if is_owner then return true end
            for _, p in ipairs(user_perms) do
                if p == action or p == "manage" then return true end
            end
            return false
        end

        return {
            can_create = has_perm("create"),
            can_read = has_perm("read"),
            can_update = has_perm("update"),
            can_delete = has_perm("delete"),
            can_manage = has_perm("manage")
        }
    end

    -- SEARCH users (must be before the general list endpoint)
    -- Requires: users.read permission
    app:get("/api/v2/users/search", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "read", function(self)
            local params = self.params or {}
            local query = params.q or params.query or ""

            if query == "" then
                return {
                    status = 200,
                    json = {
                        data = {},
                        total = 0,
                        permissions = get_user_permissions(self)
                    }
                }
            end

            local ok, result = pcall(UserQueries.search, {
                query = query,
                limit = tonumber(params.limit) or 10,
                exclude_namespace_id = params.exclude_namespace_id and tonumber(params.exclude_namespace_id),
                namespace_id = self.namespace.id
            })

            if not ok then
                return error_response(500, "Failed to search users", tostring(result))
            end

            return {
                status = 200,
                json = {
                    data = result.data or {},
                    total = result.total or 0,
                    permissions = get_user_permissions(self)
                }
            }
        end)
    ))

    -- LIST users
    -- Requires: users.read permission
    app:get("/api/v2/users", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "read", function(self)
            local params = self.params or {}

            local page = tonumber(params.page) or 1
            local perPage = tonumber(params.limit) or tonumber(params.per_page) or 10

            -- Handle offset-based pagination
            local offset = tonumber(params.offset) or 0
            if offset > 0 and page == 1 then
                page = math.floor(offset / perPage) + 1
            end

            local ok, result = pcall(UserQueries.all, {
                page = page,
                perPage = perPage,
                orderBy = params.order_by or 'id',
                orderDir = params.order_dir or 'desc',
                namespace_id = self.namespace.id
            })

            if not ok then
                return error_response(500, "Failed to list users", tostring(result))
            end

            return {
                status = 200,
                json = {
                    data = result.data or {},
                    total = result.total or 0,
                    permissions = get_user_permissions(self)
                }
            }
        end)
    ))

    -- GET single user (with optional detailed info)
    -- Requires: users.read permission
    app:get("/api/v2/users/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "read", function(self)
            local user_id = self.params.id
            local include_details = self.params.include_details == "true" or
                                    self.params.include_details == "1" or
                                    self.params.detailed == "true"

            local ok, user
            if include_details then
                ok, user = pcall(UserQueries.showDetailed, user_id)
            else
                ok, user = pcall(UserQueries.show, user_id)
            end

            if not ok then
                return error_response(500, "Failed to fetch user", tostring(user))
            end

            if not user then
                return error_response(404, "User not found")
            end

            return {
                status = 200,
                json = {
                    data = user,
                    permissions = get_user_permissions(self)
                }
            }
        end)
    ))

    -- CREATE user
    -- Requires: users.create permission
    -- Supports optional namespace assignment:
    --   - namespace_id: ID of namespace to add user to (defaults to current namespace)
    --   - namespace_role: Role within the namespace (defaults to "member")
    app:post("/api/v2/users", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "create", function(self)
            local params = RequestParser.parse_request(self)

            local valid, missing = RequestParser.require_params(params, { "email", "password" })
            if not valid then
                return error_response(400, "Missing required fields", table.concat(missing, ", "))
            end

            local user_data = {
                email = params.email,
                password = params.password,
                first_name = params.first_name or params.firstName,
                last_name = params.last_name or params.lastName,
                username = params.username or params.email,
                role = params.role or "buyer",
                -- Namespace assignment (defaults to current namespace)
                namespace_id = params.namespace_id and tonumber(params.namespace_id) or self.namespace.id,
                namespace_role = params.namespace_role or "member",
                created_by = self.current_user.uuid
            }

            ngx.log(ngx.NOTICE, "Creating user: ", params.email, " in namespace: ", self.namespace.slug)

            local ok, user = pcall(UserQueries.create, user_data)

            if not ok then
                return error_response(500, "Failed to create user", tostring(user))
            end

            return {
                status = 201,
                json = {
                    data = user,
                    message = "User created successfully",
                    permissions = get_user_permissions(self)
                }
            }
        end)
    ))

    -- UPDATE user
    -- Requires: users.update permission
    app:put("/api/v2/users/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "update", function(self)
            local user_id = self.params.id
            local params = RequestParser.parse_request(self)

            local update_data = {}
            if params.email then update_data.email = params.email end
            if params.first_name or params.firstName then
                update_data.first_name = params.first_name or params.firstName
            end
            if params.last_name or params.lastName then
                update_data.last_name = params.last_name or params.lastName
            end
            if params.username then update_data.username = params.username end
            if params.phone_no then update_data.phone_no = params.phone_no end
            if params.address then update_data.address = params.address end
            if params.active ~= nil then
                update_data.active = params.active == "true" or params.active == true or params.active == "1"
            end
            update_data.updated_by = self.current_user.uuid

            if next(update_data) == nil then
                return error_response(400, "No data provided for update")
            end

            local ok, result = pcall(UserQueries.update, user_id, update_data)

            if not ok then
                return error_response(500, "Failed to update user", tostring(result))
            end

            if not result then
                return error_response(404, "User not found")
            end

            -- Fetch the updated user to return
            local ok2, user = pcall(UserQueries.show, user_id)
            if not ok2 or not user then
                return error_response(500, "User updated but failed to fetch")
            end

            return {
                status = 200,
                json = {
                    data = user,
                    message = "User updated successfully",
                    permissions = get_user_permissions(self)
                }
            }
        end)
    ))

    -- DELETE user
    -- Requires: users.delete permission
    app:delete("/api/v2/users/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "delete", function(self)
            local user_id = self.params.id

            -- Prevent self-deletion
            if user_id == self.current_user.uuid then
                return error_response(400, "Cannot delete your own account")
            end

            local ok, result = pcall(UserQueries.destroy, user_id)

            if not ok then
                return error_response(500, "Failed to delete user", tostring(result))
            end

            if not result then
                return error_response(404, "User not found")
            end

            return {
                status = 200,
                json = {
                    message = "User deleted successfully",
                    id = user_id
                }
            }
        end)
    ))

    ----------------- SCIM User Routes --------------------
    -- SCIM routes require authentication but use their own authorization model
    -- These are typically used for enterprise SSO/identity provider integrations
    app:match("scim_users", "/scim/v2/Users", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            self.params.timestamp = true
            local users = UserQueries.SCIMall(self.params)
            return {
                json = users,
                status = 200
            }
        end),
        POST = AuthMiddleware.requireAuth(function(self)
            local user = UserQueries.SCIMcreate(self.params)
            return {
                json = user,
                status = 201
            }
        end)
    }))

    app:match("edit_scim_user", "/scim/v2/Users/:id", respond_to({
        before = AuthMiddleware.requireAuth(function(self)
            self.user = UserQueries.show(tostring(self.params.id))
            if not self.user then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "User not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end),
        GET = AuthMiddleware.requireAuth(function(self)
            local user = UserQueries.show(tostring(self.params.id))
            return {
                json = user,
                status = 200
            }
        end),
        PUT = AuthMiddleware.requireAuth(function(self)
            local content_type = self.req.headers["content-type"]
            local body = self.params
            if content_type == "application/json" then
                ngx.req.read_body()
                body = Global.getPayloads(ngx.req.get_post_args())
            end
            local user, status = UserQueries.SCIMupdate(tostring(self.params.id), body)
            return {
                json = user,
                status = status
            }
        end),
        DELETE = AuthMiddleware.requireAuth(function(self)
            local user = UserQueries.destroy(tostring(self.params.id))
            return {
                json = user,
                status = 204
            }
        end)
    }))

    ngx.log(ngx.NOTICE, "Users routes initialized successfully")
end
