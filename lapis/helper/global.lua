local bcrypt = require("bcrypt")
local Json = require("cjson")
local base64 = require 'base64'

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
    local aesInstance = assert(AES:new(secretKey, nil, AES.cipher(128, "cbc"), {
        iv = secretIV
    }))
    local encrypted = aesInstance:encrypt(secret)
    if not encrypted then
        error("Encryption failed")
    end
    return base64.encode(encrypted)
end

-- Function to decrypt data
function Global.decryptSecret(encodedSecret)
    local AES = require("resty.aes")
    local aesInstance = assert(AES:new(secretKey, nil, AES.cipher(128, "cbc"), {
        iv = secretIV
    }))
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
        schemas = { "urn:ietf:params:scim:schemas:core:2.0:User" },
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
            location = "/scim/v2/Groups/" .. group.uuid
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

function Global.generateJwt(user_id)
    local jwt = require "resty.jwt"
    local secret = os.getenv("JWT_SECRET_KEY")
    local current_time = ngx.time()
    local token = jwt:sign(
        secret,
        {
            header = { typ = "JWT", alg = "HS256" },
            payload = {
                user_id = user_id,
                exp = current_time + 3600
            }
        }
    )

    return token
end

function Global.uploadToMinio(file, file_name)
    local http = require("resty.http")
    local cjson = require("cjson.safe")
    local token = Global.generateJwt(1)
    if not file or not file.filename or not file.content then
        return nil, "Missing file or file content"
    end

    local boundary = "----LuaFormBoundary" .. tostring(math.random(1e8, 1e9))
    local crlf = "\r\n"

    local function getContentType(filename)
        local ext = filename:match("%.(%w+)$")
        local mime_types = {
            jpg = "image/jpeg",
            jpeg = "image/jpeg",
            png = "image/png",
            webp = "image/webp"
        }
        return mime_types[ext:lower()] or "application/octet-stream"
    end
    local content_type = file.content_type or getContentType(file_name)

    local body = {
        "--" .. boundary,
        string.format('Content-Disposition: form-data; name="image"; filename="%s"', file_name),
        string.format("Content-Type: %s", content_type),
        "",
        file.content,
        "--" .. boundary .. "--"
    }
    local body_data = table.concat(body, crlf)

    local httpc = http.new()
    local nodeApiUrl = os.getenv("NODE_API_URL") or "https://test-opsapi-node.workstation.co.uk/api"
    local url = nodeApiUrl .. "/upload"
    local res, err = httpc:request_uri(url,
        {
            method = "POST",
            body = body_data,
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["Content-Length"] = tostring(#body_data)
            },
            ssl_verify = false
        })

    if not res then
        return nil, "Request error: " .. tostring(err)
    end

    if res.status ~= 200 then
        return nil, "Upload failed [" .. res.status .. "]: " .. tostring(res.body)
    end

    return cjson.decode(res.body).url, nil
end

return Global
