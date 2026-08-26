--[[
    Regression spec for tenant white-labelling.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/theme-branding_spec.lua
    (plain `lua5.1` works too).

    Guards the two pieces that make an academy instructor see academy branding
    on the shared opsapi dashboard:

      1. the "academy" preset exists, is scoped to project_code "academy", and
         renders the learner site's indigo scale as CSS variables;
      2. ThemeQueries.getDefaultPreset prefers a preset whose slug equals the
         project_code — without that ORDER BY, a namespace with no explicitly
         activated theme falls back to "OpsAPI Bright" (pink) instead.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0

local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- ---------------------------------------------------------------------------
-- 1. The academy preset
-- ---------------------------------------------------------------------------
local ThemePresets = require("helper.theme-presets")
local ThemeTokenSchema = require("helper.theme-token-schema")

local academy = ThemePresets.getBySlug("academy")
check("academy preset exists", academy ~= nil)

if academy then
    check("scoped to the academy project_code", academy.project_code == "academy", academy.project_code)
    check("brand name is set", (academy.tokens.branding or {}).brand_name == "Workstation Academy")

    -- A partial scale renders half a palette: the dashboard uses every step.
    local missing = {}
    for _, key in ipairs(ThemeTokenSchema.COLOR_SCALE_KEYS) do
        if academy.tokens.colors.primary[key] == nil then missing[#missing + 1] = key end
        if academy.tokens.colors.secondary[key] == nil then missing[#missing + 1] = "s" .. key end
    end
    check("primary + secondary scales are complete (50-900)", #missing == 0, table.concat(missing, ","))
    check("primary 500 is the learner site's indigo", academy.tokens.colors.primary["500"] == "#6366f1")
end

-- ---------------------------------------------------------------------------
-- 2. Rendering: tokens actually reach the browser as CSS variables
-- ---------------------------------------------------------------------------
package.preload["cjson"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end

local ThemeRenderer = require("lib.theme-renderer")
local css = ThemeRenderer.render({ tokens = academy and academy.tokens or {} })

check("renders --color-primary-500", css:find("--color-primary-500: #6366f1", 1, true) ~= nil)
check("renders --color-secondary-900", css:find("--color-secondary-900: #171717", 1, true) ~= nil)
check("renders --brand-name", css:find("--brand-name: Workstation Academy", 1, true) ~= nil)

-- ---------------------------------------------------------------------------
-- 3. A project's own preset wins the "no theme activated" fallback
-- ---------------------------------------------------------------------------
-- ThemeQueries pulls in lapis.db, which needs a live config; assert on the
-- source instead. Cheap, but it is exactly the one line that can silently
-- regress to "first preset by id".
local fh = assert(io.open("lapis/queries/ThemeQueries.lua"))
local src = fh:read("*a")
fh:close()
local fallback = src:match("function ThemeQueries%.getDefaultPreset.-\nend")
check("getDefaultPreset prefers slug == project_code",
    fallback ~= nil and fallback:find("ORDER BY (t.slug = ?) DESC", 1, true) ~= nil)

-- ---------------------------------------------------------------------------
-- 4. The namespace's own project_code is what selects its presets
-- ---------------------------------------------------------------------------
-- routes/themes.lua read `default_project_code` — a column that has never
-- existed — so every namespace silently resolved to the pod's PROJECT_CODE and
-- no tenant could ever get its own look. Guard against the typo returning.
local rh = assert(io.open("lapis/routes/themes.lua"))
local routes_src = rh:read("*a")
rh:close()

check("no read of the non-existent default_project_code column",
    routes_src:find("%.default_project_code") == nil)
check("resolves the namespace's own project_code",
    routes_src:find("local code = ns and ns.project_code", 1, true) ~= nil)
check("treats 'all' as unpinned so existing tenants keep the pod's code",
    routes_src:find('code ~= "all"', 1, true) ~= nil)

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
