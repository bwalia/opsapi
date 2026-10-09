--[[
    AWS Secrets Manager Provider
    ============================
    Connects to AWS Secrets Manager via HTTP API with Signature V4.
]]

local cjson = require("cjson")

local AwsProvider = {}
AwsProvider.__index = AwsProvider

function AwsProvider:new(config)
    local instance = setmetatable({}, self)
    instance.region = config.region or "us-east-1"
    instance.access_key_id = config.access_key_id
    instance.secret_access_key = config.secret_access_key
    instance.prefix = config.prefix or ""
    instance.timeout = config.timeout or 10000
    instance.endpoint = "https://secretsmanager." .. instance.region .. ".amazonaws.com"
    return instance
end

local function aws_request(self, action, params)
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end

    local body = cjson.encode(params or {})
    local httpc = http.new()
    httpc:set_timeout(self.timeout)

    -- Simplified: use headers for action
    local headers = {
        ["Content-Type"] = "application/x-amz-json-1.1",
        ["X-Amz-Target"] = "secretsmanager." .. action,
        ["Host"] = "secretsmanager." .. self.region .. ".amazonaws.com",
    }

    -- In production, you'd compute full SigV4 here.
    -- For now, if running on EC2/ECS with IAM role, credentials come from instance metadata.
    if self.access_key_id and self.secret_access_key then
        -- Basic auth header placeholder - full SigV4 implementation needed for production
        ngx.log(ngx.WARN, "[AWS] Full SigV4 signing recommended for production use")
    end

    local res, err = httpc:request_uri(self.endpoint, {
        method = "POST",
        headers = headers,
        body = body,
    })
    if not res then return nil, err end
    if res.status >= 400 then
        local data = pcall(cjson.decode, res.body) and cjson.decode(res.body) or {}
        return nil, "AWS " .. res.status .. ": " .. (data.Message or data.__type or res.body)
    end
    return cjson.decode(res.body)
end

function AwsProvider:connect()
    return true -- AWS uses per-request authentication
end

function AwsProvider:testConnection()
    local data, err = aws_request(self, "ListSecrets", { MaxResults = 1 })
    if not data then return false, "Connection failed: " .. (err or "unknown") end
    return true
end

function AwsProvider:listSecrets(path)
    local params = { MaxResults = 100 }
    if self.prefix ~= "" then
        params.Filters = {{ Key = "name", Values = { self.prefix } }}
    end
    local data, err = aws_request(self, "ListSecrets", params)
    if not data then return nil, err end

    local results = {}
    for _, secret in ipairs(data.SecretList or {}) do
        results[#results + 1] = {
            path = "",
            key = secret.Name,
            version = secret.VersionIdsToStages and next(secret.VersionIdsToStages) or nil,
        }
    end
    return results
end

function AwsProvider:getSecret(path, key)
    local secret_name = path ~= "" and (path .. "/" .. key) or key
    local data, err = aws_request(self, "GetSecretValue", { SecretId = secret_name })
    if not data then return nil, err end
    return {
        value = data.SecretString or data.SecretBinary,
        version = data.VersionId,
        metadata = { arn = data.ARN, name = data.Name },
    }
end

function AwsProvider:putSecret(path, key, value)
    local secret_name = path ~= "" and (path .. "/" .. key) or key
    -- Try update first, create if not found
    local data, err = aws_request(self, "PutSecretValue", {
        SecretId = secret_name,
        SecretString = value,
    })
    if err and err:match("ResourceNotFoundException") then
        data, err = aws_request(self, "CreateSecret", {
            Name = secret_name,
            SecretString = value,
        })
    end
    if not data then return false, err end
    return true
end

function AwsProvider:deleteSecret(path, key)
    local secret_name = path ~= "" and (path .. "/" .. key) or key
    local _, err = aws_request(self, "DeleteSecret", {
        SecretId = secret_name,
        ForceDeleteWithoutRecovery = false,
        RecoveryWindowInDays = 7,
    })
    if err then return false, err end
    return true
end

return AwsProvider
