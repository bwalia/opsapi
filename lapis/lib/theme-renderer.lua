--[[
    Theme Renderer
    ==============

    Turns a resolved tokens + custom_css pair into the final CSS string served
    to browsers.

    Output shape:
        :root {
            --color-primary-50: #eff6ff;
            --color-primary-500: #3b82f6;
            --font-family-base: Inter, sans-serif;
            ...
        }

        [data-density="compact"]  { --density-padding: 0.5rem; }
        [data-density="spacious"] { --density-padding: 1.25rem; }

        <sanitised custom_css appended last>

    Discrete enum tokens (density, nav_style) emit attribute selectors so the
    frontend can flip them declaratively via <html data-density="compact">
    without re-rendering CSS.

    All user-supplied CSS is passed through css-sanitizer one more time here
    even if it was sanitised on write (defense-in-depth; see security plan).
]]

local ThemeTokenSchema = require("helper.theme-token-schema")
local CssSanitizer = require("helper.css-sanitizer")

local ThemeRenderer = {}

-- =============================================================================
-- CSS var name mapping
-- =============================================================================
-- Tokens are mapped to CSS variable names using these rules:
--   colors.primary.500        -> --color-primary-500
--   colors.background         -> --color-background
--   colors.foreground         -> --color-foreground
--   typography.font_family_base -> --font-family-base
--   radius.md                 -> --radius-md
--   spacing.scale             -> --spacing-scale
--   shadows.md                -> --shadow-md
--   layout.sidebar_width      -> --sidebar-width
--   branding.brand_name       -> --brand-name (only string-serialisable)
--   effects.animation_speed   -> --animation-speed

local function slugify(s)
    return tostring(s):gsub("_", "-"):gsub("%.", "-"):lower()
end

-- Emit `  --<name>: <value>;` lines into buf, one per scalar leaf under `value`.
-- `prefix` is the CSS var name stem (already includes leading --).
local function emit_scalar(buf, prefix, value)
    local t = type(value)
    if t == "string" or t == "number" then
        buf[#buf + 1] = string.format("  %s: %s;", prefix, tostring(value))
    elseif t == "boolean" then
        buf[#buf + 1] = string.format("  %s: %d;", prefix, value and 1 or 0)
    end
end

local function emit_color_scale(buf, prefix, scale)
    if type(scale) ~= "table" then return end
    for _, k in ipairs(ThemeTokenSchema.COLOR_SCALE_KEYS) do
        local v = scale[k]
        if v ~= nil then
            emit_scalar(buf, prefix .. "-" .. k, v)
        end
    end
end

-- =============================================================================
-- Per-group emission
-- =============================================================================

local function emit_colors(buf, colors)
    if type(colors) ~= "table" then return end
    local schema = ThemeTokenSchema.SCHEMA.colors
    for key, def in pairs(schema) do
        local v = colors[key]
        if v ~= nil then
            if def.type == "color_scale" or def.type == "color_scale_preset" then
                emit_color_scale(buf, "--color-" .. slugify(key), v)
            else
                emit_scalar(buf, "--color-" .. slugify(key), v)
            end
        end
    end
end

local function emit_typography(buf, typ)
    if type(typ) ~= "table" then return end
    for key, _def in pairs(ThemeTokenSchema.SCHEMA.typography) do
        local v = typ[key]
        if v ~= nil then
            emit_scalar(buf, "--" .. slugify(key), v)
        end
    end
end

local function emit_simple_group(buf, values, group_name, css_prefix)
    if type(values) ~= "table" then return end
    local schema_group = ThemeTokenSchema.SCHEMA[group_name]
    if type(schema_group) ~= "table" then return end
    for key, _def in pairs(schema_group) do
        local v = values[key]
        if v ~= nil then
            emit_scalar(buf, css_prefix .. slugify(key), v)
        end
    end
end

-- =============================================================================
-- Main render
-- =============================================================================

--- Render a resolved theme (tokens + custom_css) to a single CSS string.
-- @param resolved table { tokens = {...}, custom_css = "..." }
-- @param opts     table optional { theme_uuid = "..." } for :root scoping
-- @return string CSS
function ThemeRenderer.render(resolved, opts)
    resolved = resolved or {}
    opts = opts or {}
    local tokens = resolved.tokens or {}
    local buf = {}

    local selector = ":root"
    if opts.theme_uuid then
        selector = string.format(':root[data-theme-id="%s"], :root', opts.theme_uuid)
    end

    buf[#buf + 1] = selector .. " {"
    emit_colors(buf, tokens.colors)
    emit_typography(buf, tokens.typography)
    emit_simple_group(buf, tokens.radius,   "radius",   "--radius-")
    emit_simple_group(buf, tokens.spacing,  "spacing",  "--spacing-")
    emit_simple_group(buf, tokens.shadows,  "shadows",  "--shadow-")
    emit_simple_group(buf, tokens.layout,   "layout",   "--")
    emit_simple_group(buf, tokens.branding, "branding", "--")
    emit_simple_group(buf, tokens.effects,  "effects",  "--")
    buf[#buf + 1] = "}"

    -- Discrete enum attribute selectors (density / nav_style) — frontend can
    -- swap without re-rendering.
    if tokens.layout then
        local density = tokens.layout.density
        if density then
            buf[#buf + 1] = string.format('[data-density="%s"] { --layout-density-active: 1; }', tostring(density))
        end
        local nav = tokens.layout.nav_style
        if nav then
            buf[#buf + 1] = string.format('[data-nav-style="%s"] { --layout-nav-active: 1; }', tostring(nav))
        end
    end

    -- Sanitize and append user CSS (runs even if sanitised on write — D-i-D).
    local custom = resolved.custom_css
    if type(custom) == "string" and custom ~= "" then
        local clean = CssSanitizer.sanitise(custom)
        if clean and clean ~= "" then
            buf[#buf + 1] = ""
            buf[#buf + 1] = "/* --- user custom css --- */"
            buf[#buf + 1] = clean
        end
    end

    return table.concat(buf, "\n") .. "\n"
end

--- Produce a short cache key fragment for (tokens, custom_css) — used as
-- part of the Redis cache key in Phase 3.
function ThemeRenderer.fingerprint(resolved)
    resolved = resolved or {}
    local cjson = require("cjson")
    local ok, serialised = pcall(cjson.encode, {
        t = resolved.tokens or {},
        c = resolved.custom_css or "",
    })
    if not ok then return "invalid" end
    -- ngx.md5 is cheap and non-crypto but fine for a cache key
    if ngx and ngx.md5 then return ngx.md5(serialised) end
    -- Lua fallback: simple additive hash (only used in test/offline runs)
    local h = 0
    for i = 1, #serialised do h = (h * 31 + serialised:byte(i)) % 2147483647 end
    return tostring(h)
end

return ThemeRenderer
