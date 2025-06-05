local bcrypt = require("bcrypt")
local Json = require("cjson")
local base64 = require 'base64'

local secretKey = os.getenv("OPENSSL_SECRET_KEY")
local secretIV = os.getenv("OPENSSL_SECRET_IV")

-- local MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT")
local MINIO_BUCKET = os.getenv("MINIO_BUCKET")
local MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY")
local MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY")
local MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT")
local MINIO_ENDPOINT_SCHEME = os.getenv("MINIO_ENDPOINT_SCHEME") or "http" -- Default to http if not set
local MINIO_REGION = os.getenv("MINIO_REGION")

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
        schemas = {"urn:ietf:params:scim:schemas:core:2.0:User"},
        id = user.uuid,
        externalId = user.uuid,
        userName = user.username,
        name = {
            givenName = user.first_name,
            familyName = user.last_name
        },
        displayName = user.first_name .. " " .. user.last_name,
        emails = {{
            value = user.email,
            primary = true
        }},
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
        schemas = {"urn:ietf:params:scim:schemas:core:2.0:Group"},
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

-- Helper functions for AWS SigV4
local function to_hex(str)
    return string.gsub(str, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)
end

local function hmac_sha256(key, msg)
    local hmac = require "resty.openssl.hmac"
    return hmac.new(key, "sha256"):final(msg)
end

local function get_amz_date()
    return os.date("!%Y%m%dT%H%M%SZ")
end

local function get_date_stamp()
    return os.date("!%Y%m%d")
end

local function uri_encode(str)
    if not str then
        return ""
    end
    return string.gsub(str, "([^A-Za-z0-9%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function sha256_hex(str)
    local crypto = require "resty.openssl.digest"
    return to_hex(crypto.new("sha256"):final(str or ""))
end

-- Generate AWS Signature Version 4
local function generate_aws_sigv4(method, host, path, query, headers, payload, service, region)
    local algorithm = "AWS4-HMAC-SHA256"
    local date_stamp = get_date_stamp()
    local amz_date = get_amz_date()
    local content_type = headers["Content-Type"] or ""
    local content_sha256 = sha256_hex(payload)

    -- Normalize path (handle multiple slashes and encoding)
    local normalized_path = path
    if not string.find(normalized_path, "^/") then
        normalized_path = "/" .. normalized_path
    end

    -- Canonical headers must be in lowercase and sorted
    local canonical_headers = "host:" .. host:lower() .. "\nx-amz-date:" .. amz_date .. "\n"
    local signed_headers = "host;x-amz-date"

    -- Canonical query string (sorted)
    local canonical_query = ""
    if query and query ~= "" then
        local params = {}
        for k, v in string.gmatch(query, "([^&=]+)=([^&=]*)") do
            table.insert(params, {k, v})
        end
        table.sort(params, function(a, b)
            return a[1] < b[1]
        end)
        local parts = {}
        for _, param in ipairs(params) do
            table.insert(parts, uri_encode(param[1]) .. "=" .. uri_encode(param[2]))
        end
        canonical_query = table.concat(parts, "&")
    end

    -- Canonical request
    local canonical_request = string.format("%s\n%s\n%s\n%s\n%s\n%s", method:upper(), normalized_path, canonical_query,
        canonical_headers, signed_headers, content_sha256)

    -- String to sign
    local credential_scope = string.format("%s/%s/%s/aws4_request", date_stamp, region, service)

    local string_to_sign = string.format("%s\n%s\n%s\n%s", algorithm, amz_date, credential_scope,
        sha256_hex(canonical_request))

    -- Calculate signature
    local k_date = hmac_sha256("AWS4" .. MINIO_SECRET_KEY, date_stamp)
    local k_region = hmac_sha256(k_date, region)
    local k_service = hmac_sha256(k_region, service)
    local k_signing = hmac_sha256(k_service, "aws4_request")
    local signature = to_hex(hmac_sha256(k_signing, string_to_sign))

    -- Return authorization header
    return string.format("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s", algorithm, MINIO_ACCESS_KEY,
        credential_scope, signed_headers, signature)
end

function Global.uploadToMinio(file, file_name)
    local http = require "resty.http"

    local object_path = MINIO_BUCKET .. "/" .. uri_encode(file_name)
    local host = MINIO_ENDPOINT
    local urlScheme = MINIO_ENDPOINT_SCHEME
    if not urlScheme:find("://") then
        urlScheme = urlScheme .. "://"
    end
    local url = urlScheme .. host .. "/" .. object_path

    local amz_date = get_amz_date()
    local authorization = generate_aws_sigv4("PUT", host, "/" .. object_path, -- Path must start with /
    "", -- No query parameters
    {
        ["Content-Type"] = file["content-type"],
        ["x-amz-date"] = amz_date
    }, file.content, "s3", MINIO_REGION)

    local httpc = http.new()
    local res, err = httpc:request_uri(url, {
        method = "PUT",
        body = file.content,
        headers = {
            ["Host"] = host,
            ["Content-Type"] = file["content-type"],
            ["Content-Length"] = #file.content,
            ["x-amz-date"] = amz_date,
            ["Authorization"] = authorization,
            ["x-amz-content-sha256"] = sha256_hex(file.content)
        },
        ssl_verify = false
    })

    if not res or err then
        return nil, "MinIO upload error: " .. (err or "unknown")
    end

    if res.status >= 400 then
        return nil, "MinIO error (" .. res.status .. "): " .. (res.body or "unknown")
    end

    return url, nil
end

return Global
