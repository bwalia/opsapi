--[[
    Kubernetes Secrets Provider
    ===========================
    Reads/writes Kubernetes Secret resources via the K8s API.
    Supports in-cluster config and external kubeconfig token.
]]

local cjson = require("cjson")

local KubernetesProvider = {}
KubernetesProvider.__index = KubernetesProvider

-- Base64 helpers
local function b64encode(data)
    if not data then return "" end
    return ngx.encode_base64(data)
end

local function b64decode(data)
    if not data then return "" end
    return ngx.decode_base64(data) or data
end

function KubernetesProvider:new(config)
    local instance = setmetatable({}, self)
    instance.api_server = config.api_server
    instance.token = config.token
    instance.namespace = config.k8s_namespace or config.namespace or "default"
    instance.ca_cert_path = config.ca_cert_path
    instance.timeout = config.timeout or 10000
    instance.in_cluster = config.in_cluster or false

    -- Auto-detect in-cluster config
    if not instance.api_server or instance.api_server == "" then
        instance.in_cluster = true
        instance.api_server = "https://kubernetes.default.svc"
        -- Read service account token
        local f = io.open("/var/run/secrets/kubernetes.io/serviceaccount/token", "r")
        if f then
            instance.token = f:read("*a")
            f:close()
        end
        instance.ca_cert_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        -- Read namespace
        local ns_f = io.open("/var/run/secrets/kubernetes.io/serviceaccount/namespace", "r")
        if ns_f then
            instance.namespace = ns_f:read("*a"):gsub("%s+", "")
            ns_f:close()
        end
    end

    return instance
end

local function k8s_request(self, method, path, body)
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end

    local httpc = http.new()
    httpc:set_timeout(self.timeout)

    local headers = {
        ["Authorization"] = "Bearer " .. (self.token or ""),
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }

    local url = self.api_server .. path
    local params = { method = method, headers = headers, ssl_verify = false }
    if body then params.body = cjson.encode(body) end

    local res, err = httpc:request_uri(url, params)
    if not res then return nil, err end
    if res.status >= 400 then
        local data = pcall(cjson.decode, res.body) and cjson.decode(res.body) or {}
        return nil, "K8s " .. res.status .. ": " .. (data.message or res.body)
    end
    return cjson.decode(res.body)
end

function KubernetesProvider:connect()
    if not self.token or self.token == "" then
        return false, "No Kubernetes token available"
    end
    return true
end

function KubernetesProvider:testConnection()
    local data, err = k8s_request(self, "GET",
        "/api/v1/namespaces/" .. self.namespace .. "/secrets?limit=1")
    if not data then return false, "Connection failed: " .. (err or "unknown") end
    return true
end

function KubernetesProvider:listSecrets(path)
    local api_path = "/api/v1/namespaces/" .. self.namespace .. "/secrets"
    local data, err = k8s_request(self, "GET", api_path)
    if not data then return nil, err end

    local results = {}
    for _, item in ipairs(data.items or {}) do
        -- Skip service account tokens and TLS secrets unless explicitly requested
        local secret_type = item.type or ""
        if secret_type ~= "kubernetes.io/service-account-token" then
            local secret_data = item.data or {}
            for key, _ in pairs(secret_data) do
                results[#results + 1] = {
                    path = item.metadata.name,
                    key = key,
                    version = item.metadata.resourceVersion,
                }
            end
        end
    end
    return results
end

function KubernetesProvider:getSecret(path, key)
    local api_path = "/api/v1/namespaces/" .. self.namespace .. "/secrets/" .. path
    local data, err = k8s_request(self, "GET", api_path)
    if not data then return nil, err end

    local secret_data = data.data or {}
    local value = secret_data[key]
    return {
        value = value and b64decode(value) or nil,
        version = data.metadata and data.metadata.resourceVersion,
        metadata = {
            name = data.metadata and data.metadata.name,
            namespace = data.metadata and data.metadata.namespace,
            type = data.type,
        },
    }
end

function KubernetesProvider:putSecret(path, key, value, metadata)
    -- Check if secret exists
    local existing, _ = k8s_request(self, "GET",
        "/api/v1/namespaces/" .. self.namespace .. "/secrets/" .. path)

    if existing then
        -- Patch existing secret
        existing.data = existing.data or {}
        existing.data[key] = b64encode(value)
        local _, err = k8s_request(self, "PUT",
            "/api/v1/namespaces/" .. self.namespace .. "/secrets/" .. path, existing)
        if err then return false, err end
    else
        -- Create new secret
        local secret = {
            apiVersion = "v1",
            kind = "Secret",
            metadata = { name = path, namespace = self.namespace },
            type = "Opaque",
            data = { [key] = b64encode(value) },
        }
        local _, err = k8s_request(self, "POST",
            "/api/v1/namespaces/" .. self.namespace .. "/secrets", secret)
        if err then return false, err end
    end
    return true
end

function KubernetesProvider:deleteSecret(path, key)
    -- If key specified, patch to remove just that key; otherwise delete entire secret
    if key then
        local existing, err = k8s_request(self, "GET",
            "/api/v1/namespaces/" .. self.namespace .. "/secrets/" .. path)
        if not existing then return false, err end
        if existing.data then
            existing.data[key] = nil
        end
        local _, put_err = k8s_request(self, "PUT",
            "/api/v1/namespaces/" .. self.namespace .. "/secrets/" .. path, existing)
        if put_err then return false, put_err end
    else
        local _, err = k8s_request(self, "DELETE",
            "/api/v1/namespaces/" .. self.namespace .. "/secrets/" .. path)
        if err then return false, err end
    end
    return true
end

return KubernetesProvider
