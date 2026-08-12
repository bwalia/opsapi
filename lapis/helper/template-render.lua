--[[
    Template Render helper
    ======================
    The shared "{{slot}}" engine behind the namespace Templates library. A
    template is a plain string (HTML for a page layout, JSON for a domain sync
    format, …) with `{{placeholder}}` slots; render() fills them from a data
    table. Mirrors the mechanism already used by helper/wslproxy-server.lua, so
    the whole platform speaks one template dialect.

    - Placeholders are `{{ key }}` where key is [%w_.] — dots allow nested
      lookups (`{{author.name}}`).
    - A missing/nil value renders as an empty string (never the literal
      "{{key}}"), so a partially-populated template degrades cleanly.
    - render() does NOT escape — the caller owns escaping for its target format
      (CMS HTML is already sanitised upstream; the domain JSON path uses
      wslproxy-server's JSON-aware renderer).
]]

local TemplateRender = {}

-- Resolve a possibly-dotted key ("a.b.c") against a data table.
local function lookup(data, key)
    if data == nil then return nil end
    if data[key] ~= nil then return data[key] end -- fast path: exact key
    local cur = data
    for part in key:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

--- Fill every {{placeholder}} in `template` from `data`. Function replacement
--- avoids Lua's `%` handling in gsub replacement strings.
function TemplateRender.render(template, data)
    if type(template) ~= "string" then return "" end
    data = data or {}
    return (template:gsub("{{%s*([%w_%.]+)%s*}}", function(key)
        local val = lookup(data, key)
        if val == nil then return "" end
        if type(val) == "boolean" then return val and "true" or "false" end
        if type(val) == "table" then return "" end
        return tostring(val)
    end))
end

--- Unique placeholder names in `template`, in first-seen order (for the editor
--- to show which variables a template expects).
function TemplateRender.placeholders(template)
    if type(template) ~= "string" then return {} end
    local seen, out = {}, {}
    for key in template:gmatch("{{%s*([%w_%.]+)%s*}}") do
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    return out
end

return TemplateRender
