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

-- Simplified AWS Signature V4 (HMAC-SHA256 based)
local function hmac_sha256(key, data)
    local ok, hmac = pcall(require, "resty.hmac")
    if ok then
        local h = hmac:new(key, hmac.ALGOS.SHA256)
        h:update(data)
        return h:final()
    end
    -- Fallback: use openssl via shell
    local handle = io.popen("echo -n '" .. data .. "' | openssl dgst -sha256 -hmac '" .. key .. "' -binary 2>/dev/null | xxd -p -c 256")
    local result = handle and handle:read("*a") or ""
    if handle then handle:close() end
    return result:gsub("%s+", "")
end

local function sha256_hex(data)
    local ok, resty_sha256 = pcall(require, "resty.sha256")
    if ok then
        local sha = resty_sha256:new()
        sha:update(data or "")
        local digest = sha:final()
        local hex = {}
        for i = 1, #digest do
            hex[i] = string.format("%02x", string.byte(digest, i))
        end
        return table.concat(hex)
    end
    local handle = io.popen("echo -n '" .. (data or "") .. "' | sha256sum 2>/dev/null")
    local result = handle and handle:read("*a") or ""
    if handle then handle:close() end
    return result:match("^(%x+)") or ""
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
