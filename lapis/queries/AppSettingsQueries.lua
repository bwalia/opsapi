-- App Settings Queries — issue #308
--
-- Read/write helpers for the tax_app_settings key/value table. The two
-- toggles introduced by issue #308 (allow_user_category_editing,
-- allow_user_custom_categories) live here, and any future global
-- settings can be added without a migration — just INSERT a new row.
--
-- A small in-process cache (60s TTL) sits in front of the read path
-- because the classify page hits get_public() on every render and
-- reading from Postgres on each request would be wasteful. The cache
-- is invalidated on every successful PUT, so admin changes propagate
-- immediately on the same node and within at most 60s on other nodes.
--
-- Cross-setting validation lives here, not in the route layer, so the
-- invariant ("you can't enable custom categories unless editing is
-- enabled too") is enforced regardless of which surface (Lapis,
-- FastAPI, internal call) sets the value.

local db = require("lapis.db")
local cjson = require("cjson")

local AppSettingsQueries = {}

-- ---------------------------------------------------------------------------
-- In-process cache
-- ---------------------------------------------------------------------------

local _cache = nil          -- { [key] = row } where row.setting_value is decoded
local _cache_loaded_at = 0
local CACHE_TTL_SECONDS = 60

local function decode_value(raw, setting_type)
    -- setting_value is stored as JSONB in Postgres. Lapis returns it as a
    -- string for many JSONB columns; defensively decode and coerce.
    if raw == nil then return nil end
    if type(raw) == "string" then
        local ok, decoded = pcall(cjson.decode, raw)
        if ok then return decoded end
        -- Some clients return the literal text already (booleans / numbers).
        if setting_type == "boolean" then
            return raw == "true"
        elseif setting_type == "integer" then
            return tonumber(raw)
        end
        return raw
    end
    return raw
end

local function load_all()
    local rows = db.select("* FROM tax_app_settings ORDER BY category, setting_key")
    local cache = {}
    for _, row in ipairs(rows) do
        cache[row.setting_key] = {
            id = row.id,
            setting_key = row.setting_key,
            setting_value = decode_value(row.setting_value, row.setting_type),
            setting_type = row.setting_type,
            description = row.description,
            category = row.category,
            is_admin_only = row.is_admin_only,
            updated_by_user_uuid = row.updated_by_user_uuid,
            updated_at = row.updated_at,
            created_at = row.created_at,
        }
    end
    _cache = cache
    _cache_loaded_at = os.time()
end

local function ensure_cache()
    if _cache == nil or (os.time() - _cache_loaded_at) > CACHE_TTL_SECONDS then
        load_all()
    end
end

function AppSettingsQueries.invalidate()
    _cache = nil
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- Return all settings (admin-facing — includes admin-only ones).
function AppSettingsQueries.list(params)
    params = params or {}
    ensure_cache()

    local result = {}
    for _, row in pairs(_cache) do
        local include = true
        if params.category and row.category ~= params.category then
            include = false
        end
        if include then
            table.insert(result, row)
        end
    end
    -- Stable order
    table.sort(result, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.setting_key < b.setting_key
    end)
    return result
end

