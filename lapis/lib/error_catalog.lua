--[[
    Error Catalog Lookup (Lua mirror of backend/app/errors/catalog.py)

    Reads from the same `message_catalog` and `message_translations` tables
    the Python FastAPI side writes to, giving OpsAPI auth endpoints the
    exact same response envelope and localisation story without
    duplicating the translation files.

    Caching strategy
    ---------------
    - Per-worker cache keyed by "<code>::<locale>" in ngx.shared.cache (50MB).
    - 5-minute TTL matches the Python snapshot. Python's translation-reload
      endpoint doesn't invalidate the Lua cache today; in the worst case
      an edit goes live 5 minutes later on the Lapis side. Acceptable.
    - On DB error, fall back to a hardcoded English string. Rate-limit
      failures must never take down login.

    Contract
    --------
    Errors.resolve(code, locale, context) → {
        code            = "AUTH_401",
        catalog_uuid    = "uuid-or-empty",
        category        = "error",
        http_status     = 401,
        locale          = "hi",           -- locale actually served
        user_message    = "कृपया साइन इन करें।",
        title           = "साइन इन आवश्यक है",   -- may be nil
        is_fallback_locale = false,
    }
]]

local db = require("lapis.db")

local Catalog = {}

local CACHE_DICT = "cache"
local CACHE_TTL_SECONDS = 300
local CACHE_KEY_PREFIX = "err_catalog:"

-- Final fallback when the DB is unreachable at boot or during an outage.
-- English, deliberately terse — we never want the limiter path to crash.
local HARDCODED_FALLBACK = {
    code = "SYSTEM_500",
    catalog_uuid = "",
    category = "error",
    http_status = 500,
    locale = "en",
    user_message = "Something went wrong on our side. Please try again in a moment.",
    title = "Something went wrong",
    is_fallback_locale = true,
}


--- Interpolate {placeholder} tokens. Missing keys stay literal, as in Python.
-- @param template string
-- @param context table or nil
-- @return string
local function interpolate(template, context)
    if not context or type(context) ~= "table" then
        return template
    end
    return (template:gsub("{(%w+)}", function(key)
        local v = context[key]
        if v == nil then
            return "{" .. key .. "}"
        end
        return tostring(v)
    end))
end


--- Read one catalog row + its preferred translation from Postgres.
-- Performs two small SELECTs rather than a JOIN; the second query only
-- runs when the first hits. Both tables are small (tens to hundreds of
-- rows) so this is well under 5ms end-to-end.
local function read_from_db(code, locale)
    local cat = db.select(
        "uuid, code, category, severity, http_status, default_locale "
        .. "FROM message_catalog WHERE code = ? AND is_active = true LIMIT 1",
        code
    )
    if not cat or #cat == 0 then
        return nil
    end
    local row = cat[1]

    -- Preferred locale → catalog's default_locale → English → any.
    local candidates = { locale, row.default_locale, "en" }
    for _, loc in ipairs(candidates) do
        if loc and loc ~= "" then
            local tx = db.select(
                "user_message, title, locale FROM message_translations "
                .. "WHERE catalog_uuid = ? AND locale = ? LIMIT 1",
                row.uuid, loc
            )
            if tx and tx[1] then
                return row, tx[1]
            end
        end
    end

    -- Last-ditch: grab any translation for this code.
    local tx = db.select(
        "user_message, title, locale FROM message_translations "
        .. "WHERE catalog_uuid = ? LIMIT 1",
        row.uuid
    )
    if tx and tx[1] then
        return row, tx[1]
    end

    return row, nil
end


--- Resolve a code + locale into a fully materialised message.
-- Cache hits bypass the DB entirely; cache misses fill the cache.
-- @param code string    catalog code e.g. "AUTH_401"
-- @param locale string  requested locale e.g. "hi"
-- @param context table  optional placeholder values
-- @return table ResolvedMessage
function Catalog.resolve(code, locale, context)
    locale = locale or "en"
    if not code or code == "" then
        code = "SYSTEM_500"
    end

    local cache_key = CACHE_KEY_PREFIX .. code .. "::" .. locale
    local cached
    local dict = ngx.shared[CACHE_DICT]
    if dict then
        cached = dict:get(cache_key)
    end

    local built
    if cached then
        -- ngx.shared only stores scalars, so we store JSON-encoded struct.
        local ok, decoded = pcall(require("cjson").decode, cached)
        if ok and type(decoded) == "table" then
            built = decoded
        end
    end

    if not built then
        local ok, catalog_row, tx_row = pcall(read_from_db, code, locale)
        if not ok or not catalog_row then
            if not ok then
                ngx.log(ngx.ERR, "error_catalog: DB read failed for code=", code, " err=", tostring(catalog_row))
            end
            return {
                code = HARDCODED_FALLBACK.code,
                catalog_uuid = HARDCODED_FALLBACK.catalog_uuid,
                category = HARDCODED_FALLBACK.category,
                http_status = HARDCODED_FALLBACK.http_status,
                locale = HARDCODED_FALLBACK.locale,
                user_message = HARDCODED_FALLBACK.user_message,
                title = HARDCODED_FALLBACK.title,
                is_fallback_locale = true,
            }
        end

        local used_locale = tx_row and tx_row.locale or locale
        local user_message = tx_row and tx_row.user_message or HARDCODED_FALLBACK.user_message
        local title = tx_row and tx_row.title or nil

        built = {
            code = catalog_row.code,
            catalog_uuid = catalog_row.uuid,
            category = catalog_row.category or "error",
            http_status = tonumber(catalog_row.http_status) or 500,
            locale = used_locale,
            user_message = user_message,
            title = title,
            is_fallback_locale = used_locale ~= locale,
        }

        if dict then
            local ok_set, err = dict:set(cache_key, require("cjson").encode(built), CACHE_TTL_SECONDS)
            if not ok_set then
                ngx.log(ngx.WARN, "error_catalog: cache set failed: ", tostring(err))
            end
        end
    end

    -- Interpolate AFTER caching so the same cached template serves many
    -- callers with different contexts without growing the cache.
    local msg = interpolate(built.user_message, context)
    local title = built.title and interpolate(built.title, context) or nil

    return {
        code = built.code,
        catalog_uuid = built.catalog_uuid,
        category = built.category,
        http_status = built.http_status,
        locale = built.locale,
        user_message = msg,
        title = title,
        is_fallback_locale = built.is_fallback_locale,
    }
end


--- Force the per-worker cache to reload on next request.
-- Useful in tests and after a translation reload. Because each worker
-- has its own shared dict slice we can only invalidate for this worker
-- here; an HTTP reload endpoint that loops across workers would be
-- overkill for now.
function Catalog.invalidate()
    local dict = ngx.shared[CACHE_DICT]
    if not dict then return end
    -- flush_all is cheap; rate-limit entries in the same dict re-create
    -- themselves on next use, so the blast radius is negligible.
    -- If this cache ever shares the dict with long-lived data we'll
    -- switch to prefix-based deletion.
    local keys = dict:get_keys(0) or {}
    for _, key in ipairs(keys) do
        if key:sub(1, #CACHE_KEY_PREFIX) == CACHE_KEY_PREFIX then
            dict:delete(key)
        end
    end
end


return Catalog
