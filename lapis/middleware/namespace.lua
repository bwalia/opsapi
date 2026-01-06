--[[
    Namespace Middleware

    Resolves the current namespace context from:
    1. X-Namespace-Id or X-Namespace-Slug header
    2. JWT token payload
    3. Subdomain (e.g., acme.example.com → "acme")

    Validates user has access to the namespace and sets:
    - self.namespace: The resolved namespace
    - self.namespace_membership: User's membership in the namespace
    - self.namespace_role: User's highest priority role in the namespace
    - self.namespace_permissions: User's combined permissions
]]

local NamespaceQueries = require("queries.NamespaceQueries")
local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
local cjson = require("cjson")

local NamespaceMiddleware = {}

--- Extract namespace identifier from request
-- @param self table Lapis request context
-- @return string|nil Namespace identifier (uuid, id, or slug)
local function extractNamespaceIdentifier(self)
    -- Priority 1: Header
    local header_id = self.req.headers["x-namespace-id"]
    if header_id and header_id ~= "" then
        return header_id
    end

    local header_slug = self.req.headers["x-namespace-slug"]
    if header_slug and header_slug ~= "" then
        return header_slug
    end

    -- Priority 2: JWT Token (if current_user has namespace info)
    if self.current_user and self.current_user.namespace then
        if self.current_user.namespace.uuid then
            return self.current_user.namespace.uuid
        elseif self.current_user.namespace.slug then
            return self.current_user.namespace.slug
        end
    end

    -- Priority 3: Subdomain
    local host = self.req.headers["host"]
    if host then
        -- Extract subdomain (e.g., "acme" from "acme.example.com")
        local subdomain = host:match("^([^.]+)%.")
        -- Skip common non-namespace subdomains
        if subdomain and subdomain ~= "www" and subdomain ~= "api" and
           subdomain ~= "localhost" and subdomain ~= "dashboard" then
            return subdomain
        end
    end

    return nil
end

--- Resolve namespace and validate access
-- Wrapper that requires a namespace context
-- @param handler function The route handler
-- @return function Wrapped handler
function NamespaceMiddleware.requireNamespace(handler)
    return function(self)
        -- Extract namespace identifier
        local namespace_identifier = extractNamespaceIdentifier(self)

        if not namespace_identifier then
            ngx.log(ngx.WARN, "Namespace context required but not provided")
            return {
                json = {
                    error = "Namespace context required",
                    message = "Please provide X-Namespace-Id or X-Namespace-Slug header"
                },
                status = 400
            }
        end

        -- Find namespace
        local namespace = NamespaceQueries.findByIdentifier(namespace_identifier)

        if not namespace then
            ngx.log(ngx.WARN, "Namespace not found: ", namespace_identifier)
            return {
                json = { error = "Namespace not found" },
                status = 404
            }
        end

        -- Check namespace is active
        if namespace.status ~= "active" then
            ngx.log(ngx.WARN, "Namespace is not active: ", namespace.slug, " status: ", namespace.status)
            return {
                json = {
                    error = "Namespace is not accessible",
                    status = namespace.status
                },
                status = 403
            }
        end

        -- Check user has access to this namespace (if authenticated)
        if self.current_user then
            local membership = NamespaceMemberQueries.findByUserAndNamespace(
                self.current_user.uuid,
                namespace.id
            )

            if not membership then
                ngx.log(ngx.WARN, "User ", self.current_user.uuid, " does not have access to namespace ", namespace.slug)
                return {
                    json = { error = "Access denied to this namespace" },
                    status = 403
                }
            end

            if membership.status ~= "active" then
                ngx.log(ngx.WARN, "User membership is not active in namespace: ", membership.status)
                return {
                    json = {
                        error = "Your access to this namespace is not active",
                        status = membership.status
                    },
                    status = 403
                }
            end

            -- Get member's roles and permissions
            local member_details = NamespaceMemberQueries.getWithDetails(membership.id)
            local permissions = NamespaceMemberQueries.getPermissions(membership.id)

            -- Ensure is_owner is a proper boolean (PostgreSQL might return 't'/'f' or other formats)
            local raw_is_owner = membership.is_owner
            local is_owner = raw_is_owner == true or raw_is_owner == 't' or raw_is_owner == 1

            -- Set namespace context
            self.namespace = namespace
            self.namespace_membership = membership
            self.namespace_member = member_details
            self.namespace_permissions = permissions
            self.is_namespace_owner = is_owner

            -- Parse roles if available
            if member_details and member_details.roles then
                if type(member_details.roles) == "string" then
                    local ok, parsed = pcall(cjson.decode, member_details.roles)
                    if ok then
                        self.namespace_roles = parsed
                    end
                else
                    self.namespace_roles = member_details.roles
                end
            end
        else
            -- No authenticated user - just set namespace
            self.namespace = namespace
            self.namespace_membership = nil
            self.namespace_permissions = {}
            self.is_namespace_owner = false
        end

        ngx.log(ngx.INFO, "Namespace context set: ", namespace.slug, " for user: ",
            (self.current_user and self.current_user.uuid or "anonymous"))

        return handler(self)
    end
