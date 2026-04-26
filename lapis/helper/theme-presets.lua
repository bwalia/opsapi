--[[
    Theme Presets
    =============

    Platform-provided starter themes. These are seeded once per project_code
    with namespace_id=NULL and is_system=true, giving every new tenant a
    pre-built palette they can duplicate and customize.

    Adding a new preset = add an entry to ThemePresets.LIST. No migration
    needed — the seed migration is idempotent and re-runs on every deploy
    via the zzz auto-delete pattern (registered in migrations.lua).

    Each preset contains the canonical token shape that the system-wide
    token schema (shipped in Phase 2 as theme-token-schema.lua) will
    validate against. Keep new presets in sync with the schema.

    Preset contract:
      slug              : stable identifier (lowercase, hyphens) — used in UNIQUE index
      name              : human-readable label
      description       : shown in the theme picker
      project_code      : which project this preset applies to ("*" = all projects)
      preview_image_url : optional thumbnail (served from MinIO in Phase 6)
      tokens            : design tokens (colors, typography, radius, spacing, shadows, layout, branding, effects)
      custom_css        : optional raw CSS appended after token-derived CSS
]]

local ThemePresets = {}

-- Shared token fragments reused across presets
local FONT_STACK_SANS = "Inter, ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
local FONT_STACK_MONO = "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Courier New', monospace"
local FONT_STACK_SERIF = "Georgia, Cambria, 'Times New Roman', Times, serif"

-- Default structural tokens (non-color) shared by most presets
local function structural_defaults()
    return {
        typography = {
            font_family_base    = FONT_STACK_SANS,
            font_family_heading = FONT_STACK_SANS,
            font_family_mono    = FONT_STACK_MONO,
            font_size_base      = "16px",
            line_height_base    = 1.5,
            letter_spacing      = "0",
        },
        radius = {
            sm   = "4px",
            md   = "8px",
            lg   = "12px",
            xl   = "16px",
            full = "9999px",
        },
        spacing = {
            scale = 4,
        },
        shadows = {
            sm = "0 1px 2px 0 rgba(0,0,0,0.05)",
            md = "0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -2px rgba(0,0,0,0.1)",
            lg = "0 10px 15px -3px rgba(0,0,0,0.1), 0 4px 6px -4px rgba(0,0,0,0.1)",
            xl = "0 20px 25px -5px rgba(0,0,0,0.1), 0 8px 10px -6px rgba(0,0,0,0.1)",
        },
        layout = {
            sidebar_width       = "280px",
            container_max_width = "1280px",
            density             = "comfortable",
            nav_style           = "fixed",
        },
        branding = {
            logo_asset_id    = nil,
            logo_text        = "",
            favicon_asset_id = nil,
            brand_name       = "",
        },
        effects = {
            enable_animations = true,
            animation_speed   = "normal",
            glass_morphism    = false,
        },
    }
end

-- Merge structural defaults with a preset's color + overrides
local function build_tokens(colors, overrides)
    local tokens = structural_defaults()
    tokens.colors = colors
    if overrides then
        for group, fields in pairs(overrides) do
            if type(fields) == "table" and type(tokens[group]) == "table" then
                for k, v in pairs(fields) do
                    tokens[group][k] = v
                end
            else
                tokens[group] = fields
            end
        end
    end
    return tokens
end

