local db = require("lapis.db")

-- Resolve the caller's current namespace to its numeric id.
--
-- The dashboard's api-client sends X-Namespace-Id as the namespace *uuid*
-- (occasionally X-Namespace-Slug). The old inline resolver did tonumber() on it
-- and got nil for a uuid, silently falling back to the 'system' namespace — so
-- every tenant's chat collapsed into one shared namespace. This accepts a numeric
-- id OR a uuid OR a slug header, and only then falls back to 'system'.
--
-- Returns the numeric namespace id, or nil if nothing resolves.
local ChatNamespace = {}

function ChatNamespace.resolve()
    local ns = ngx.var.http_x_namespace_id
    if ns and ns ~= "" then
        local as_num = tonumber(ns)
        if as_num then
            return as_num
        end
        local r = db.query("SELECT id FROM namespaces WHERE uuid = ? LIMIT 1", ns)
        if r and r[1] then
            return r[1].id
        end
    end

    local slug = ngx.var.http_x_namespace_slug
    if slug and slug ~= "" then
        local r = db.query("SELECT id FROM namespaces WHERE slug = ? LIMIT 1", slug)
        if r and r[1] then
            return r[1].id
        end
    end

    local sys = db.query("SELECT id FROM namespaces WHERE slug = 'system' LIMIT 1")
    if sys and sys[1] then
        return sys[1].id
    end

    return nil
end

return ChatNamespace
