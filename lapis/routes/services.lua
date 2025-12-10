--[[
    Service Routes

    API endpoints for namespace-scoped service management with GitHub workflow integration.

    Security Architecture:
    ======================
    - All services are namespace-scoped (X-Namespace-Id header required)
    - Secrets are encrypted at rest and NEVER exposed in API responses
    - Only users with 'services' permission can manage services
    - Only users with 'deploy' permission can trigger deployments

    Endpoints:
    - GET    /api/v2/namespace/services             - List services
    - POST   /api/v2/namespace/services             - Create service
    - GET    /api/v2/namespace/services/:id         - Get service details
    - PUT    /api/v2/namespace/services/:id         - Update service
    - DELETE /api/v2/namespace/services/:id         - Delete service

    - POST   /api/v2/namespace/services/:id/secrets     - Add secret
    - GET    /api/v2/namespace/services/:id/secrets     - List secrets (masked)
    - PUT    /api/v2/namespace/services/:id/secrets/:sid - Update secret
    - DELETE /api/v2/namespace/services/:id/secrets/:sid - Delete secret

    - POST   /api/v2/namespace/services/:id/variables     - Add variable
    - GET    /api/v2/namespace/services/:id/variables     - List variables
    - PUT    /api/v2/namespace/services/:id/variables/:vid - Update variable
    - DELETE /api/v2/namespace/services/:id/variables/:vid - Delete variable

    - POST   /api/v2/namespace/services/:id/deploy  - Trigger deployment
    - GET    /api/v2/namespace/services/:id/deployments - List deployments
    - GET    /api/v2/namespace/services/:id/deployments/:did - Get deployment

    - GET    /api/v2/namespace/github-integrations  - List GitHub integrations
    - POST   /api/v2/namespace/github-integrations  - Create GitHub integration
    - PUT    /api/v2/namespace/github-integrations/:id - Update GitHub integration
    - DELETE /api/v2/namespace/github-integrations/:id - Delete GitHub integration

    - GET    /api/v2/namespace/services/stats       - Get service statistics
]]

local ServiceQueries = require("queries.ServiceQueries")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require("helper.request_parser")
local cjson = require("cjson.safe")

-- Configure cjson
cjson.encode_empty_table_as_object(false)

