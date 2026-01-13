local bcrypt = require("bcrypt")
local Json = require("cjson")
local base64 = require 'base64'

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

--- Parse a timestamp string to Unix time
-- Supports formats: "YYYY-MM-DD HH:MM:SS" and "YYYY-MM-DDTHH:MM:SSZ"
-- @param datetimeStr string The timestamp string to parse
-- @return number|nil Unix timestamp or nil if parsing fails
function Global.parseTimestamp(datetimeStr)
    if not datetimeStr or datetimeStr == "" then
        return nil
    end

    -- Try standard format: "YYYY-MM-DD HH:MM:SS"
    local pattern = "(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)"
    local year, month, day, hour, minute, second = datetimeStr:match(pattern)

    -- Try ISO 8601 format: "YYYY-MM-DDTHH:MM:SSZ"
    if not year then
        pattern = "(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)"
        year, month, day, hour, minute, second = datetimeStr:match(pattern)
    end

    if not year then
        return nil
    end

    local dt_table = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour) or 0,
        min = tonumber(minute) or 0,
        sec = tonumber(second) or 0
    }

    return os.time(dt_table)
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

-- Validate encryption key and IV lengths for AES-128-CBC (requires 16 bytes each)
local function validateEncryptionConfig()
    local secretKey = Global.getEnvVar("OPENSSL_SECRET_KEY")
    local secretIV = Global.getEnvVar("OPENSSL_SECRET_IV")

    if not secretKey or #secretKey == 0 then
        error("OPENSSL_SECRET_KEY environment variable is not set")
    end

    if not secretIV or #secretIV == 0 then
        error("OPENSSL_SECRET_IV environment variable is not set")
    end

    -- AES-128 requires 16-byte key and IV
    -- Keys can be provided as 16 raw bytes or 32 hex characters
    if #secretKey < 16 then
        ngx.log(ngx.WARN, "OPENSSL_SECRET_KEY is ", #secretKey, " bytes, AES-128 requires 16 bytes. Key will be padded.")
    end

    if #secretIV < 16 then
        ngx.log(ngx.WARN, "OPENSSL_SECRET_IV is ", #secretIV, " bytes, AES-128 requires 16 bytes. IV will be padded.")
    end

    return secretKey, secretIV
end

function Global.encryptSecret(secret)
    if not secret or secret == "" then
        error("Cannot encrypt empty secret")
    end

    local secretKey, secretIV = validateEncryptionConfig()
    local AES = require("resty.aes")
    local aesInstance = assert(AES:new(secretKey, nil, AES.cipher(128, "cbc"), {
        iv = secretIV
    }), "Failed to initialize AES encryption")

    local encrypted = aesInstance:encrypt(secret)
    if not encrypted then
        error("Encryption failed - AES encrypt returned nil")
    end

    -- Use OpenResty's native base64 encoding for consistency
    return ngx.encode_base64(encrypted)
end

-- Function to decrypt data
function Global.decryptSecret(encodedSecret)
    if not encodedSecret or encodedSecret == "" then
        error("Cannot decrypt empty secret")
    end

    local secretKey, secretIV = validateEncryptionConfig()
    local AES = require("resty.aes")
    local aesInstance = assert(AES:new(secretKey, nil, AES.cipher(128, "cbc"), {
        iv = secretIV
    }), "Failed to initialize AES decryption")

    -- Try OpenResty's native base64 decoding first
    local encrypted = ngx.decode_base64(encodedSecret)
    local decode_method = "ngx"

    if not encrypted then
        -- Fallback to the lua-base64 library for backwards compatibility
        -- with tokens encrypted before this change
        encrypted = base64.decode(encodedSecret)
        decode_method = "lua-base64"
    end

    if not encrypted then
        ngx.log(ngx.ERR, "Base64 decode failed for both methods")
        error("Base64 decoding failed")
    end

    local decrypted = aesInstance:decrypt(encrypted)
    if not decrypted then
        ngx.log(ngx.ERR, "AES decryption failed using ", decode_method, " base64 decode")
        error("Decryption failed - secret may have been encrypted with different key")
    end

    ngx.log(ngx.DEBUG, "Decryption successful using ", decode_method, " method")
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
            location = "http://172.19.0.12:80/api/v2/Users/" .. user.uuid,
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
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
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

function Global.trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function Global.getEnvVar(name)
    local value = os.getenv(name)
    if value == nil then
        ngx.log(ngx.ERR, "Environment variable " .. name .. " is not set")
        return nil
    end
    return Global.trim(value)
end

function Global.splitName(fullName)
    if not fullName or fullName == "" then
        return { first_name = "", last_name = "" }
    end
    
    local parts = Global.splitStr(fullName, " ")
    local first_name = parts[1] or ""
    local last_name = ""
    
    if #parts > 1 then
        last_name = table.concat(parts, " ", 2)
    end
    
    return { first_name = first_name, last_name = last_name }
end

function Global.generateRandomPassword()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    local password = ""
    for i = 1, 16 do
        local rand = math.random(#chars)
        password = password .. string.sub(chars, rand, rand)
    end
    return password
end

--- Upload file to MinIO/S3 storage directly
-- Uses the new MinIO client with AWS Signature V4 authentication
-- @param file table File object { content, filename, content_type? }
-- @param file_name string Optional filename override
-- @param options table Optional upload options { prefix?, max_size?, validate_type? }
-- @return string|nil URL of uploaded file
-- @return string|nil Error message if failed
-- @return table|nil Metadata of uploaded file
function Global.uploadToMinio(file, file_name, options)
    local MinioClient = require("helper.minio")

    -- Validate input
    if not file then
        return nil, "No file provided"
    end

    -- Normalize file object
    local upload_file = {
        content = file.content,
        filename = file_name or file.filename,
        content_type = file.content_type
    }

    -- Validate file content exists
    if not upload_file.content or upload_file.content == "" then
        return nil, "File content is empty"
    end

    -- Merge options with defaults
    options = options or {}

    -- Upload using MinIO client
    local url, err, metadata = MinioClient.quickUpload(upload_file, options)

    if not url then
        ngx.log(ngx.ERR, "[Global.uploadToMinio] Upload failed: ", err)
        return nil, err
    end

    ngx.log(ngx.INFO, "[Global.uploadToMinio] Upload successful: ", url)
    return url, nil, metadata
end

--- Delete file from MinIO/S3 storage
-- @param object_key string The object key or full URL
-- @param bucket string Optional bucket name
-- @return boolean Success status
-- @return string|nil Error message if failed
function Global.deleteFromMinio(object_key, bucket)
    local MinioClient = require("helper.minio")

    if not object_key or object_key == "" then
        return false, "No object key provided"
    end

    -- Extract object key from URL if full URL provided
    local endpoint = Global.getEnvVar("MINIO_ENDPOINT")
    if endpoint and object_key:match("^https?://") then
        local bucket_name = bucket or Global.getEnvVar("MINIO_BUCKET")
        local pattern = endpoint .. "/" .. bucket_name .. "/"
        object_key = object_key:gsub(pattern, "")
    end

    return MinioClient.quickDelete(object_key, bucket)
end

--- Get presigned URL for temporary file access
-- @param object_key string The object key
-- @param expires_in number Seconds until expiration (default 3600)
-- @return string|nil Presigned URL
function Global.getMinioPresignedUrl(object_key, expires_in)
    local MinioClient = require("helper.minio")
    return MinioClient.getDefault():getPresignedUrl(object_key, expires_in)
end

--- Safely validate and sanitize ORDER BY parameters to prevent SQL injection
-- @param order_by string The requested order field
-- @param order_dir string The requested order direction (asc/desc)
-- @param valid_fields table A table of valid field names { field1 = true, field2 = true }
-- @param default_field string Default field if invalid (defaults to "created_at")
-- @param default_dir string Default direction if invalid (defaults to "desc")
-- @return string, string Sanitized order_by field and direction
function Global.sanitizeOrderBy(order_by, order_dir, valid_fields, default_field, default_dir)
    default_field = default_field or "created_at"
    default_dir = default_dir or "desc"

    -- Validate order_by against whitelist
    if not order_by or not valid_fields[order_by] then
        order_by = default_field
    end

    -- Validate order_dir is strictly asc or desc
    if order_dir then
        order_dir = order_dir:lower()
        if order_dir ~= "asc" and order_dir ~= "desc" then
            order_dir = default_dir
        end
    else
        order_dir = default_dir
    end

    return order_by, order_dir:upper()
end

return Global
