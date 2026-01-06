--[[
    Permissions Routes (Admin Only)

    SECURITY: All endpoints require authentication and admin role.
    These routes manage RBAC permissions for roles.
]]

local PermissionQueries = require "queries.PermissionQueries"
local RequestParser = require "helper.request_parser"
local AuthMiddleware = require("middleware.auth")
local cjson = require "cjson"

-- Configure cjson to encode empty tables as arrays
cjson.encode_empty_table_as_object(false)

return function(app)
    -- Helper function for error responses
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Permissions API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    -- Helper to check if user is admin
    local function is_admin(user)
        if not user then return false end

        if user.roles then
            if type(user.roles) == "string" then
                return user.roles:lower():find("admin") ~= nil
            elseif type(user.roles) == "table" then
                for _, role in ipairs(user.roles) do
                    local role_name = type(role) == "string" and role or (role.role_name or role.name or "")
                    if role_name:lower():find("admin") then
                        return true
                    end
                end
            end
        end

        return false
    end

    -- LIST all permissions (with optional role filter) - Admin only
    app:get("/api/v2/permissions", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Access denied. Admin privileges required.")
        end

        local params = self.params or {}

        local perPage = tonumber(params.limit) or tonumber(params.perPage) or 100
        local page = tonumber(params.page) or 1
        local offset = tonumber(params.offset)

        -- Calculate page from offset if provided
        if offset and offset > 0 then
            page = math.floor(offset / perPage) + 1
        end

        ngx.log(ngx.NOTICE, "Listing permissions - page: ", page, ", perPage: ", perPage, ", role: ",
            tostring(params.role))

        local ok, result = pcall(PermissionQueries.all, {
            page = page,
            perPage = perPage,
            role = params.role,
            module = params.module
        })

        if not ok then
            return error_response(500, "Failed to list permissions", tostring(result))
        end

        return {
            status = 200,
            json = result
        }
    end))

    -- GET single permission by UUID - Admin only
    app:get("/api/v2/permissions/:id", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Access denied. Admin privileges required.")
        end

        local uuid = self.params.id

        ngx.log(ngx.NOTICE, "Fetching permission: ", uuid)

        local ok, permission = pcall(PermissionQueries.show, tostring(uuid))

        if not ok then
            return error_response(500, "Failed to fetch permission", tostring(permission))
        end

        if not permission then
            return error_response(404, "Permission not found")
        end

        return {
            status = 200,
            json = permission
        }
    end))

    -- CREATE new permission - Admin only
    app:post("/api/v2/permissions", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Access denied. Admin privileges required.")
        end

        local params = RequestParser.parse_request(self)

        -- Validate required fields
        local valid, missing = RequestParser.require_params(params, { "role", "module_machine_name", "permissions" })
        if not valid then
            return error_response(400, "Missing required fields", table.concat(missing, ", "))
        end

        ngx.log(ngx.NOTICE, "Creating permission: role=", params.role,
            ", module=", params.module_machine_name,
            ", permissions=", params.permissions)

        local ok, permission = pcall(PermissionQueries.create, {
            role = params.role,
            module_machine_name = params.module_machine_name,
            permissions = params.permissions
        })

        if not ok then
            return error_response(500, "Failed to create permission", tostring(permission))
        end

        return {
            status = 201,
            json = permission
        }
    end))

    -- UPDATE existing permission - Admin only
    app:put("/api/v2/permissions/:id", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Access denied. Admin privileges required.")
        end

        local uuid = self.params.id
        local params = RequestParser.parse_request(self)

        local update_data = {}
        if params.permissions then update_data.permissions = params.permissions end

        if next(update_data) == nil then
            return error_response(400, "No data provided for update")
        end

        ngx.log(ngx.NOTICE, "Updating permission ", uuid, ": ", cjson.encode(update_data))

        local ok, permission = pcall(PermissionQueries.update, tostring(uuid), update_data)

        if not ok then
            return error_response(500, "Failed to update permission", tostring(permission))
        end

        if not permission then
            return error_response(404, "Permission not found")
        end

        return {
            status = 200,
            json = permission
        }
    end))

    -- DELETE permission - Admin only
    app:delete("/api/v2/permissions/:id", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Access denied. Admin privileges required.")
        end

        local uuid = self.params.id

        ngx.log(ngx.NOTICE, "Deleting permission: ", uuid)

        local ok, result = pcall(PermissionQueries.destroy, tostring(uuid))

        if not ok then
            return error_response(500, "Failed to delete permission", tostring(result))
        end

        return {
            status = 200,
            json = {
                message = "Permission deleted successfully",
                id = uuid
            }
        }
    end))

    -- BATCH update/create permissions for a role - Admin only
    app:post("/api/v2/permissions/batch", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Access denied. Admin privileges required.")
        end

        local params = RequestParser.parse_request(self)

        -- Validate required fields
        local valid, missing = RequestParser.require_params(params, { "role", "permissions" })
        if not valid then
            return error_response(400, "Missing required fields", table.concat(missing, ", "))
        end

        local roleName = params.role
        local permissionsData = params.permissions

        -- Parse permissions if it's a JSON string
        if type(permissionsData) == "string" then
            local ok, parsed = pcall(cjson.decode, permissionsData)
            if not ok then
                return error_response(400, "Invalid permissions format. Expected JSON object.")
            end
            permissionsData = parsed
        end

        if type(permissionsData) ~= "table" then
            return error_response(400, "Permissions must be an object with module names as keys")
        end

        ngx.log(ngx.NOTICE, "Batch updating permissions for role: ", roleName)

        local ok, result = pcall(PermissionQueries.batchUpdate, {
            role = roleName,
            permissions = permissionsData
        })

        if not ok then
            return error_response(500, "Failed to batch update permissions", tostring(result))
        end

        return {
            status = 200,
            json = {
                message = "Permissions updated successfully",
                role = roleName,
                updated = result.updated or 0,
                created = result.created or 0,
                deleted = result.deleted or 0
            }
        }
    end))

    ngx.log(ngx.NOTICE, "Permissions routes initialized successfully")
end
