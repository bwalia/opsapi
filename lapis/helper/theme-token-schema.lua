--[[
    Theme Token Schema
    ==================

    Canonical definition of every editable design token. This is the SINGLE
    SOURCE OF TRUTH for:

      - theme-validator.lua      : rejects unknown keys, enforces types/ranges
      - theme-renderer.lua       : maps tokens to CSS variables
      - frontend editor UI       : consumed via /api/v2/themes/schema; auto-
                                   generates input controls for every field

    Adding a new token = edit this file only. The editor UI and validator
    pick it up automatically with no other code changes.

    Schema structure:
    -----------------
    Groups contain fields. Each field declares:
      type        : color | color_scale | size | font | number | string |
                    enum | boolean | shadow | asset | color_scale_preset
      required    : boolean (default: false)
      default     : fallback value applied during rendering if absent
      min / max   : for number/size types
      values      : for enum types
      max_length  : for string types
      asset_type  : for asset types (logo|favicon|background|font|image)
      ui.label    : label shown in editor
      ui.hint     : optional help text
      ui.group    : logical grouping in editor UI
      ui.order    : sort order within group (lower = earlier)

    The schema is intentionally plain data so it can be serialized to JSON
    for the frontend without any transformation.
]]

local ThemeTokenSchema = {}

-- Color scale keys (50 is lightest, 900 is darkest)
ThemeTokenSchema.COLOR_SCALE_KEYS = { "50", "100", "200", "300", "400", "500", "600", "700", "800", "900" }

-- Enum values for density and nav style
ThemeTokenSchema.DENSITY_VALUES = { "compact", "comfortable", "spacious" }
ThemeTokenSchema.NAV_STYLE_VALUES = { "fixed", "floating", "minimal" }
ThemeTokenSchema.ANIMATION_SPEED_VALUES = { "fast", "normal", "slow" }

