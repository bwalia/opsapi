--[[
    Customer Routes

    API endpoints for namespace-scoped customer management.

    Security Architecture:
    ======================
    - All endpoints require authentication
    - Customer operations are namespace-scoped (X-Namespace-Id header required)
    - Only users with 'customers' permission can manage customers
    - 'manage' permission grants full access
    - 'create', 'read', 'update', 'delete' are granular permissions

    Endpoints:
    - GET    /api/v2/customers          - List customers (requires customers.read)
    - GET    /api/v2/customers/:id      - Get customer details (requires customers.read)
    - POST   /api/v2/customers          - Create customer (requires customers.create)
    - PUT    /api/v2/customers/:id      - Update customer (requires customers.update)
    - DELETE /api/v2/customers/:id      - Delete customer (requires customers.delete)
]]

local respond_to = require("lapis.application").respond_to
local CustomerQueries = require "queries.CustomerQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require "helper.request_parser"

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Customers API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    -- Helper to get customer permissions for response
    local function get_customer_permissions(self)
        local is_owner = self.is_namespace_owner
        local perms = self.namespace_permissions or {}
        local customer_perms = perms.customers or {}

        local function has_perm(action)
            if is_owner then return true end
            for _, p in ipairs(customer_perms) do
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

    -- LIST customers
    -- Requires: customers.read permission
    app:get("/api/v2/customers", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("customers", "read", function(self)
            local params = self.params or {}
            params.namespace_id = self.namespace.id

            local ok, result = pcall(CustomerQueries.all, params)

            if not ok then
                return error_response(500, "Failed to list customers", tostring(result))
            end

            return {
                status = 200,
                json = {
                    data = result.data or result or {},
                    total = result.total or 0,
                    permissions = get_customer_permissions(self)
                }
            }
        end)
    ))

    -- CREATE customer
    -- Requires: customers.create permission
    app:post("/api/v2/customers", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("customers", "create", function(self)
            local params = RequestParser.parse_request(self)
            params.namespace_id = self.namespace.id
            params.created_by = self.current_user.uuid

            ngx.log(ngx.NOTICE, "Creating customer in namespace: ", self.namespace.slug)

            local ok, customer = pcall(CustomerQueries.create, params)

            if not ok then
                return error_response(500, "Failed to create customer", tostring(customer))
            end

            return {
                status = 201,
                json = {
                    data = customer,
                    message = "Customer created successfully",
                    permissions = get_customer_permissions(self)
                }
            }
        end)
    ))

    -- GET single customer
    -- Requires: customers.read permission
    app:get("/api/v2/customers/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("customers", "read", function(self)
            local customer_id = self.params.id

            local ok, customer = pcall(CustomerQueries.show, tostring(customer_id))

            if not ok then
                return error_response(500, "Failed to fetch customer", tostring(customer))
            end

            if not customer then
                return error_response(404, "Customer not found")
            end

            -- Verify customer belongs to current namespace (if namespace-scoped)
            if customer.namespace_id and customer.namespace_id ~= self.namespace.id then
                return error_response(403, "Customer not found in this namespace")
            end

            return {
                status = 200,
                json = {
                    data = customer,
                    permissions = get_customer_permissions(self)
                }
            }
        end)
    ))

    -- UPDATE customer
    -- Requires: customers.update permission
    app:put("/api/v2/customers/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("customers", "update", function(self)
            local customer_id = self.params.id

            -- First verify customer exists and belongs to namespace
            local ok, customer = pcall(CustomerQueries.show, tostring(customer_id))

            if not ok then
                return error_response(500, "Failed to fetch customer", tostring(customer))
            end

            if not customer then
                return error_response(404, "Customer not found")
            end

            -- Verify customer belongs to current namespace (if namespace-scoped)
            if customer.namespace_id and customer.namespace_id ~= self.namespace.id then
                return error_response(403, "Customer not found in this namespace")
            end

            local params = RequestParser.parse_request(self)
            params.updated_by = self.current_user.uuid

            local ok2, result = pcall(CustomerQueries.update, customer_id, params)

            if not ok2 then
                return error_response(500, "Failed to update customer", tostring(result))
            end

            return {
                status = 200,
                json = {
                    data = result,
                    message = "Customer updated successfully",
                    permissions = get_customer_permissions(self)
                }
            }
        end)
    ))

    -- DELETE customer
    -- Requires: customers.delete permission
    app:delete("/api/v2/customers/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("customers", "delete", function(self)
            local customer_id = self.params.id

            -- First verify customer exists and belongs to namespace
            local ok, customer = pcall(CustomerQueries.show, tostring(customer_id))

            if not ok then
                return error_response(500, "Failed to fetch customer", tostring(customer))
            end

            if not customer then
                return error_response(404, "Customer not found")
            end

            -- Verify customer belongs to current namespace (if namespace-scoped)
            if customer.namespace_id and customer.namespace_id ~= self.namespace.id then
                return error_response(403, "Customer not found in this namespace")
            end

            local ok2, result = pcall(CustomerQueries.destroy, customer_id)

            if not ok2 then
                return error_response(500, "Failed to delete customer", tostring(result))
            end

            return {
                status = 200,
                json = {
                    message = "Customer deleted successfully",
                    id = customer_id
                }
            }
        end)
    ))

    ngx.log(ngx.NOTICE, "Customers routes initialized successfully")
end
