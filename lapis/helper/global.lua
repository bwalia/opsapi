local bcrypt = require("bcrypt")
local Json = require("cjson")
local base64 = require'base64'

local secretKey = os.getenv("OPENSSL_SECRET_KEY")
local secretIV = os.getenv("OPENSSL_SECRET_IV")

local saltRounds = 10
local Global = {}

function Global.generateUUID()
    local random = math.random(1000000000)
    local timestamp = os.time()
    local hash = ngx.md5(tostring(random) .. tostring(timestamp))
    local uuid = string.format("%s-%s-%s-%s-%s", string.sub(hash, 1, 8), string.sub(hash, 9, 12),
        string.sub(hash, 13, 16), string.sub(hash, 17, 20), string.sub(hash, 21, 32))
    return uuid
end

function Global.generateStaticUUID()
    local random = math.random
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"

    -- Replace each 'x' and 'y' with random hex digits.
    -- 'x' can be any hex digit (0-9, a-f)
    -- 'y' is one of 8, 9, A, or B (for UUID v4 compliance)
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and random(0, 15) or random(8, 11)
        return string.format("%x", v)
    end)
end

function Global.getCurrentTimestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

function Global.hashPassword(password)
    local hash = bcrypt.digest(password, saltRounds)
    return hash
end

function Global.matchPassword(password, hashedPassword)
    return bcrypt.verify(password, hashedPassword)
end

function Global.removeBykey(table, key)
    local element = table[key]
    table[key] = nil
    return element
end

function Global.encryptSecret(secret)
    local AES = require("resty.aes")
    local aesInstance = assert(AES:new(secretKey,
    nil, AES.cipher(128, "cbc"), { iv = secretIV }))
    local encrypted = aesInstance:encrypt(secret)
    if not encrypted then
        error("Encryption failed")
    end
    return base64.encode(encrypted)
end

-- Function to decrypt data
function Global.decryptSecret(encodedSecret)
    local AES = require("resty.aes")
    local aesInstance = assert(AES:new(secretKey,
    nil, AES.cipher(128, "cbc"), { iv = secretIV }))
    local encrypted = base64.decode(encodedSecret)
    local decrypted = aesInstance:decrypt(encrypted)
    if not decrypted then
        error("Decryption failed")
    end
    return decrypted
end

function Global.convertIso8601(datetimeStr)
    -- Parse the input date string to extract year, month, day, hour, minute, second
    local pattern = "(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)"
    local year, month, day, hour, minute, second = datetimeStr:match(pattern)

    -- Create a table representing the date and time
    local dt_table = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(minute),
        sec = tonumber(second)
    }

    -- Convert to UNIX timestamp (UTC)
    local utc_time = os.time(dt_table)

    -- Format the date to ISO 8601 format (Z for UTC)
    local iso8601_date = os.date("!%Y-%m-%dT%H:%M:%SZ", utc_time)

    return iso8601_date
end

-- Base SCIM schema for User
function Global.scimUserSchema(user)
    return {
        schemas = {
            "urn:ietf:params:scim:schemas:core:2.0:User"
        },
        id = user.uuid,
        externalId = user.uuid,
        userName = user.username,
        name = {
            givenName = user.first_name,
            familyName = user.last_name
        },
        displayName = user.first_name .. " " .. user.last_name,
        emails = { {
            value = user.email,
            primary = true
        } },
        active = user.active,
        roles = user.roles,
        meta = {
            resourceType = "User",
            location = "http://172.19.0.12:8080/api/v2/Users/" .. user.uuid,
            created = Global.convertIso8601(user.created_at),
            lastModified = Global.convertIso8601(user.updated_at)
        }
    }
end

-- Base SCIM schema for Group
function Global.scimGroupSchema(group)
    return {
        schemas = { "urn:ietf:params:scim:schemas:core:2.0:Group" },
        id = group.uuid,
        externalId = group.uuid,
        displayName = group.name,
        members = group.members or {},
        meta = {
            resourceType = "Group",
            created = Global.convertIso8601(group.created_at),
            lastModified = Global.convertIso8601(group.updated_at),
            location = "/scim/v2/Groups/" .. group.uuid,
        }
    }
end

-- Get POST/PUT Args
function Global.getPayloads(body)
    local keyset = {}
    local n = 0
    for k, v in pairs(body) do
        n = n + 1
        if type(v) == "string" then
            if v ~= nil and v ~= "" then
                table.insert(keyset, Json.decode(k .. v))
            end
        else
            table.insert(keyset, Json.decode(k))
        end
    end
    return keyset[1]
end

-- Split String
function Global.splitStr(str, sep)
    local t = {}
    for tag in string.gmatch(str, "([^" .. sep .. "]+)") do
      table.insert(t, tag:match("^%s*(.-)%s*$"))
    end
    return t
  end

return Global
