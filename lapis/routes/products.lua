--[[
    Product Routes

    API endpoints for namespace-scoped product management.

    Security Architecture:
    ======================
    - All mutating endpoints require authentication
    - Product operations are namespace-scoped (X-Namespace-Id header required for most operations)
    - Only users with 'products' permission can manage products
    - 'manage' permission grants full access
    - 'create', 'read', 'update', 'delete' are granular permissions
    - Public product listing is available without authentication (for marketplace)

    Endpoints:
    - GET    /api/v2/products          - List/search products (public for marketplace)
    - GET    /api/v2/products/:id      - Get product details (public)
    - POST   /api/v2/products          - Create product (requires products.create)
    - PUT    /api/v2/products/:id      - Update product (requires products.update or store ownership)
    - DELETE /api/v2/products/:id      - Delete product (requires products.delete or store ownership)
]]

local StoreproductQueries = require "queries.StoreproductQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local StoreQueries = require "queries.StoreQueries"
local RequestParser = require "helper.request_parser"

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Products API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    -- Helper to get product permissions for response
    local function get_product_permissions(self)
        local is_owner = self.is_namespace_owner
        local perms = self.namespace_permissions or {}
        local product_perms = perms.products or {}

        local function has_perm(action)
            if is_owner then return true end
            for _, p in ipairs(product_perms) do
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

    -- Helper to check if user owns the store for this product
    local function user_owns_product_store(self, product)
        if not self.current_user then return false end
        if not product.store_id then return false end

        local store = StoreQueries.show(product.store_id)
        if not store then return false end

        local UserQueries = require("queries.UserQueries")
        local user_data = UserQueries.show(self.current_user.sub or self.current_user.uuid)
        return user_data and store.user_id == user_data.internal_id
    end

    -- LIST/SEARCH products (public)
    -- Public for marketplace browsing, namespace-scoped when authenticated with namespace header
    app:get("/api/v2/products", NamespaceMiddleware.optionalNamespace(function(self)
        local params = self.params or {}

        -- If namespace context is present, scope to namespace
        if self.namespace then
            params.namespace_id = self.namespace.id
        end

        local ok, result = pcall(StoreproductQueries.searchProducts, params)

        if not ok then
            return error_response(500, "Failed to list products", tostring(result))
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
            response.json.permissions = get_product_permissions(self)
        end

        return response
    end))

    -- GET single product (public)
    app:get("/api/v2/products/:id", NamespaceMiddleware.optionalNamespace(function(self)
        local product_id = self.params.id

        local ok, product = pcall(StoreproductQueries.show, product_id)

        if not ok then
            return error_response(500, "Failed to fetch product", tostring(product))
        end

        if not product then
            return error_response(404, "Product not found")
        end

        local response = {
            status = 200,
            json = {
                data = product
            }
        }

        -- Add permissions if authenticated with namespace
        if self.namespace and self.current_user then
            response.json.permissions = get_product_permissions(self)
        end

        return response
    end))

    -- CREATE product
    -- Requires: products.create permission
    app:post("/api/v2/products", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("products", "create", function(self)
            local params = RequestParser.parse_request(self)

            -- Verify store exists and belongs to namespace (if store_id provided)
            if params.store_id then
                local store = StoreQueries.showByUUID(params.store_id)
                if not store then
                    return error_response(404, "Store not found")
                end

                -- Verify store is in current namespace (if namespace-scoped)
                if store.namespace_id and store.namespace_id ~= self.namespace.id then
                    return error_response(403, "Store not found in this namespace")
                end
            end

            params.namespace_id = self.namespace.id
            params.created_by = self.current_user.uuid

            ngx.log(ngx.NOTICE, "Creating product in namespace: ", self.namespace.slug)

            local ok, product = pcall(StoreproductQueries.create, params)

            if not ok then
                return error_response(500, "Failed to create product", tostring(product))
            end

            return {
                status = 201,
                json = {
                    data = product,
                    message = "Product created successfully",
                    permissions = get_product_permissions(self)
                }
            }
        end)
    ))

    -- UPDATE product
    -- Requires: products.update permission OR store ownership
    app:put("/api/v2/products/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local product_id = self.params.id

            local ok, product = pcall(StoreproductQueries.show, product_id)

            if not ok then
                return error_response(500, "Failed to fetch product", tostring(product))
            end

            if not product then
                return error_response(404, "Product not found")
            end

            -- Check permission: namespace products.update OR store ownership
            local perms = get_product_permissions(self)
            local is_store_owner = user_owns_product_store(self, product)

            if not perms.can_update and not is_store_owner then
                return error_response(403, "Access denied - you don't have permission to update this product")
            end

            local params = RequestParser.parse_request(self)
            params.updated_by = self.current_user.uuid

            local ok2, updated = pcall(StoreproductQueries.update, product_id, params)

            if not ok2 then
                return error_response(500, "Failed to update product", tostring(updated))
            end

            return {
                status = 200,
                json = {
                    data = updated,
                    message = "Product updated successfully",
                    permissions = get_product_permissions(self)
                }
            }
        end)
    ))

    -- DELETE product
    -- Requires: products.delete permission OR store ownership
    app:delete("/api/v2/products/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local product_id = self.params.id

            local ok, product = pcall(StoreproductQueries.show, product_id)

            if not ok then
                return error_response(500, "Failed to fetch product", tostring(product))
            end

            if not product then
                return error_response(404, "Product not found")
            end

            -- Check permission: namespace products.delete OR store ownership
            local perms = get_product_permissions(self)
            local is_store_owner = user_owns_product_store(self, product)

            if not perms.can_delete and not is_store_owner then
                return error_response(403, "Access denied - you don't have permission to delete this product")
            end

            local ok2, result = pcall(StoreproductQueries.destroy, product_id)

            if not ok2 then
                return error_response(500, "Failed to delete product", tostring(result))
            end

            return {
                status = 200,
                json = {
                    message = "Product deleted successfully",
                    id = product_id
                }
            }
        end)
    ))

    ngx.log(ngx.NOTICE, "Products routes initialized successfully")
end
