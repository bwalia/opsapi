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
-- GitHub Token Validation
-- ============================================

--- Validate a GitHub token by making a test API call
-- This verifies the token is authentic and has appropriate permissions
-- @param github_token string The decrypted GitHub token to validate
-- @return boolean Success status
-- @return table|nil Token info (login, scopes) on success, error message on failure
function ServiceQueries.validateGithubToken(github_token)
    if not github_token or github_token == "" or github_token == "********" then
        return false, "Invalid or empty token"
    end

    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(15000)

    local ssl_verify = os.getenv("OPSAPI_SSL_VERIFY") == "true"

    -- Clean the token (remove any whitespace or control characters)
    github_token = github_token:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%z", ""):gsub("%c", "")

    -- Validate token format
    local token_format = "unknown"
    if github_token:match("^ghp_") then
        token_format = "classic_pat"
    elseif github_token:match("^github_pat_") then
        token_format = "fine_grained_pat"
    elseif github_token:match("^gho_") then
        token_format = "oauth_token"
    elseif github_token:match("^ghu_") then
        token_format = "user_access_token"
    elseif github_token:match("^ghs_") then
        token_format = "installation_token"
    elseif github_token:match("^ghr_") then
        token_format = "refresh_token"
    end

    ngx.log(ngx.INFO, "[TokenValidation] Validating token with format: ", token_format, ", length: ", #github_token)

    -- Use the /user endpoint to validate token and get user info
    local res, err = httpc:request_uri("https://api.github.com/user", {
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["Authorization"] = "Bearer " .. github_token,
            ["X-GitHub-Api-Version"] = "2022-11-28",
            ["User-Agent"] = "OpsAPI-TokenValidator"
        },
        ssl_verify = ssl_verify
    })

    if not res then
        ngx.log(ngx.ERR, "[TokenValidation] HTTP request failed: ", tostring(err))
        return false, "Failed to connect to GitHub API: " .. tostring(err)
    end

    ngx.log(ngx.INFO, "[TokenValidation] Response status: ", res.status)

    if res.status == 200 then
        local user_data = cjson.decode(res.body)

        if not user_data then
            return false, "Failed to parse GitHub response"
        end

        -- Extract useful information
        local token_info = {
            valid = true,
            login = user_data.login,
            id = user_data.id,
            name = user_data.name,
            token_format = token_format,
            -- Extract scopes from response headers (classic PATs only)
            scopes = res.headers["x-oauth-scopes"] or "",
            -- Rate limit info
            rate_limit = res.headers["x-ratelimit-limit"],
            rate_remaining = res.headers["x-ratelimit-remaining"]
        }

        ngx.log(ngx.INFO, "[TokenValidation] Token valid for user: ", token_info.login,
            ", scopes: ", token_info.scopes)

        return true, token_info
    elseif res.status == 401 then
        local error_data = cjson.decode(res.body) or {}
        local error_msg = error_data.message or "Bad credentials"
        ngx.log(ngx.WARN, "[TokenValidation] Token authentication failed: ", error_msg)
        return false, "Invalid token: " .. error_msg
    elseif res.status == 403 then
        local error_data = cjson.decode(res.body) or {}
        local error_msg = error_data.message or "Access forbidden"
        ngx.log(ngx.WARN, "[TokenValidation] Token forbidden: ", error_msg)
        return false, "Token access forbidden: " .. error_msg
    else
        ngx.log(ngx.WARN, "[TokenValidation] Unexpected response status: ", res.status)
        return false, "GitHub API returned status " .. res.status
    end
end

