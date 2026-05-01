--[[
    Locale resolution for OpsAPI (Lua mirror of backend/app/errors/locale.py).

    Order of precedence:
      1. Explicit ?lang=xx query parameter.
      2. Accept-Language header, best q-value match against supported locales.
      3. Default "en".

    Supported locales are discovered once per worker from the
    message_translations table — adding a new xx.json in the Python repo
    AND reloading Python catalog is enough to enable xx here too.
]]

local db = require("lapis.db")

local Locale = {}

local DEFAULT_LOCALE = "en"
Locale.DEFAULT_LOCALE = DEFAULT_LOCALE

-- Per-worker cache of supported locales, refreshed every 5 minutes.
-- Undersized cache on a fresh worker costs one cheap SELECT; we don't need
-- cross-worker sync here.
local _supported_cache = nil
local _supported_cached_at = 0
local SUPPORTED_TTL = 300


--- Return the set of locales that have at least one translation row.
-- ``en`` is always included so the resolver never refuses the default.
-- @return table map locale → true
function Locale.supported_locales()
    local now = ngx.time()
    if _supported_cache and (now - _supported_cached_at) < SUPPORTED_TTL then
        return _supported_cache
    end

    local set = { [DEFAULT_LOCALE] = true }
    local ok, rows = pcall(db.select, "DISTINCT locale FROM message_translations")
    if ok and rows then
        for _, row in ipairs(rows) do
            if type(row.locale) == "string" and #row.locale >= 2 and #row.locale <= 3 then
                set[row.locale:lower()] = true
            end
        end
    end

    _supported_cache = set
    _supported_cached_at = now
    return set
end


--- Parse an Accept-Language header string into a ranked list.
-- Malformed entries are skipped silently — a bad header never breaks a request.
-- @param header string
-- @return table list of { locale = string, q = number } sorted by q desc
function Locale.parse_accept_language(header)
    local out = {}
    if not header or header == "" then
        return out
    end

    for raw in header:gmatch("([^,]+)") do
        local entry = raw:match("^%s*(.-)%s*$")
        if entry and entry ~= "" then
            -- "en-GB;q=0.8", "hi", "es-419"
            local lang, rest = entry:match("^([%a][%a%-_]*)(.*)$")
            if lang then
                lang = lang:gsub("[-_].*$", ""):lower()
                if #lang >= 2 and #lang <= 3 then
                    local q = 1.0
                    local qstr = rest:match("q%s*=%s*([%d%.]+)")
                    if qstr then
                        local parsed = tonumber(qstr)
                        if parsed then q = parsed end
                    end
                    table.insert(out, { locale = lang, q = q })
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.q > b.q end)
    return out
end


--- Resolve the best supported locale for a Lapis request.
-- @param self table Lapis request (accesses self.req.headers and self.params)
-- @return string two-or-three-letter ISO code, always a supported locale
function Locale.resolve(self)
    local supported = Locale.supported_locales()

    -- 1. Explicit ?lang=xx (case-insensitive).
    local qlang = self and self.params and self.params.lang
    if type(qlang) == "string" then
        local code = qlang:lower()
        if supported[code] then
            return code
        end
    end

    -- 2. Accept-Language header.
    local header
    if self and self.req and self.req.headers then
        header = self.req.headers["accept-language"] or self.req.headers["Accept-Language"]
    end
    if header then
        local ranked = Locale.parse_accept_language(header)
        for _, entry in ipairs(ranked) do
            if supported[entry.locale] then
                return entry.locale
            end
        end
    end

    return DEFAULT_LOCALE
end


return Locale
