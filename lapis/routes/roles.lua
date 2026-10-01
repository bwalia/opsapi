--[[
    Platform Role Routes (`roles` table: administrative, member, tax_admin, ...)

    SECURITY: platform admins only. These roles are global — the table has no
    namespace_id — and "administrative" IS platform admin. These routes used
    to be guarded by a workspace permission (roles.*), so any workspace
    owner/admin could delete a platform role (the namespace and "system"
    checks read columns that don't exist and always passed). Workspace roles
    are /api/v2/namespace/roles (NamespaceRoleQueries).

    Endpoints:
    - GET    /api/v2/roles          - List platform roles
    - GET    /api/v2/roles/:id      - Get a platform role
    - POST   /api/v2/roles          - Create a platform role   { name, description? }
    - PUT    /api/v2/roles/:id      - Rename / describe a role { name?, description? }
    - DELETE /api/v2/roles/:id      - Delete an unused, non-built-in role
]]

local RoleQueries = require "queries.RoleQueries"
local RequestParser = require "helper.request_parser"
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")

-- Roles the platform itself depends on: never renamed or deleted.
local BUILT_IN = {
    administrative = true, member = true, buyer = true, seller = true, delivery_partner = true,
    tax_admin = true, tax_accountant = true, tax_client = true, tax_viewer = true,
}

-- Platform admins may do everything here.
local ALL_RIGHTS = { can_create = true, can_read = true, can_update = true, can_delete = true, can_manage = true }

local function admin_only(handler)
    return AuthMiddleware.requireRole("administrative", handler)
end

local function valid_name(name)
    return type(name) == "string" and name:match("^[%a][%w_]*$") ~= nil and #name >= 2 and #name <= 25
end

return function(app)

    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Roles API error: ", message, " | Details: ", tostring(details))
        -- 5xx: never echo the raw error (SQL + user data); input errors become 4xx.
        return require("lib.errors").legacy(status, message, details)
    end

    local function users_with(role)
        local id = role.internal_id or role.id
        if type(id) ~= "number" then
            local row = db.select("id FROM roles WHERE uuid = ? LIMIT 1", tostring(role.uuid or role.id))[1]
            id = row and row.id
        end
        if not id then return 0 end
        return db.select("COUNT(*)::int AS n FROM user__roles WHERE role_id = ?", id)[1].n
    end

    app:get("/api/v2/roles", admin_only(function(self)
        local params = self.params or {}
        local limit = math.min(math.max(math.floor(tonumber(params.limit) or 100), 1), 500)
        local offset = math.max(math.floor(tonumber(params.offset) or 0), 0)
        local ok, roles = pcall(RoleQueries.list, { perPage = limit, page = math.floor(offset / limit) + 1 })
        if not ok then
            return error_response(500, "Failed to list roles", tostring(roles))
        end
        local count_ok, total = pcall(RoleQueries.count, {})
        return {
            status = 200,
            json = { data = roles or {}, total = count_ok and total or 0, permissions = ALL_RIGHTS },
        }
    end))

    app:get("/api/v2/roles/:id", admin_only(function(self)
        local ok, role = pcall(RoleQueries.show, self.params.id)
        if not ok then
            return error_response(500, "Failed to fetch role", tostring(role))
        end
        if not role then
            return error_response(404, "Role not found")
        end
        return { status = 200, json = { data = role, permissions = ALL_RIGHTS } }
    end))

    app:post("/api/v2/roles", admin_only(function(self)
        local params = RequestParser.parse_request(self)
        if not valid_name(params.name) then
            return error_response(422, "name is required: 2-25 letters, digits or _, starting with a letter")
        end
        if RoleQueries.roleByName(params.name) then
            return error_response(409, "A role with this name already exists")
        end
        local ok, role = pcall(RoleQueries.create, {
            role_name = params.name,
            description = type(params.description) == "string" and params.description or nil,
        })
        if not ok then
            return error_response(500, "Failed to create role", tostring(role))
        end
        return {
            status = 201,
            json = { data = role, message = "Role created successfully", permissions = ALL_RIGHTS },
        }
    end))

    app:put("/api/v2/roles/:id", admin_only(function(self)
        local ok, role = pcall(RoleQueries.show, self.params.id)
        if not ok then
            return error_response(500, "Failed to fetch role", tostring(role))
        end
        if not role then
            return error_response(404, "Role not found")
        end

        local params = RequestParser.parse_request(self)
        local update_data = {}
        if params.name ~= nil and params.name ~= role.role_name then
            if BUILT_IN[role.role_name] then
                return error_response(400, "Built-in roles can't be renamed")
            end
            if not valid_name(params.name) then
                return error_response(422, "name: 2-25 letters, digits or _, starting with a letter")
            end
            if RoleQueries.roleByName(params.name) then
                return error_response(409, "A role with this name already exists")
            end
            update_data.role_name = params.name
        end
        if type(params.description) == "string" then update_data.description = params.description end
        if next(update_data) == nil then
            return error_response(400, "No data provided for update")
        end

        local ok2, updated_role = pcall(RoleQueries.update, self.params.id, update_data)
        if not ok2 then
            return error_response(500, "Failed to update role", tostring(updated_role))
        end
        if not updated_role then
            return error_response(404, "Role not found")
        end
        return {
            status = 200,
            json = { data = updated_role, message = "Role updated successfully", permissions = ALL_RIGHTS },
        }
    end))

    app:delete("/api/v2/roles/:id", admin_only(function(self)
        local role_id = self.params.id
        local ok, role = pcall(RoleQueries.show, role_id)
        if not ok then
            return error_response(500, "Failed to fetch role", tostring(role))
        end
        if not role then
            return error_response(404, "Role not found")
        end
        if BUILT_IN[role.role_name] then
            return error_response(400, "Built-in roles can't be deleted")
        end
        local holders = users_with(role)
        if holders > 0 then
            return error_response(409, "Role is assigned to " .. holders .. " user(s); unassign it first")
        end

        local ok2, result = pcall(RoleQueries.delete, role_id)
        if not ok2 then
            return error_response(500, "Failed to delete role", tostring(result))
        end
        if not result then
            return error_response(404, "Role not found")
        end
        return { status = 200, json = { message = "Role deleted successfully", id = role_id } }
    end))
end