end

--- Optional namespace resolution (doesn't fail if no namespace)
-- Useful for routes that work with or without namespace context
-- @param handler function The route handler
-- @return function Wrapped handler
function NamespaceMiddleware.optionalNamespace(handler)
    return function(self)
        local namespace_identifier = extractNamespaceIdentifier(self)

        if namespace_identifier then
            local namespace = NamespaceQueries.findByIdentifier(namespace_identifier)

            if namespace and namespace.status == "active" then
                self.namespace = namespace

                if self.current_user then
                    local membership = NamespaceMemberQueries.findByUserAndNamespace(
                        self.current_user.uuid,
                        namespace.id
                    )

                    if membership and membership.status == "active" then
                        self.namespace_membership = membership
                        self.namespace_permissions = NamespaceMemberQueries.getPermissions(membership.id)
                        -- Ensure is_owner is a proper boolean
                        local raw_is_owner = membership.is_owner
                        self.is_namespace_owner = raw_is_owner == true or raw_is_owner == 't' or raw_is_owner == 1
                    end
                end
            end
        end

        return handler(self)
    end
end

--- Check if user has a specific permission in the current namespace
-- @param module string Module name (e.g., "stores", "orders")
-- @param action string Action name (e.g., "create", "read", "update", "delete", "manage")
-- @param handler function The route handler
-- @return function Wrapped handler
function NamespaceMiddleware.requirePermission(module, action, handler)
    return NamespaceMiddleware.requireNamespace(function(self)
        -- Owners have all permissions
        if self.is_namespace_owner then
            return handler(self)
        end

        -- Check specific permission
        local permissions = self.namespace_permissions or {}
        local module_perms = permissions[module]

        if not module_perms then
            ngx.log(ngx.WARN, "Permission denied: no permissions for module ", module)
            return {
                json = {
                    error = "Permission denied",
                    required = { module = module, action = action }
                },
                status = 403
            }
        end

        -- Check for specific action or "manage" (full access)
        local has_permission = false
        for _, perm in ipairs(module_perms) do
            if perm == action or perm == "manage" then
                has_permission = true
                break
            end
        end

        if not has_permission then
            ngx.log(ngx.WARN, "Permission denied: ", module, ".", action, " for user ", self.current_user.uuid)
            return {
                json = {
                    error = "Permission denied",
                    required = { module = module, action = action }
                },
                status = 403
            }
        end

        return handler(self)
    end)
end

--- Require user to be namespace owner
-- @param handler function The route handler
-- @return function Wrapped handler
function NamespaceMiddleware.requireOwner(handler)
    return NamespaceMiddleware.requireNamespace(function(self)
        if not self.is_namespace_owner then
            ngx.log(ngx.WARN, "Owner access denied for user ", self.current_user.uuid)
            return {
                json = { error = "This action requires namespace owner privileges" },
                status = 403
            }
        end

        return handler(self)
    end)
end

--- Require user to be namespace admin (owner or has namespace.manage permission)
-- @param handler function The route handler
-- @return function Wrapped handler
function NamespaceMiddleware.requireAdmin(handler)
    return NamespaceMiddleware.requirePermission("namespace", "manage", handler)
end

--- Helper to check permission in handler (for conditional logic)
-- @param self table Lapis request context
-- @param module string Module name
-- @param action string Action name
-- @return boolean
function NamespaceMiddleware.hasPermission(self, module, action)
    if self.is_namespace_owner then
        return true
    end

    local permissions = self.namespace_permissions or {}
    local module_perms = permissions[module]

    if not module_perms then
        return false
    end

    for _, perm in ipairs(module_perms) do
        if perm == action or perm == "manage" then
            return true
        end
    end

    return false
end

--- Get the namespace ID for use in queries
-- Always returns the numeric ID for database queries
-- @param self table Lapis request context
-- @return number|nil Namespace ID
function NamespaceMiddleware.getNamespaceId(self)
    if self.namespace then
        return self.namespace.id
    end
    return nil
end

return NamespaceMiddleware