return function(app)

    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Services API error: ", message, " | Details: ", tostring(details))
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

    -- Helper to check namespace permission
    local function check_permission(permissions, module_name, action)
        if not permissions then return false end
        local module_perms = permissions[module_name]
        if not module_perms then return false end
        for _, perm in ipairs(module_perms) do
            if perm == action or perm == "manage" then
                return true
            end
        end
        return false
    end

    -- ============================================================
    -- SERVICE STATISTICS
    -- ============================================================

    app:get("/api/v2/namespace/services/stats", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view services")
            end

            local stats = ServiceQueries.getStats(self.namespace.id)
            return success_response({ data = stats })
        end)
    ))

    -- ============================================================
    -- GITHUB INTEGRATIONS
    -- ============================================================

    -- List GitHub integrations
    app:get("/api/v2/namespace/github-integrations", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view GitHub integrations")
            end

            local integrations = ServiceQueries.getGithubIntegrations(self.namespace.id)
            return success_response({
                data = integrations,
                total = #integrations
            })
        end)
    ))

    -- Create GitHub integration
    app:post("/api/v2/namespace/github-integrations", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "create") then
                return error_response(403, "You don't have permission to create GitHub integrations")
            end

            local params = RequestParser.parse_request(self)

            if not params.github_token or params.github_token == "" then
                return error_response(400, "GitHub Personal Access Token is required")
            end

            local ok, integration = pcall(ServiceQueries.createGithubIntegration, self.namespace.id, {
                name = params.name,
                github_token = params.github_token,
                github_username = params.github_username,
                created_by = self.current_user.id
            })

            if not ok then
                return error_response(500, "Failed to create GitHub integration", tostring(integration))
            end

            return success_response({ data = integration, message = "GitHub integration created successfully" }, 201)
        end)
    ))

    -- Get single GitHub integration
    app:get("/api/v2/namespace/github-integrations/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view GitHub integrations")
            end

            local integration = ServiceQueries.getGithubIntegration(self.params.id)
            if not integration then
                return error_response(404, "GitHub integration not found")
            end

            -- Verify it belongs to current namespace
            if integration.namespace_id ~= self.namespace.id then
                return error_response(403, "GitHub integration not found in this namespace")
            end

            return success_response({ data = integration })
        end)
    ))

    -- Update GitHub integration
    app:put("/api/v2/namespace/github-integrations/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "update") then
                return error_response(403, "You don't have permission to update GitHub integrations")
            end

            local integration = ServiceQueries.getGithubIntegration(self.params.id)
            if not integration then
                return error_response(404, "GitHub integration not found")
            end

            if integration.namespace_id ~= self.namespace.id then
                return error_response(403, "GitHub integration not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            local ok, updated = pcall(ServiceQueries.updateGithubIntegration, self.params.id, {
                name = params.name,
                github_token = params.github_token,
                github_username = params.github_username,
                status = params.status
            })

            if not ok then
                return error_response(500, "Failed to update GitHub integration", tostring(updated))
            end

            return success_response({ data = updated, message = "GitHub integration updated successfully" })
        end)
    ))

    -- Delete GitHub integration
    app:delete("/api/v2/namespace/github-integrations/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "delete") then
                return error_response(403, "You don't have permission to delete GitHub integrations")
            end

            local integration = ServiceQueries.getGithubIntegration(self.params.id)
            if not integration then
                return error_response(404, "GitHub integration not found")
            end

            if integration.namespace_id ~= self.namespace.id then
                return error_response(403, "GitHub integration not found in this namespace")
            end

            local ok, result = pcall(ServiceQueries.deleteGithubIntegration, self.params.id)
            if not ok then
                return error_response(500, "Failed to delete GitHub integration", tostring(result))
            end

            return success_response({ message = "GitHub integration deleted successfully" })
        end)
    ))

    -- ============================================================
    -- SERVICES CRUD
    -- ============================================================

    -- List services
    app:get("/api/v2/namespace/services", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view services")
            end

            local params = self.params or {}
            local ok, result = pcall(ServiceQueries.all, self.namespace.id, {
                page = params.page,
                perPage = params.per_page or params.limit,
                status = params.status,
                search = params.search or params.q,
                orderBy = params.order_by,
                orderDir = params.order_dir
            })

            if not ok then
                return error_response(500, "Failed to list services", tostring(result))
            end

            return success_response(result)
        end)
    ))

    -- Create service
    app:post("/api/v2/namespace/services", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "create") then
                return error_response(403, "You don't have permission to create services")
            end

            local params = RequestParser.parse_request(self)

            -- Validate required fields
            local required = { "name", "github_owner", "github_repo", "github_workflow_file" }
            for _, field in ipairs(required) do
                if not params[field] or params[field] == "" then
                    return error_response(400, "Missing required field: " .. field)
                end
            end

            local ok, service = pcall(ServiceQueries.create, self.namespace.id, {
                name = params.name,
                description = params.description,
                icon = params.icon,
                color = params.color,
                github_owner = params.github_owner,
                github_repo = params.github_repo,
                github_workflow_file = params.github_workflow_file,
                github_branch = params.github_branch,
                github_integration_id = params.github_integration_id and tonumber(params.github_integration_id),
                status = params.status,
                created_by = self.current_user.id
            })

            if not ok then
                return error_response(500, "Failed to create service", tostring(service))
            end

            return success_response({ data = service, message = "Service created successfully" }, 201)
        end)
    ))

    -- Get single service (detailed)
    app:get("/api/v2/namespace/services/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view services")
            end

            local ok, service = pcall(ServiceQueries.showDetailed, self.params.id)
            if not ok then
                return error_response(500, "Failed to get service", tostring(service))
            end

            if not service then
                return error_response(404, "Service not found")
            end

            -- Verify it belongs to current namespace
            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            return success_response({ data = service })
        end)
    ))

    -- Update service
    app:put("/api/v2/namespace/services/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "update") then
                return error_response(403, "You don't have permission to update services")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            local ok, updated = pcall(ServiceQueries.update, self.params.id, {
                name = params.name,
                description = params.description,
                icon = params.icon,
                color = params.color,
                github_owner = params.github_owner,
                github_repo = params.github_repo,
                github_workflow_file = params.github_workflow_file,
                github_branch = params.github_branch,
                github_integration_id = params.github_integration_id and tonumber(params.github_integration_id),
                status = params.status,
                updated_by = self.current_user.id
            })

            if not ok then
                return error_response(500, "Failed to update service", tostring(updated))
            end

            return success_response({ data = updated, message = "Service updated successfully" })
        end)
    ))

    -- Delete service
    app:delete("/api/v2/namespace/services/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "delete") then
                return error_response(403, "You don't have permission to delete services")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local ok, result = pcall(ServiceQueries.destroy, self.params.id)
            if not ok then
                return error_response(500, "Failed to delete service", tostring(result))
            end

            return success_response({ message = "Service deleted successfully" })
        end)
    ))

    -- ============================================================
    -- SECRETS MANAGEMENT (Encrypted)
    -- ============================================================

    -- List secrets (masked values)
    app:get("/api/v2/namespace/services/:id/secrets", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view service secrets")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local secrets = ServiceQueries.getSecrets(service.id)
            return success_response({
                data = secrets,
                total = #secrets
            })
        end)
    ))

    -- Add secret
    app:post("/api/v2/namespace/services/:id/secrets", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "create") then
                return error_response(403, "You don't have permission to add secrets")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            if not params.key or params.key == "" then
                return error_response(400, "Secret key is required")
            end
            if not params.value or params.value == "" then
                return error_response(400, "Secret value is required")
            end

            local ok, secret = pcall(ServiceQueries.addSecret, service.id, {
                key = params.key,
                value = params.value,
                description = params.description,
                is_required = params.is_required == "true" or params.is_required == true,
                created_by = self.current_user.id
            })

            if not ok then
                -- Check for duplicate key error
                if tostring(secret):find("unique") then
                    return error_response(400, "Secret with this key already exists")
                end
                return error_response(500, "Failed to add secret", tostring(secret))
            end

            return success_response({ data = secret, message = "Secret added successfully" }, 201)
        end)
    ))

    -- Update secret
    app:put("/api/v2/namespace/services/:id/secrets/:sid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "update") then
                return error_response(403, "You don't have permission to update secrets")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            local ok, updated = pcall(ServiceQueries.updateSecret, self.params.sid, {
                key = params.key,
                value = params.value,
                description = params.description,
                is_required = params.is_required == "true" or params.is_required == true,
                updated_by = self.current_user.id
            })

            if not ok then
                return error_response(500, "Failed to update secret", tostring(updated))
            end

            if not updated then
                return error_response(404, "Secret not found")
            end

            return success_response({ data = updated, message = "Secret updated successfully" })
        end)
    ))

    -- Delete secret
    app:delete("/api/v2/namespace/services/:id/secrets/:sid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "delete") then
                return error_response(403, "You don't have permission to delete secrets")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local ok, result = pcall(ServiceQueries.deleteSecret, self.params.sid)
            if not ok then
                return error_response(500, "Failed to delete secret", tostring(result))
            end

            return success_response({ message = "Secret deleted successfully" })
        end)
    ))

    -- ============================================================
    -- VARIABLES MANAGEMENT (Plain text)
    -- ============================================================

    -- List variables
    app:get("/api/v2/namespace/services/:id/variables", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view service variables")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local variables = ServiceQueries.getVariables(service.id)
            return success_response({
                data = variables,
                total = #variables
            })
        end)
    ))

    -- Add variable
    app:post("/api/v2/namespace/services/:id/variables", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "create") then
                return error_response(403, "You don't have permission to add variables")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            if not params.key or params.key == "" then
                return error_response(400, "Variable key is required")
            end

            local ok, variable = pcall(ServiceQueries.addVariable, service.id, {
                key = params.key,
                value = params.value or "",
                description = params.description,
                is_required = params.is_required == "true" or params.is_required == true,
                default_value = params.default_value
            })

            if not ok then
                if tostring(variable):find("unique") then
                    return error_response(400, "Variable with this key already exists")
                end
                return error_response(500, "Failed to add variable", tostring(variable))
            end

            return success_response({ data = variable, message = "Variable added successfully" }, 201)
        end)
    ))

    -- Update variable
    app:put("/api/v2/namespace/services/:id/variables/:vid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "update") then
                return error_response(403, "You don't have permission to update variables")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            local ok, updated = pcall(ServiceQueries.updateVariable, self.params.vid, {
                key = params.key,
                value = params.value,
                description = params.description,
                is_required = params.is_required == "true" or params.is_required == true,
                default_value = params.default_value
            })

            if not ok then
                return error_response(500, "Failed to update variable", tostring(updated))
            end

            if not updated then
                return error_response(404, "Variable not found")
            end

            return success_response({ data = updated, message = "Variable updated successfully" })
        end)
    ))

    -- Delete variable
    app:delete("/api/v2/namespace/services/:id/variables/:vid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "delete") then
                return error_response(403, "You don't have permission to delete variables")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local ok, result = pcall(ServiceQueries.deleteVariable, self.params.vid)
            if not ok then
                return error_response(500, "Failed to delete variable", tostring(result))
            end

            return success_response({ message = "Variable deleted successfully" })
        end)
    ))

    -- ============================================================
    -- DEPLOYMENT MANAGEMENT
    -- ============================================================

    -- Trigger deployment
    app:post("/api/v2/namespace/services/:id/deploy", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            -- Check for deploy permission specifically
            if not check_permission(permissions, "services", "deploy") then
                return error_response(403, "You don't have permission to trigger deployments")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local params = RequestParser.parse_request(self)

            -- Parse custom inputs if provided
            local custom_inputs = nil
            if params.inputs then
                if type(params.inputs) == "string" then
                    local ok, parsed = pcall(cjson.decode, params.inputs)
                    if ok then
                        custom_inputs = parsed
                    end
                elseif type(params.inputs) == "table" then
                    custom_inputs = params.inputs
                end
            end

            local deployment, err = ServiceQueries.triggerWorkflow(
                service.id,
                self.current_user.id,
                custom_inputs
            )

            if err then
                return success_response({
                    data = deployment,
                    message = "Deployment triggered with error",
                    error = err
                }, deployment and deployment.status == "triggered" and 200 or 500)
            end

            return success_response({
                data = deployment,
                message = "Deployment triggered successfully"
            }, 201)
        end)
    ))

    -- List deployments
    app:get("/api/v2/namespace/services/:id/deployments", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view deployments")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local params = self.params or {}
            local ok, result = pcall(ServiceQueries.getDeployments, service.id, {
                page = params.page,
                perPage = params.per_page or params.limit,
                status = params.status
            })

            if not ok then
                return error_response(500, "Failed to list deployments", tostring(result))
            end

            return success_response(result)
        end)
    ))

    -- Get single deployment
    app:get("/api/v2/namespace/services/:id/deployments/:did", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view deployments")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local deployment = ServiceQueries.getDeployment(self.params.did)
            if not deployment then
                return error_response(404, "Deployment not found")
            end

            -- Verify deployment belongs to this service
            if deployment.service_id ~= service.id then
                return error_response(403, "Deployment not found for this service")
            end

            return success_response({ data = deployment })
        end)
    ))

    -- ============================================================
    -- DEPLOYMENT STATUS SYNC
    -- ============================================================

    -- Sync single deployment status from GitHub
    app:post("/api/v2/namespace/services/:id/deployments/:did/sync", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view deployments")
            end

            local service = ServiceQueries.show(self.params.id)
            if not service then
                return error_response(404, "Service not found")
            end

            if service.namespace_id ~= self.namespace.id then
                return error_response(403, "Service not found in this namespace")
            end

            local deployment = ServiceQueries.getDeployment(self.params.did)
            if not deployment then
                return error_response(404, "Deployment not found")
            end

            if deployment.service_id ~= service.id then
                return error_response(403, "Deployment not found for this service")
            end

            local updated, err = ServiceQueries.syncDeploymentStatus(self.params.did)
            if err then
                return error_response(500, "Failed to sync deployment status", err)
            end

            return success_response({
                data = updated,
                message = "Deployment status synced successfully"
            })
        end)
    ))

    -- Sync all pending deployments for the namespace
    app:post("/api/v2/namespace/services/sync-deployments", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to view deployments")
            end

            local results = ServiceQueries.syncAllPendingDeployments(self.namespace.id)

            return success_response({
                data = results,
                message = string.format(
                    "Synced %d of %d pending deployments (%d errors)",
                    results.updated, results.total, results.errors
                )
            })
        end)
    ))

    -- ============================================================
    -- GITHUB WEBHOOK
    -- ============================================================

    -- GitHub Webhook endpoint for workflow_run events
    -- This endpoint does NOT require authentication as it's called by GitHub
    -- Instead, it verifies the webhook signature using the secret
    app:post("/api/v2/webhooks/github", function(_)
        local payload_raw = ngx.req.get_body_data()
        if not payload_raw then
            ngx.req.read_body()
            payload_raw = ngx.req.get_body_data()
        end

        if not payload_raw then
            return error_response(400, "Empty request body")
        end

        -- Get the GitHub signature header
        local signature = ngx.req.get_headers()["X-Hub-Signature-256"]
        local event_type = ngx.req.get_headers()["X-GitHub-Event"]

        ngx.log(ngx.INFO, "Received GitHub webhook: event=", tostring(event_type))

        -- Verify webhook signature if secret is configured
        local webhook_secret = os.getenv("GITHUB_WEBHOOK_SECRET")
        if webhook_secret and webhook_secret ~= "" then
            if not signature then
                ngx.log(ngx.WARN, "GitHub webhook received without signature")
                return error_response(401, "Missing signature")
            end

            -- Compute expected signature
            local resty_string = require("resty.string")
            local hmac = require("resty.hmac")

            local hmac_sha256 = hmac:new(webhook_secret, hmac.ALGOS.SHA256)
            if not hmac_sha256 then
                ngx.log(ngx.ERR, "Failed to create HMAC instance")
                return error_response(500, "Internal error")
            end

            hmac_sha256:update(payload_raw)
            local computed_signature = "sha256=" .. resty_string.to_hex(hmac_sha256:final())

            if computed_signature ~= signature then
                ngx.log(ngx.WARN, "GitHub webhook signature mismatch")
                return error_response(401, "Invalid signature")
            end
        end

        -- Parse the payload
        local payload = cjson.decode(payload_raw)
        if not payload then
            return error_response(400, "Invalid JSON payload")
        end

        -- Only process workflow_run events
        if event_type ~= "workflow_run" then
            ngx.log(ngx.INFO, "Ignoring GitHub event: ", tostring(event_type))
            return success_response({ message = "Event ignored" })
        end

        -- Process the workflow run event
        local ok, err = ServiceQueries.handleWorkflowRunWebhook(payload)
        if not ok then
            ngx.log(ngx.WARN, "Failed to process webhook: ", tostring(err))
            -- Return 200 anyway to prevent GitHub from retrying
            return success_response({ message = "Webhook received", warning = err })
        end

        return success_response({ message = "Webhook processed successfully" })
    end)

    -- ============================================================
    -- DIAGNOSTICS
    -- ============================================================

    -- Test GitHub API connectivity (useful for debugging connection issues)
    app:get("/api/v2/namespace/services/test-github-connectivity", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local permissions = self.namespace_permissions or {}

            if not check_permission(permissions, "services", "read") then
                return error_response(403, "You don't have permission to run diagnostics")
            end

            ngx.log(ngx.NOTICE, "Running GitHub connectivity test for namespace: ", self.namespace.id)

            local ok, results = pcall(ServiceQueries.testGitHubConnectivity)
            if not ok then
                return error_response(500, "Failed to run connectivity test", tostring(results))
            end

            return success_response({
                data = results,
                message = results.message
            })
        end)
    ))

    ngx.log(ngx.NOTICE, "Services routes initialized successfully")
end