-- Return settings safe to expose to non-admin users (is_admin_only = false).
-- The classify page calls this to learn whether the two #308 flags are on.
function AppSettingsQueries.list_public()
    ensure_cache()
    local result = {}
    for _, row in pairs(_cache) do
        if not row.is_admin_only then
            -- Strip admin metadata from the public payload — frontend doesn't
            -- need (and shouldn't see) who last changed it.
            table.insert(result, {
                setting_key = row.setting_key,
                setting_value = row.setting_value,
                setting_type = row.setting_type,
                description = row.description,
                category = row.category,
            })
        end
    end
    table.sort(result, function(a, b) return a.setting_key < b.setting_key end)
    return result
end

function AppSettingsQueries.get(key)
    ensure_cache()
    return _cache[key]
end

-- Convenience: typed boolean read for hot-path callers (classify page,
-- transaction PATCH endpoint). Returns the explicit default if the row
-- is missing rather than nil — never let a missing row enable a feature.
function AppSettingsQueries.get_bool(key, default_value)
    local row = AppSettingsQueries.get(key)
    if not row then return default_value end
    if type(row.setting_value) == "boolean" then return row.setting_value end
    return default_value
end

-- ---------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------

-- Cross-setting invariants enforced in code so every write path
-- (REST, internal, future MCP/CLI) goes through the same gate.
local function validate_cross_setting(key, new_value)
    if key == "allow_user_custom_categories" and new_value == true then
        local editing_enabled = AppSettingsQueries.get_bool(
            "allow_user_category_editing", false
        )
        if not editing_enabled then
            return false,
                "Cannot enable allow_user_custom_categories while " ..
                "allow_user_category_editing is false. Enable category " ..
                "editing first."
        end
    end
    if key == "allow_user_category_editing" and new_value == false then
        -- Disabling editing should also disable custom categories — they're
        -- meaningless without editing. Don't block the write; the route
        -- layer will cascade the change.
    end
    return true
end

-- Validate that `value` matches the declared setting_type. Returns
-- (ok, error_message). Strict — callers that pass strings for boolean
-- columns are rejected so shapes stay consistent across the system.
local function validate_type(setting_type, value)
    if setting_type == "boolean" then
        if type(value) ~= "boolean" then
            return false, "Expected boolean, got " .. type(value)
        end
    elseif setting_type == "integer" then
        if type(value) ~= "number" or value ~= math.floor(value) then
            return false, "Expected integer, got " .. type(value)
        end
    elseif setting_type == "string" then
        if type(value) ~= "string" then
            return false, "Expected string, got " .. type(value)
        end
    elseif setting_type == "object" then
        if type(value) ~= "table" then
            return false, "Expected object, got " .. type(value)
        end
    elseif setting_type == "array" then
        if type(value) ~= "table" then
            return false, "Expected array, got " .. type(value)
        end
    end
    return true
end

-- Update a setting. Returns (row, error). On success returns
-- (updated_row, nil). On validation failure returns (nil, error_message).
-- Wraps the cascade (disabling editing also disables customs) in a
-- single transaction so partial state can never leak.
function AppSettingsQueries.set(key, new_value, updated_by_user_uuid)
    -- Read current row to know its setting_type
    local existing = db.select(
        "* FROM tax_app_settings WHERE setting_key = ? LIMIT 1", key
    )
    if not existing or #existing == 0 then
        return nil, "Setting '" .. key .. "' does not exist"
    end
    local row = existing[1]

    local ok, type_err = validate_type(row.setting_type, new_value)
    if not ok then return nil, type_err end

    local ok2, cross_err = validate_cross_setting(key, new_value)
    if not ok2 then return nil, cross_err end

    db.query("BEGIN")
    local txn_ok, txn_err = pcall(function()
        db.update("tax_app_settings", {
            setting_value = db.raw(db.escape_literal(cjson.encode(new_value)) .. "::jsonb"),
            updated_by_user_uuid = updated_by_user_uuid,
            updated_at = db.raw("NOW()"),
        }, { setting_key = key })

        -- Cascade: if editing is being disabled, also force custom
        -- categories OFF. They're meaningless without editing and leaving
        -- them ON would be confusing for the next admin.
        if key == "allow_user_category_editing" and new_value == false then
            db.update("tax_app_settings", {
                setting_value = db.raw("'false'::jsonb"),
                updated_by_user_uuid = updated_by_user_uuid,
                updated_at = db.raw("NOW()"),
            }, { setting_key = "allow_user_custom_categories" })
        end
    end)

    if not txn_ok then
        db.query("ROLLBACK")
        return nil, "Transaction failed: " .. tostring(txn_err)
    end
    db.query("COMMIT")

    AppSettingsQueries.invalidate()

    return AppSettingsQueries.get(key), nil
end

return AppSettingsQueries