--- Validate a GitHub token and check if it has required workflow permissions
-- @param github_token string The decrypted GitHub token
-- @param owner string Optional: Repository owner to check specific repo access
-- @param repo string Optional: Repository name to check specific repo access
-- @return boolean Success
-- @return table|nil Token info or error message
function ServiceQueries.validateGithubTokenWithPermissions(github_token, owner, repo)
    -- First, basic token validation
    local valid, result = ServiceQueries.validateGithubToken(github_token)
    if not valid then
        return false, result
    end

    -- If no owner/repo specified, basic validation is sufficient
    if not owner or not repo then
        return true, result
    end

    -- Check specific repository access
    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(15000)

    local ssl_verify = os.getenv("OPSAPI_SSL_VERIFY") == "true"
    github_token = github_token:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%z", ""):gsub("%c", "")

    -- Check if token can access the repo
    local repo_url = string.format("https://api.github.com/repos/%s/%s", owner, repo)
    local res, err = httpc:request_uri(repo_url, {
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["Authorization"] = "Bearer " .. github_token,
            ["X-GitHub-Api-Version"] = "2022-11-28",
            ["User-Agent"] = "OpsAPI-TokenValidator"
        },
        ssl_verify = ssl_verify
    })

    if not res then
        ngx.log(ngx.WARN, "[TokenValidation] Failed to check repo access: ", tostring(err))
        result.repo_access = false
        result.repo_error = "Failed to connect: " .. tostring(err)
        return true, result  -- Token is valid, but repo check failed
    end

    if res.status == 200 then
        local repo_data = cjson.decode(res.body)
        result.repo_access = true
        result.repo_full_name = repo_data and repo_data.full_name
        result.repo_permissions = repo_data and repo_data.permissions

        -- Check if we have actions permission (needed for workflow_dispatch)
        if repo_data and repo_data.permissions then
            result.can_trigger_workflows = repo_data.permissions.push or repo_data.permissions.admin
        end

        ngx.log(ngx.INFO, "[TokenValidation] Repo access confirmed for: ", owner, "/", repo)
    elseif res.status == 404 then
        result.repo_access = false
        result.repo_error = "Repository not found or no access"
        ngx.log(ngx.WARN, "[TokenValidation] No access to repo: ", owner, "/", repo)
    else
        result.repo_access = false
        result.repo_error = "GitHub API returned status " .. res.status
    end

    return true, result
end

-- ============================================
-- GitHub Integration Management
-- ============================================

--- Create a GitHub integration for a namespace
-- Validates the token before storing and sets last_validated_at
-- @param namespace_id number The namespace ID
-- @param data table { name?, github_token, github_username?, created_by?, skip_validation? }
-- @return table The created integration (token masked)
-- @return string|nil Error message if validation failed
function ServiceQueries.createGithubIntegration(namespace_id, data)
    local timestamp = Global.getCurrentTimestamp()

    -- Validate the GitHub token before storing (unless explicitly skipped)
    local token_info = nil
    if not data.skip_validation then
        local valid, result = ServiceQueries.validateGithubToken(data.github_token)
        if not valid then
            ngx.log(ngx.WARN, "[createGithubIntegration] Token validation failed: ", result)
            return nil, "Token validation failed: " .. result
        end
        token_info = result
        ngx.log(ngx.INFO, "[createGithubIntegration] Token validated for user: ", token_info.login)
    end

    -- Encrypt the GitHub token
    local encrypted_token = Global.encryptSecret(data.github_token)

    -- Use validated username if not provided
    local github_username = data.github_username
    if not github_username and token_info and token_info.login then
        github_username = token_info.login
    end

    local integration_data = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = data.name or "default",
        github_token = encrypted_token,
        github_username = github_username,
        status = "active",
        last_validated_at = timestamp,  -- Set validation timestamp
        created_by = data.created_by,
        created_at = timestamp,
        updated_at = timestamp
    }

    local integration = GithubIntegrations:create(integration_data, { returning = "*" })

    -- Never return the actual token
    integration.github_token = "********"

    -- Include validation info in response
    if token_info then
        integration.validation_info = {
            login = token_info.login,
            token_format = token_info.token_format,
            scopes = token_info.scopes
        }
    end

    return integration, nil
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
-- Validates new token if provided and updates last_validated_at
-- @param id string|number Integration ID or UUID
-- @param data table Fields to update
-- @return table|nil The updated integration
-- @return string|nil Error message if token validation failed
function ServiceQueries.updateGithubIntegration(id, data)
    local integration = GithubIntegrations:find({ uuid = tostring(id) })
    if not integration and tonumber(id) then
        integration = GithubIntegrations:find({ id = tonumber(id) })
    end

    if not integration then return nil end

    local timestamp = Global.getCurrentTimestamp()
    local update_data = { updated_at = timestamp }
    local token_info = nil

    if data.name then update_data.name = data.name end
    if data.github_username then update_data.github_username = data.github_username end
    if data.status then update_data.status = data.status end

    -- Encrypt and validate new token if provided
    if data.github_token and data.github_token ~= "********" then
        -- Validate the new token before storing (unless explicitly skipped)
        if not data.skip_validation then
            local valid, result = ServiceQueries.validateGithubToken(data.github_token)
            if not valid then
                ngx.log(ngx.WARN, "[updateGithubIntegration] Token validation failed: ", result)
                return nil, "Token validation failed: " .. result
            end
            token_info = result
            ngx.log(ngx.INFO, "[updateGithubIntegration] New token validated for user: ", token_info.login)

            -- Update username from validated token if not explicitly provided
            if not data.github_username and token_info.login then
                update_data.github_username = token_info.login
            end
        end

        update_data.github_token = Global.encryptSecret(data.github_token)
        update_data.last_validated_at = timestamp  -- Update validation timestamp
    end

    integration:update(update_data)
    integration.github_token = "********"

    -- Include validation info in response
    if token_info then
        integration.validation_info = {
            login = token_info.login,
            token_format = token_info.token_format,
            scopes = token_info.scopes
        }
    end

    return integration, nil