-- Canonical list of platform presets. Order matters for "default" selection.
ThemePresets.LIST = {
    {
        slug         = "light",
        name         = "Light",
        description  = "Clean, bright default with blue brand accents. Suitable for most dashboards.",
        project_code = "*",
        tokens = build_tokens({
            primary = {
                ["50"]  = "#eff6ff", ["100"] = "#dbeafe", ["200"] = "#bfdbfe",
                ["300"] = "#93c5fd", ["400"] = "#60a5fa", ["500"] = "#3b82f6",
                ["600"] = "#2563eb", ["700"] = "#1d4ed8", ["800"] = "#1e40af",
                ["900"] = "#1e3a8a",
            },
            secondary = {
                ["50"]  = "#f8fafc", ["100"] = "#f1f5f9", ["200"] = "#e2e8f0",
                ["300"] = "#cbd5e1", ["400"] = "#94a3b8", ["500"] = "#64748b",
                ["600"] = "#475569", ["700"] = "#334155", ["800"] = "#1e293b",
                ["900"] = "#0f172a",
            },
            accent           = "#3b82f6",
            background       = "#ffffff",
            foreground       = "#0f172a",
            surface          = "#ffffff",
            surface_elevated = "#ffffff",
            success          = "#10b981",
            warning          = "#f59e0b",
            danger           = "#ef4444",
            info             = "#0ea5e9",
        }),
    },

    {
        slug         = "dark",
        name         = "Dark",
        description  = "Low-light palette tuned for long sessions. Reduces eye strain in dim environments.",
        project_code = "*",
        tokens = build_tokens({
            primary = {
                ["50"]  = "#eef2ff", ["100"] = "#e0e7ff", ["200"] = "#c7d2fe",
                ["300"] = "#a5b4fc", ["400"] = "#818cf8", ["500"] = "#6366f1",
                ["600"] = "#4f46e5", ["700"] = "#4338ca", ["800"] = "#3730a3",
                ["900"] = "#312e81",
            },
            secondary = {
                ["50"]  = "#18181b", ["100"] = "#27272a", ["200"] = "#3f3f46",
                ["300"] = "#52525b", ["400"] = "#71717a", ["500"] = "#a1a1aa",
                ["600"] = "#d4d4d8", ["700"] = "#e4e4e7", ["800"] = "#f4f4f5",
                ["900"] = "#fafafa",
            },
            accent           = "#a78bfa",
            background       = "#09090b",
            foreground       = "#fafafa",
            surface          = "#18181b",
            surface_elevated = "#27272a",
            success          = "#34d399",
            warning          = "#fbbf24",
            danger           = "#f87171",
            info             = "#38bdf8",
        }),
    },

    {
        slug         = "corporate-blue",
        name         = "Corporate Blue",
        description  = "Trustworthy navy-and-slate palette for financial and professional services.",
        project_code = "*",
        tokens = build_tokens({
            primary = {
                ["50"]  = "#f0f7ff", ["100"] = "#e0effe", ["200"] = "#bae0fd",
                ["300"] = "#7cc5fc", ["400"] = "#36a6f8", ["500"] = "#0c89e9",
                ["600"] = "#006bc7", ["700"] = "#0156a1", ["800"] = "#064a85",
                ["900"] = "#0a3f6e",
            },
            secondary = {
                ["50"]  = "#f5f7fa", ["100"] = "#e4e9f2", ["200"] = "#cdd5e0",
                ["300"] = "#9fadbd", ["400"] = "#6b7a8f", ["500"] = "#4a5568",
                ["600"] = "#2d3748", ["700"] = "#1a202c", ["800"] = "#131820",
                ["900"] = "#0b0f14",
            },
            accent           = "#006bc7",
            background       = "#ffffff",
            foreground       = "#1a202c",
            surface          = "#ffffff",
            surface_elevated = "#ffffff",
            success          = "#047857",
            warning          = "#b45309",
            danger           = "#b91c1c",
            info             = "#0e7490",
        }, {
            typography = { font_family_heading = FONT_STACK_SERIF },
            radius     = { sm = "2px", md = "4px", lg = "6px", xl = "8px" },
        }),
    },

    {
        slug         = "minimal",
        name         = "Minimal",
        description  = "Grayscale-first aesthetic. Lets your content lead with understated chrome.",
        project_code = "*",
        tokens = build_tokens({
            primary = {
                ["50"]  = "#fafafa", ["100"] = "#f5f5f5", ["200"] = "#e5e5e5",
                ["300"] = "#d4d4d4", ["400"] = "#a3a3a3", ["500"] = "#737373",
                ["600"] = "#525252", ["700"] = "#404040", ["800"] = "#262626",
                ["900"] = "#171717",
            },
            secondary = {
                ["50"]  = "#ffffff", ["100"] = "#f5f5f5", ["200"] = "#e5e5e5",
                ["300"] = "#d4d4d4", ["400"] = "#a3a3a3", ["500"] = "#737373",
                ["600"] = "#525252", ["700"] = "#404040", ["800"] = "#262626",
                ["900"] = "#0a0a0a",
            },
            accent           = "#171717",
            background       = "#fafafa",
            foreground       = "#171717",
            surface          = "#ffffff",
            surface_elevated = "#ffffff",
            success          = "#166534",
            warning          = "#854d0e",
            danger           = "#991b1b",
            info             = "#1e3a8a",
        }, {
            radius = { sm = "2px", md = "2px", lg = "4px", xl = "6px", full = "9999px" },
            shadows = {
                sm = "0 1px 0 0 rgba(0,0,0,0.04)",
                md = "0 1px 3px 0 rgba(0,0,0,0.06)",
                lg = "0 2px 6px 0 rgba(0,0,0,0.08)",
                xl = "0 4px 12px 0 rgba(0,0,0,0.10)",
            },
            effects = { enable_animations = false, glass_morphism = false },
        }),
    },

    {
        slug         = "vibrant",
        name         = "Vibrant",
        description  = "Energetic magenta + teal palette for creative and consumer-facing workspaces.",
        project_code = "*",
        tokens = build_tokens({
            primary = {
                ["50"]  = "#fdf4ff", ["100"] = "#fae8ff", ["200"] = "#f5d0fe",
                ["300"] = "#f0abfc", ["400"] = "#e879f9", ["500"] = "#d946ef",
                ["600"] = "#c026d3", ["700"] = "#a21caf", ["800"] = "#86198f",
                ["900"] = "#701a75",
            },
            secondary = {
                ["50"]  = "#f0fdfa", ["100"] = "#ccfbf1", ["200"] = "#99f6e4",
                ["300"] = "#5eead4", ["400"] = "#2dd4bf", ["500"] = "#14b8a6",
                ["600"] = "#0d9488", ["700"] = "#0f766e", ["800"] = "#115e59",
                ["900"] = "#134e4a",
            },
            accent           = "#f97316",
            background       = "#ffffff",
            foreground       = "#1c1917",
            surface          = "#ffffff",
            surface_elevated = "#ffffff",
            success          = "#22c55e",
            warning          = "#eab308",
            danger           = "#ef4444",
            info             = "#06b6d4",
        }, {
            radius = { sm = "8px", md = "12px", lg = "16px", xl = "24px", full = "9999px" },
            effects = { enable_animations = true, animation_speed = "fast", glass_morphism = true },
        }),
    },

    {
        slug         = "high-contrast",
        name         = "High Contrast",
        description  = "WCAG AAA accessibility preset. Pure black on pure white with bold focus rings.",
        project_code = "*",
        tokens = build_tokens({
            primary = {
                ["50"]  = "#ffffff", ["100"] = "#f0f0f0", ["200"] = "#d0d0d0",
                ["300"] = "#a0a0a0", ["400"] = "#707070", ["500"] = "#404040",
                ["600"] = "#202020", ["700"] = "#101010", ["800"] = "#080808",
                ["900"] = "#000000",
            },
            secondary = {
                ["50"]  = "#ffffff", ["100"] = "#ffffff", ["200"] = "#f0f0f0",
                ["300"] = "#c0c0c0", ["400"] = "#808080", ["500"] = "#404040",
                ["600"] = "#202020", ["700"] = "#101010", ["800"] = "#000000",
                ["900"] = "#000000",
            },
            accent           = "#0000ff",
            background       = "#ffffff",
            foreground       = "#000000",
            surface          = "#ffffff",
            surface_elevated = "#ffffff",
            success          = "#008000",
            warning          = "#d97706",
            danger           = "#cc0000",
            info             = "#0000cc",
        }, {
            radius  = { sm = "0px", md = "0px", lg = "0px", xl = "0px", full = "9999px" },
            layout  = { density = "comfortable" },
            effects = { enable_animations = false, glass_morphism = false },
        }),
        custom_css = table.concat({
            ":root { --focus-ring-width: 3px; --focus-ring-color: #0000ff; }",
            "*:focus-visible { outline: var(--focus-ring-width) solid var(--focus-ring-color); outline-offset: 2px; }",
        }, "\n"),
    },
}

--- Get the full preset list
function ThemePresets.getAll()
    return ThemePresets.LIST
end

--- Get a specific preset by slug (returns nil if not found)
function ThemePresets.getBySlug(slug)
    for _, preset in ipairs(ThemePresets.LIST) do
        if preset.slug == slug then
            return preset
        end
    end
    return nil
end

--- Get the default preset slug (first entry)
function ThemePresets.getDefaultSlug()
    return ThemePresets.LIST[1] and ThemePresets.LIST[1].slug or "light"
end

return ThemePresets
