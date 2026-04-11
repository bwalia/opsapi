--[[
    HashiCorp Vault Provider
    ========================
    Connects to HashiCorp Vault via HTTP API (KV v2 engine).
    Supports token and AppRole authentication.
]]

local cjson = require("cjson")

local HashicorpProvider = {}
HashicorpProvider.__index = HashicorpProvider

function HashicorpProvider:new(config)
    local instance = setmetatable({}, self)
    instance.vault_url = (config.vault_url or ""):gsub("/$", "")
    instance.auth_method = config.auth_method or "token"
    instance.token = config.token
    instance.role_id = config.role_id
    instance.secret_id = config.secret_id
    instance.mount_path = config.mount_path or "secret"
    instance.namespace = config.namespace
    instance.timeout = config.timeout or 10000
    return instance
end

local function http_request(self, method, path, body)
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end

    local httpc = http.new()
    httpc:set_timeout(self.timeout)

    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Vault-Token"] = self.token,
    }
    if self.namespace then
        headers["X-Vault-Namespace"] = self.namespace
    end

    local params = {
        method = method,
        headers = headers,
    }
    if body then params.body = cjson.encode(body) end

    local url = self.vault_url .. path
    local res, err = httpc:request_uri(url, params)
    if not res then return nil, err end

    if res.status >= 400 then
        local data = pcall(cjson.decode, res.body) and cjson.decode(res.body) or {}
        local errors = data.errors and table.concat(data.errors, "; ") or res.body
        return nil, "HTTP " .. res.status .. ": " .. errors
    end

    local data = res.body and res.body ~= "" and cjson.decode(res.body) or {}
    return data
end

function HashicorpProvider:connect()
    if self.auth_method == "approle" and self.role_id then
        local data, err = http_request(self, "POST", "/v1/auth/approle/login", {
            role_id = self.role_id,
            secret_id = self.secret_id,
        })
        if not data then return false, "AppRole login failed: " .. (err or "unknown") end
        self.token = data.auth and data.auth.client_token
        if not self.token then return false, "No token returned from AppRole login" end
    end
    return true
end

function HashicorpProvider:testConnection()
    local data, err = http_request(self, "GET", "/v1/sys/health")
    if not data then return false, "Connection failed: " .. (err or "unknown") end
    return true
end

function HashicorpProvider:listSecrets(path)
    path = path or ""
    local api_path = "/v1/" .. self.mount_path .. "/metadata/" .. path
    local data, err = http_request(self, "LIST", api_path)
    if not data then return nil, err end

    local keys = data.data and data.data.keys or {}
    local results = {}
    for _, key in ipairs(keys) do
        -- Keys ending with / are subpaths
        if not key:match("/$") then
            results[#results + 1] = {
                path = path,
                key = key,
                version = nil,
            }
        end
    end
    return results
end

function HashicorpProvider:getSecret(path, key)
    local secret_path = path ~= "" and (path .. "/" .. key) or key
    local api_path = "/v1/" .. self.mount_path .. "/data/" .. secret_path
    local data, err = http_request(self, "GET", api_path)
    if not data then return nil, err end

    local secret_data = data.data and data.data.data or {}
    local metadata = data.data and data.data.metadata or {}
    -- Return the first value or the whole data table serialized
    local value = secret_data.value or cjson.encode(secret_data)
    return {
        value = value,
        version = metadata.version,
        metadata = metadata,
    }
end

function HashicorpProvider:putSecret(path, key, value, metadata)
    local secret_path = path ~= "" and (path .. "/" .. key) or key
    local api_path = "/v1/" .. self.mount_path .. "/data/" .. secret_path
    local body = { data = { value = value } }
    if metadata then body.data.metadata = metadata end

    local _, err = http_request(self, "POST", api_path, body)
    if err then return false, err end
    return true
end

function HashicorpProvider:deleteSecret(path, key)
    local secret_path = path ~= "" and (path .. "/" .. key) or key
    local api_path = "/v1/" .. self.mount_path .. "/metadata/" .. secret_path
    local _, err = http_request(self, "DELETE", api_path)
    if err then return false, err end
    return true
end

return HashicorpProvider
