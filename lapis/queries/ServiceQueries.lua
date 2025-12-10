--[[
    ServiceQueries.lua

    CRUD operations for namespace services with secure secrets management.

    Security Architecture:
    ======================
    - Secrets are encrypted at rest using AES-128-CBC (Global.encryptSecret)
    - Secrets are NEVER exposed in API responses (always masked as ********)
    - Secrets are only decrypted server-side when triggering GitHub workflows
    - All services are namespace-scoped for tenant isolation
]]

local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson.safe")
local Model = require("lapis.db.model").Model

-- Models
local Services = Model:extend("namespace_services")
local ServiceSecrets = Model:extend("namespace_service_secrets")
local ServiceVariables = Model:extend("namespace_service_variables")
local ServiceDeployments = Model:extend("namespace_service_deployments")
local GithubIntegrations = Model:extend("namespace_github_integrations")

local ServiceQueries = {}

-- ============================================
-- GitHub Integration Management
-- ============================================

--- Create a GitHub integration for a namespace
-- @param namespace_id number The namespace ID
-- @param data table { name?, github_token, github_username?, created_by? }
-- @return table The created integration (token masked)
function ServiceQueries.createGithubIntegration(namespace_id, data)
    local timestamp = Global.getCurrentTimestamp()

    -- Encrypt the GitHub token
    local encrypted_token = Global.encryptSecret(data.github_token)

    local integration_data = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = data.name or "default",
        github_token = encrypted_token,
        github_username = data.github_username,
        status = "active",
        created_by = data.created_by,
        created_at = timestamp,
        updated_at = timestamp
    }

    local integration = GithubIntegrations:create(integration_data, { returning = "*" })

    -- Never return the actual token
    integration.github_token = "********"
    return integration
end

--- Get GitHub integrations for a namespace
-- @param namespace_id number The namespace ID
-- @return table List of integrations (tokens masked)
function ServiceQueries.getGithubIntegrations(namespace_id)
    local integrations = db.query([[
        SELECT id, uuid, namespace_id, name, github_username, status,
               last_validated_at, created_by, created_at, updated_at,
               '********' as github_token
        FROM namespace_github_integrations
        WHERE namespace_id = ?
        ORDER BY created_at DESC
    ]], namespace_id)
    return integrations or {}
end

--- Get a single GitHub integration
-- @param id string|number Integration ID or UUID
-- @param include_token boolean Whether to include decrypted token (internal use only)
-- @return table|nil The integration
function ServiceQueries.getGithubIntegration(id, include_token)
    local integration = GithubIntegrations:find({ uuid = tostring(id) })
    if not integration and tonumber(id) then
        integration = GithubIntegrations:find({ id = tonumber(id) })
    end

    if integration then
        if include_token then
            -- Decrypt token for internal use (e.g., triggering workflows)
            local ok, decrypted = pcall(Global.decryptSecret, integration.github_token)
            if ok and decrypted then
                integration.github_token_decrypted = decrypted
                ngx.log(ngx.DEBUG, "Successfully decrypted GitHub token for integration: ", integration.id)
            else
                ngx.log(ngx.ERR, "Failed to decrypt GitHub token for integration: ", integration.id, " Error: ",
                    tostring(decrypted))
            end
        end
        integration.github_token = "********"
    end

    return integration
end

--- Update GitHub integration
-- @param id string|number Integration ID or UUID
-- @param data table Fields to update
-- @return table|nil The updated integration
function ServiceQueries.updateGithubIntegration(id, data)
    local integration = GithubIntegrations:find({ uuid = tostring(id) })
    if not integration and tonumber(id) then
        integration = GithubIntegrations:find({ id = tonumber(id) })
    end

    if not integration then return nil end

    local update_data = { updated_at = Global.getCurrentTimestamp() }

    if data.name then update_data.name = data.name end
    if data.github_username then update_data.github_username = data.github_username end
    if data.status then update_data.status = data.status end
    if data.last_validated_at then update_data.last_validated_at = data.last_validated_at end

    -- Encrypt new token if provided
    if data.github_token and data.github_token ~= "********" then
        update_data.github_token = Global.encryptSecret(data.github_token)
    end

    integration:update(update_data)
    integration.github_token = "********"
    return integration
end

--- Delete GitHub integration
-- @param id string|number Integration ID or UUID
-- @return boolean Success status
function ServiceQueries.deleteGithubIntegration(id)
    local integration = GithubIntegrations:find({ uuid = tostring(id) })
    if not integration and tonumber(id) then
        integration = GithubIntegrations:find({ id = tonumber(id) })
    end

    if not integration then return nil end
    return integration:delete()
end

-- ============================================
-- Service Management
-- ============================================

--- Create a new service
-- @param namespace_id number The namespace ID
-- @param data table Service data
-- @return table The created service
function ServiceQueries.create(namespace_id, data)
    local timestamp = Global.getCurrentTimestamp()

    local service_data = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = data.name,
        description = data.description,
        icon = data.icon or "server",
        color = data.color or "blue",
        github_owner = data.github_owner,
        github_repo = data.github_repo,
        github_workflow_file = data.github_workflow_file,
        github_branch = data.github_branch or "main",
        github_integration_id = data.github_integration_id,
        status = data.status or "active",
        created_by = data.created_by,
        created_at = timestamp,
        updated_at = timestamp
    }

    return Services:create(service_data, { returning = "*" })
end