end

--- Re-validate an existing GitHub integration's token
-- Updates last_validated_at on success, marks status as invalid on failure
-- @param id string|number Integration ID or UUID
-- @return boolean Success status
-- @return table|string Token info on success, error message on failure
function ServiceQueries.revalidateGithubIntegration(id)
    local integration = GithubIntegrations:find({ uuid = tostring(id) })
    if not integration and tonumber(id) then
        integration = GithubIntegrations:find({ id = tonumber(id) })
    end

    if not integration then
        return false, "Integration not found"
    end

    -- Decrypt the token
    local ok, decrypted_token = pcall(Global.decryptSecret, integration.github_token)
    if not ok or not decrypted_token then
        ngx.log(ngx.ERR, "[revalidateGithubIntegration] Failed to decrypt token for integration: ", id)
        -- Mark as invalid since we can't even decrypt
        integration:update({
            status = "invalid",
            updated_at = Global.getCurrentTimestamp()
        })
        return false, "Failed to decrypt token"
    end

    -- Validate the token
    local valid, result = ServiceQueries.validateGithubToken(decrypted_token)
    local timestamp = Global.getCurrentTimestamp()

    if valid then
        -- Update last_validated_at and ensure status is active
        integration:update({
            last_validated_at = timestamp,
            status = "active",
            github_username = result.login or integration.github_username,
            updated_at = timestamp
        })
        ngx.log(ngx.INFO, "[revalidateGithubIntegration] Token validated successfully for integration: ", id)
        return true, result
    else
        -- Mark the integration as having an invalid token
        integration:update({
            status = "invalid",
            updated_at = timestamp
        })
        ngx.log(ngx.WARN, "[revalidateGithubIntegration] Token validation failed for integration: ", id, " - ", result)
        return false, result
    end
end

