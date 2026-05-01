--[[
    Azure Key Vault Provider
    ========================
    Connects to Azure Key Vault via REST API with OAuth2 authentication.
]]

local cjson = require("cjson")

local AzureProvider = {}
AzureProvider.__index = AzureProvider

function AzureProvider:new(config)
    local instance = setmetatable({}, self)
    instance.vault_url = (config.vault_url or ""):gsub("/$", "")
    instance.tenant_id = config.tenant_id
    instance.client_id = config.client_id
    instance.client_secret = config.client_secret
    instance.api_version = config.api_version or "7.4"
    instance.timeout = config.timeout or 10000
    instance.access_token = nil
    return instance
end

local function http_request(url, method, headers, body, timeout)
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end

    local httpc = http.new()
    httpc:set_timeout(timeout or 10000)

    local params = { method = method, headers = headers }
    if body then params.body = body end

    local res, err = httpc:request_uri(url, params)
    if not res then return nil, err end
    if res.status >= 400 then
        local data = pcall(cjson.decode, res.body) and cjson.decode(res.body) or {}
        local msg = data.error and (data.error.message or data.error.code) or res.body
        return nil, "Azure " .. res.status .. ": " .. tostring(msg)
    end
    return res.body ~= "" and cjson.decode(res.body) or {}
end

function AzureProvider:connect()
    local token_url = "https://login.microsoftonline.com/" .. self.tenant_id .. "/oauth2/v2.0/token"
    local body = "grant_type=client_credentials"
        .. "&client_id=" .. ngx.escape_uri(self.client_id)
        .. "&client_secret=" .. ngx.escape_uri(self.client_secret)
        .. "&scope=" .. ngx.escape_uri("https://vault.azure.net/.default")

    local data, err = http_request(token_url, "POST", {
        ["Content-Type"] = "application/x-www-form-urlencoded",
    }, body, self.timeout)

    if not data then return false, "OAuth2 token request failed: " .. (err or "unknown") end
    self.access_token = data.access_token
    if not self.access_token then return false, "No access token in response" end
    return true
end

function AzureProvider:testConnection()
    local ok, err = self:connect()
    if not ok then return false, err end
    -- Try listing secrets
    local _, list_err = self:listSecrets("")
    if list_err then return false, list_err end
    return true
end

local function api_headers(self)
    return {
        ["Authorization"] = "Bearer " .. (self.access_token or ""),
        ["Content-Type"] = "application/json",
    }
end

function AzureProvider:listSecrets(path)
    if not self.access_token then
        local ok, err = self:connect()
        if not ok then return nil, err end
    end

    local url = self.vault_url .. "/secrets?api-version=" .. self.api_version
    local data, err = http_request(url, "GET", api_headers(self), nil, self.timeout)
    if not data then return nil, err end

    local results = {}
    for _, secret in ipairs(data.value or {}) do
        local name = secret.id and secret.id:match("/secrets/([^/]+)") or ""
        results[#results + 1] = {
            path = "",
            key = name,
            version = nil,
        }
    end
    return results
end

function AzureProvider:getSecret(path, key)
    if not self.access_token then
        local ok, err = self:connect()
        if not ok then return nil, err end
    end

    local url = self.vault_url .. "/secrets/" .. key .. "?api-version=" .. self.api_version
    local data, err = http_request(url, "GET", api_headers(self), nil, self.timeout)
    if not data then return nil, err end

    return {
        value = data.value,
        version = data.id and data.id:match("/([^/]+)$"),
        metadata = data.attributes,
    }
end

function AzureProvider:putSecret(path, key, value)
    if not self.access_token then
        local ok, err = self:connect()
        if not ok then return nil, err end
    end

    local url = self.vault_url .. "/secrets/" .. key .. "?api-version=" .. self.api_version
    local _, err = http_request(url, "PUT", api_headers(self), cjson.encode({ value = value }), self.timeout)
    if err then return false, err end
    return true
end

function AzureProvider:deleteSecret(path, key)
    if not self.access_token then
        local ok, err = self:connect()
        if not ok then return nil, err end
    end

    local url = self.vault_url .. "/secrets/" .. key .. "?api-version=" .. self.api_version
    local _, err = http_request(url, "DELETE", api_headers(self), nil, self.timeout)
    if err then return false, err end
    return true
end

return AzureProvider
