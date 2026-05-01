--[[
    Migration Utilities

    This helper provides utilities that work in CLI context (migrations)
    without requiring OpenResty/ngx dependencies.

    Includes bcrypt password hashing using PostgreSQL's pgcrypto extension.
]]

local db = require("lapis.db")

local MigrationUtils = {}

-- Cost factor for bcrypt (10-12 is recommended for production)
local BCRYPT_COST = 10

-- Generate a UUID v4 using pure Lua (no ngx dependency)
function MigrationUtils.generateUUID()
    local random = math.random
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"

    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and random(0, 15) or random(8, 11)
        return string.format("%x", v)
    end)
end

-- Get current timestamp in SQL format
function MigrationUtils.getCurrentTimestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

--[[
    Hash a password using PostgreSQL's pgcrypto extension with bcrypt.
    This works in CLI context without requiring OpenResty/ngx.

    The bcrypt hash format: $2a$[cost]$[22 char salt][31 char hash]

    @param password (string) - The plain text password to hash
    @return (string) - The bcrypt hash, or nil if error
]]
function MigrationUtils.hashPassword(password)
    if not password or password == "" then
        error("Password cannot be empty")
    end

    -- Ensure pgcrypto extension is available
    local ok, _ = pcall(function()
        db.query("CREATE EXTENSION IF NOT EXISTS pgcrypto")
    end)

    if not ok then
        -- If pgcrypto isn't available, log warning and return nil
        -- The calling code should handle this case
        print("[WARNING] pgcrypto extension not available for password hashing")
        return nil
    end

    -- Use PostgreSQL's crypt function with bcrypt (gen_salt('bf'))
    -- gen_salt('bf', cost) generates a bcrypt salt with specified cost factor
    local result = db.query(
        "SELECT crypt(?, gen_salt('bf', ?)) as hash",
        password,
        BCRYPT_COST
    )

    if result and result[1] and result[1].hash then
        return result[1].hash
    end

    error("Failed to generate password hash")
end

--[[
    Verify a password against a bcrypt hash using PostgreSQL's pgcrypto.

    @param password (string) - The plain text password
    @param hash (string) - The bcrypt hash to verify against
    @return (boolean) - True if password matches, false otherwise
]]
function MigrationUtils.verifyPassword(password, hash)
    if not password or not hash then
        return false
    end

    local result = db.query(
        "SELECT crypt(?, ?) = ? as valid",
        password,
        hash,
        hash
    )

    return result and result[1] and result[1].valid == true
end

-- Seed the random number generator
math.randomseed(os.time())

return MigrationUtils
