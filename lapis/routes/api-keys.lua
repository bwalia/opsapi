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
]]

local cjson = require("cjson")
local db = require("lapis.db")
local ApiKeyHelper = require("helper.api-key")
local ApiKeyQueries = require("queries.ApiKeyQueries")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

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
    }
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

            local rows = ApiKeyQueries.listByNamespace(self.namespace.id)
            local data = {}
            for _, row in ipairs(rows or {}) do
                data[#data + 1] = present(row)
            end
            -- cjson encodes an empty Lua table as {}; a list must stay a list.
            return { json = { success = true, data = #data > 0 and data or cjson.empty_array } }
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
end
