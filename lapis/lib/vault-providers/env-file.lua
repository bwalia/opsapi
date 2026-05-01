--[[
    .env / Environment File Provider
    =================================
    Import/export secrets from .env file format, JSON, or YAML.
]]

local cjson = require("cjson")

local EnvFileProvider = {}
EnvFileProvider.__index = EnvFileProvider

function EnvFileProvider:new(config)
    local instance = setmetatable({}, self)
    instance.file_content = config.file_content or ""
    instance.format = config.format or "dotenv" -- dotenv, json
    instance.secrets = nil -- parsed cache
    return instance
end

function EnvFileProvider:connect()
    return true
end

function EnvFileProvider:testConnection()
    if not self.file_content or self.file_content == "" then
        return false, "No file content provided"
    end
    local secrets, err = self:_parse()
    if not secrets then return false, err end
    return true, nil
end

function EnvFileProvider:_parse()
    if self.secrets then return self.secrets end

    if self.format == "json" then
        local ok, data = pcall(cjson.decode, self.file_content)
        if not ok then return nil, "Invalid JSON" end
        local results = {}
        for k, v in pairs(data) do
            results[k] = tostring(v)
        end
        self.secrets = results
        return results
    end

    -- Default: dotenv format
    local results = {}
    for line in self.file_content:gmatch("[^\r\n]+") do
        -- Skip comments and empty lines
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^#") then
            -- Parse KEY=VALUE (support quoted values)
            local key, value = trimmed:match("^([%w_%.%-]+)%s*=%s*(.*)")
            if key then
                -- Strip surrounding quotes
                value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
                -- Strip inline comments (not inside quotes)
                if not trimmed:match('=.*".*#') and not trimmed:match("=.*'.*#") then
                    value = value:match("^(.-)%s*#") or value
                end
                results[key] = value
            end
        end
    end
    self.secrets = results
    return results
end

function EnvFileProvider:listSecrets(path)
    local secrets, err = self:_parse()
    if not secrets then return nil, err end

    local results = {}
    for key, _ in pairs(secrets) do
        results[#results + 1] = {
            path = "",
            key = key,
            version = nil,
        }
    end
    table.sort(results, function(a, b) return a.key < b.key end)
    return results
end

function EnvFileProvider:getSecret(path, key)
    local secrets, err = self:_parse()
    if not secrets then return nil, err end

    local value = secrets[key]
    if not value then return nil, "Key not found: " .. key end

    return {
        value = value,
        version = nil,
        metadata = {},
    }
end

function EnvFileProvider:putSecret(path, key, value)
    local secrets, _ = self:_parse()
    if not secrets then secrets = {} end
    secrets[key] = value
    self.secrets = secrets
    return true
end

function EnvFileProvider:deleteSecret(path, key)
    local secrets, _ = self:_parse()
    if secrets then
        secrets[key] = nil
        self.secrets = secrets
    end
    return true
end

-- Export all secrets as .env format string
function EnvFileProvider:exportDotenv(secrets_table)
    local lines = {}
    local keys = {}
    for k, _ in pairs(secrets_table) do keys[#keys + 1] = k end
    table.sort(keys)

    for _, k in ipairs(keys) do
        local v = secrets_table[k]
        -- Quote values with spaces or special chars
        if v:match("[%s#\"']") then
            v = '"' .. v:gsub('"', '\\"') .. '"'
        end
        lines[#lines + 1] = k .. "=" .. v
    end
    return table.concat(lines, "\n")
end

-- Export as JSON
function EnvFileProvider:exportJson(secrets_table)
    return cjson.encode(secrets_table)
end

return EnvFileProvider
