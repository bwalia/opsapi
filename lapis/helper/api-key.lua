--[[
    API Key Helper (helper/api-key.lua)

    Generates and authenticates namespace-scoped machine credentials.

    A raw key is "opsk_" + 48 hex chars (24 random bytes), shown once at
    creation and stored only as a SHA-256 hash (same scheme as
    helper/refresh-token.lua). At request time the key arrives as
    "Authorization: Bearer opsk_..." — the "opsk_" prefix is what routes a
    bearer token here instead of to JWT verification.

    authenticate() returns a *principal* table shaped so the rest of the
    stack works unchanged: it carries api_key = true (the discriminator
    every layer checks), the owning namespace row, and the key's scopes in
    the same {module -> [actions]} shape as namespace role permissions.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local ApiKey = {}

ApiKey.PREFIX = "opsk_"

-- How much of the raw key is kept in clear for display ("opsk_a1b2c3d").
local PREFIX_DISPLAY_LEN = 12

-- last_used_at is on the hot path; only touch it when it is older than this.
local LAST_USED_THROTTLE_SECONDS = 60

--- Does this bearer token look like an API key (vs a JWT)?
-- @param token string|nil
-- @return boolean
function ApiKey.is_api_key(token)
    return type(token) == "string" and token:sub(1, #ApiKey.PREFIX) == ApiKey.PREFIX
end

--- May a key principal touch this URI?
--
-- Scope enforcement proper lives in the namespace middleware, but plenty of
-- routes authenticate with requireAuth alone and never establish a namespace —
-- on those, nothing would check a key's scopes at all. So keys are confined
-- here, centrally and fail-closed: a key may only reach /api/v2/<module>/...
-- for a module it is actually scoped for. Anything else is refused before the
-- handler runs, including any route added later.
-- A self-service key is also held to the actions its owner chose, by HTTP method: a read-only
-- key can't write anywhere, even where a route only checks project membership (kanban).
local METHOD_ACTION = { GET = "read", HEAD = "read", OPTIONS = "read", POST = "create", PUT = "update",
    PATCH = "update", DELETE = "delete" }

local function allows(principal, actions, method)
    if not principal.self_service then return true end
    local want = METHOD_ACTION[string.upper(method or "GET")]
    if not want or type(actions) ~= "table" then return false end
    for _, a in ipairs(actions) do
        if a == want or a == "manage" then return true end
    end
    return false
end

-- @param principal table from ApiKey.authenticate
-- @param uri string ngx.var.uri
-- @param method string|nil request method (self-service keys: checked against their actions)
-- @return boolean
function ApiKey.permits_uri(principal, uri, method)
    if type(uri) ~= "string" then return false end
    -- The module is the first segment, with or without more path: a key
    -- scoped to customers may list/create (/api/v2/customers) as well as
    -- reach /api/v2/customers/{id}.
    local module_name = uri:match("^/api/v2/([^/]+)")
    if not module_name then return false end
    local scopes = principal and principal.scopes or {}
    if scopes[module_name] ~= nil then return allows(principal or {}, scopes[module_name], method) end
    -- A plugin's routes live under its api_prefix (/api/v2/helpdesk/...) while
    -- its RBAC modules are named per resource (helpdesk_tickets): a key scoped
    -- for one of the plugin's modules may reach the plugin's prefix. The
    -- route's own permission check (sdk.crud / sdk.handler) still decides.
    local ok, ProjectLoader = pcall(require, "helper.project-loader")
    if not ok then return false end
    for _, plugin in ipairs(ProjectLoader.getRegistered()) do
        local prefix = plugin.api_prefix
        if uri:sub(1, #prefix + 1) == prefix .. "/" then
            for _, m in ipairs(plugin.modules) do
                if scopes[m.machine_name] ~= nil and allows(principal or {}, scopes[m.machine_name], method) then
                    return true
                end
            end
            return false
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Self-service ("personal") keys: a member mints a key for themselves
-- (routes/api-keys.lua, /api/v2/me/api-keys). Such a key never holds more than
-- its owner: scopes are checked against the owner's role at mint time and
-- narrowed to the owner's CURRENT role on every request (authenticate below).
-- ---------------------------------------------------------------------------

ApiKey.SELF = "self"                 -- api_keys.created_via for self-service keys
ApiKey.SELF_DEFAULT_DAYS = 90
ApiKey.SELF_MAX_DAYS = 365
ApiKey.SELF_MAX_ACTIVE = 10          -- live self-service keys per user per workspace
ApiKey.SELF_CREATES_PER_HOUR = 10
-- What an AI agent / MCP server needs: read, create and update tasks (create also covers time
-- entries and comments, which are POSTs).
ApiKey.AGENT_PRESET = { kanban = { "read", "create", "update" }, projects = { "read" } }

-- Modules that manage keys, members or roles: never on a personal key.
local SELF_FORBIDDEN = { namespace = true, api_keys = true }

-- A scope that only opens a URL prefix (see permits_uri) whose routes enforce a
-- different RBAC module: every /api/v2/kanban/* route checks projects.* (the
-- kanban feature's module in helper/project-config.lua), so a member holding
-- projects.X holds kanban.X for this purpose.
local SCOPE_ALIASES = { kanban = "projects" }
-- Modules whose writes each route decides per project (project owner/admin/member/viewer), exactly as
-- for the same person in the dashboard: any access to the aliased module lets a key carry every action
-- but manage, and the route still refuses what the person can't do in that project.
local ROLE_GOVERNED = { kanban = { "read", "create", "update", "delete" } }

-- The actions a member holds on a module (alias included), as a set.
local function held(perms, module_name)
    local set = {}
    for _, m in ipairs({ module_name, SCOPE_ALIASES[module_name] }) do
        local acts = perms[m]
        if type(acts) == "table" then
            for _, a in ipairs(acts) do set[a] = true end
        end
    end
    if ROLE_GOVERNED[module_name] and next(set) ~= nil then
        for _, a in ipairs(ROLE_GOVERNED[module_name]) do set[a] = true end
    end
    return set
end

--- Narrow a key's scopes to what its owner holds now. Per module, keep the
-- actions both sides have; "manage" on one side stands for every action of the
-- other. Modules left with no action are dropped.
-- @param scopes table key scopes {module -> [actions]}
-- @param perms table the owner's permissions, same shape
-- @return table effective scopes
function ApiKey.effective_scopes(scopes, perms)
    local out = {}
    for module_name, actions in pairs(scopes or {}) do
        local have, keep = held(perms or {}, module_name), {}
        for _, a in ipairs(type(actions) == "table" and actions or {}) do
            if have.manage or have[a] then
                keep[a] = true
            elseif a == "manage" then
                for h in pairs(have) do keep[h] = true end
            end
        end
        local list = {}
        for a in pairs(keep) do list[#list + 1] = a end
        if #list > 0 then
            table.sort(list)
            out[module_name] = list
        end
    end
    return out
end

--- Validate the scopes a member asks for on their own key: every module/action
-- must be one they hold now ("manage" covers all), and never a module that
-- manages keys, members or roles.
-- @param scopes any decoded request value
-- @param perms table the caller's permissions in this workspace
-- @return table|nil normalized scopes
-- @return string|nil error message (the caller answers 422)
function ApiKey.check_self_scopes(scopes, perms)
    if type(scopes) ~= "table" or next(scopes) == nil then
        return nil, "scopes must be a non-empty object of module -> actions, e.g. {\"projects\":[\"read\"]}"
    end
    local out, denied = {}, {}
    for module_name, actions in pairs(scopes) do
        if type(module_name) ~= "string" or module_name == "" then
            return nil, "scope module names must be strings"
        end
        if SELF_FORBIDDEN[module_name] then
            return nil, "Personal API keys cannot be granted the " .. module_name .. " module"
        end
        if type(actions) ~= "table" or #actions == 0 then
            return nil, "scope actions for " .. module_name .. " must be a non-empty array"
        end
        local have, list, seen = held(perms or {}, module_name), {}, {}
        for _, a in ipairs(actions) do
            if type(a) ~= "string" or a == "" then
                return nil, "scope actions for " .. module_name .. " must be strings"
            end
            if not (have.manage or have[a]) then
                denied[#denied + 1] = module_name .. "." .. a
            elseif not seen[a] then
                seen[a] = true
                list[#list + 1] = a
            end
        end
        out[module_name] = list
    end
    if #denied > 0 then
        table.sort(denied)
        return nil, "You do not have these permissions in this workspace: " .. table.concat(denied, ", ")
    end
    return out
end

--- Days until a self-service key expires: default 90, whole days 1..365.
-- @return number|nil days
-- @return string|nil error message
function ApiKey.self_expiry_days(value)
    if value == nil then return ApiKey.SELF_DEFAULT_DAYS end
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < 1 or n > ApiKey.SELF_MAX_DAYS then
        return nil, "expires_in_days must be a whole number from 1 to " .. ApiKey.SELF_MAX_DAYS
    end
    return n
end

--- Hash a raw key with SHA-256 for storage/lookup.
-- @param raw string
-- @return string Hex-encoded SHA-256 hash
function ApiKey.hash(raw)
    local resty_sha256 = require("resty.sha256")
    local str = require("resty.string")
    local sha = resty_sha256:new()
    sha:update(raw)
    return str.to_hex(sha:final())
end

--- Generate a new key.
-- @return string raw key ("opsk_" + 48 hex) — send to the caller, never stored
-- @return string key_prefix (first 12 chars, display only)
-- @return string key_hash (SHA-256 hex, what gets persisted)
function ApiKey.generate()
    local resty_random = require("resty.random")
    local bytes = resty_random.bytes(24)
    local hex
    if bytes then
        local parts = {}
        for i = 1, #bytes do
            parts[#parts + 1] = string.format("%02x", string.byte(bytes, i))
        end
        hex = table.concat(parts)
    else
        -- Fallback (less secure, but functional)
        math.randomseed(ngx.now() * 1000 + ngx.worker.pid())
        local parts = {}
        for _ = 1, 24 do
            parts[#parts + 1] = string.format("%02x", math.random(0, 255))
        end
        hex = table.concat(parts)
    end

    local raw = ApiKey.PREFIX .. hex
    return raw, raw:sub(1, PREFIX_DISPLAY_LEN), ApiKey.hash(raw)
end

--- Opportunistically record use, at most once per throttle window.
local function touch_last_used(key_id)
    pcall(function()
        db.query([[
            UPDATE api_keys SET last_used_at = NOW()
            WHERE id = ?
              AND (last_used_at IS NULL OR last_used_at < NOW() - INTERVAL ']] ..
            LAST_USED_THROTTLE_SECONDS .. [[ seconds')
        ]], key_id)
    end)
end

--- Authenticate a raw API key.
-- @param raw string The bearer token (already known to carry the opsk_ prefix)
-- @return table|nil principal (see module docstring) if the key is valid
-- @return string|nil error message
-- @return number|nil HTTP status for the error (401 or 403)
function ApiKey.authenticate(raw)
    if not raw or raw == "" then
        return nil, "API key is required", 401
    end

    local rows = db.query([[
        SELECT ak.id, ak.uuid, ak.name, ak.namespace_id, ak.scopes,
               ak.expires_at, ak.revoked_at, ak.user_uuid, ak.created_via,
               (ak.expires_at IS NOT NULL AND ak.expires_at <= NOW()) AS is_expired,
               ns.id AS ns_id, ns.uuid AS ns_uuid, ns.slug AS ns_slug,
               ns.name AS ns_name, ns.status AS ns_status,
               u.username AS user_username, u.active AS user_active,
               nm.id AS member_id, nm.status AS member_status
        FROM api_keys ak
        JOIN namespaces ns ON ns.id = ak.namespace_id
        LEFT JOIN users u ON u.uuid = ak.user_uuid
        LEFT JOIN namespace_members nm ON nm.namespace_id = ak.namespace_id AND nm.user_id = u.id
        WHERE ak.key_hash = ?
        LIMIT 1
    ]], ApiKey.hash(raw))

    if not rows or #rows == 0 then
        return nil, "Invalid API key", 401
    end
    local row = rows[1]

    if row.revoked_at and row.revoked_at ~= ngx.null then
        return nil, "API key has been revoked", 401
    end
    if row.is_expired then
        return nil, "API key has expired", 401
    end
    if row.ns_status and row.ns_status ~= ngx.null and row.ns_status ~= "active" then
        return nil, "Namespace is not accessible", 403
    end

    local scopes = {}
    if row.scopes and row.scopes ~= ngx.null and row.scopes ~= "" then
        local ok, decoded = pcall(cjson.decode, row.scopes)
        if ok and type(decoded) == "table" then scopes = decoded end
    end

    -- A self-service key is only ever as strong as its owner is NOW: removed,
    -- suspended or deactivated owners lose it, and a demotion narrows it on the
    -- next request. getPermissions is the same cached lookup (busted on every
    -- role change) the namespace middleware runs for a session. Admin-minted
    -- keys (created_via NULL) keep their scopes as granted.
    if row.created_via == ApiKey.SELF then
        local active = row.user_active == true or row.user_active == "t"
        if not active or row.member_id == nil or row.member_id == ngx.null
            or row.member_status ~= "active" then
            return nil, "API key owner is no longer an active member of this workspace", 401
        end
        local perms = require("queries.NamespaceMemberQueries").getPermissions(row.member_id)
        scopes = ApiKey.effective_scopes(scopes, perms)
    end

    touch_last_used(row.id)

    local principal = {
        api_key = true,
        self_service = row.created_via == ApiKey.SELF,
        key_id = row.id,
        key_uuid = row.uuid,
        key_name = row.name,
        namespace_id = row.namespace_id,
        namespace = {
            id = row.ns_id,
            uuid = row.ns_uuid,
            slug = row.ns_slug,
            name = row.ns_name,
            status = row.ns_status,
        },
        scopes = scopes,
    }

    -- Identity. A user-bound key (personal access token) acts AS that user:
    -- principal.uuid = the user's uuid, so every request-time authz that reads
    -- the current user's uuid (kanban isMember/isEditor/getByAssignee, time-entry
    -- attribution, author resolution) behaves as the employee. An unbound key
    -- keeps its historical machine identity (uuid = key uuid, matches no users
    -- row). Note: namespace RBAC still evaluates the KEY's scopes, not the
    -- user's role (see middleware/namespace.lua) — this only sets identity.
    local bound = row.user_uuid
    if bound ~= nil and bound ~= ngx.null and bound ~= "" then
        principal.uuid = bound
        principal.user_bound = true
        principal.username = row.user_username or ("user:" .. bound)
    else
        principal.uuid = row.uuid
        principal.username = "api-key:" .. (row.name or row.uuid)
    end

    return principal, nil, nil
end

return ApiKey