--- Get all services for a namespace
-- @param namespace_id number The namespace ID
-- @param params table { page?, perPage?, status?, search? }
-- @return table { data, total }
function ServiceQueries.all(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.perPage) or tonumber(params.per_page) or 10
    local order_by = params.orderBy or params.order_by or "created_at"
    local order_dir = params.orderDir or params.order_dir or "desc"

    -- Validate order_by
    local valid_fields = {
        id = true,
        name = true,
        status = true,
        created_at = true,
        updated_at = true,
        last_deployment_at = true,
        deployment_count = true
    }
    if not valid_fields[order_by] then
        order_by = "created_at"
    end
    order_dir = order_dir:lower() == "asc" and "ASC" or "DESC"

    -- Build WHERE clause (use s. prefix for namespace_services table)
    local conditions = { "s.namespace_id = ?" }
    local values = { namespace_id }

    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "s.status = ?")
        table.insert(values, params.status)
    end

    if params.search and params.search ~= "" then
        table.insert(conditions, "(s.name ILIKE ? OR s.description ILIKE ? OR s.github_repo ILIKE ?)")
        local search_term = "%" .. params.search .. "%"
        table.insert(values, search_term)
        table.insert(values, search_term)
        table.insert(values, search_term)
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")

    -- Get total count (alias s for consistency with conditions)
    local count_result = db.query("SELECT COUNT(*) as total FROM namespace_services s " .. where_clause,
        table.unpack(values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data
    local offset = (page - 1) * per_page
    local data_query = string.format([[
        SELECT
            s.*,
            (SELECT COUNT(*) FROM namespace_service_secrets WHERE service_id = s.id) as secrets_count,
            (SELECT COUNT(*) FROM namespace_service_variables WHERE service_id = s.id) as variables_count,
            gi.name as github_integration_name
        FROM namespace_services s
        LEFT JOIN namespace_github_integrations gi ON s.github_integration_id = gi.id
        %s
        ORDER BY %s %s
        LIMIT %d OFFSET %d
    ]], where_clause, order_by, order_dir, per_page, offset)

    local data = db.query(data_query, table.unpack(values))

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Get a single service by ID or UUID
-- @param id string|number Service ID or UUID
-- @return table|nil The service
function ServiceQueries.show(id)
    local service = Services:find({ uuid = tostring(id) })
    if not service and tonumber(id) then
        service = Services:find({ id = tonumber(id) })
    end
    return service
end

--- Get detailed service with secrets (masked) and variables
-- @param id string|number Service ID or UUID
-- @return table|nil The service with details
function ServiceQueries.showDetailed(id)
    local service = ServiceQueries.show(id)
    if not service then return nil end

    -- Get secrets (masked)
    local secrets = db.query([[
        SELECT id, uuid, service_id, key, '********' as value, description, is_required, created_at, updated_at
        FROM namespace_service_secrets
        WHERE service_id = ?
        ORDER BY key ASC
    ]], service.id)

    -- Get variables (not masked)
    local variables = db.query([[
        SELECT * FROM namespace_service_variables
        WHERE service_id = ?
        ORDER BY key ASC
    ]], service.id)

    -- Get recent deployments
    local deployments = db.query([[
        SELECT d.*, u.first_name, u.last_name, u.email as triggered_by_email
        FROM namespace_service_deployments d
        LEFT JOIN users u ON d.triggered_by = u.id
        WHERE d.service_id = ?
        ORDER BY d.created_at DESC
        LIMIT 10
    ]], service.id)

    -- Get GitHub integration info
    local github_integration = nil
    if service.github_integration_id then
        github_integration = db.query([[
            SELECT id, uuid, name, github_username, status, last_validated_at
            FROM namespace_github_integrations
            WHERE id = ?
        ]], service.github_integration_id)
        github_integration = github_integration and github_integration[1]
    end

    service.secrets = secrets or {}
    service.variables = variables or {}
    service.deployments = deployments or {}
    service.github_integration = github_integration

    return service
end

--- Update a service
-- @param id string|number Service ID or UUID
-- @param data table Fields to update
-- @return table|nil The updated service
function ServiceQueries.update(id, data)
    local service = ServiceQueries.show(id)
    if not service then return nil end

    local update_data = { updated_at = Global.getCurrentTimestamp() }

    local allowed_fields = {
        "name", "description", "icon", "color",
        "github_owner", "github_repo", "github_workflow_file", "github_branch",
        "github_integration_id", "status", "updated_by"
    }

    for _, field in ipairs(allowed_fields) do
        if data[field] ~= nil then
            update_data[field] = data[field]
        end
    end

    service:update(update_data)
    return service
end

--- Delete a service
-- @param id string|number Service ID or UUID
-- @return boolean Success status
function ServiceQueries.destroy(id)
    local service = ServiceQueries.show(id)
    if not service then return nil end
    return service:delete()
end

-- ============================================
-- Secret Management (Encrypted)
-- ============================================

--- Add a secret to a service
-- @param service_id number The service ID
-- @param data table { key, value, description?, is_required?, created_by? }
-- @return table The created secret (value masked)
function ServiceQueries.addSecret(service_id, data)
    local timestamp = Global.getCurrentTimestamp()

    -- Encrypt the secret value
    local encrypted_value = Global.encryptSecret(data.value)

    local secret_data = {
        uuid = Global.generateUUID(),
        service_id = service_id,
        key = data.key,
        value = encrypted_value,
        description = data.description,
        is_required = data.is_required or false,
        created_by = data.created_by,
        created_at = timestamp,
        updated_at = timestamp
    }

    local secret = ServiceSecrets:create(secret_data, { returning = "*" })

    -- Never return the actual value
    secret.value = "********"
    return secret
end

--- Get all secrets for a service (values masked)
-- @param service_id number The service ID
-- @return table List of secrets
function ServiceQueries.getSecrets(service_id)
    return db.query([[
        SELECT id, uuid, service_id, key, '********' as value, description, is_required, created_at, updated_at
        FROM namespace_service_secrets
        WHERE service_id = ?
        ORDER BY key ASC
    ]], service_id) or {}
end

--- Update a secret
-- @param id string|number Secret ID or UUID
-- @param data table Fields to update
-- @return table|nil The updated secret (value masked)
function ServiceQueries.updateSecret(id, data)
    local secret = ServiceSecrets:find({ uuid = tostring(id) })
    if not secret and tonumber(id) then
        secret = ServiceSecrets:find({ id = tonumber(id) })
    end

    if not secret then return nil end

    local update_data = { updated_at = Global.getCurrentTimestamp() }

    if data.key then update_data.key = data.key end
    if data.description then update_data.description = data.description end
    if data.is_required ~= nil then update_data.is_required = data.is_required end
    if data.updated_by then update_data.updated_by = data.updated_by end

    -- Encrypt new value if provided and not masked
    if data.value and data.value ~= "********" then
        update_data.value = Global.encryptSecret(data.value)
    end

    secret:update(update_data)
    secret.value = "********"
    return secret
end

--- Delete a secret
-- @param id string|number Secret ID or UUID
-- @return boolean Success status
function ServiceQueries.deleteSecret(id)
    local secret = ServiceSecrets:find({ uuid = tostring(id) })
    if not secret and tonumber(id) then
        secret = ServiceSecrets:find({ id = tonumber(id) })
    end

    if not secret then return nil end
    return secret:delete()
end

--- Get decrypted secrets for a service (INTERNAL USE ONLY - for workflow triggering)
-- @param service_id number The service ID
-- @return table { key: value } map of decrypted secrets
function ServiceQueries.getDecryptedSecrets(service_id)
    local secrets = db.query([[
        SELECT key, value FROM namespace_service_secrets WHERE service_id = ?
    ]], service_id)

    local result = {}
    for _, secret in ipairs(secrets or {}) do
        local ok, decrypted = pcall(Global.decryptSecret, secret.value)
        if ok then
            result[secret.key] = decrypted
        end
    end

    return result
end

-- ============================================
-- Variable Management (Plain text)
-- ============================================

--- Add a variable to a service
-- @param service_id number The service ID
-- @param data table { key, value, description?, is_required?, default_value? }
-- @return table The created variable
function ServiceQueries.addVariable(service_id, data)
    local timestamp = Global.getCurrentTimestamp()

    local variable_data = {
        uuid = Global.generateUUID(),
        service_id = service_id,
        key = data.key,
        value = data.value,
        description = data.description,
        is_required = data.is_required or false,
        default_value = data.default_value,
        created_at = timestamp,
        updated_at = timestamp
    }

    return ServiceVariables:create(variable_data, { returning = "*" })
end

--- Get all variables for a service
-- @param service_id number The service ID
-- @return table List of variables
function ServiceQueries.getVariables(service_id)
    return db.query([[
        SELECT * FROM namespace_service_variables
        WHERE service_id = ?
        ORDER BY key ASC
    ]], service_id) or {}
end

--- Update a variable
-- @param id string|number Variable ID or UUID
-- @param data table Fields to update
-- @return table|nil The updated variable
function ServiceQueries.updateVariable(id, data)
    local variable = ServiceVariables:find({ uuid = tostring(id) })
    if not variable and tonumber(id) then
        variable = ServiceVariables:find({ id = tonumber(id) })
    end

    if not variable then return nil end

    local update_data = { updated_at = Global.getCurrentTimestamp() }

    if data.key then update_data.key = data.key end
    if data.value then update_data.value = data.value end
    if data.description then update_data.description = data.description end
    if data.is_required ~= nil then update_data.is_required = data.is_required end
    if data.default_value then update_data.default_value = data.default_value end

    variable:update(update_data)
    return variable
end

--- Delete a variable
-- @param id string|number Variable ID or UUID
-- @return boolean Success status
function ServiceQueries.deleteVariable(id)
    local variable = ServiceVariables:find({ uuid = tostring(id) })
    if not variable and tonumber(id) then
        variable = ServiceVariables:find({ id = tonumber(id) })
    end

    if not variable then return nil end
    return variable:delete()
end

-- ============================================
-- Deployment Management
-- ============================================

--- Create a deployment record
-- @param service_id number The service ID
-- @param data table { triggered_by?, inputs?, status? }
-- @return table The created deployment
function ServiceQueries.createDeployment(service_id, data)
    local timestamp = Global.getCurrentTimestamp()

    local deployment_data = {
        uuid = Global.generateUUID(),
        service_id = service_id,
        triggered_by = data.triggered_by,
        status = data.status or "pending",
        inputs = data.inputs and cjson.encode(data.inputs) or "{}",
        started_at = timestamp,
        created_at = timestamp,
        updated_at = timestamp
    }

    return ServiceDeployments:create(deployment_data, { returning = "*" })
end

--- Update deployment status
-- @param id string|number Deployment ID or UUID
-- @param data table { status, github_run_id?, github_run_url?, github_run_number?, error_message?, error_details?, completed_at? }
-- @return table|nil The updated deployment
function ServiceQueries.updateDeployment(id, data)
    local deployment = ServiceDeployments:find({ uuid = tostring(id) })
    if not deployment and tonumber(id) then
        deployment = ServiceDeployments:find({ id = tonumber(id) })
    end

    if not deployment then return nil end

    local update_data = { updated_at = Global.getCurrentTimestamp() }

    if data.status then update_data.status = data.status end
    if data.github_run_id then update_data.github_run_id = data.github_run_id end
    if data.github_run_url then update_data.github_run_url = data.github_run_url end
    if data.github_run_number then update_data.github_run_number = data.github_run_number end
    if data.error_message then update_data.error_message = data.error_message end
    if data.error_details then update_data.error_details = data.error_details end
    if data.completed_at then update_data.completed_at = data.completed_at end

    deployment:update(update_data)
    return deployment
end

--- Get deployments for a service
-- @param service_id number The service ID
-- @param params table { page?, perPage?, status? }
-- @return table { data, total }
function ServiceQueries.getDeployments(service_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.perPage) or 20

    local conditions = { "d.service_id = ?" }
    local values = { service_id }

    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "d.status = ?")
        table.insert(values, params.status)
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")

    -- Get total count
    local count_result = db.query("SELECT COUNT(*) as total FROM namespace_service_deployments d " .. where_clause,
        table.unpack(values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data
    local offset = (page - 1) * per_page
    local data_query = string.format([[
        SELECT d.*, u.first_name, u.last_name, u.email as triggered_by_email
        FROM namespace_service_deployments d
        LEFT JOIN users u ON d.triggered_by = u.id
        %s
        ORDER BY d.created_at DESC
        LIMIT %d OFFSET %d
    ]], where_clause, per_page, offset)

    local data = db.query(data_query, table.unpack(values))

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Get a single deployment
-- @param id string|number Deployment ID or UUID
-- @return table|nil The deployment
function ServiceQueries.getDeployment(id)
    local query = [[
        SELECT d.*, u.first_name, u.last_name, u.email as triggered_by_email,
               s.name as service_name, s.github_owner, s.github_repo, s.github_workflow_file
        FROM namespace_service_deployments d
        LEFT JOIN users u ON d.triggered_by = u.id
        LEFT JOIN namespace_services s ON d.service_id = s.id
        WHERE d.uuid = ? OR d.id = ?
        LIMIT 1
    ]]
    local result = db.query(query, tostring(id), tonumber(id) or 0)
    return result and result[1]
end

-- ============================================
-- Workflow Triggering (GitHub API)
-- ============================================

--- Trigger a GitHub workflow
-- @param service_id number The service ID
-- @param triggered_by number The user ID triggering the deployment
-- @param custom_inputs table Optional custom inputs to override defaults
-- @return table { deployment, error? }
function ServiceQueries.triggerWorkflow(service_id, triggered_by, custom_inputs)
    local http = require("resty.http")

    -- Get service details
    local service = ServiceQueries.showDetailed(service_id)
    if not service then
        return nil, "Service not found"
    end

    if service.status ~= "active" then
        return nil, "Service is not active"
    end

    -- Get GitHub token
    local github_token = nil
    if service.github_integration_id then
        ngx.log(ngx.INFO, "Fetching GitHub integration ID: ", service.github_integration_id)
        local integration = ServiceQueries.getGithubIntegration(service.github_integration_id, true)
        if integration then
            ngx.log(ngx.INFO, "Integration found: ", integration.name or "unnamed")
            if integration.github_token_decrypted then
                github_token = integration.github_token_decrypted
                -- Log first/last few chars for debugging (safe partial reveal)
                local token_preview = string.sub(github_token, 1, 4) .. "..." .. string.sub(github_token, -4)
                ngx.log(ngx.INFO, "Token retrieved: ", token_preview, " (length: ", #github_token, ")")

                -- Debug: Show raw bytes at start and end to detect corruption
                ngx.log(ngx.INFO, "Token first 4 bytes (hex): ",
                    string.format("%02x %02x %02x %02x",
                        string.byte(github_token, 1) or 0,
                        string.byte(github_token, 2) or 0,
                        string.byte(github_token, 3) or 0,
                        string.byte(github_token, 4) or 0))
                ngx.log(ngx.INFO, "Token last 4 bytes (hex): ",
                    string.format("%02x %02x %02x %02x",
                        string.byte(github_token, -4) or 0,
                        string.byte(github_token, -3) or 0,
                        string.byte(github_token, -2) or 0,
                        string.byte(github_token, -1) or 0))

                -- Check for AES padding bytes that might not have been stripped
                local last_byte = string.byte(github_token, -1)
                if last_byte and last_byte >= 1 and last_byte <= 16 then
                    -- This could be PKCS7 padding - check if it's valid padding
                    local potential_padding = true
                    for i = 1, last_byte do
                        if string.byte(github_token, -i) ~= last_byte then
                            potential_padding = false
                            break
                        end
                    end
                    if potential_padding then
                        ngx.log(ngx.WARN, "Token may have unstripped PKCS7 padding! Last byte: ", last_byte)
                        -- Strip the padding manually
                        github_token = string.sub(github_token, 1, -last_byte - 1)
                        ngx.log(ngx.INFO, "Token after padding removal, length: ", #github_token)
                    end
                end
            else
                ngx.log(ngx.ERR, "Integration found but github_token_decrypted is nil")
            end
        else
            ngx.log(ngx.ERR, "Integration not found for ID: ", service.github_integration_id)
        end
    else
        ngx.log(ngx.ERR, "Service has no github_integration_id")
    end

    if not github_token then
        return nil, "No GitHub integration configured for this service"
    end

    -- WORKFLOW INPUT STRATEGY:
    -- For dynamic workflows (e.g., build-and-deploy-opsapi-dynamic.yml), we send BOTH:
    --   1. Secrets - decrypted and passed as workflow inputs (masked in GitHub logs via ::add-mask::)
    --   2. Variables - passed as workflow inputs (for non-sensitive config like TARGET_ENV)
    --
    -- SECURITY: The dynamic workflow file MUST:
    --   1. Define these secrets as workflow_dispatch inputs
    --   2. Mask them with ::add-mask:: at the start of the job
    --   3. Fall back to repository secrets if inputs are empty
    --
    -- For regular workflows, secrets should be in GitHub repo settings and referenced via ${{ secrets.* }}

    -- Get decrypted secrets (these become workflow inputs for dynamic workflows)
    local secrets = ServiceQueries.getDecryptedSecrets(service.id)

    -- Get variables (these become workflow inputs)
    local variables = {}
    for _, v in ipairs(service.variables or {}) do
        variables[v.key] = v.value or v.default_value
    end

    -- Build workflow inputs from BOTH secrets and variables
    -- Secrets are sent to dynamic workflows that accept them as inputs
    local inputs = {}

    -- Add secrets as inputs (the workflow must define these as inputs and mask them)
    for k, v in pairs(secrets) do
        inputs[k] = v
    end

    -- Add variables as inputs (these override secrets if same key)
    for k, v in pairs(variables) do
        inputs[k] = v
    end

    -- Custom inputs override variable defaults
    if custom_inputs then
        for k, v in pairs(custom_inputs) do
            inputs[k] = v
        end
    end

    -- Create deployment record (store inputs for audit, but MASK secret values)
    local safe_inputs = {}
    for k, v in pairs(custom_inputs or {}) do
        safe_inputs[k] = v
    end
    for k, v in pairs(variables) do
        safe_inputs[k] = v
    end
    -- Store secret KEYS but not values for audit trail
    for k, _ in pairs(secrets) do
        safe_inputs[k] = "********" -- Mask secret values in audit log
    end

    local deployment = ServiceQueries.createDeployment(service.id, {
        triggered_by = triggered_by,
        inputs = safe_inputs,
        status = "pending"
    })

    -- Build GitHub API URL
    local api_url = string.format(
        "https://api.github.com/repos/%s/%s/actions/workflows/%s/dispatches",
        service.github_owner,
        service.github_repo,
        service.github_workflow_file
    )

    ngx.log(ngx.NOTICE, "=== GitHub API Request Debug ===")
    ngx.log(ngx.NOTICE, "API URL: ", api_url)
    ngx.log(ngx.NOTICE, "GitHub Owner: ", service.github_owner)
    ngx.log(ngx.NOTICE, "GitHub Repo: ", service.github_repo)
    ngx.log(ngx.NOTICE, "Workflow File: ", service.github_workflow_file)
    ngx.log(ngx.NOTICE, "Branch: ", service.github_branch)

    -- Build request body
    -- Force empty table to be encoded as object {} not array []
    local body
    if next(inputs) == nil then
        body = '{"ref":"' .. service.github_branch .. '","inputs":{}}'
    else
        body = cjson.encode({
            ref = service.github_branch,
            inputs = inputs
        })
    end

    ngx.log(ngx.NOTICE, "Request Body: ", body)

    -- Make request to GitHub API
    local httpc = http.new()

    -- Set timeouts: connect, send, read (in milliseconds)
    httpc:set_timeouts(10000, 30000, 30000) -- 10s connect, 30s send, 30s read

    -- SSL verification: disable in development/Docker environments where CA certs may not be available
    -- Set OPSAPI_SSL_VERIFY=true in production with proper CA certificates installed
    local ssl_verify = os.getenv("OPSAPI_SSL_VERIFY") == "true"
    ngx.log(ngx.NOTICE, "SSL Verify: ", tostring(ssl_verify))

    -- Trim whitespace from token (encryption/decryption may add whitespace)
    local original_len = #github_token
    github_token = github_token:gsub("^%s+", ""):gsub("%s+$", "")
    local trimmed_len = #github_token
    if original_len ~= trimmed_len then
        ngx.log(ngx.WARN, "Token had whitespace trimmed! Original len: ", original_len, " Trimmed len: ", trimmed_len)
    end

    -- Also remove any null bytes or control characters
    -- Lua pattern: %z matches null, %c matches control characters
    github_token = github_token:gsub("%z", ""):gsub("%c", "")
    if #github_token ~= trimmed_len then
        ngx.log(ngx.WARN, "Token had control characters removed! After: ", #github_token)
    end

    -- Log token info for debugging (safe partial reveal)
    local token_prefix = string.sub(github_token, 1, 10)
    local token_suffix = string.sub(github_token, -4)
    ngx.log(ngx.NOTICE, "Token prefix: ", token_prefix, "...")
    ngx.log(ngx.NOTICE, "Token suffix: ...", token_suffix)
    ngx.log(ngx.NOTICE, "Token length: ", #github_token)

    -- Verify token format (classic PATs start with ghp_, fine-grained with github_pat_)
    if github_token:match("^ghp_") then
        ngx.log(ngx.NOTICE, "Token format: Classic PAT (ghp_)")
    elseif github_token:match("^github_pat_") then
        ngx.log(ngx.NOTICE, "Token format: Fine-grained PAT (github_pat_)")
    else
        ngx.log(ngx.WARN, "Token format: Unknown (does not start with ghp_ or github_pat_)")
    end

    -- Check for any non-printable characters
    local has_special = false
    for i = 1, #github_token do
        local byte = string.byte(github_token, i)
        if byte < 32 or byte > 126 then
            ngx.log(ngx.WARN, "Token has non-printable char at position ", i, ": byte ", byte)
            has_special = true
        end
    end
    if not has_special then
        ngx.log(ngx.NOTICE, "Token contains only printable ASCII characters")
    end

    -- Log hex dump of first 20 chars for detailed debugging
    local hex_prefix = ""
    for i = 1, math.min(20, #github_token) do
        hex_prefix = hex_prefix .. string.format("%02x ", string.byte(github_token, i))
    end
    ngx.log(ngx.NOTICE, "Token hex (first 20 chars): ", hex_prefix)

    -- GitHub API authentication options:
    -- 1. "Bearer <token>" - Recommended for all PATs per current GitHub docs
    -- 2. "token <token>" - Legacy format for classic PATs
    -- 3. Basic auth with username:token
    --
    -- Since user reported "Bearer" and "token" give "Bad credentials" but raw token works in curl,
    -- there might be an issue with how the token is being passed.
    -- Let's try Bearer format as it's the official recommendation
    local auth_header = "Bearer " .. github_token
    ngx.log(ngx.NOTICE, "Auth header format: Bearer <token>")
    ngx.log(ngx.NOTICE, "Full auth header length: ", #auth_header)

    local headers = {
        ["Accept"] = "application/vnd.github+json",
        ["Authorization"] = auth_header,
        ["X-GitHub-Api-Version"] = "2022-11-28",
        ["Content-Type"] = "application/json",
        ["User-Agent"] = "OpsAPI-Services"
    }

    ngx.log(ngx.NOTICE, "Request Headers:")
    for k, v in pairs(headers) do
        if k == "Authorization" then
            ngx.log(ngx.NOTICE, "  ", k, ": ", string.sub(v, 1, 15), "...[REDACTED]")
        else
            ngx.log(ngx.NOTICE, "  ", k, ": ", v)
        end
    end

    ngx.log(ngx.NOTICE, "Sending workflow dispatch request...")

    local res, err = httpc:request_uri(api_url, {
        method = "POST",
        body = body,
        headers = headers,
        ssl_verify = ssl_verify
    })

    ngx.log(ngx.NOTICE, "=== GitHub API Response Debug ===")

    if not res then
        ngx.log(ngx.ERR, "HTTP request failed: ", tostring(err))
        ServiceQueries.updateDeployment(deployment.uuid, {
            status = "error",
            error_message = "Failed to connect to GitHub API",
            error_details = err,
            completed_at = Global.getCurrentTimestamp()
        })
        return deployment, "Failed to connect to GitHub API: " .. tostring(err)
    end

    ngx.log(ngx.NOTICE, "Response Status: ", res.status)
    ngx.log(ngx.NOTICE, "Response Body: ", res.body or "empty")

    -- Log response headers
    if res.headers then
        ngx.log(ngx.NOTICE, "Response Headers:")
        for k, v in pairs(res.headers) do
            ngx.log(ngx.NOTICE, "  ", k, ": ", tostring(v))
        end
    end

    if res.status == 204 then
        -- Success - workflow triggered
        ServiceQueries.updateDeployment(deployment.uuid, {
            status = "triggered"
        })

        -- Update service stats
        local timestamp = Global.getCurrentTimestamp()
        db.update("namespace_services", {
            deployment_count = db.raw("deployment_count + 1"),
            last_deployment_at = timestamp,
            last_deployment_status = "triggered",
            updated_at = timestamp
        }, { id = service.id })

        deployment.status = "triggered"
        return deployment, nil
    else
        -- Error from GitHub API
        local error_body = cjson.decode(res.body) or {}
        local error_message = error_body.message or ("GitHub API error: " .. res.status)

        ServiceQueries.updateDeployment(deployment.uuid, {
            status = "error",
            error_message = error_message,
            error_details = res.body,
            completed_at = Global.getCurrentTimestamp()
        })

        -- Update service failure count
        db.update("namespace_services", {
            failure_count = db.raw("failure_count + 1"),
            last_deployment_at = Global.getCurrentTimestamp(),
            last_deployment_status = "error",
            updated_at = Global.getCurrentTimestamp()
        }, { id = service.id })

        deployment.status = "error"
        deployment.error_message = error_message
        return deployment, error_message
    end
end

--- Get service statistics for a namespace
-- @param namespace_id number The namespace ID
-- @return table Statistics
function ServiceQueries.getStats(namespace_id)
    local stats = db.query([[
        SELECT
            (SELECT COUNT(*) FROM namespace_services WHERE namespace_id = ? AND status = 'active') as total_services,
            (SELECT COUNT(*) FROM namespace_services WHERE namespace_id = ?) as total_all_services,
            (SELECT COALESCE(SUM(deployment_count), 0) FROM namespace_services WHERE namespace_id = ?) as total_deployments,
            (SELECT COALESCE(SUM(success_count), 0) FROM namespace_services WHERE namespace_id = ?) as total_successes,
            (SELECT COALESCE(SUM(failure_count), 0) FROM namespace_services WHERE namespace_id = ?) as total_failures,
            (SELECT COUNT(*) FROM namespace_github_integrations WHERE namespace_id = ? AND status = 'active') as active_integrations
    ]], namespace_id, namespace_id, namespace_id, namespace_id, namespace_id, namespace_id)

    return stats and stats[1] or {
        total_services = 0,
        total_all_services = 0,
        total_deployments = 0,
        total_successes = 0,
        total_failures = 0,
        active_integrations = 0
    }
end

--- Helper to get GitHub headers for API calls
-- @param github_token string The GitHub PAT
-- @return table Headers table
local function getGitHubHeaders(github_token)
    return {
        ["Accept"] = "application/vnd.github+json",
        ["Authorization"] = "Bearer " .. github_token,
        ["X-GitHub-Api-Version"] = "2022-11-28",
        ["User-Agent"] = "OpsAPI-Services"
    }
end

--- Find the GitHub workflow run ID after triggering a dispatch
-- GitHub doesn't return the run ID immediately, so we poll for it
-- @param service table The service record
-- @param github_token string The decrypted GitHub token
-- @return number|nil The workflow run ID, or nil if not found
function ServiceQueries.findWorkflowRunId(service, github_token)
    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(15000)

    local ssl_verify = os.getenv("OPSAPI_SSL_VERIFY") == "true"
    local headers = getGitHubHeaders(github_token)

    -- Query workflow runs for this workflow, sorted by created_at desc
    local runs_url = string.format(
        "https://api.github.com/repos/%s/%s/actions/workflows/%s/runs?per_page=5&branch=%s",
        service.github_owner,
        service.github_repo,
        service.github_workflow_file,
        service.github_branch
    )

    ngx.log(ngx.INFO, "Finding workflow run ID from: ", runs_url)

    local res, err = httpc:request_uri(runs_url, {
        method = "GET",
        headers = headers,
        ssl_verify = ssl_verify
    })

    if not res then
        ngx.log(ngx.ERR, "Failed to query workflow runs: ", tostring(err))
        return nil
    end

    if res.status ~= 200 then
        ngx.log(ngx.WARN, "GitHub API returned status ", res.status, " when querying runs")
        return nil
    end

    local body = cjson.decode(res.body)
    if not body or not body.workflow_runs then
        ngx.log(ngx.WARN, "No workflow_runs in response")
        return nil
    end

    -- Find the most recent run that was created around our trigger time
    -- GitHub workflow runs take 1-5 seconds to appear after dispatch
    for _, run in ipairs(body.workflow_runs) do
        -- Return the most recent run (they're sorted by created_at desc)
        -- In production, you'd want to match by time window or store a unique identifier
        ngx.log(ngx.INFO, "Found workflow run: id=", run.id, " status=", run.status, " conclusion=", tostring(run.conclusion))
        return run.id, run.html_url
    end

    return nil
end

--- Map GitHub workflow status/conclusion to our deployment status
-- @param github_status string GitHub's workflow status (queued, in_progress, completed, etc)
-- @param github_conclusion string|nil GitHub's workflow conclusion (success, failure, cancelled, etc)
-- @return string Our deployment status
local function mapGitHubStatusToDeploymentStatus(github_status, github_conclusion)
    if github_status == "queued" or github_status == "pending" then
        return "pending"
    elseif github_status == "in_progress" or github_status == "waiting" then
        return "running"
    elseif github_status == "completed" then
        if github_conclusion == "success" then
            return "success"
        elseif github_conclusion == "failure" then
            return "failure"
        elseif github_conclusion == "cancelled" then
            return "cancelled"
        elseif github_conclusion == "skipped" then
            return "cancelled"
        elseif github_conclusion == "timed_out" then
            return "failure"
        else
            return "failure"
        end
    else
        return "triggered"
    end
end

--- Sync deployment status from GitHub
-- This is the main function to update deployment status by querying GitHub's API
-- @param deployment_uuid string The deployment UUID
-- @return deployment table|nil Updated deployment or nil
-- @return string|nil Error message
function ServiceQueries.syncDeploymentStatus(deployment_uuid)
    -- Get the deployment
    local deployment = ServiceQueries.getDeployment(deployment_uuid)
    if not deployment then
        return nil, "Deployment not found"
    end

    -- Only sync deployments that are not already in a final state
    local final_states = { success = true, failure = true, cancelled = true, error = true }
    if final_states[deployment.status] then
        ngx.log(ngx.INFO, "Deployment ", deployment_uuid, " is already in final state: ", deployment.status)
        return deployment, nil
    end

    -- Get the service
    local service = ServiceQueries.show(deployment.service_id)
    if not service then
        return nil, "Service not found"
    end

    -- Get the GitHub integration
    if not service.github_integration_id then
        return nil, "Service has no GitHub integration"
    end

    local integration = ServiceQueries.getGithubIntegration(service.github_integration_id, true)
    if not integration or not integration.github_token_decrypted then
        return nil, "GitHub integration not found or token not available"
    end

    local github_token = integration.github_token_decrypted
    -- Clean the token
    github_token = github_token:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%z", ""):gsub("%c", "")

    -- If we don't have a run ID, try to find it
    if not deployment.github_run_id then
        local run_id, run_url = ServiceQueries.findWorkflowRunId(service, github_token)
        if run_id then
            ServiceQueries.updateDeployment(deployment_uuid, {
                github_run_id = run_id,
                github_run_url = run_url
            })
            deployment.github_run_id = run_id
            deployment.github_run_url = run_url
            ngx.log(ngx.INFO, "Found and stored workflow run ID: ", run_id)
        else
            ngx.log(ngx.WARN, "Could not find workflow run ID for deployment ", deployment_uuid)
            return deployment, nil  -- Not an error, just couldn't find it yet
        end
    end

    -- Query the workflow run status from GitHub
    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(15000)

    local ssl_verify = os.getenv("OPSAPI_SSL_VERIFY") == "true"
    local headers = getGitHubHeaders(github_token)

    local run_url = string.format(
        "https://api.github.com/repos/%s/%s/actions/runs/%s",
        service.github_owner,
        service.github_repo,
        deployment.github_run_id
    )

    ngx.log(ngx.INFO, "Querying workflow run status: ", run_url)

    local res, err = httpc:request_uri(run_url, {
        method = "GET",
        headers = headers,
        ssl_verify = ssl_verify
    })

    if not res then
        ngx.log(ngx.ERR, "Failed to query workflow run: ", tostring(err))
        return nil, "Failed to connect to GitHub API: " .. tostring(err)
    end

    if res.status == 404 then
        ngx.log(ngx.WARN, "Workflow run not found (may have been deleted)")
        return deployment, nil
    end

    if res.status ~= 200 then
        ngx.log(ngx.WARN, "GitHub API returned status ", res.status)
        return nil, "GitHub API error: " .. res.status
    end

    local run_data = cjson.decode(res.body)
    if not run_data then
        return nil, "Failed to parse GitHub response"
    end

    -- Map GitHub status to our status
    local new_status = mapGitHubStatusToDeploymentStatus(run_data.status, run_data.conclusion)
    local timestamp = Global.getCurrentTimestamp()

    ngx.log(ngx.INFO, "GitHub run status: ", run_data.status, " conclusion: ", tostring(run_data.conclusion), " -> ", new_status)

    -- Prepare update data
    local update_data = {
        status = new_status,
        github_run_url = run_data.html_url
    }

    -- Update timestamps based on status
    if new_status == "running" and not deployment.started_at then
        update_data.started_at = timestamp
    end

    if final_states[new_status] then
        update_data.completed_at = timestamp

        -- Update service stats
        if new_status == "success" then
            db.update("namespace_services", {
                success_count = db.raw("success_count + 1"),
                last_deployment_status = "success",
                updated_at = timestamp
            }, { id = service.id })
        elseif new_status == "failure" or new_status == "error" then
            db.update("namespace_services", {
                failure_count = db.raw("failure_count + 1"),
                last_deployment_status = new_status,
                updated_at = timestamp
            }, { id = service.id })
        end
    end

    -- Update the deployment
    local updated = ServiceQueries.updateDeployment(deployment_uuid, update_data)

    return updated, nil
end

--- Sync all pending deployments for a namespace
-- This can be called periodically to update all non-final deployments
-- @param namespace_id number The namespace ID
-- @return table Results summary
function ServiceQueries.syncAllPendingDeployments(namespace_id)
    -- Get all deployments that are not in final state
    local pending = db.query([[
        SELECT d.uuid
        FROM namespace_service_deployments d
        JOIN namespace_services s ON d.service_id = s.id
        WHERE s.namespace_id = ?
        AND d.status IN ('triggered', 'pending', 'running')
        AND d.created_at > NOW() - INTERVAL '24 hours'
        ORDER BY d.created_at DESC
        LIMIT 50
    ]], namespace_id)

    local results = {
        total = 0,
        updated = 0,
        errors = 0
    }

    if not pending then
        return results
    end

    results.total = #pending

    for _, deployment in ipairs(pending) do
        local _, err = ServiceQueries.syncDeploymentStatus(deployment.uuid)
        if err then
            results.errors = results.errors + 1
            ngx.log(ngx.WARN, "Failed to sync deployment ", deployment.uuid, ": ", err)
        else
            results.updated = results.updated + 1
        end
    end

    return results
end

--- Handle GitHub webhook payload for workflow_run events
-- This provides real-time updates when GitHub sends a webhook
-- @param payload table The webhook payload
-- @return boolean Success
-- @return string|nil Error message
function ServiceQueries.handleWorkflowRunWebhook(payload)
    if not payload or not payload.workflow_run then
        return false, "Invalid webhook payload"
    end

    local run = payload.workflow_run
    local run_id = run.id
    local repo_full_name = payload.repository and payload.repository.full_name

    if not run_id or not repo_full_name then
        return false, "Missing run_id or repository"
    end

    ngx.log(ngx.INFO, "Processing webhook for run ", run_id, " in ", repo_full_name)

    -- Find deployments with this run ID
    local deployments = db.query([[
        SELECT d.uuid, d.service_id
        FROM namespace_service_deployments d
        JOIN namespace_services s ON d.service_id = s.id
        WHERE d.github_run_id = ?
        OR (
            d.github_run_id IS NULL
            AND d.status IN ('triggered', 'pending')
            AND CONCAT(s.github_owner, '/', s.github_repo) = ?
            AND d.created_at > NOW() - INTERVAL '1 hour'
        )
    ]], run_id, repo_full_name)

    if not deployments or #deployments == 0 then
        ngx.log(ngx.INFO, "No matching deployments found for run ", run_id)
        return true, nil  -- Not an error, just no matching deployment
    end

    -- Map status
    local new_status = mapGitHubStatusToDeploymentStatus(run.status, run.conclusion)
    local timestamp = Global.getCurrentTimestamp()
    local final_states = { success = true, failure = true, cancelled = true, error = true }

    for _, deployment in ipairs(deployments) do
        local update_data = {
            status = new_status,
            github_run_id = run_id,
            github_run_url = run.html_url
        }

        if new_status == "running" then
            update_data.started_at = timestamp
        end

        if final_states[new_status] then
            update_data.completed_at = timestamp

            -- Update service stats
            local service = ServiceQueries.show(deployment.service_id)
            if service then
                if new_status == "success" then
                    db.update("namespace_services", {
                        success_count = db.raw("success_count + 1"),
                        last_deployment_status = "success",
                        updated_at = timestamp
                    }, { id = service.id })
                elseif new_status == "failure" or new_status == "error" then
                    db.update("namespace_services", {
                        failure_count = db.raw("failure_count + 1"),
                        last_deployment_status = new_status,
                        updated_at = timestamp
                    }, { id = service.id })
                end
            end
        end

        ServiceQueries.updateDeployment(deployment.uuid, update_data)
        ngx.log(ngx.INFO, "Updated deployment ", deployment.uuid, " to status: ", new_status)
    end

    return true, nil
end

return ServiceQueries
