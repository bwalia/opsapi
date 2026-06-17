--[[
    Theme Token Validator
    =====================

    Validates an incoming tokens table against helper.theme-token-schema.
    Returns (ok, errors) where errors is a list of human-readable messages.

    Rejects:
      - unknown top-level groups (typo guard)
      - unknown field keys within a group
      - wrong types
      - color strings that don't match #rgb, #rrggbb, #rgba, #rrggbbaa
      - color_scale missing required keys (50-900)
      - numbers outside declared min/max
      - size strings outside min/max (only when both are size-comparable)
      - enum values not in the declared value list
      - strings exceeding max_length
      - required fields missing

    The validator is intentionally strict. Callers (theme-service) apply the
    returned errors as 422 responses — no silent fallback.
]]

local ThemeTokenSchema = require("helper.theme-token-schema")

local ThemeValidator = {}

-- =============================================================================
-- Primitive type checks
-- =============================================================================

-- Hex color: #rgb, #rrggbb, #rgba, #rrggbbaa
local function is_hex_color(v)
    if type(v) ~= "string" then return false end
    return v:match("^#%x%x%x$") ~= nil
        or v:match("^#%x%x%x%x$") ~= nil
        or v:match("^#%x%x%x%x%x%x$") ~= nil
        or v:match("^#%x%x%x%x%x%x%x%x$") ~= nil
end

-- Also accept rgb()/rgba()/hsl()/hsla() functional notation
local function is_color_like(v)
    if is_hex_color(v) then return true end
    if type(v) ~= "string" then return false end
    local fn = v:match("^(%a+)%s*%(")
    if fn and (fn == "rgb" or fn == "rgba" or fn == "hsl" or fn == "hsla") then
        return v:match("%)$") ~= nil
    end
    return false
end

-- Size with a CSS unit. Accepts px, rem, em, %, vh, vw, ch, pt, or bare "0".
local function is_size(v)
    if type(v) == "number" then return true end
    if type(v) ~= "string" then return false end
    if v == "0" then return true end
    return v:match("^%-?%d+%.?%d*(%a+)$") ~= nil
        or v:match("^%-?%.%d+(%a+)$") ~= nil
        or v:match("^%-?%d+%.?%d*%%$") ~= nil
end

