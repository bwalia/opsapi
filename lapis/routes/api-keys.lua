--[[
    API Key Management Routes
    =========================

    Create, list and revoke namespace-scoped machine credentials (API keys).
    A key authenticates as "Authorization: Bearer opsk_..." and can only do
    what its scopes grant, inside its own namespace.

    All endpoints require a real user session (JWT) with namespace admin
    rights (owner or namespace.manage) — an API key can never manage keys.

      POST   /api/v2/api-keys        {name, scopes, expires_at?} → raw key, once
      GET    /api/v2/api-keys        list (never returns the key or its hash)
      DELETE /api/v2/api-keys/:uuid  revoke (idempotent)

    Self-service personal keys — any active member, for themselves only (still
    a JWT session; keys cannot mint keys). Bound to the caller, never stronger
    than the caller's role (checked now and on every request, helper/api-key.lua):

      POST   /api/v2/me/api-keys        {name, scopes?, expires_in_days?} → raw key, once
      GET    /api/v2/me/api-keys        the caller's own self-service keys here
      DELETE /api/v2/me/api-keys/:uuid  revoke one of them (404 for anyone else's)
]]

local cjson = require("cjson")
local db = require("lapis.db")
local ApiKeyHelper = require("helper.api-key")
local ApiKeyQueries = require("queries.ApiKeyQueries")
local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
local NamespaceAuditLogQueries = require("queries.NamespaceAuditLogQueries")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RateLimit = require("middleware.rate-limit")

local function parse_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then return nil end
    local ok, decoded = pcall(cjson.decode, body)
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded
end

--- Validate the scopes object: non-empty {module -> [action strings]}.
-- Refuses the "namespace" module so a key can never mint or manage keys,
-- members or roles (no self-escalation).
-- @return table|nil normalized scopes
-- @return string|nil error message
local function validate_scopes(scopes)
    if type(scopes) ~= "table" or next(scopes) == nil then
        return nil, "scopes must be a non-empty object of module -> actions, e.g. {\"cms\":[\"create\"]}"
    end
    local out = {}
    for module_name, actions in pairs(scopes) do
        if type(module_name) ~= "string" or module_name == "" then
            return nil, "scope module names must be strings"
        end
        if module_name == "namespace" then
            return nil, "API keys cannot be granted the namespace module"
        end
        if type(actions) ~= "table" or #actions == 0 then
            return nil, "scope actions for '" .. module_name .. "' must be a non-empty array"
        end
        local list = {}
        for _, action in ipairs(actions) do
            if type(action) ~= "string" or action == "" then
                return nil, "scope actions for '" .. module_name .. "' must be strings"
            end
            list[#list + 1] = action
        end
        out[module_name] = list
    end
    return out
end

--- Shared guard: keys cannot manage keys.
local function refuse_api_key_auth(self)
    if self.api_key_auth then
        return { json = { error = "API keys cannot manage API keys" }, status = 403 }
    end
    return nil
end

--- A list row with a computed revoked flag.
local function present(row)
    local revoked_at = row.revoked_at ~= ngx.null and row.revoked_at or nil
    local scopes = {}
    if row.scopes and row.scopes ~= ngx.null and row.scopes ~= "" then
        local ok, decoded = pcall(cjson.decode, row.scopes)
        if ok then scopes = decoded end
    end
    return {
        uuid = row.uuid,
        name = row.name,
        key_prefix = row.key_prefix,
        scopes = scopes,
        last_used_at = row.last_used_at ~= ngx.null and row.last_used_at or nil,
        expires_at = row.expires_at ~= ngx.null and row.expires_at or nil,
        revoked_at = revoked_at,
        revoked = revoked_at ~= nil,
        created_at = row.created_at,
        -- Which user this key acts as (nil = machine key).
        user_uuid = (row.user_uuid ~= nil and row.user_uuid ~= ngx.null and row.user_uuid ~= "") and row.user_uuid or nil,
        -- "self" = minted by its owner (self-service); nil = by an admin.
        created_via = row.created_via ~= ngx.null and row.created_via or nil,
    }
end

local function list_json(rows)
    local data = {}
    for _, row in ipairs(rows or {}) do
        data[#data + 1] = present(row)
    end
    -- cjson encodes an empty Lua table as {}; a list must stay a list.
    return { json = { success = true, data = #data > 0 and data or cjson.empty_array } }
end

--- Self-service endpoints: a real session of an active member of this
-- workspace. Platform admins who are not members have no role to bound a key.
local function member_session(handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
        local refused = refuse_api_key_auth(self)
        if refused then return refused end
        if not self.namespace_membership then
            return {
                json = { error = "Only members of this workspace can have personal API keys" },
                status = 403
            }
        end
        return handler(self)
    end))
end

local function audit(self, action, key_uuid, values)
    pcall(NamespaceAuditLogQueries.log, {
        namespace_id = self.namespace.id,
        user_id = self.namespace_membership.user_id,
        action = action,
        entity_type = "api_key",
        entity_id = key_uuid,
        new_values = values,
        ip_address = RateLimit.getClientIP(),
        user_agent = self.req.headers["user-agent"],
    })
end

return function(app)
    app:post("/api/v2/api-keys", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireAdmin(function(self)
            local refused = refuse_api_key_auth(self)
            if refused then return refused end

            local body = parse_body()
            if not body then
                return { json = { error = "Invalid JSON body" }, status = 400 }
            end
            if type(body.name) ~= "string" or body.name == "" then
                return { json = { error = "name is required" }, status = 400 }
            end
            local scopes, scopes_err = validate_scopes(body.scopes)
            if not scopes then
                return { json = { error = scopes_err }, status = 400 }
            end
            -- Passed straight into the INSERT, so anything Postgres cannot read
            -- as a timestamp would surface as a 500. Check the shape here.
            if body.expires_at ~= nil then
                if type(body.expires_at) ~= "string"
                    or not body.expires_at:match("^%d%d%d%d%-%d%d%-%d%d") then
                    return {
                        json = { error = "expires_at must be a timestamp string, e.g. 2027-01-31 or 2027-01-31T09:00:00Z" },
                        status = 400
                    }
                end
            end

            -- Optional: bind the key to a user (a "personal access token" that
            -- authenticates AS that user). The user must be a member of THIS
            -- namespace — this blocks an admin from minting a key that acts as
            -- someone outside their tenant. Unbound keys stay machine credentials.
            local user_uuid
            if body.user_uuid ~= nil and body.user_uuid ~= "" then
                if type(body.user_uuid) ~= "string" then
                    return { json = { error = "user_uuid must be a string" }, status = 400 }
                end
                local membership = NamespaceMemberQueries.findByUserAndNamespace(body.user_uuid, self.namespace.id)
                if not membership then
                    return {
                        json = { error = "user_uuid must be a member of this namespace" },
                        status = 400
                    }
                end
                user_uuid = body.user_uuid
            end

            -- The acting user's DB id, for the audit trail. The JWT carries
            -- the uuid; resolve it, tolerating a missing row (created_by is a
            -- soft reference).
            local created_by
            if self.current_user and self.current_user.uuid then
                local users = db.select("id from users where uuid = ?", self.current_user.uuid)
                created_by = users and users[1] and users[1].id or nil
            end

            local raw, key_prefix, key_hash = ApiKeyHelper.generate()
            local row = ApiKeyQueries.create({
                namespace_id = self.namespace.id,
                name = body.name,
                key_prefix = key_prefix,
                key_hash = key_hash,
                scopes = cjson.encode(scopes),
                created_by = created_by,
                expires_at = body.expires_at,
                user_uuid = user_uuid,
            })

            return {
                json = {
                    success = true,
                    data = {
                        key = raw,
                        uuid = row.uuid,
                        name = row.name,
                        key_prefix = row.key_prefix,
                        scopes = scopes,
                        expires_at = body.expires_at,
                        user_uuid = user_uuid,
                    },
                    meta = {
                        note = "Store this key now — it cannot be retrieved again."
                    }
                },
                status = 201
            }
        end)))

    app:get("/api/v2/api-keys", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireAdmin(function(self)
            local refused = refuse_api_key_auth(self)
            if refused then return refused end

            return list_json(ApiKeyQueries.listByNamespace(self.namespace.id))
        end)))

    app:delete("/api/v2/api-keys/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireAdmin(function(self)
            local refused = refuse_api_key_auth(self)
            if refused then return refused end

            local existing = ApiKeyQueries.findByUuidAndNamespace(
                self.params.uuid, self.namespace.id)
            if not existing then
                return { json = { error = "API key not found" }, status = 404 }
            end

            ApiKeyQueries.revoke(self.params.uuid, self.namespace.id)
            return { json = { success = true } }
        end)))

    -- ------------------------------------------------------------------
    -- Self-service personal keys
    -- ------------------------------------------------------------------

    app:get("/api/v2/me/api-keys", member_session(function(self)
        return list_json(ApiKeyQueries.listMine(self.namespace.id, self.current_user.uuid))
    end))

    app:post("/api/v2/me/api-keys", member_session(function(self)
        local body = parse_body()
        if not body then
            return { json = { error = "Invalid JSON body" }, status = 400 }
        end
        local name = type(body.name) == "string" and body.name:match("^%s*(.-)%s*$") or ""
        if name == "" or #name > 100 then
            return { json = { error = "name is required (at most 100 characters)" }, status = 422 }
        end

        -- Never more than the caller holds right now. No scopes = the AI-agent
        -- preset, narrowed to the caller's role; asked-for scopes must all be held.
        local perms = self.namespace_permissions or {}
        local scopes, scopes_err
        if body.scopes == nil or body.scopes == cjson.null then
            scopes = ApiKeyHelper.effective_scopes(ApiKeyHelper.AGENT_PRESET, perms)
            if next(scopes) == nil then
                scopes_err = "Your role in this workspace has no access to projects or tasks, "
                    .. "so the AI agent preset would grant nothing"
            end
        else
            scopes, scopes_err = ApiKeyHelper.check_self_scopes(body.scopes, perms)
        end
        if scopes_err then
            return { json = { error = scopes_err }, status = 422 }
        end

        local days, days_err = ApiKeyHelper.self_expiry_days(
            body.expires_in_days ~= cjson.null and body.expires_in_days or nil)
        if not days then
            return { json = { error = days_err }, status = 422 }
        end

        local user_uuid = self.current_user.uuid
        if ApiKeyQueries.countActiveMine(self.namespace.id, user_uuid) >= ApiKeyHelper.SELF_MAX_ACTIVE then
            return {
                json = { error = "You already have " .. ApiKeyHelper.SELF_MAX_ACTIVE
                    .. " active personal API keys in this workspace. Revoke one first." },
                status = 422
            }
        end

        local allowed, _, retry_after = RateLimit.check("me_api_keys:" .. user_uuid,
            ApiKeyHelper.SELF_CREATES_PER_HOUR, 3600)
        if not allowed then
            ngx.header["Retry-After"] = tostring(retry_after)
            return {
                json = { error = "Too many API keys created. Please try again later.", retry_after = retry_after },
                status = 429
            }
        end

        local raw, key_prefix, key_hash = ApiKeyHelper.generate()
        local row = ApiKeyQueries.create({
            namespace_id = self.namespace.id,
            name = name,
            key_prefix = key_prefix,
            key_hash = key_hash,
            scopes = cjson.encode(scopes),
            created_by = self.namespace_membership.user_id,
            expires_at = db.raw(string.format("NOW() + make_interval(days => %d)", days)),
            user_uuid = user_uuid,
            created_via = ApiKeyHelper.SELF,
        })
        audit(self, "api_key.created", row.uuid, {
            name = name, key_prefix = key_prefix, scopes = scopes,
            expires_at = row.expires_at, created_via = ApiKeyHelper.SELF,
        })

        return {
            json = {
                success = true,
                data = {
                    key = raw,
                    uuid = row.uuid,
                    name = row.name,
                    key_prefix = row.key_prefix,
                    scopes = scopes,
                    expires_at = row.expires_at,
                    created_at = row.created_at,
                    user_uuid = user_uuid,
                    created_via = ApiKeyHelper.SELF,
                },
                meta = {
                    note = "Store this key now — it cannot be retrieved again."
                }
            },
            status = 201
        }
    end))

    app:delete("/api/v2/me/api-keys/:uuid", member_session(function(self)
        -- Owner + workspace + self-service in one lookup: anyone else's key is
        -- simply "not found" (no hint that it exists).
        local key = ApiKeyQueries.findMine(self.params.uuid, self.namespace.id, self.current_user.uuid)
        if not key then
            return { json = { error = "API key not found" }, status = 404 }
        end
        if ApiKeyQueries.revoke(key.uuid, self.namespace.id) then
            audit(self, "api_key.revoked", key.uuid, {
                name = key.name, key_prefix = key.key_prefix, created_via = ApiKeyHelper.SELF,
            })
        end
        return { json = { success = true } }
    end))
end
