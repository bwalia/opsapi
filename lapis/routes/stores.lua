--[[
    Store Routes

    API endpoints for namespace-scoped store management.

    Security Architecture:
    ======================
    - All mutating endpoints require authentication
    - Store operations are namespace-scoped (X-Namespace-Id header required for most operations)
    - Only users with 'stores' permission can manage stores
    - 'manage' permission grants full access
    - 'create', 'read', 'update', 'delete' are granular permissions
    - Public store listing is available without authentication (for marketplace)

    Endpoints:
    - GET    /api/v2/stores              - List stores (public for marketplace, namespace-scoped when authenticated)
    - GET    /api/v2/stores/:id          - Get store details (public)
    - POST   /api/v2/stores              - Create store (requires stores.create)
    - PUT    /api/v2/stores/:id          - Update store (requires stores.update or ownership)
    - DELETE /api/v2/stores/:id          - Delete store (requires stores.delete or ownership)
    - GET    /api/v2/my/stores           - Get current user's stores (requires authentication)
    - GET    /api/v2/stores/:store_id/products - List store products (public)
    - POST   /api/v2/stores/:store_id/products - Add product to store (requires stores.update or ownership)
]]

local StoreQueries = require "queries.StoreQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require "helper.request_parser"

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Stores API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    -- Helper to get store permissions for response
    local function get_store_permissions(self)
        local is_owner = self.is_namespace_owner
        local perms = self.namespace_permissions or {}
        local store_perms = perms.stores or {}

        local function has_perm(action)
            if is_owner then return true end
            for _, p in ipairs(store_perms) do
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

    -- Helper to check if user owns the store
    local function user_owns_store(self, store)
        if not self.current_user then return false end
        local UserQueries = require("queries.UserQueries")
        local user_data = UserQueries.show(self.current_user.sub or self.current_user.uuid)
        return user_data and store.user_id == user_data.internal_id
    end

    -- LIST stores
    -- Public for marketplace browsing, namespace-scoped when authenticated with namespace header
    app:get("/api/v2/stores", NamespaceMiddleware.optionalNamespace(function(self)
        local params = self.params or {}

        -- If namespace context is present, scope to namespace
        if self.namespace then
            params.namespace_id = self.namespace.id
        end

        local ok, result = pcall(StoreQueries.all, params)

        if not ok then
            return error_response(500, "Failed to list stores", tostring(result))
        end

        local response = {
            status = 200,
            json = {
                data = result.data or result or {},
                total = result.total or 0
            }
        }

        -- Add permissions if authenticated with namespace
        if self.namespace and self.current_user then
            response.json.permissions = get_store_permissions(self)
        end

        return response
    end))

    -- CREATE store
    -- Requires: stores.create permission
    app:post("/api/v2/stores", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("stores", "create", function(self)
            local params = RequestParser.parse_request(self)

            -- Get current user's internal ID
            local UserQueries = require("queries.UserQueries")
            local user_data = UserQueries.show(self.current_user.sub or self.current_user.uuid)
            if not user_data then
                return error_response(404, "User not found")
            end

            params.user_id = user_data.internal_id
            params.namespace_id = self.namespace.id
            params.created_by = self.current_user.uuid

            ngx.log(ngx.NOTICE, "Creating store in namespace: ", self.namespace.slug)

            local ok, store = pcall(StoreQueries.create, params)

            if not ok then
                return error_response(500, "Failed to create store", tostring(store))
            end

            return {
                status = 201,
                json = {
                    data = store,
                    message = "Store created successfully",
                    permissions = get_store_permissions(self)
                }
            }
        end)
    ))

    -- User's own stores (authenticated)
    app:get("/api/v2/my/stores", AuthMiddleware.requireAuth(function(self)
        -- Get user data to get internal ID
        local UserQueries = require("queries.UserQueries")
        local user_data = UserQueries.show(self.current_user.sub or self.current_user.uuid)
        if not user_data then
            return error_response(404, "User not found")
        end

        local ok, result = pcall(StoreQueries.getByUser, user_data.internal_id, self.params)

        if not ok then
            return error_response(500, "Failed to list stores", tostring(result))
        end

        return {
            status = 200,
            json = {
                data = result.data or result or {},
                total = result.total or 0
            }
        }
    end))

    -- GET single store (public)
    app:get("/api/v2/stores/:id", NamespaceMiddleware.optionalNamespace(function(self)
        local store_id = self.params.id

        local ok, store = pcall(StoreQueries.show, tostring(store_id))

        if not ok then
            return error_response(500, "Failed to fetch store", tostring(store))
        end

        if not store then
            return error_response(404, "Store not found")
        end

        local response = {
            status = 200,
            json = {
                data = store
            }
        }

        -- Add permissions if authenticated with namespace
        if self.namespace and self.current_user then
            response.json.permissions = get_store_permissions(self)
        end

        return response
    end))

    -- UPDATE store
    -- Requires: stores.update permission OR ownership
    app:put("/api/v2/stores/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local store_id = self.params.id

            local ok, store = pcall(StoreQueries.show, tostring(store_id))

            if not ok then
                return error_response(500, "Failed to fetch store", tostring(store))
            end

            if not store then
                return error_response(404, "Store not found")
            end

            -- Check permission: namespace stores.update OR ownership
            local perms = get_store_permissions(self)
            local is_owner = user_owns_store(self, store)

            if not perms.can_update and not is_owner then
                return error_response(403, "Access denied - you don't have permission to update this store")
            end

            local params = RequestParser.parse_request(self)
            params.updated_by = self.current_user.uuid

            local ok2, result = pcall(StoreQueries.update, store_id, params)

            if not ok2 then
                return error_response(500, "Failed to update store", tostring(result))
            end

            return {
                status = 200,
                json = {
                    data = result,
                    message = "Store updated successfully",
                    permissions = get_store_permissions(self)
                }
            }
        end)
    ))

    -- DELETE store
    -- Requires: stores.delete permission OR ownership
    app:delete("/api/v2/stores/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local store_id = self.params.id

            local ok, store = pcall(StoreQueries.show, tostring(store_id))

            if not ok then
                return error_response(500, "Failed to fetch store", tostring(store))
            end

            if not store then
                return error_response(404, "Store not found")
            end

            -- Check permission: namespace stores.delete OR ownership
            local perms = get_store_permissions(self)
            local is_owner = user_owns_store(self, store)

            if not perms.can_delete and not is_owner then
                return error_response(403, "Access denied - you don't have permission to delete this store")
            end

            local ok2, result = pcall(StoreQueries.destroy, store_id)

            if not ok2 then
                return error_response(500, "Failed to delete store", tostring(result))
            end

            return {
                status = 200,
                json = {
                    message = "Store deleted successfully",
                    id = store_id
                }
            }
        end)
    ))

    -- LIST store products (public)
    app:get("/api/v2/stores/:store_id/products", function(self)
        local StoreproductQueries = require "queries.StoreproductQueries"

        local ok, result = pcall(StoreproductQueries.getByStore, self.params.store_id, self.params)

        if not ok then
            return error_response(500, "Failed to list products", tostring(result))
        end

        return {
            status = 200,
            json = {
                data = result.data or result or {},
                total = result.total or 0
            }
        }
    end)

    -- ADD product to store
    -- Requires: stores.update permission OR ownership
    app:post("/api/v2/stores/:store_id/products", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local store_id = self.params.store_id

            local ok, store = pcall(StoreQueries.show, store_id)

            if not ok then
                return error_response(500, "Failed to fetch store", tostring(store))
            end

            if not store then
                return error_response(404, "Store not found")
            end

            -- Check permission: namespace stores.update OR ownership
            local perms = get_store_permissions(self)
            local is_owner = user_owns_store(self, store)

            if not perms.can_update and not is_owner then
                return error_response(403, "Access denied - you don't have permission to add products to this store")
            end

            local StoreproductQueries = require "queries.StoreproductQueries"
            local params = RequestParser.parse_request(self)
            params.store_id = store_id
            params.created_by = self.current_user.uuid

            local ok2, product = pcall(StoreproductQueries.create, params)

            if not ok2 then
                return error_response(500, "Failed to create product", tostring(product))
            end

            return {
                status = 201,
                json = {
                    data = product,
                    message = "Product added successfully"
                }
            }
        end)
    ))

    ngx.log(ngx.NOTICE, "Stores routes initialized successfully")
end