-- =============================================================================
-- Schema definition
-- =============================================================================
ThemeTokenSchema.SCHEMA = {
    colors = {
        primary = {
            type = "color_scale", required = true,
            ui = { label = "Primary", group = "Brand", order = 1, hint = "Main brand color (50-900 scale)" },
        },
        secondary = {
            type = "color_scale", required = true,
            ui = { label = "Secondary", group = "Brand", order = 2, hint = "Supporting neutral scale" },
        },
        accent = {
            type = "color",
            ui = { label = "Accent", group = "Brand", order = 3 },
        },
        background = {
            type = "color", default = "#ffffff",
            ui = { label = "Background", group = "Surface", order = 1 },
        },
        foreground = {
            type = "color", default = "#0f172a",
            ui = { label = "Foreground", group = "Surface", order = 2, hint = "Default text color" },
        },
        success = {
            type = "color", default = "#10b981",
            ui = { label = "Success", group = "Semantic", order = 1 },
        },
        warning = {
            type = "color", default = "#f59e0b",
            ui = { label = "Warning", group = "Semantic", order = 2 },
        },
        danger = {
            type = "color", default = "#ef4444",
            ui = { label = "Danger", group = "Semantic", order = 3 },
        },
        info = {
            type = "color", default = "#0ea5e9",
            ui = { label = "Info", group = "Semantic", order = 4 },
        },
    },

    typography = {
        font_family_base = {
            type = "font", default = "Inter, sans-serif",
            ui = { label = "Body font", group = "Typography", order = 1 },
        },
        font_family_heading = {
            type = "font", default = "Inter, sans-serif",
            ui = { label = "Heading font", group = "Typography", order = 2 },
        },
        font_family_mono = {
            type = "font", default = "JetBrains Mono, monospace",
            ui = { label = "Monospace font", group = "Typography", order = 3 },
        },
        font_size_base = {
            type = "size", default = "16px", min = "12px", max = "20px",
            ui = { label = "Base size", group = "Typography", order = 4 },
        },
        line_height_base = {
            type = "number", default = 1.5, min = 1.0, max = 2.0,
            ui = { label = "Line height", group = "Typography", order = 5 },
        },
        letter_spacing = {
            type = "size", default = "0",
            ui = { label = "Letter spacing", group = "Typography", order = 6 },
        },
    },

    radius = {
        sm   = { type = "size", default = "4px",    ui = { label = "Small",  group = "Radius", order = 1 } },
        md   = { type = "size", default = "8px",    ui = { label = "Medium", group = "Radius", order = 2 } },
        lg   = { type = "size", default = "12px",   ui = { label = "Large",  group = "Radius", order = 3 } },
        xl   = { type = "size", default = "16px",   ui = { label = "XL",     group = "Radius", order = 4 } },
        full = { type = "size", default = "9999px", ui = { label = "Full",   group = "Radius", order = 5 } },
    },

    spacing = {
        scale = {
            type = "number", default = 4, min = 2, max = 8,
            ui = { label = "Scale (px)", group = "Spacing", order = 1, hint = "Base grid unit" },
        },
    },

    shadows = {
        sm = { type = "shadow", default = "0 1px 2px 0 rgba(0,0,0,0.05)",
               ui = { label = "Small",  group = "Shadows", order = 1 } },
        md = { type = "shadow", default = "0 4px 6px -1px rgba(0,0,0,0.1)",
               ui = { label = "Medium", group = "Shadows", order = 2 } },
        lg = { type = "shadow", default = "0 10px 15px -3px rgba(0,0,0,0.1)",
               ui = { label = "Large",  group = "Shadows", order = 3 } },
        xl = { type = "shadow", default = "0 20px 25px -5px rgba(0,0,0,0.1)",
               ui = { label = "XL",     group = "Shadows", order = 4 } },
    },

    layout = {
        sidebar_width = {
            type = "size", default = "280px",
            ui = { label = "Sidebar width", group = "Layout", order = 1 },
        },
        container_max_width = {
            type = "size", default = "1280px",
            ui = { label = "Container max width", group = "Layout", order = 2 },
        },
        density = {
            type = "enum", values = ThemeTokenSchema.DENSITY_VALUES, default = "comfortable",
            ui = { label = "Density", group = "Layout", order = 3 },
        },
        nav_style = {
            type = "enum", values = ThemeTokenSchema.NAV_STYLE_VALUES, default = "fixed",
            ui = { label = "Navigation style", group = "Layout", order = 4 },
        },
    },

    branding = {
        logo_asset_id = {
            type = "asset", asset_type = "logo",
            ui = { label = "Logo", group = "Branding", order = 1 },
        },
        logo_text = {
            type = "string", max_length = 50, default = "",
            ui = { label = "Logo text", group = "Branding", order = 2, hint = "Shown if no image uploaded" },
        },
        favicon_asset_id = {
            type = "asset", asset_type = "favicon",
            ui = { label = "Favicon", group = "Branding", order = 3 },
        },
        brand_name = {
            type = "string", max_length = 100, default = "",
            ui = { label = "Brand name", group = "Branding", order = 4 },
        },
    },

    effects = {
        enable_animations = {
            type = "boolean", default = true,
            ui = { label = "Enable animations", group = "Effects", order = 1 },
        },
        animation_speed = {
            type = "enum", values = ThemeTokenSchema.ANIMATION_SPEED_VALUES, default = "normal",
            ui = { label = "Animation speed", group = "Effects", order = 2 },
        },
        glass_morphism = {
            type = "boolean", default = false,
            ui = { label = "Glass morphism", group = "Effects", order = 3 },
        },
    },
}

-- =============================================================================
-- Lookup helpers
-- =============================================================================

--- Return the full schema as plain table (safe to JSON-encode for API)
function ThemeTokenSchema.getSchema()
    return ThemeTokenSchema.SCHEMA
end

--- Get a single field definition by group + key (returns nil if absent)
function ThemeTokenSchema.getField(group, key)
    local g = ThemeTokenSchema.SCHEMA[group]
    return g and g[key] or nil
end

--- Iterate every (group, key, field) tuple — used by validator and renderer
function ThemeTokenSchema.iterFields()
    local items = {}
    for group, fields in pairs(ThemeTokenSchema.SCHEMA) do
        for key, def in pairs(fields) do
            table.insert(items, { group = group, key = key, def = def })
        end
    end
    return items
end

--- Build a table of defaults (tokens with the default for every declared field)
function ThemeTokenSchema.getDefaults()
    local defaults = {}
    for group, fields in pairs(ThemeTokenSchema.SCHEMA) do
        defaults[group] = {}
        for key, def in pairs(fields) do
            if def.default ~= nil then
                defaults[group][key] = def.default
            end
        end
    end
    return defaults
end

--- True if the given type name is one we recognise
function ThemeTokenSchema.isValidType(type_name)
    local known = {
        color = true, color_scale = true, size = true, font = true,
        number = true, string = true, enum = true, boolean = true,
        shadow = true, asset = true,
    }
    return known[type_name] == true
end

return ThemeTokenSchema