-- Parse pixel value out of a size string; returns nil if not px-expressible
local function px_of(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return nil end
    local n = v:match("^(%-?%d+%.?%d*)px$")
    if n then return tonumber(n) end
    return nil
end

-- Font strings: simple allowlist check — no quotes injection, reasonable length
local function is_font(v)
    if type(v) ~= "string" then return false end
    if #v == 0 or #v > 500 then return false end
    if v:find("[<>;{}`]") then return false end
    return true
end

-- =============================================================================
-- Field-level validation
-- =============================================================================

local function validate_color_scale(value, errors, path)
    if type(value) ~= "table" then
        table.insert(errors, path .. ": expected color_scale object with 50-900 keys")
        return
    end
    for _, key in ipairs(ThemeTokenSchema.COLOR_SCALE_KEYS) do
        local v = value[key]
        if v == nil then
            table.insert(errors, path .. "." .. key .. ": missing (required for color_scale)")
        elseif not is_color_like(v) then
            table.insert(errors, path .. "." .. key .. ": not a valid color")
        end
    end
    -- Disallow extra keys to catch typos
    for k in pairs(value) do
        local known = false
        for _, ck in ipairs(ThemeTokenSchema.COLOR_SCALE_KEYS) do
            if k == ck then known = true break end
        end
        if not known then
            table.insert(errors, path .. "." .. tostring(k) .. ": unknown color_scale key")
        end
    end
end

local function validate_field(def, value, errors, path)
    local t = def.type

    if t == "color" then
        if not is_color_like(value) then
            table.insert(errors, path .. ": not a valid color")
        end

    elseif t == "color_scale" or t == "color_scale_preset" then
        validate_color_scale(value, errors, path)

    elseif t == "size" then
        if not is_size(value) then
            table.insert(errors, path .. ": not a valid CSS size")
        else
            local px = px_of(value)
            local min_px = def.min and px_of(def.min)
            local max_px = def.max and px_of(def.max)
            if px and min_px and px < min_px then
                table.insert(errors, path .. ": below minimum " .. tostring(def.min))
            end
            if px and max_px and px > max_px then
                table.insert(errors, path .. ": above maximum " .. tostring(def.max))
            end
        end

    elseif t == "font" then
        if not is_font(value) then
            table.insert(errors, path .. ": not a valid font family string")
        end

    elseif t == "number" then
        if type(value) ~= "number" then
            table.insert(errors, path .. ": expected number")
        else
            if def.min and value < def.min then
                table.insert(errors, path .. ": below minimum " .. tostring(def.min))
            end
            if def.max and value > def.max then
                table.insert(errors, path .. ": above maximum " .. tostring(def.max))
            end
        end

    elseif t == "string" then
        if type(value) ~= "string" then
            table.insert(errors, path .. ": expected string")
        elseif def.max_length and #value > def.max_length then
            table.insert(errors, path .. ": exceeds max_length " .. tostring(def.max_length))
        end

    elseif t == "enum" then
        local ok = false
        if type(value) == "string" and def.values then
            for _, v in ipairs(def.values) do
                if v == value then ok = true break end
            end
        end
        if not ok then
            table.insert(errors, path .. ": must be one of " ..
                (def.values and table.concat(def.values, ", ") or "<no values declared>"))
        end

    elseif t == "boolean" then
        if type(value) ~= "boolean" then
            table.insert(errors, path .. ": expected boolean")
        end

    elseif t == "shadow" then
        if type(value) ~= "string" then
            table.insert(errors, path .. ": expected CSS shadow string")
        elseif #value > 500 then
            table.insert(errors, path .. ": shadow string too long")
        elseif value:find("[<>{}]") or value:lower():find("javascript") or value:lower():find("expression") then
            table.insert(errors, path .. ": shadow contains forbidden characters")
        end

    elseif t == "asset" then
        -- Asset refs are UUIDs managed by theme_assets; we accept strings or nil.
        if value ~= nil and type(value) ~= "string" then
            table.insert(errors, path .. ": asset reference must be a UUID string or null")
        elseif type(value) == "string" and not value:match("^[%w%-]+$") then
            table.insert(errors, path .. ": asset reference contains invalid characters")
        end

    else
        table.insert(errors, path .. ": unknown field type '" .. tostring(t) .. "'")
    end
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Validate a tokens table against the canonical schema.
-- @param tokens table Candidate tokens
-- @return boolean ok, table errors
function ThemeValidator.validate(tokens)
    local errors = {}
    if tokens == nil then
        return true, errors -- absence is fine; defaults will fill in
    end
    if type(tokens) ~= "table" then
        return false, { "tokens: must be an object" }
    end

    local schema = ThemeTokenSchema.SCHEMA

    -- Unknown top-level group guard
    for group in pairs(tokens) do
        if not schema[group] then
            table.insert(errors, string.format("tokens.%s: unknown group", tostring(group)))
        end
    end

    for group, fields in pairs(schema) do
        local values = tokens[group]
        if values ~= nil then
            if type(values) ~= "table" then
                table.insert(errors, "tokens." .. group .. ": must be an object")
            else
                -- Unknown field guard
                for k in pairs(values) do
                    if not fields[k] then
                        table.insert(errors, string.format(
                            "tokens.%s.%s: unknown field", group, tostring(k)
                        ))
                    end
                end

                -- Validate each declared field
                for key, def in pairs(fields) do
                    local v = values[key]
                    if v == nil then
                        if def.required then
                            table.insert(errors, string.format(
                                "tokens.%s.%s: required", group, key
                            ))
                        end
                    else
                        validate_field(def, v, errors, "tokens." .. group .. "." .. key)
                    end
                end
            end
        else
            -- Group absent — only error if any field in group is required
            for key, def in pairs(fields) do
                if def.required then
                    table.insert(errors, string.format(
                        "tokens.%s.%s: required (group missing)", group, key
                    ))
                end
            end
        end
    end

    return #errors == 0, errors
end

return ThemeValidator
