local respond_to = require("lapis.application").respond_to
local RoleQueries = require "queries.RoleQueries"
local RequestParser = require "helper.request_parser"
local cjson = require "cjson"

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

    -- LIST all roles
    app:get("/api/v2/roles", function(self)
        local params = self.params or {}
        
        local limit = tonumber(params.limit) or 100
        local offset = tonumber(params.offset) or 0
        
        ngx.log(ngx.NOTICE, "Listing roles - limit: ", limit, ", offset: ", offset)
        
        local ok, roles = pcall(RoleQueries.list, {
            limit = limit,
            offset = offset
        })
        
        if not ok then
            return error_response(500, "Failed to list roles", tostring(roles))
        end
        
        local count_ok, total = pcall(RoleQueries.count)
        if not count_ok then
            total = 0
        end
        
        return {
            status = 200,
            json = {
                data = roles or {},
                total = total
            }
        }
    end)
    
    -- GET single role by ID
    app:get("/api/v2/roles/:id", function(self)
        local role_id = self.params.id
        
        ngx.log(ngx.NOTICE, "Fetching role: ", role_id)
        
        local ok, role = pcall(RoleQueries.show, role_id)
        
        if not ok then
            return error_response(500, "Failed to fetch role", tostring(role))
        end
        
        if not role then
            return error_response(404, "Role not found")
        end
        
        return {
            status = 200,
            json = role
        }
    end)
    
    -- CREATE new role
    app:post("/api/v2/roles", function(self)
        local params, files = RequestParser.parse_request(self)
        
        -- Validate required fields
        local valid, missing = RequestParser.require_params(params, {"name"})
        if not valid then
            return error_response(400, "Missing required fields", table.concat(missing, ", "))
        end
        
        local role_data = {
            role_name = params.name,
            description = params.description,
            permissions = params.permissions
        }
        
        ngx.log(ngx.NOTICE, "Creating role: ", cjson.encode(role_data))
        
        local ok, role = pcall(RoleQueries.create, role_data)
        
        if not ok then
            return error_response(500, "Failed to create role", tostring(role))
        end
        
        return {
            status = 201,
            json = role
        }
    end)
    
    -- UPDATE existing role
    app:put("/api/v2/roles/:id", function(self)
        local role_id = self.params.id
        local params, files = RequestParser.parse_request(self)
        
        local update_data = {}
        if params.name then update_data.role_name = params.name end
        if params.description then update_data.description = params.description end
        if params.permissions then update_data.permissions = params.permissions end
        
        if next(update_data) == nil then
            return error_response(400, "No data provided for update")
        end
        
        ngx.log(ngx.NOTICE, "Updating role ", role_id, ": ", cjson.encode(update_data))
        
        local ok, role = pcall(RoleQueries.update, role_id, update_data)
        
        if not ok then
            return error_response(500, "Failed to update role", tostring(role))
        end
        
        if not role then
            return error_response(404, "Role not found")
        end
        
        return {
            status = 200,
            json = role
        }
    end)
    
    -- DELETE role
    app:delete("/api/v2/roles/:id", function(self)
        local role_id = self.params.id
        
        ngx.log(ngx.NOTICE, "Deleting role: ", role_id)
        
        local ok, result = pcall(RoleQueries.delete, role_id)
        
        if not ok then
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
    
    ngx.log(ngx.NOTICE, "Roles routes initialized successfully")
end
