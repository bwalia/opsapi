--[[
    Form fields: the type registry, schema normalisation and answer validation
    =========================================================================

    One registry drives everything. The builder UI, the REST API and the AI
    agent all save through Fields.normalize(), and every public answer is
    checked by Fields.validate() against the PUBLISHED version. Browser checks
    are a convenience only.

    Adding a field type = one entry in TYPES (and its renderer in the
    dashboard's components/forms/field-types.ts).

    A schema is { fields = { field, ... } }. A field:
        key          stable answer key (generated from the label, never changes)
        type         a TYPES key
        label        question / heading text
        help, placeholder, required, width ("full" | "half")
        options      { { value, label }, ... }        (choice types)
        validation   { min_length, max_length, min, max, integer,
                       min_selected, max_selected }   (per type, see below)
        scale        5 | 10                           (rating)
        text         the statement shown               (consent, paragraph)
        param        URL query parameter to read       (hidden)
        maps_to      phone | company | job_title | address | notes | marketing_consent
        system       "contact.name" | "contact.email": added because the form
                     creates records; locked (always required, type fixed)

    No user-written regex anywhere (ReDoS); text is plain text everywhere.
]]

local cjson = require("lib.forms.json")

local Fields = {}

Fields.MAX_FIELDS = 200
Fields.MAX_OPTIONS = 500
Fields.MAX_SCHEMA_BYTES = 256 * 1024

local NULL = cjson.null

-- ---------------------------------------------------------------------------
-- Text helpers
-- ---------------------------------------------------------------------------

-- Valid UTF-8 (Postgres rejects anything else with a 500-shaped error).
local function utf8_ok(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3
            or (c >= 0xF0 and c <= 0xF4) and 4 or nil
        if not len or i + len - 1 > n then return false end
        for j = i + 1, i + len - 1 do
            local b = s:byte(j)
            if b < 0x80 or b > 0xBF then return false end
        end
        i = i + len
    end
    return true
end

--- Trimmed plain text, or nil, err. `multiline` keeps \n and \t.
local function text(v, max, multiline)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" then return nil, "must be text" end
    if not utf8_ok(v) then return nil, "contains invalid characters" end
    v = v:gsub(multiline and "[%z\1-\8\11\12\14-\31\127]" or "[%z\1-\31\127]", ""):gsub("\r\n?", "\n")
    v = v:match("^%s*(.-)%s*$")
    if max and #v > max then return nil, "must be at most " .. max .. " characters" end
    return v
end
Fields.text = text

-- No answer: nil, null, "", {} or a name/address whose parts are all blank.
local function empty(v)
    if v == nil or v == NULL or v == "" then return true end
    if type(v) == "table" then
        for _, part in pairs(v) do
            if not (part == "" or part == NULL or (type(part) == "string" and part:match("^%s*$"))) then
                return false
            end
        end
        return true
    end
    return false
end

local function slug(label, max)
    local s = tostring(label or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if s == "" or not s:match("^%a") then s = "f_" .. s end
    return (s:sub(1, max or 40):gsub("_+$", ""))
end

local KEY = "^[a-z][a-z0-9_]*$"
local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- Files a form accepts: by extension, with the type the server stores (never
-- the browser's). No SVG/HTML: they could run script where they're served.
Fields.FILE_TYPES = {
    jpg = { "image/jpeg", "images" }, jpeg = { "image/jpeg", "images" }, png = { "image/png", "images" },
    gif = { "image/gif", "images" }, webp = { "image/webp", "images" }, heic = { "image/heic", "images" },
    heif = { "image/heif", "images" },
    pdf = { "application/pdf", "documents" }, txt = { "text/plain", "documents" }, csv = { "text/csv", "documents" },
    doc = { "application/msword", "documents" },
    docx = { "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "documents" },
    xls = { "application/vnd.ms-excel", "documents" },
    xlsx = { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "documents" },
    ppt = { "application/vnd.ms-powerpoint", "documents" },
    pptx = { "application/vnd.openxmlformats-officedocument.presentationml.presentation", "documents" },
}
local EMAIL = "^[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+$" -- the customers table's own check
local ISO_DATE = "^(%d%d%d%d)%-(%d%d)%-(%d%d)$"

local function valid_date(s)
    local y, m, d = tostring(s):match(ISO_DATE)
    if not y then return false end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 then return false end
    local feb = (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28
    local days = { 31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    return d <= days[m]
end

local function bool(v)
    if v == true or v == false then return v end
    local s = tostring(v):lower()
    if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
    if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    return nil
end

local function int(v, lo, hi)
    local n = tonumber(v)
    if not n or n ~= math.floor(n) or n < lo or n > hi then return nil end
    return n
end

local function option_of(field, value)
    for _, o in ipairs(field.options or {}) do
        if o.value == value then return o end
    end
end

-- ---------------------------------------------------------------------------
-- Field types
-- ---------------------------------------------------------------------------
-- define(field, raw) checks/copies type-specific properties (raw = what the
-- client sent); validate(value, field) returns the clean answer or nil, err;
-- show(value, field) is the human-readable answer (emails, CSV).
-- `input = false`: display-only (no answer). `maps`: maps_to kinds it can feed.

local function define_text_limits(cap, default_max)
    return function(f, raw)
        local v = type(raw.validation) == "table" and raw.validation or {}
        local max = v.max_length == nil and default_max or int(v.max_length, 1, cap)
        local min = v.min_length == nil and nil or int(v.min_length, 0, cap)
        if not max then return "validation.max_length must be 1-" .. cap end
        if v.min_length ~= nil and not min then return "validation.min_length must be 0-" .. cap end
        if min and min > max then return "validation.min_length is larger than max_length" end
        f.validation = { max_length = max, min_length = min }
    end
end

local function validate_text(multiline)
    return function(value, f)
        local s, err = text(value, f.validation.max_length, multiline)
        if not s then return nil, err end
        if f.validation.min_length and #s < f.validation.min_length then
            return nil, "must be at least " .. f.validation.min_length .. " characters"
        end
        return s
    end
end

local function define_options(f, raw)
    if type(raw.options) ~= "table" or #raw.options == 0 then return "needs at least one option" end
    if #raw.options > Fields.MAX_OPTIONS then return "has more than " .. Fields.MAX_OPTIONS .. " options" end
    local out, seen = {}, {}
    for i, o in ipairs(raw.options) do
        local label, value
        if type(o) == "table" then
            label, value = o.label, o.value
        else
            label = o
        end
        label = text(label, 200)
        if not label or label == "" then return "option " .. i .. " needs a label" end
        value = value ~= nil and text(value, 100)
            or (label:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""):sub(1, 100))
        if value == "" then value = "option_" .. i end
        if not value or value == "" then return "option " .. i .. " has an invalid value" end
        if seen[value] then return "option value '" .. value .. "' is used twice" end
        seen[value] = true
        out[#out + 1] = { value = value, label = label }
    end
    f.options = setmetatable(out, cjson.array_mt)
end

local function show_option(value, f)
    local o = option_of(f, value)
    return o and o.label or tostring(value)
end

Fields.TYPES = {
    short_text = {
        define = define_text_limits(1000, 255),
        validate = validate_text(false),
        maps = { phone = true, company = true, job_title = true, address = true, notes = true },
    },
    long_text = {
        define = define_text_limits(20000, 5000),
        validate = validate_text(true),
        maps = { address = true, notes = true },
    },
    email = {
        validate = function(value)
            local s = text(value, 254)
            if not s or not s:match(EMAIL) then return nil, "must be a valid email address" end
            return s
        end,
    },
    phone = {
        validate = function(value)
            local s = text(value, 30)
            if not s or not s:match("^[%d%s%+%-%(%)%.]+$") or #s:gsub("%D", "") < 5 then
                return nil, "must be a valid phone number"
            end
            return s
        end,
        maps = { phone = true },
    },
    url = {
        validate = function(value)
            local s = text(value, 2000)
            if not s or not s:match("^https?://[%w%-%.]+[^%s]*$") then
                return nil, "must be a web address starting with http:// or https://"
            end
            return s
        end,
    },
    number = {
        define = function(f, raw)
            local v = type(raw.validation) == "table" and raw.validation or {}
            local min, max = tonumber(v.min), tonumber(v.max)
            if (v.min ~= nil and not min) or (v.max ~= nil and not max) then
                return "validation.min/max must be numbers"
            end
            if min and max and min > max then return "validation.min is larger than max" end
            f.validation = { min = min, max = max, integer = bool(v.integer) == true or nil }
        end,
        validate = function(value, f)
            local n = tonumber(value)
            if not n or n ~= n or n == math.huge or n == -math.huge then return nil, "must be a number" end
            if f.validation.integer and n ~= math.floor(n) then return nil, "must be a whole number" end
            if f.validation.min and n < f.validation.min then return nil, "must be at least " .. f.validation.min end
            if f.validation.max and n > f.validation.max then return nil, "must be at most " .. f.validation.max end
            return n
        end,
    },
    date = {
        define = function(f, raw)
            local v = type(raw.validation) == "table" and raw.validation or {}
            for _, k in ipairs({ "min", "max" }) do
                if v[k] ~= nil and not valid_date(v[k]) then return "validation." .. k .. " must be YYYY-MM-DD" end
            end
            f.validation = { min = v.min, max = v.max }
        end,
        validate = function(value, f)
            if type(value) ~= "string" or not valid_date(value) then return nil, "must be a date (YYYY-MM-DD)" end
            local v = f.validation
            if v.min and value < v.min then return nil, "must be on or after " .. v.min end
            if v.max and value > v.max then return nil, "must be on or before " .. v.max end
            return value
        end,
    },
    time = {
        validate = function(value)
            local h, m = tostring(value):match("^(%d%d):(%d%d)$")
            if not h or tonumber(h) > 23 or tonumber(m) > 59 then return nil, "must be a time (HH:MM)" end
            return value
        end,
    },
    single_select = {
        define = define_options,
        validate = function(value, f)
            if not option_of(f, value) then return nil, "must be one of the options" end
            return value
        end,
        show = show_option,
    },
    radio = {
        define = define_options,
        validate = function(value, f)
            if not option_of(f, value) then return nil, "must be one of the options" end
            return value
        end,
        show = show_option,
    },
    multi_select = {
        define = function(f, raw)
            local err = define_options(f, raw)
            if err then return err end
            local v = type(raw.validation) == "table" and raw.validation or {}
            local lo = v.min_selected == nil and nil or int(v.min_selected, 0, #f.options)
            local hi = v.max_selected == nil and nil or int(v.max_selected, 1, #f.options)
            if (v.min_selected ~= nil and not lo) or (v.max_selected ~= nil and not hi) or (lo and hi and lo > hi) then
                return "validation.min_selected/max_selected must fit the number of options"
            end
            f.validation = { min_selected = lo, max_selected = hi }
        end,
        validate = function(value, f)
            if type(value) ~= "table" then value = { value } end
            local out, seen = {}, {}
            for _, v in ipairs(value) do
                if not option_of(f, v) then return nil, "must only contain the listed options" end
                if not seen[v] then
                    seen[v] = true
                    out[#out + 1] = v
                end
            end
            if f.validation.min_selected and #out < f.validation.min_selected then
                return nil, "choose at least " .. f.validation.min_selected
            end
            if f.validation.max_selected and #out > f.validation.max_selected then
                return nil, "choose at most " .. f.validation.max_selected
            end
            return setmetatable(out, cjson.array_mt)
        end,
        show = function(value, f)
            local labels = {}
            for _, v in ipairs(type(value) == "table" and value or {}) do labels[#labels + 1] = show_option(v, f) end
            return table.concat(labels, ", ")
        end,
    },
    boolean = {
        validate = function(value)
            local b = bool(value)
            if b == nil then return nil, "must be yes or no" end
            return b
        end,
        show = function(value) return value == true and "Yes" or "No" end,
        maps = { marketing_consent = true },
    },
    rating = {
        define = function(f, raw)
            local scale = raw.scale == nil and 5 or tonumber(raw.scale)
            if scale ~= 5 and scale ~= 10 then return "scale must be 5 or 10" end
            f.scale = scale
        end,
        validate = function(value, f)
            local n = int(value, 1, f.scale)
            if not n then return nil, "must be a rating from 1 to " .. f.scale end
            return n
        end,
        show = function(value, f) return tostring(value) .. "/" .. f.scale end,
    },
    consent = {
        define = function(f, raw)
            local t, err = text(raw.text, 2000, true)
            if not t or t == "" then return "needs the consent statement (text)" .. (err and (": " .. err) or "") end
            f.text = t
        end,
        -- Ticked = true; an unticked required consent is "missing" (see validate()).
        validate = function(value)
            local b = bool(value)
            if b == nil then return nil, "must be ticked or not" end
            return b
        end,
        show = function(value) return value == true and "Agreed" or "Not agreed" end,
        maps = { marketing_consent = true },
    },
    name = {
        validate = function(value)
            if type(value) == "string" then
                local first, last = value:match("^%s*(%S+)%s*(.-)%s*$")
                value = { first = first, last = last }
            end
            if type(value) ~= "table" then return nil, "must be a name" end
            local first, ferr = text(value.first or "", 100)
            local last, lerr = text(value.last or "", 100)
            if not first or not last then return nil, "name " .. (ferr or lerr) end
            if first == "" then return nil, "needs a first name" end
            return { first = first, last = last }
        end,
        show = function(value)
            return type(value) == "table" and ((value.first or "") .. " " .. (value.last or "")):gsub("%s+$", "") or ""
        end,
    },
    address = {
        validate = function(value)
            if type(value) ~= "table" then return nil, "must be an address" end
            local out = {}
            for _, k in ipairs({ "line1", "line2", "city", "postcode", "country" }) do
                local s, err = text(value[k] or "", 200)
                if not s then return nil, k .. " " .. err end
                out[k] = s
            end
            if out.line1 == "" then return nil, "needs the first address line" end
            return out
        end,
        show = function(value)
            if type(value) ~= "table" then return "" end
            local parts = {}
            for _, k in ipairs({ "line1", "line2", "city", "postcode", "country" }) do
                if value[k] and value[k] ~= "" then parts[#parts + 1] = value[k] end
            end
            return table.concat(parts, ", ")
        end,
        maps = { address = true },
    },
    -- Filled from the link's query string (?utm_source=...): never required, and
    -- as untrusted as any other answer.
    hidden = {
        define = function(f, raw)
            local p = raw.param == nil and f.key or raw.param
            if type(p) ~= "string" or not p:match("^[%w_%-]+$") or #p > 64 then
                return "param must be letters, digits, - or _"
            end
            f.param = p
            f.required = nil
        end,
        validate = function(value) return text(value, 500) end,
    },
    -- Files go up first (POST .../uploads, lib/forms/uploads.lua); the answer is
    -- their upload ids, which the submit swaps for { id, name, size, type }.
    file_upload = {
        define = function(f, raw)
            local n = raw.max_files == nil and 1 or int(raw.max_files, 1, 10)
            local mb = raw.max_size_mb == nil and 10 or int(raw.max_size_mb, 1, 10)
            local accept = raw.accept == nil and "any" or raw.accept
            if not n then return "max_files must be 1-10" end
            if not mb then return "max_size_mb must be 1-10" end
            if accept ~= "images" and accept ~= "documents" and accept ~= "any" then
                return "accept must be images, documents or any"
            end
            f.max_files, f.max_size_mb, f.accept = n, mb, accept
        end,
        validate = function(value, f)
            if type(value) ~= "table" or (value.id ~= nil) then value = { value } end
            if #value > f.max_files then return nil, "attach at most " .. f.max_files .. " file(s)" end
            local out = {}
            for _, v in ipairs(value) do
                local id = type(v) == "table" and v.id or v
                if type(id) ~= "string" or not id:match(UUID_PATTERN) then return nil, "has a file that isn't valid" end
                out[#out + 1] = id
            end
            return setmetatable(out, cjson.array_mt)
        end,
        show = function(value)
            local names = {}
            for _, v in ipairs(type(value) == "table" and value or {}) do
                names[#names + 1] = type(v) == "table" and (v.name or v.id) or tostring(v)
            end
            return table.concat(names, ", ")
        end,
    },
    heading = { input = false },
    -- Starts a new step of a multi-step form; its label (optional) titles the step.
    page_break = { input = false },
    paragraph = {
        input = false,
        define = function(f, raw)
            local t = text(raw.text or "", 5000, true)
            if not t then return "text must be plain text (max 5000)" end
            f.text = t
        end,
    },
}

Fields.TYPE_NAMES = {}
for name in pairs(Fields.TYPES) do Fields.TYPE_NAMES[#Fields.TYPE_NAMES + 1] = name end
table.sort(Fields.TYPE_NAMES)

-- Contact fields the record-creating targets need, by system role.
Fields.SYSTEM = {
    ["contact.name"] = { type = "name", label = "Name", key = "name" },
    ["contact.email"] = { type = "email", label = "Email", key = "email" },
}
local SYSTEM_ORDER = { "contact.name", "contact.email" }
local SYSTEM_RANK = { ["contact.name"] = 1, ["contact.email"] = 2 }

Fields.MAPS_TO = { "phone", "company", "job_title", "address", "notes", "marketing_consent" }

-- ---------------------------------------------------------------------------
-- Schema normalisation
-- ---------------------------------------------------------------------------

local function unique_key(base, taken)
    local key, n = base, 1
    while taken[key] do
        n = n + 1
        key = base:sub(1, 36) .. "_" .. n
    end
    taken[key] = true
    return key
end

local function normalize_field(raw, i, taken)
    if type(raw) ~= "table" then return nil, "field " .. i .. " must be an object" end
    local def = Fields.TYPES[raw.type]
    if not def then
        return nil, "field " .. i .. ": unknown type '" .. tostring(raw.type) .. "' (use one of: "
            .. table.concat(Fields.TYPE_NAMES, ", ") .. ")"
    end
    local where = "field " .. i
    local label, lerr = text(raw.label, 300)
    if not label then return nil, where .. ": label " .. lerr end
    if label == "" and raw.type ~= "paragraph" and raw.type ~= "page_break" then
        return nil, where .. ": label is required"
    end
    where = "field '" .. (label ~= "" and label or tostring(i)) .. "'"

    local key = raw.key
    if type(key) ~= "string" or not key:match(KEY) or #key > 40 or taken[key] then
        key = slug(label ~= "" and label or raw.type)
    end
    local f = {
        key = unique_key(key, taken),
        type = raw.type,
        label = label,
        required = def.input ~= false and bool(raw.required) == true or nil,
        width = raw.width == "half" and "half" or nil,
    }
    for _, k in ipairs({ "help", "placeholder" }) do
        if raw[k] ~= nil and raw[k] ~= NULL and raw[k] ~= "" then
            local v, err = text(raw[k], k == "help" and 500 or 200)
            if not v then return nil, where .. ": " .. k .. " " .. err end
            f[k] = v ~= "" and v or nil
        end
    end
    if def.define then
        local err = def.define(f, raw)
        if err then return nil, where .. ": " .. err end
    end
    if raw.maps_to ~= nil and raw.maps_to ~= NULL and raw.maps_to ~= "" then
        if not (def.maps and def.maps[raw.maps_to]) then
            return nil, where .. ": a " .. raw.type .. " field can't fill '" .. tostring(raw.maps_to) .. "'"
        end
        f.maps_to = raw.maps_to
    end
    if raw.system ~= nil and Fields.SYSTEM[raw.system] then f.system = raw.system end
    f._logic = raw.logic -- checked once every field's final position is known (clean_logic)
    return f
end

-- ---------------------------------------------------------------------------
-- Conditional logic: "show this question only if ..."
-- ---------------------------------------------------------------------------
-- field.logic = { match = "all" | "any", rules = { { field, op, value }, ... } }
-- A rule may only refer to an answer field ABOVE it, so a form reads top to
-- bottom and can't loop. A hidden question is never required and its answer
-- is dropped (Fields.validate), on the server as in the browser
-- (components/forms/logic.ts mirrors this).

local OPS = { eq = true, neq = true, ["in"] = true, not_in = true, gt = true, lt = true, filled = true,
    empty = true, contains = true }
local CHOICE = { single_select = true, radio = true, multi_select = true }
local NUMERIC = { number = true, rating = true }
Fields.MAX_RULES = 10

local function rule_value(src, op, value, where)
    if op == "filled" or op == "empty" then return nil end
    if op == "in" or op == "not_in" then
        if not CHOICE[src.type] then return nil, where .. ": 'is one of' needs a choice question" end
        if type(value) ~= "table" or #value == 0 or #value > 50 then return nil, where .. ": choose 1-50 options" end
        local out = {}
        for _, v in ipairs(value) do
            if not option_of(src, v) then return nil, where .. ": '" .. tostring(v) .. "' isn't one of its options" end
            out[#out + 1] = v
        end
        return setmetatable(out, cjson.array_mt)
    end
    if op == "gt" or op == "lt" then
        if NUMERIC[src.type] then
            local n = tonumber(value)
            if not n then return nil, where .. ": compare with a number" end
            return n
        end
        if src.type == "date" then
            if not valid_date(value) then return nil, where .. ": compare with a date (YYYY-MM-DD)" end
            return value
        end
        return nil, where .. ": 'greater/less than' needs a number, rating or date question"
    end
    if CHOICE[src.type] then
        if not option_of(src, value) then return nil, where .. ": '" .. tostring(value) .. "' isn't one of its options" end
        return value
    end
    if src.type == "boolean" or src.type == "consent" then
        local b = bool(value)
        if b == nil then return nil, where .. ": compare with yes or no" end
        return b
    end
    if NUMERIC[src.type] then
        local n = tonumber(value)
        if not n then return nil, where .. ": compare with a number" end
        return n
    end
    local t = text(value, 200)
    if not t or t == "" then return nil, where .. ": give a value to compare with" end
    return t
end

local function clean_logic(raw, earlier, where)
    if raw == nil or raw == NULL then return nil end
    if type(raw) ~= "table" then return nil, where .. ": logic must be { match, rules }" end
    local rules = raw.rules
    if rules == nil or rules == NULL or (type(rules) == "table" and #rules == 0) then return nil end
    if type(rules) ~= "table" then return nil, where .. ": logic rules must be a list" end
    if #rules > Fields.MAX_RULES then return nil, where .. ": at most " .. Fields.MAX_RULES .. " rules" end
    local out = {}
    for i, r in ipairs(rules) do
        local at = where .. " rule " .. i
        local src = type(r) == "table" and earlier[r.field]
        if not src then return nil, at .. " must refer to a question above this one" end
        if not OPS[r.op] then return nil, at .. ": unknown condition '" .. tostring(r.op) .. "'" end
        local value, err = rule_value(src, r.op, r.value, at)
        if err then return nil, err end
        out[#out + 1] = { field = r.field, op = r.op, value = value }
    end
    return { match = raw.match == "any" and "any" or "all", rules = setmetatable(out, cjson.array_mt) }
end

local function rule_ok(r, answers)
    local v = answers[r.field]
    if r.op == "filled" then return v ~= nil end
    if r.op == "empty" then return v == nil end
    if v == nil then return r.op == "neq" or r.op == "not_in" end
    if r.op == "contains" then
        if type(v) == "table" then
            for _, x in ipairs(v) do if x == r.value then return true end end
            return false
        end
        return tostring(v):lower():find(tostring(r.value):lower(), 1, true) ~= nil
    end
    if r.op == "in" or r.op == "not_in" then
        local hit = false
        for _, x in ipairs(type(v) == "table" and v or { v }) do
            for _, y in ipairs(r.value or {}) do
                if x == y then hit = true end
            end
        end
        return (r.op == "in") == hit
    end
    if r.op == "gt" or r.op == "lt" then
        local a, b = v, r.value
        if type(b) == "number" then a = tonumber(v) end
        if a == nil or type(a) ~= type(b) then return false end
        if r.op == "gt" then return a > b end
        return a < b
    end
    local same = false -- eq / neq; a multi-select "equals" a value it contains
    if type(v) == "table" then
        for _, x in ipairs(v) do if x == r.value then same = true end end
    elseif type(r.value) == "number" then
        same = tonumber(v) == r.value
    else
        same = v == r.value
    end
    return (r.op == "eq") == same
end

--- Is the field shown, given the (clean) answers above it?
function Fields.visible(field, answers)
    local logic = field.logic
    if type(logic) ~= "table" or type(logic.rules) ~= "table" or #logic.rules == 0 then return true end
    local any = logic.match == "any"
    for _, r in ipairs(logic.rules) do
        local ok = rule_ok(r, answers)
        if any and ok then return true end
        if not any and not ok then return false end
    end
    return not any
end

--- Clean and validate a schema, adding (and locking) the contact fields the
-- form's targets need. Unknown properties are dropped.
-- @param schema { fields = {...} } (or the fields list itself)
-- @param required_roles set of system roles to enforce, e.g. { ["contact.email"] = true }
-- @return schema | nil, err
function Fields.normalize(schema, required_roles)
    required_roles = required_roles or {}
    if type(schema) == "string" then
        local ok, decoded = pcall(cjson.decode, schema)
        schema = ok and decoded or nil
    end
    if type(schema) ~= "table" then return nil, "schema must be an object with a fields list" end
    local list = schema.fields or (schema[1] ~= nil and schema) or {}
    if type(list) ~= "table" then return nil, "fields must be a list" end
    if #list > Fields.MAX_FIELDS then return nil, "a form can have at most " .. Fields.MAX_FIELDS .. " fields" end

    -- System keys are reserved first so a user field can't take "name"/"email"
    -- away from the contact fields that need them.
    local taken, fields, seen_system = {}, {}, {}
    for _, raw in ipairs(list) do
        if type(raw) == "table" and Fields.SYSTEM[raw.system] and required_roles[raw.system]
            and type(raw.key) == "string" and raw.key:match(KEY) then
            taken[raw.key] = true
        end
    end
    for i, raw in ipairs(list) do
        local system = type(raw) == "table" and Fields.SYSTEM[raw.system] and raw.system or nil
        if system and required_roles[system] then
            if seen_system[system] then goto continue end -- a duplicate of a locked field
            if type(raw.key) == "string" then taken[raw.key] = nil end
            local copy = {}
            for k, v in pairs(raw) do copy[k] = v end
            copy.type = Fields.SYSTEM[system].type -- type is locked
            local f, err = normalize_field(copy, i, taken)
            if not f then return nil, err end
            f.required, f.system = true, system
            seen_system[system] = true
            fields[#fields + 1] = f
        else
            local copy = raw
            if type(raw) == "table" and raw.system then
                copy = {}
                for k, v in pairs(raw) do copy[k] = v end
                copy.system = nil -- no longer locked once its target is off
            end
            local f, err = normalize_field(copy, i, taken)
            if not f then return nil, err end
            fields[#fields + 1] = f
        end
        ::continue::
    end
    -- A missing contact field: promote the form's first field of that type
    -- (an "Email" question added before "create a customer" was ticked), else
    -- add one at the top, in a fixed order.
    local missing = {}
    for _, role in ipairs(SYSTEM_ORDER) do
        if required_roles[role] and not seen_system[role] then
            local s = Fields.SYSTEM[role]
            local promoted
            for _, f in ipairs(fields) do
                if f.type == s.type and not f.system then
                    f.system, f.required = role, true
                    promoted = true
                    break
                end
            end
            if not promoted then
                missing[#missing + 1] = {
                    key = unique_key(s.key, taken), type = s.type, label = s.label, required = true, system = role,
                }
            end
        end
    end
    -- Each goes right after the contact field before it in SYSTEM_ORDER (name,
    -- then email), else at the top.
    for _, f in ipairs(missing) do
        local at = 1
        for i, existing in ipairs(fields) do
            if existing.system and SYSTEM_RANK[existing.system] < SYSTEM_RANK[f.system] then at = i + 1 end
        end
        table.insert(fields, at, f)
    end
    if #fields > Fields.MAX_FIELDS then return nil, "a form can have at most " .. Fields.MAX_FIELDS .. " fields" end

    -- Logic, now that every field's final position is known. Locked contact
    -- fields are always shown.
    local earlier = {}
    for _, f in ipairs(fields) do
        local raw_logic = f._logic
        f._logic = nil
        if raw_logic ~= nil and not f.system then
            local logic, err = clean_logic(raw_logic, earlier, "field '" .. (f.label ~= "" and f.label or f.key) .. "'")
            if err then return nil, err end
            f.logic = logic
        end
        local def = Fields.TYPES[f.type]
        if def and def.input ~= false then earlier[f.key] = f end
    end

    local out = { fields = setmetatable(fields, cjson.array_mt) }
    if #cjson.encode(out) > Fields.MAX_SCHEMA_BYTES then return nil, "the form is too large" end
    return out
end

-- ---------------------------------------------------------------------------
-- Answers
-- ---------------------------------------------------------------------------

--- Validate answers against a (normalized, published) schema.
-- Unknown keys are dropped; display-only fields take no answer.
-- @return clean answers, nil | nil, { [key] = message }
function Fields.validate(schema, data)
    if type(data) ~= "table" then return nil, { _form = "answers must be an object" } end
    local clean, errors = {}, nil
    for _, f in ipairs(schema.fields or {}) do
        local def = Fields.TYPES[f.type]
        -- A question hidden by its logic takes no answer and isn't required.
        if def and def.input ~= false and Fields.visible(f, clean) then
            local value = data[f.key]
            local missing = empty(value) or (f.type == "consent" and bool(value) == false)
            if not missing then
                local v, err = def.validate(value, f)
                if v == nil then
                    errors = errors or {}
                    errors[f.key] = err
                elseif not empty(v) then
                    clean[f.key] = v
                else
                    missing = true
                end
            end
            if missing and f.required then
                errors = errors or {}
                errors[f.key] = f.type == "consent" and "must be ticked" or "is required"
            end
        end
    end
    if errors then return nil, errors end
    return clean
end

--- The contact (name + email) and mapped values of a response, for targets.
-- @return { email, first_name, last_name }, { phone = ..., company = ..., ... }
function Fields.contact(schema, answers)
    local contact, mapped = {}, {}
    for _, f in ipairs(schema.fields or {}) do
        local v = answers[f.key]
        if v ~= nil then
            if f.system == "contact.email" then
                contact.email = v
            elseif f.system == "contact.name" then
                contact.first_name, contact.last_name = v.first, v.last
            end
            if f.maps_to and mapped[f.maps_to] == nil then
                mapped[f.maps_to] = f.type == "address" and Fields.show(f, v) or v
            end
        end
    end
    -- No locked email field (no targets): still note who answered, if asked.
    if not contact.email then
        for _, f in ipairs(schema.fields or {}) do
            if f.type == "email" and answers[f.key] then
                contact.email = answers[f.key]
                break
            end
        end
    end
    return contact, mapped
end

--- Human-readable answer (emails, CSV).
function Fields.show(field, value)
    if value == nil or value == NULL then return "" end
    local def = Fields.TYPES[field.type]
    if def and def.show then return def.show(value, field) end
    if type(value) == "table" then return cjson.encode(value) end
    return tostring(value)
end

--- One CSV cell. Spreadsheet formula injection: a cell starting with
-- = + - @ tab or CR is run as a formula by Excel/Sheets, so it gets a
-- leading apostrophe.
function Fields.csv_cell(v)
    v = tostring(v or "")
    if v:match("^[=+%-@\t\r]") then v = "'" .. v end
    if v:find('[",\n\r]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

return Fields
