--[[
    Plugins per workspace: on/off and settings
    ==========================================

    A plugin is installed for the whole deployment; each workspace (namespace)
    can turn it off, and fills in the settings its manifest declares:

        default_enabled = false,      -- opt-in: off until a workspace turns it on
        settings = {
            auto_close_days = { type = "integer", label = "Close pending tickets after (days)",
                                default = 14, min = 1, max = 365 },
            slack_webhook_url = { type = "url", label = "Slack webhook", secret = true },
        },

    Rules are sdk.validate's (type, required, min, max, enum, label) plus
    `default`, `description` and `secret` (stored encrypted, never returned by
    the API). Plugin code reads them with sdk.settings(self), event.settings
    and job.settings.

    Off is a hard switch for that workspace, whatever the caller's role: its
    routes answer 404 (middleware/namespace.lua), no event deliveries or jobs
    are queued for it (opsapi_plugin_enabled() in the event trigger, emit and
    the job claim), and its sidebar entries and pages disappear.

    Tables: plugins (code, default_enabled: synced from manifests on migrate)
    and namespace_plugins (namespace_id, plugin_code, enabled: NULL = the
    plugin's default, settings jsonb).
]]

local cjson = require("cjson")

local PluginWorkspaces = {}

local function db()
    return require("lapis.db")
end

local SETTING_NAME = "^[a-z][a-z0-9_]*$"
-- sdk.validate types a setting can have (json would need its own editor).
local SETTING_TYPES = {
    string = true, text = true, integer = true, number = true, boolean = true,
    date = true, datetime = true, email = true, url = true, uuid = true,
}

--- Validate a manifest's `settings` table. @return nil when valid, else a message
function PluginWorkspaces.checkSettings(settings)
    if settings == nil then return nil end
    if type(settings) ~= "table" or settings[1] ~= nil then
        return "settings must be a table like { auto_close_days = { type = \"integer\", default = 14 } }"
    end
    local sdk = require("helper.plugin-sdk")
    for name, rule in pairs(settings) do
        if type(name) ~= "string" or not name:match(SETTING_NAME) then
            return "setting " .. tostring(name) .. ": use lowercase letters, digits and _"
        end
        if type(rule) ~= "table" then return "setting " .. name .. " must be a table of rules" end
        local t = rule.type or "string"
        if not SETTING_TYPES[t] then
            return "setting " .. name .. ": type must be one of string, text, integer, number, boolean, "
                .. "date, datetime, email, url, uuid"
        end
        if rule.secret and t ~= "string" and t ~= "text" and t ~= "url" then
            return "setting " .. name .. ": only string, text and url settings can be secret"
        end
        if rule.secret and rule.default ~= nil then
            return "setting " .. name .. ": a secret can't have a default"
        end
        if rule.default ~= nil then
            local _, errors = sdk.validate({ [name] = rule.default }, { [name] = rule })
            if errors then return "setting " .. name .. ": default " .. errors[name] end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Schema (helper.project-migrator, on every migrate)
-- ---------------------------------------------------------------------------

function PluginWorkspaces.ensureSchema()
    local q = db().query
    q([[
        CREATE TABLE IF NOT EXISTS plugins (
            code VARCHAR(100) PRIMARY KEY,
            default_enabled BOOLEAN NOT NULL DEFAULT true,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    q([[
        CREATE TABLE IF NOT EXISTS namespace_plugins (
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            plugin_code VARCHAR(100) NOT NULL,
            enabled BOOLEAN,
            settings JSONB NOT NULL DEFAULT '{}'::jsonb,
            updated_by VARCHAR(255),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (namespace_id, plugin_code)
        )
    ]])
    -- The one definition of "is this plugin on in this workspace", used by the
    -- event trigger, emit(), the job claim and isEnabled(). Unknown plugins
    -- (and workspace webhooks / core subscribers) count as on.
    q([==[
        CREATE OR REPLACE FUNCTION opsapi_plugin_enabled(p_code text, p_ns bigint) RETURNS boolean
        LANGUAGE sql STABLE AS $fn$
            SELECT COALESCE(
                (SELECT np.enabled FROM namespace_plugins np
                 WHERE np.namespace_id = p_ns AND np.plugin_code = p_code),
                (SELECT p.default_enabled FROM plugins p WHERE p.code = p_code),
                true)
        $fn$
    ]==])
end

--- Record a plugin's default (manifest default_enabled) for the SQL check.
function PluginWorkspaces.syncPlugin(manifest)
    db().query([[
        INSERT INTO plugins (code, default_enabled) VALUES (?, ?)
        ON CONFLICT (code) DO UPDATE SET default_enabled = EXCLUDED.default_enabled, updated_at = NOW()
        WHERE plugins.default_enabled IS DISTINCT FROM EXCLUDED.default_enabled
    ]], manifest.code, manifest.default_enabled ~= false)
end

local function ready()
    return require("helper.table-exists")("namespace_plugins")
end

-- ---------------------------------------------------------------------------
-- On / off
-- ---------------------------------------------------------------------------

--- Is the plugin on in this workspace? (true before the tables exist: nothing
-- can have been turned off yet.)
function PluginWorkspaces.isEnabled(code, namespace_id)
    if not namespace_id or not ready() then return true end
    return db().query("SELECT opsapi_plugin_enabled(?, ?) AS on", code, namespace_id)[1].on == true
end

--- The plugins among `codes` that are off in this workspace, as a set.
function PluginWorkspaces.disabledIn(namespace_id, codes)
    local off = {}
    if not namespace_id or #codes == 0 or not ready() then return off end
    local d = db()
    local list = {}
    for i, c in ipairs(codes) do list[i] = d.escape_literal(c) end
    for _, r in ipairs(d.query("SELECT c AS code FROM unnest(ARRAY[" .. table.concat(list, ", ")
        .. "]::text[]) c WHERE NOT opsapi_plugin_enabled(c, " .. tonumber(namespace_id) .. ")")) do
        off[r.code] = true
    end
    return off
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function stored_row(code, namespace_id)
    if not namespace_id or not ready() then return nil end
    local row = db().query("SELECT enabled, settings FROM namespace_plugins WHERE namespace_id = ? AND plugin_code = ?",
        namespace_id, code)[1]
    if row and type(row.settings) == "string" then row.settings = cjson.decode(row.settings) end
    return row
end

local function decrypt(value)
    local ok, plain = pcall(require("helper.global").decryptSecret, value)
    if ok then return plain end
    ngx.log(ngx.ERR, "[plugins] a secret setting could not be decrypted (OPENSSL_SECRET_KEY changed?)")
    return nil
end

--- A workspace's settings for a plugin: stored values, else defaults.
-- Secrets come back decrypted, for plugin code only.
function PluginWorkspaces.settings(manifest, namespace_id)
    local row = stored_row(manifest.code, namespace_id)
    local stored = row and row.settings or {}
    local out = {}
    for name, rule in pairs(manifest.settings or {}) do
        local v = stored[name]
        if v == cjson.null then v = nil end
        if v ~= nil and rule.secret then v = decrypt(v) end
        if v == nil then v = rule.default end
        out[name] = v
    end
    return out
end

local function sorted_settings(manifest)
    local names = {}
    for name in pairs(manifest.settings or {}) do names[#names + 1] = name end
    table.sort(names, function(a, b) -- required first, then by name
        local ra, rb = manifest.settings[a].required and 1 or 0, manifest.settings[b].required and 1 or 0
        if ra ~= rb then return ra > rb end
        return a < b
    end)
    return names
end

local function humanize(name)
    return (name:gsub("_", " "):gsub("^%l", string.upper))
end

--- The plugin as a workspace admin sees it: on/off, and each setting with its
-- value (secrets: only whether one is set).
function PluginWorkspaces.describe(manifest, namespace_id)
    local row = stored_row(manifest.code, namespace_id)
    local stored = row and row.settings or {}
    local enabled = row and row.enabled
    if enabled == nil or enabled == db().NULL then enabled = manifest.default_enabled ~= false end

    local settings = {}
    for _, name in ipairs(sorted_settings(manifest)) do
        local rule = manifest.settings[name]
        local v = stored[name]
        if v == cjson.null then v = nil end
        local s = {
            name = name, label = rule.label or humanize(name), type = rule.type or "string",
            description = rule.description, required = rule.required == true,
            enum = rule.enum, min = rule.min, max = rule.max, secret = rule.secret == true,
        }
        if rule.secret then
            s.is_set = v ~= nil
        else
            s.default = rule.default
            s.value = v
        end
        settings[#settings + 1] = s
    end
    return {
        code = manifest.code, name = manifest.name, description = manifest.description,
        version = manifest.version, enabled = enabled, default_enabled = manifest.default_enabled ~= false,
        settings = setmetatable(settings, cjson.array_mt),
    }
end

--- Change a workspace's on/off and settings. input = { enabled?, settings? }:
-- settings are partial (only the names sent change); null or "" clears one
-- (back to its default). Turning a plugin on needs its required settings.
-- @return after, before (describe()), or nil, status, message, details
function PluginWorkspaces.update(manifest, namespace_id, input, actor_uuid)
    local d = db()
    local sdk = require("helper.plugin-sdk")
    local rules = manifest.settings or {}

    if input.enabled ~= nil and type(input.enabled) ~= "boolean" then
        return nil, 422, "Validation failed", { enabled = "must be true or false" }
    end
    local sets, clears = {}, {}
    if input.settings ~= nil then
        if type(input.settings) ~= "table" or input.settings[1] ~= nil then
            return nil, 422, "Validation failed", { settings = "must be an object" }
        end
        local errors = {}
        for name in pairs(input.settings) do
            if not rules[name] then errors[name] = "isn't a setting of this plugin" end
        end
        local clean, invalid = sdk.validate(input.settings, rules, true)
        for name, msg in pairs(invalid or {}) do errors[name] = msg end
        if next(errors) then return nil, 422, "Validation failed", errors end
        for name, v in pairs(clean) do
            if v == d.NULL or v == "" then
                clears[#clears + 1] = name
            elseif rules[name].secret then
                sets[name] = require("helper.global").encryptSecret(v)
            else
                sets[name] = v
            end
        end
    end

    local before = PluginWorkspaces.describe(manifest, namespace_id)
    local turning_on = input.enabled == true or (input.enabled == nil and before.enabled)
    if turning_on then
        local current = stored_row(manifest.code, namespace_id)
        current = current and current.settings or {}
        local missing = {}
        for name, rule in pairs(rules) do
            local has = (sets[name] ~= nil) or (current[name] ~= nil and current[name] ~= cjson.null)
            for _, c in ipairs(clears) do if c == name then has = false end end
            if rule.required and not has and rule.default == nil then missing[name] = "is required" end
        end
        if next(missing) then
            return nil, 422, manifest.name .. " needs these settings before it can be turned on", missing
        end
    end

    d.query([[
        INSERT INTO namespace_plugins (namespace_id, plugin_code, enabled, settings, updated_by, updated_at)
        VALUES (?, ?, ?, ?::jsonb, ?, NOW())
        ON CONFLICT (namespace_id, plugin_code) DO UPDATE SET
            enabled = COALESCE(EXCLUDED.enabled, namespace_plugins.enabled),
            settings = (namespace_plugins.settings || EXCLUDED.settings)
                       - ARRAY(SELECT jsonb_array_elements_text(?::jsonb)),
            updated_by = EXCLUDED.updated_by, updated_at = NOW()
    ]], namespace_id, manifest.code, input.enabled == nil and d.NULL or input.enabled,
        -- (an empty Lua table must be the object {}: the app sets cjson to encode it as [])
        next(sets) and cjson.encode(sets) or "{}", actor_uuid or d.NULL,
        cjson.encode(setmetatable(clears, cjson.array_mt)))
    return PluginWorkspaces.describe(manifest, namespace_id), before
end

return PluginWorkspaces
