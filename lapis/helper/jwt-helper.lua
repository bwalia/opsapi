--[[
    JWT Helper Module

    Centralized JWT token generation with namespace support.
    Provides consistent token structure across all auth endpoints.
]]

local jwt = require("resty.jwt")
local Global = require("helper.global")
local cjson = require("cjson")

local JWTHelper = {}

--- Default token expiration (7 days in seconds)
local DEFAULT_EXPIRATION = 7 * 24 * 60 * 60

--- Get JWT secret key from environment
-- @return string The JWT secret key
local function getSecretKey()
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
    if not secret then
        error("JWT_SECRET_KEY not configured")
    end
    return secret
end

--- Generate a JWT token for a user
-- @param user table User object with uuid, email, first_name, last_name
-- @param options table Optional { namespace?, roles?, expiration? }
-- @return string The JWT token
function JWTHelper.generateToken(user, options)
    options = options or {}
    local expiration = options.expiration or DEFAULT_EXPIRATION
    local now = ngx.time()

    -- Build userinfo payload
    local userinfo = {
        uuid = user.uuid,
        email = user.email,
        name = (user.first_name or "") .. " " .. (user.last_name or ""),
        first_name = user.first_name,
        last_name = user.last_name
    }

    -- Add roles (can be string or table)
    if options.roles then
        if type(options.roles) == "table" then
            -- Get primary role name for backward compatibility
            userinfo.roles = options.roles[1] and options.roles[1].name or "member"
            userinfo.user_roles = options.roles
        else
            userinfo.roles = options.roles
        end
    elseif user.roles then
        if type(user.roles) == "table" and user.roles[1] then
            userinfo.roles = user.roles[1].name or user.roles[1].role_name or "member"
            userinfo.user_roles = user.roles
        else
            userinfo.roles = user.roles
        end
    else
        userinfo.roles = "member"
    end

    -- Add namespace context if provided
    if options.namespace then
        userinfo.namespace = {
            id = options.namespace.id,
            uuid = options.namespace.uuid,
            name = options.namespace.name,
            slug = options.namespace.slug
        }

        -- Add namespace-specific role if provided
        if options.namespace_role then
            userinfo.namespace.role = options.namespace_role
        end

        -- Add namespace permissions if provided
        if options.namespace_permissions then
            userinfo.namespace.permissions = options.namespace_permissions
        end

        -- Add is_owner flag if provided
        if options.is_namespace_owner ~= nil then
            userinfo.namespace.is_owner = options.is_namespace_owner
        end
    end

    -- Build JWT payload
    local payload = {
        userinfo = userinfo,
        iat = now,
        exp = now + expiration,
        iss = "opsapi"
    }

    -- Sign and return token
    local token = jwt:sign(getSecretKey(), {
        header = {
            typ = "JWT",
            alg = "HS256"
        },
        payload = payload
    })

    return token
end

--- Generate a token for namespace switch
-- Creates a new token with updated namespace context
-- @param user table User object
-- @param namespace table Namespace object
-- @param membership table Namespace membership object
-- @param options table Optional { namespace_roles?, namespace_permissions? }
-- @return string The JWT token
function JWTHelper.generateNamespaceToken(user, namespace, membership, options)
    options = options or {}

    -- Determine namespace role from membership
    local namespace_role = nil
    if membership.is_owner then
        namespace_role = "owner"
    elseif options.namespace_roles and #options.namespace_roles > 0 then
        -- Get highest priority role name
        namespace_role = options.namespace_roles[1].role_name or options.namespace_roles[1].display_name
    else
        namespace_role = "member"
    end

    return JWTHelper.generateToken(user, {
        roles = options.user_roles or user.roles,
        namespace = namespace,
        namespace_role = namespace_role,
        namespace_permissions = options.namespace_permissions,
        is_namespace_owner = membership.is_owner,
        expiration = options.expiration
    })
end

--- Verify a JWT token
-- @param token string The JWT token
-- @return table|nil Verification result { valid, payload, reason }
function JWTHelper.verifyToken(token)
    local secret = getSecretKey()
    local jwt_obj = jwt:verify(secret, token)

    return {
        valid = jwt_obj.verified,
        payload = jwt_obj.payload,
        reason = jwt_obj.reason
    }
end

