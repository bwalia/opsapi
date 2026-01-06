--[[
    Menu Routes (Multi-Tenant)

    API endpoints for retrieving user's accessible menu items.
    The menu is filtered based on:
    - Current namespace context (different namespaces can have different menus)
    - Namespace permissions (from user's roles in current namespace)
    - Platform admin status (for admin-only items)
    - Namespace ownership (owners have access to all within namespace)

    This is the SINGLE SOURCE OF TRUTH for menu items.
    All clients (web, mobile, etc.) should use this endpoint.

    Multi-Tenant Architecture:
    - Users can have different roles in different namespaces
    - Each namespace can customize which menus are visible
    - Menu filtering happens at API level, not frontend
]]

local respond_to = require("lapis.application").respond_to
local MenuQueries = require("queries.MenuQueries")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require("helper.request_parser")
local db = require("lapis.db")
local cjson = require("cjson")

-- Configure cjson
cjson.encode_empty_table_as_object(false)

return function(app)

    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Menu API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    local function success_response(data, status)
        return {
            status = status or 200,
            json = data
        }
    end

    -- Helper function to check platform admin access
    local function is_platform_admin(current_user)
        if not current_user then
            return false
        end

        local admin_check = db.query([[
            SELECT ur.id FROM user__roles ur
            JOIN roles r ON ur.role_id = r.id
            JOIN users u ON ur.user_id = u.id
            WHERE u.uuid = ? AND LOWER(r.role_name) = 'administrative'
        ]], current_user.uuid)

        return admin_check and #admin_check > 0
    end

    -- ============================================================
    -- GET /api/v2/user/menu
    -- Returns menu items filtered by user's permissions in current namespace
    -- This is the main endpoint for frontend navigation
    -- ============================================================
    app:get("/api/v2/user/menu", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            -- Parse namespace permissions if they're in string format
            local namespace_permissions = self.namespace_permissions
            if type(namespace_permissions) == "string" then
                local ok, parsed = pcall(cjson.decode, namespace_permissions)
                if ok then
                    namespace_permissions = parsed
                else
                    namespace_permissions = {}
                end
            end

            -- Get filtered menu items for this namespace
            local menu_items = MenuQueries.getForNamespace(
                self.namespace.id,
                namespace_permissions,
                self.is_namespace_owner,
                is_platform_admin(self.current_user)
            )

            -- Separate main menu and secondary menu (settings)
            local main_menu = {}
            local secondary_menu = {}

            for _, item in ipairs(menu_items) do
                if item.key == "settings" then
                    table.insert(secondary_menu, item)
                else
                    table.insert(main_menu, item)
                end
            end

            return success_response({
                menu = menu_items,
                main_menu = main_menu,
                secondary_menu = secondary_menu,
                namespace = {
                    id = self.namespace.id,
                    uuid = self.namespace.uuid,
                    name = self.namespace.name,
                    slug = self.namespace.slug,
                    is_owner = self.is_namespace_owner
                },
                permissions = namespace_permissions,
                is_admin = is_platform_admin(self.current_user)
            })
        end)
    ))

    -- ============================================================
    -- GET /api/v2/namespace/menu-config
    -- Returns the menu configuration for the current namespace (admin only)
    -- ============================================================
    app:get("/api/v2/namespace/menu-config", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            -- Check if user has namespace management permission
            if not self.is_namespace_owner and not NamespaceMiddleware.hasPermission(self, "namespace", "manage") then
                return error_response(403, "Permission denied. Namespace owner or manage permission required.")
            end

            local config = MenuQueries.getNamespaceConfig(self.namespace.id)

            return success_response({
                namespace = {
                    id = self.namespace.id,
                    uuid = self.namespace.uuid,
                    name = self.namespace.name
                },
                menu_config = config
            })
        end)
    ))

    -- ============================================================
    -- PUT /api/v2/namespace/menu-config
    -- Update menu configuration for current namespace (admin only)
    -- Body: { menus: { "dashboard": { is_enabled: true }, "users": { is_enabled: false, custom_name: "Team" } } }
    -- ============================================================
    app:put("/api/v2/namespace/menu-config", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            -- Check if user has namespace management permission
            if not self.is_namespace_owner and not NamespaceMiddleware.hasPermission(self, "namespace", "manage") then
                return error_response(403, "Permission denied. Namespace owner or manage permission required.")
            end

            local params = RequestParser.parse_request(self)

            if not params.menus or type(params.menus) ~= "table" then
                return error_response(400, "menus object is required")
            end

            local results = MenuQueries.batchUpdateNamespaceConfig(self.namespace.id, params.menus)

            return success_response({
                message = "Menu configuration updated",
                results = results
            })
        end)
    ))

    -- ============================================================
    -- PUT /api/v2/namespace/menu-config/:key
    -- Update a specific menu item configuration for current namespace
    -- ============================================================
    app:put("/api/v2/namespace/menu-config/:key", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            if not self.is_namespace_owner and not NamespaceMiddleware.hasPermission(self, "namespace", "manage") then
                return error_response(403, "Permission denied. Namespace owner or manage permission required.")
            end

            local params = RequestParser.parse_request(self)
            local menu_key = self.params.key

            local result, err = MenuQueries.updateNamespaceMenuConfig(self.namespace.id, menu_key, params)

            if not result then
                return error_response(404, err or "Menu item not found")
            end

            return success_response({
                message = "Menu configuration updated",
                config = result
            })
        end)
    ))

    -- ============================================================
    -- POST /api/v2/namespace/menu-config/:key/enable
    -- Enable a menu item for current namespace
    -- ============================================================
    app:post("/api/v2/namespace/menu-config/:key/enable", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            if not self.is_namespace_owner and not NamespaceMiddleware.hasPermission(self, "namespace", "manage") then
                return error_response(403, "Permission denied")
            end

            local result, err = MenuQueries.enableMenuItem(self.namespace.id, self.params.key)

            if not result then
                return error_response(404, err or "Menu item not found")
            end

            return success_response({ message = "Menu item enabled", config = result })
        end)
    ))

    -- ============================================================
    -- POST /api/v2/namespace/menu-config/:key/disable
    -- Disable a menu item for current namespace
    -- ============================================================
    app:post("/api/v2/namespace/menu-config/:key/disable", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            if not self.is_namespace_owner and not NamespaceMiddleware.hasPermission(self, "namespace", "manage") then
                return error_response(403, "Permission denied")
            end

            local result, err = MenuQueries.disableMenuItem(self.namespace.id, self.params.key)

            if not result then
                return error_response(404, err or "Menu item not found")
            end

            return success_response({ message = "Menu item disabled", config = result })
        end)
    ))

    -- ============================================================
    -- PLATFORM ADMIN ROUTES (Global Menu Template Management)
    -- ============================================================

    -- ============================================================
    -- GET /api/v2/menu/all
    -- Returns all menu items (platform admin only, for menu management)
    -- ============================================================
    app:get("/api/v2/menu/all", AuthMiddleware.requireAuth(function(self)
        if not is_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local menu_items = MenuQueries.all()

        return success_response({
            data = menu_items,
            total = #menu_items
        })
    end))

    -- ============================================================
    -- POST /api/v2/menu
    -- Create a new menu item (platform admin only)
    -- ============================================================
    app:post("/api/v2/menu", AuthMiddleware.requireAuth(function(self)
        if not is_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local params = RequestParser.parse_request(self)

        if not params.key or params.key == "" then
            return error_response(400, "Menu key is required")
        end

        if not params.name or params.name == "" then
            return error_response(400, "Menu name is required")
        end

        if not params.path or params.path == "" then
            return error_response(400, "Menu path is required")
        end

        -- Check if key already exists
        local existing = MenuQueries.getByKey(params.key)
        if existing then
            return error_response(400, "Menu key already exists")
        end

        local ok, item = pcall(MenuQueries.create, params)

        if not ok then
            return error_response(500, "Failed to create menu item", item)
        end

        return success_response({
            message = "Menu item created successfully",
            item = item
        }, 201)
    end))

    -- ============================================================
    -- GET/PUT/DELETE /api/v2/menu/:id
    -- Manage individual menu items (platform admin only)
    -- ============================================================
    app:match("menu_item_detail", "/api/v2/menu/:id", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            if not is_platform_admin(self.current_user) then
                return error_response(403, "Platform admin access required")
            end

            local item = MenuQueries.show(self.params.id)
            if not item then
                return error_response(404, "Menu item not found")
            end

            return success_response({ item = item })
        end),

        PUT = AuthMiddleware.requireAuth(function(self)
            if not is_platform_admin(self.current_user) then
                return error_response(403, "Platform admin access required")
            end

            local params = RequestParser.parse_request(self)

            local ok, item = pcall(MenuQueries.update, self.params.id, params)

            if not ok then
                return error_response(500, "Failed to update menu item", item)
            end

            if not item then
                return error_response(404, "Menu item not found")
            end

            return success_response({
                message = "Menu item updated successfully",
                item = item
            })
        end),

        DELETE = AuthMiddleware.requireAuth(function(self)
            if not is_platform_admin(self.current_user) then
                return error_response(403, "Platform admin access required")
            end

            local ok, result = pcall(MenuQueries.destroy, self.params.id)

            if not ok then
                return error_response(500, "Failed to delete menu item", result)
            end

            if not result then
                return error_response(404, "Menu item not found")
            end

            return success_response({
                message = "Menu item deleted successfully"
            })
        end)
    }))

    ngx.log(ngx.NOTICE, "Menu routes initialized successfully")
end
