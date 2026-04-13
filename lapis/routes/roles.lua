--[[
    Role Routes

    API endpoints for namespace-scoped role management.

    Security Architecture:
    ======================
    - All endpoints require authentication
    - Role operations are namespace-scoped (X-Namespace-Id header required)
    - Only users with 'roles' permission can manage roles
    - 'manage' permission grants full access
    - 'create', 'read', 'update', 'delete' are granular permissions

    Endpoints:
    - GET    /api/v2/roles          - List roles (requires roles.read)
    - GET    /api/v2/roles/:id      - Get role details (requires roles.read)
    - POST   /api/v2/roles          - Create role (requires roles.create)
    - PUT    /api/v2/roles/:id      - Update role (requires roles.update)
    - DELETE /api/v2/roles/:id      - Delete role (requires roles.delete)
]]

local RoleQueries = require "queries.RoleQueries"
local RequestParser = require "helper.request_parser"
local cjson = require "cjson"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

return function(app)

    -- Helper function for error responses
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Roles API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    -- Helper to get role permissions for response
    local function get_role_permissions(self)
        local is_owner = self.is_namespace_owner
        local perms = self.namespace_permissions or {}
        local role_perms = perms.roles or {}

        local function has_perm(action)
            if is_owner then return true end
            for _, p in ipairs(role_perms) do
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

    -- LIST all roles
    -- Requires: roles.read permission
    app:get("/api/v2/roles", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "read", function(self)
            local params = self.params or {}

            local limit = tonumber(params.limit) or 100
            local offset = tonumber(params.offset) or 0

            ngx.log(ngx.NOTICE, "Listing roles for namespace: ", self.namespace.slug,
                " - limit: ", limit, ", offset: ", offset)

            local ok, roles = pcall(RoleQueries.list, {
                limit = limit,
                offset = offset,
                namespace_id = self.namespace.id
            })

            if not ok then
                return error_response(500, "Failed to list roles", tostring(roles))
            end

            local count_ok, total = pcall(RoleQueries.count, {
                namespace_id = self.namespace.id
            })
            if not count_ok then
                total = 0
            end

            return {
                status = 200,
                json = {
                    data = roles or {},
                    total = total,
                    permissions = get_role_permissions(self)
                }
            }
        end)
    ))

    -- GET single role by ID
    -- Requires: roles.read permission
    app:get("/api/v2/roles/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "read", function(self)
            local role_id = self.params.id

            ngx.log(ngx.NOTICE, "Fetching role: ", role_id, " for namespace: ", self.namespace.slug)

            local ok, role = pcall(RoleQueries.show, role_id)

            if not ok then
                return error_response(500, "Failed to fetch role", tostring(role))
            end

            if not role then
                return error_response(404, "Role not found")
            end

            -- Verify role belongs to current namespace (if namespace-scoped)
            if role.namespace_id and role.namespace_id ~= self.namespace.id then
                return error_response(403, "Role not found in this namespace")
            end

            return {
                status = 200,
                json = {
                    data = role,
                    permissions = get_role_permissions(self)
                }
            }
        end)
    ))

    -- CREATE new role
    -- Requires: roles.create permission
    app:post("/api/v2/roles", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "create", function(self)
            local params = RequestParser.parse_request(self)

            -- Validate required fields
            local valid, missing = RequestParser.require_params(params, {"name"})
            if not valid then
                return error_response(400, "Missing required fields", table.concat(missing, ", "))
            end

            local role_data = {
                role_name = params.name,
                description = params.description,
                permissions = params.permissions,
                namespace_id = self.namespace.id,
                created_by = self.current_user.uuid
            }

            ngx.log(ngx.NOTICE, "Creating role in namespace ", self.namespace.slug, ": ", cjson.encode(role_data))

            local ok, role = pcall(RoleQueries.create, role_data)

            if not ok then
                return error_response(500, "Failed to create role", tostring(role))
            end

            return {
                status = 201,
                json = {
                    data = role,
                    message = "Role created successfully",
                    permissions = get_role_permissions(self)
                }
            }
        end)
    ))

    -- UPDATE existing role
    -- Requires: roles.update permission
    app:put("/api/v2/roles/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "update", function(self)
            local role_id = self.params.id

            -- First verify role exists and belongs to namespace
            local ok, role = pcall(RoleQueries.show, role_id)

            if not ok then
                return error_response(500, "Failed to fetch role", tostring(role))
            end

            if not role then
                return error_response(404, "Role not found")
            end

            -- Verify role belongs to current namespace (if namespace-scoped)
            if role.namespace_id and role.namespace_id ~= self.namespace.id then
                return error_response(403, "Role not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            local update_data = {
                updated_by = self.current_user.uuid
            }
            if params.name then update_data.role_name = params.name end
            if params.description then update_data.description = params.description end
            if params.permissions then update_data.permissions = params.permissions end

            if next(update_data) == nil then
                return error_response(400, "No data provided for update")
            end

            ngx.log(ngx.NOTICE, "Updating role ", role_id, " in namespace ", self.namespace.slug,
                ": ", cjson.encode(update_data))

            local ok2, updated_role = pcall(RoleQueries.update, role_id, update_data)

            if not ok2 then
                return error_response(500, "Failed to update role", tostring(updated_role))
            end

            if not updated_role then
                return error_response(404, "Role not found")
            end

            return {
                status = 200,
                json = {
                    data = updated_role,
                    message = "Role updated successfully",
                    permissions = get_role_permissions(self)
                }
            }
        end)
    ))

    -- DELETE role
    -- Requires: roles.delete permission
    app:delete("/api/v2/roles/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "delete", function(self)
            local role_id = self.params.id

            -- First verify role exists and belongs to namespace
            local ok, role = pcall(RoleQueries.show, role_id)

            if not ok then
                return error_response(500, "Failed to fetch role", tostring(role))
            end

            if not role then
                return error_response(404, "Role not found")
            end

            -- Verify role belongs to current namespace (if namespace-scoped)
            if role.namespace_id and role.namespace_id ~= self.namespace.id then
                return error_response(403, "Role not found in this namespace")
            end

            -- Prevent deletion of system roles
            if role.is_system then
                return error_response(400, "Cannot delete system roles")
            end

            ngx.log(ngx.NOTICE, "Deleting role: ", role_id, " from namespace: ", self.namespace.slug)

            local ok2, result = pcall(RoleQueries.delete, role_id)

            if not ok2 then
                return error_response(500, "Failed to delete role", tostring(result))
            end

            if not result then
                return error_response(404, "Role not found")
            end

            return {
                status = 200,
                json = {
                    message = "Role deleted successfully",
                    id = role_id
                }
            }
        end)
    ))

    ngx.log(ngx.NOTICE, "Roles routes initialized successfully")
end
