--[[
    Theme Resolver
    ==============

    Produces the final, fully-populated token tree for a theme by collapsing
    the inheritance chain:

        platform defaults  (from theme-token-schema)
          └─ parent theme  (if parent_theme_id set; walks the chain)
              └─ current theme tokens

    Custom CSS is concatenated in the same order — parent CSS first, child
    last — so child rules win on specificity ties.

    Safe against cycles (tracks visited theme_ids, 10-level hard cap).

    Pure read operation. No DB writes. Callers: theme-renderer, activate flow,
    preview endpoint.
]]

local cjson = require("cjson")
local ThemeTokenSchema = require("helper.theme-token-schema")
local ThemeQueries = require("queries.ThemeQueries")

local ThemeResolver = {}

local MAX_DEPTH = 10

-- Deep-merge two token trees. `override` wins; arrays are replaced wholesale
-- (never concatenated — a color_scale override must be a complete 50-900 set).
local function deep_merge(base, override)
    if type(override) ~= "table" then return override end
    local out = {}
    if type(base) == "table" then
        for k, v in pairs(base) do out[k] = v end
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(out[k]) == "table" then
            out[k] = deep_merge(out[k], v)
        else
            out[k] = v
        end
    end
    return out
end

local function parse_tokens(raw)
    if raw == nil or raw == "" then return {} end
    if type(raw) == "table" then return raw end
    local ok, decoded = pcall(cjson.decode, raw)
    if ok and type(decoded) == "table" then return decoded end
    return {}
end

-- Walk parent chain bottom-up (child -> ancestor) so we can merge top-down.
local function collect_chain(theme_row)
    local chain = { theme_row }
    local visited = { [theme_row.id] = true }
    local cursor = theme_row
    local depth = 0

    while cursor.parent_theme_id and depth < MAX_DEPTH do
        if visited[cursor.parent_theme_id] then break end -- cycle guard
        local parent = ThemeQueries.getById(cursor.parent_theme_id)
        if not parent then break end
        visited[parent.id] = true
        table.insert(chain, parent)
        cursor = parent
        depth = depth + 1
    end

    return chain
end

--- Resolve a theme (given the theme row) into final tokens + custom_css.
-- @param theme_row table   Row from `themes` (must include id, parent_theme_id)
-- @return table           { tokens = <final>, custom_css = <concatenated> }
function ThemeResolver.resolve(theme_row)
    if not theme_row or not theme_row.id then
        return {
            tokens = ThemeTokenSchema.getDefaults(),
            custom_css = "",
        }
    end

    -- Chain from child to ancestor. We want to merge ancestor first, then
    -- each descendant layers on top, so reverse the chain before merging.
    local chain = collect_chain(theme_row)
    local tokens = ThemeTokenSchema.getDefaults()
    local css_parts = {}

    for i = #chain, 1, -1 do
        local t = chain[i]
        local row = ThemeQueries.getTokens(t.id)
        if row then
            tokens = deep_merge(tokens, parse_tokens(row.tokens))
            if row.custom_css and row.custom_css ~= "" then
                table.insert(css_parts, row.custom_css)
            end
        end
    end

    return {
        tokens = tokens,
        custom_css = table.concat(css_parts, "\n\n"),
    }
end

--- Convenience: resolve a tokens+css pair directly (already-decoded). Used by
-- the preview endpoint where the editor sends in-flight edits that haven't
-- been persisted yet.
function ThemeResolver.resolveInline(parent_theme_row, override_tokens, override_css)
    local base = { tokens = ThemeTokenSchema.getDefaults(), custom_css = "" }
    if parent_theme_row then
        base = ThemeResolver.resolve(parent_theme_row)
    end

    local tokens = deep_merge(base.tokens, parse_tokens(override_tokens))
    local css = base.custom_css
    if override_css and override_css ~= "" then
        css = css == "" and override_css or (css .. "\n\n" .. override_css)
    end

    return { tokens = tokens, custom_css = css }
end

return ThemeResolver
