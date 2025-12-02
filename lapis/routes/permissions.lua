local PermissionQueries = require "queries.PermissionQueries"
local RequestParser = require "helper.request_parser"
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

    -- LIST all permissions (with optional role filter)
    app:get("/api/v2/permissions", function(self)
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
    end)

    -- GET single permission by UUID
    app:get("/api/v2/permissions/:id", function(self)
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
    end)

    -- CREATE new permission
    app:post("/api/v2/permissions", function(self)
        local params, _ = RequestParser.parse_request(self)

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
    end)

    -- UPDATE existing permission
    app:put("/api/v2/permissions/:id", function(self)
        local uuid = self.params.id
        local params, _ = RequestParser.parse_request(self)

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
    end)

    -- DELETE permission
    app:delete("/api/v2/permissions/:id", function(self)
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
    end)

    ngx.log(ngx.NOTICE, "Permissions routes initialized successfully")
end