--- Extract userinfo from a verified token
-- @param token string The JWT token
-- @return table|nil User info or nil if invalid
function JWTHelper.getUserInfo(token)
    local result = JWTHelper.verifyToken(token)
    if result.valid and result.payload then
        return result.payload.userinfo
    end
    return nil
end

--- Extract namespace from a verified token
-- @param token string The JWT token
-- @return table|nil Namespace info or nil if not present
function JWTHelper.getNamespace(token)
    local userinfo = JWTHelper.getUserInfo(token)
    if userinfo then
        return userinfo.namespace
    end
    return nil
end

--- Check if token has namespace context
-- @param token string The JWT token
-- @return boolean
function JWTHelper.hasNamespace(token)
    local namespace = JWTHelper.getNamespace(token)
    return namespace ~= nil and namespace.uuid ~= nil
end

--- Refresh a token with extended expiration
-- Re-validates user and roles from DB to prevent stale/revoked access
-- @param token string The JWT token
-- @param expiration number|nil New expiration in seconds
-- @return string|nil New token or nil if invalid/deactivated
function JWTHelper.refreshToken(token, expiration)
    local db = require("lapis.db")

    local result = JWTHelper.verifyToken(token)
    if not result.valid then
        return nil
    end

    local userinfo = result.payload.userinfo
    if not userinfo or not userinfo.uuid then
        return nil
    end

    -- Re-validate user from DB (catches deactivated users, deleted accounts)
    local db_user = db.select("* FROM users WHERE uuid = ? AND active = true", userinfo.uuid)
    if not db_user or #db_user == 0 then
        return nil
    end
    db_user = db_user[1]

    -- Re-fetch platform roles from DB (catches role changes)
    local platform_roles = db.query([[
        SELECT r.id, r.role_name, r.role_name as name FROM roles r
        JOIN user__roles ur ON r.id = ur.role_id
        WHERE ur.user_id = ?
    ]], db_user.id)

    local user = {
        uuid = db_user.uuid,
        email = db_user.email,
        first_name = db_user.first_name,
        last_name = db_user.last_name
    }

    local options = {
        roles = platform_roles,
        expiration = expiration or DEFAULT_EXPIRATION
    }

    -- Re-fetch namespace context if present
    if userinfo.namespace and userinfo.namespace.uuid then
        local ns = db.select("* FROM namespaces WHERE uuid = ? AND status = 'active'", userinfo.namespace.uuid)
        if ns and #ns > 0 then
            options.namespace = ns[1]

            -- Re-fetch membership and permissions
            local membership = db.query([[
                SELECT nm.* FROM namespace_members nm
                JOIN namespaces n ON nm.namespace_id = n.id
                WHERE nm.user_id = ? AND n.uuid = ? AND nm.status = 'active'
            ]], db_user.id, userinfo.namespace.uuid)

            if membership and #membership > 0 then
                local raw_is_owner = membership[1].is_owner
                options.is_namespace_owner = raw_is_owner == true or raw_is_owner == 't' or raw_is_owner == 1

                -- Re-fetch namespace permissions via member's roles
                local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
                local permissions = NamespaceMemberQueries.getPermissions(membership[1].id)
                options.namespace_permissions = permissions

                -- Get namespace role name
                local member_details = NamespaceMemberQueries.getWithDetails(membership[1].id)
                if member_details and member_details.roles then
                    local roles = member_details.roles
                    if type(roles) == "string" then
                        local ok, parsed = pcall(cjson.decode, roles)
                        if ok then roles = parsed end
                    end
                    if type(roles) == "table" and #roles > 0 then
                        options.namespace_role = roles[1].role_name
                    end
                end
            else
                -- User lost membership — issue token without namespace context
                options.namespace = nil
            end
        end
    end

    return JWTHelper.generateToken(user, options)
end

--- Create a minimal token (for API keys, service accounts)
-- @param identifier string Unique identifier
-- @param options table { scope?, expiration? }
-- @return string The JWT token
function JWTHelper.createServiceToken(identifier, options)
    options = options or {}
    local now = ngx.time()

    local payload = {
        sub = identifier,
        type = "service",
        scope = options.scope or "api",
        iat = now,
        exp = now + (options.expiration or DEFAULT_EXPIRATION),
        iss = "opsapi"
    }

    return jwt:sign(getSecretKey(), {
        header = {
            typ = "JWT",
            alg = "HS256"
        },
        payload = payload
    })
end

return JWTHelper