--- Revalidate all GitHub integrations for a namespace
-- Useful for periodic token validation
-- @param namespace_id number The namespace ID
-- @return table Results summary { total, valid, invalid, errors }
function ServiceQueries.revalidateAllGithubIntegrations(namespace_id)
    local integrations = db.query([[
        SELECT id, uuid FROM namespace_github_integrations
        WHERE namespace_id = ? AND status != 'deleted'
    ]], namespace_id)

    local results = {
        total = 0,
        valid = 0,
        invalid = 0,
        errors = {}
    }

    if not integrations then
        return results
    end

    results.total = #integrations

    for _, integration in ipairs(integrations) do
        local valid, err = ServiceQueries.revalidateGithubIntegration(integration.uuid)
        if valid then
            results.valid = results.valid + 1
        else
            results.invalid = results.invalid + 1
            table.insert(results.errors, {
                uuid = integration.uuid,
                error = err
            })
        end
    end

    ngx.log(ngx.INFO, "[revalidateAllGithubIntegrations] Namespace ", namespace_id,
        ": ", results.valid, " valid, ", results.invalid, " invalid out of ", results.total)

    return results
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

    -- SECURITY: Never log the request body as it contains decrypted secrets
    -- Log only the count of inputs for debugging
    local input_count = 0
    for _ in pairs(inputs) do input_count = input_count + 1 end
    ngx.log(ngx.NOTICE, "Request Body: [REDACTED - contains ", input_count, " inputs including secrets]")

    -- SSL verification: disable in development/Docker environments where CA certs may not be available
    -- Set OPSAPI_SSL_VERIFY=true in production with proper CA certificates installed
    local ssl_verify = os.getenv("OPSAPI_SSL_VERIFY") == "true"
    ngx.log(ngx.NOTICE, "SSL Verify: ", tostring(ssl_verify))

    -- Resolve GitHub API IP addresses using multiple DNS servers
    -- This handles geo-routing issues where some IPs may be blocked
    local function resolve_github_ips()
        local resolver = require("resty.dns.resolver")
        local ips = {}

        -- Try multiple DNS servers to get different GitHub IPs
        local dns_servers = {
            {"8.8.8.8", "Google DNS"},
            {"1.1.1.1", "Cloudflare DNS"},
            {"208.67.222.222", "OpenDNS"},
        }

        for _, dns in ipairs(dns_servers) do
            local r, _ = resolver:new({
                nameservers = {dns[1]},
                retrans = 2,
                timeout = 3000,
            })

            if r then
                local answers, _ = r:query("api.github.com", { qtype = r.TYPE_A })
                if answers and not answers.errcode then
                    for _, ans in ipairs(answers) do
                        if ans.address then
                            -- Add unique IPs only
                            local found = false
                            for _, existing in ipairs(ips) do
                                if existing == ans.address then
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                table.insert(ips, ans.address)
                                ngx.log(ngx.INFO, "DNS (", dns[2], "): api.github.com -> ", ans.address)
                            end
                        end
                    end
                end
            end
        end

        return ips
    end

    -- Try connecting to GitHub using multiple resolved IPs
    local function make_github_request(api_path, request_body, request_headers)
        local ips = resolve_github_ips()

        if #ips == 0 then
            ngx.log(ngx.ERR, "Failed to resolve any IPs for api.github.com")
            return nil, "DNS resolution failed for api.github.com"
        end

        ngx.log(ngx.INFO, "Resolved ", #ips, " IP(s) for api.github.com")

        -- Collect all errors for debugging
        local all_errors = {}

        -- Try each IP until one works
        for _, ip in ipairs(ips) do
            ngx.log(ngx.NOTICE, "Trying GitHub API via IP: ", ip)

            local httpc = http.new()
            httpc:set_timeouts(10000, 30000, 30000) -- 10s connect, 30s send/read (increased)

            -- Connect directly to the IP
            local ok, conn_err = httpc:connect(ip, 443)
            if ok then
                ngx.log(ngx.NOTICE, "TCP connection successful to IP: ", ip)

                -- Perform SSL handshake with correct SNI
                local session, ssl_err = httpc:ssl_handshake(nil, "api.github.com", ssl_verify)
                if session then
                    ngx.log(ngx.NOTICE, "SSL handshake successful with IP: ", ip)

                    -- Send the request
                    local res, req_err = httpc:request({
                        method = "POST",
                        path = api_path,
                        headers = request_headers,
                        body = request_body,
                    })

                    if res then
                        -- Read the response body
                        local response_body = res:read_body()
                        httpc:close()

                        ngx.log(ngx.NOTICE, "GitHub API request successful via IP: ", ip)

                        return {
                            status = res.status,
                            headers = res.headers,
                            body = response_body
                        }, nil
                    else
                        local err_msg = "Request failed: " .. (req_err or "unknown")
                        ngx.log(ngx.ERR, "IP ", ip, " - ", err_msg)
                        table.insert(all_errors, ip .. ": " .. err_msg)
                        httpc:close()
                    end
                else
                    local err_msg = "SSL handshake failed: " .. (ssl_err or "unknown")
                    ngx.log(ngx.ERR, "IP ", ip, " - ", err_msg)
                    table.insert(all_errors, ip .. ": " .. err_msg)
                    httpc:close()
                end
            else
                local err_msg = "TCP connection failed: " .. (conn_err or "unknown")
                ngx.log(ngx.ERR, "IP ", ip, " - ", err_msg)
                table.insert(all_errors, ip .. ": " .. err_msg)
            end
        end

        local error_details = table.concat(all_errors, "; ")
        ngx.log(ngx.ERR, "All GitHub IPs failed. Details: ", error_details)
        return nil, "All GitHub API IPs failed: " .. error_details
    end

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

    -- Build the API path for the request
    local api_path = string.format(
        "/repos/%s/%s/actions/workflows/%s/dispatches",
        service.github_owner,
        service.github_repo,
        service.github_workflow_file
    )

    -- Add Host header for the request (required when connecting by IP)
    headers["Host"] = "api.github.com"

    -- Use the multi-IP GitHub request function for reliability
    local res, err = make_github_request(api_path, body, headers)

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

--- Test GitHub API connectivity
-- This diagnostic function tests DNS resolution, TCP connection, and SSL handshake
-- @return table Detailed diagnostic results
function ServiceQueries.testGitHubConnectivity()
    local http = require("resty.http")
    local resolver = require("resty.dns.resolver")

    local results = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        dns_tests = {},
        connection_tests = {},
        working_ips = {},
        summary = {
            dns_success = 0,
            dns_failed = 0,
            tcp_success = 0,
            tcp_failed = 0,
            ssl_success = 0,
            ssl_failed = 0,
            request_success = 0,
            request_failed = 0
        }
    }

    -- Test multiple DNS servers
    local dns_servers = {
        {"8.8.8.8", "Google DNS"},
        {"1.1.1.1", "Cloudflare DNS"},
        {"208.67.222.222", "OpenDNS"},
    }

    local all_ips = {}

    for _, dns in ipairs(dns_servers) do
        local dns_result = {
            server = dns[1],
            name = dns[2],
            success = false,
            ips = {},
            error = nil
        }

        local r, r_err = resolver:new({
            nameservers = {dns[1]},
            retrans = 2,
            timeout = 5000,
        })

        if r then
            local answers, dns_err = r:query("api.github.com", { qtype = r.TYPE_A })
            if answers and not answers.errcode then
                dns_result.success = true
                results.summary.dns_success = results.summary.dns_success + 1
                for _, ans in ipairs(answers) do
                    if ans.address then
                        table.insert(dns_result.ips, ans.address)
                        -- Add to all_ips if not already present
                        local found = false
                        for _, existing in ipairs(all_ips) do
                            if existing == ans.address then found = true; break end
                        end
                        if not found then
                            table.insert(all_ips, ans.address)
                        end
                    end
                end
            else
                dns_result.error = answers and answers.errcode and ("DNS error: " .. answers.errcode) or (dns_err or "Unknown DNS error")
                results.summary.dns_failed = results.summary.dns_failed + 1
            end
        else
            dns_result.error = "Resolver creation failed: " .. (r_err or "unknown")
            results.summary.dns_failed = results.summary.dns_failed + 1
        end

        table.insert(results.dns_tests, dns_result)
    end

    results.total_unique_ips = #all_ips

    -- Test connection to each IP
    for _, ip in ipairs(all_ips) do
        local conn_result = {
            ip = ip,
            tcp_connect = false,
            tcp_error = nil,
            ssl_handshake = false,
            ssl_error = nil,
            http_request = false,
            http_error = nil,
            http_status = nil,
            response_snippet = nil
        }

        local httpc = http.new()
        httpc:set_timeouts(10000, 15000, 15000) -- 10s connect, 15s send/read

        -- Test TCP connection
        local ok, conn_err = httpc:connect(ip, 443)
        if ok then
            conn_result.tcp_connect = true
            results.summary.tcp_success = results.summary.tcp_success + 1

            -- Test SSL handshake
            local session, ssl_err = httpc:ssl_handshake(nil, "api.github.com", false)
            if session then
                conn_result.ssl_handshake = true
                results.summary.ssl_success = results.summary.ssl_success + 1

                -- Test a simple HTTP request (rate_limit endpoint doesn't need auth)
                local res, req_err = httpc:request({
                    method = "GET",
                    path = "/rate_limit",
                    headers = {
                        ["Host"] = "api.github.com",
                        ["User-Agent"] = "OPSAPI-Connectivity-Test/1.0",
                        ["Accept"] = "application/vnd.github+json",
                    },
                })

                if res then
                    conn_result.http_request = true
                    conn_result.http_status = res.status
                    results.summary.request_success = results.summary.request_success + 1

                    local body = res:read_body()
                    if body then
                        conn_result.response_snippet = string.sub(body, 1, 100) .. (string.len(body) > 100 and "..." or "")
                    end

                    table.insert(results.working_ips, ip)
                else
                    conn_result.http_error = req_err or "Unknown request error"
                    results.summary.request_failed = results.summary.request_failed + 1
                end
            else
                conn_result.ssl_error = ssl_err or "Unknown SSL error"
                results.summary.ssl_failed = results.summary.ssl_failed + 1
            end
        else
            conn_result.tcp_error = conn_err or "Unknown TCP error"
            results.summary.tcp_failed = results.summary.tcp_failed + 1
        end

        httpc:close()
        table.insert(results.connection_tests, conn_result)
    end

    -- Determine overall status
    if #results.working_ips > 0 then
        results.overall_status = "OK"
        results.message = "GitHub API is reachable via " .. #results.working_ips .. " IP(s)"
    elseif #all_ips > 0 then
        results.overall_status = "FAILED"
        results.message = "DNS resolved " .. #all_ips .. " IP(s) but all connections failed"
    else
        results.overall_status = "DNS_FAILED"
        results.message = "Could not resolve any IP addresses for api.github.com"
    end

    return results
end

return ServiceQueries
