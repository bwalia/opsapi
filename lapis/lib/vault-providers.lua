--[[
    Vault Provider Abstraction Layer
    =================================

    Registry and factory for external vault provider implementations.

    Each provider must implement the following interface:
      provider:connect(config) -> bool, error
      provider:listSecrets(path) -> [{path, key, version}], error
      provider:getSecret(path, key) -> {value, version, metadata}, error
      provider:putSecret(path, key, value, metadata) -> bool, error
      provider:deleteSecret(path, key) -> bool, error
      provider:testConnection(config) -> bool, error
]]

local VaultProviders = {}

-- Registry of provider implementations
local providers = {}

--- Register a provider implementation
-- @param provider_type string One of: hashicorp_vault, aws_secrets_manager, azure_key_vault, gcp_secret_manager, kubernetes, env_file, dotenv
-- @param implementation table A table/class implementing the provider interface
function VaultProviders.register(provider_type, implementation)
    if not provider_type or type(provider_type) ~= "string" then
        return false, "provider_type must be a non-empty string"
    end
    if not implementation then
        return false, "implementation must be provided"
    end
    providers[provider_type] = implementation
    return true
end

--- Get a provider implementation by type
-- @param provider_type string The provider type key
-- @return table|nil The provider implementation, or nil
-- @return string|nil Error message if not found
function VaultProviders.get(provider_type)
    local impl = providers[provider_type]
    if not impl then
        return nil, "Unknown provider type: " .. tostring(provider_type)
    end
    return impl
end

--- List all registered provider types
-- @return table Array of registered provider type strings
function VaultProviders.list()
    local result = {}
    for k, _ in pairs(providers) do
        result[#result + 1] = k
    end
    table.sort(result)
    return result
end

--- Create a new provider instance with the given config
-- @param provider_type string The provider type
-- @param config table Provider-specific configuration
-- @return table|nil Provider instance, or nil on error
-- @return string|nil Error message
function VaultProviders.create(provider_type, config)
    local impl, err = VaultProviders.get(provider_type)
    if not impl then
        return nil, err
    end
    return impl:new(config)
end

-- Auto-register built-in providers (load lazily to avoid hard failures)
local builtin_providers = {
    { type = "hashicorp_vault", module = "lib.vault-providers.hashicorp" },
    { type = "aws_secrets_manager", module = "lib.vault-providers.aws" },
    { type = "azure_key_vault", module = "lib.vault-providers.azure" },
    { type = "kubernetes", module = "lib.vault-providers.kubernetes" },
    { type = "env_file", module = "lib.vault-providers.env-file" },
    { type = "dotenv", module = "lib.vault-providers.env-file" },
}

for _, bp in ipairs(builtin_providers) do
    local ok, mod = pcall(require, bp.module)
    if ok and mod then
        VaultProviders.register(bp.type, mod)
    end
end

return VaultProviders
