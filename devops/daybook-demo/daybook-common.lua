-- Shared by seed-daybook.lua and seed-daybook-data.lua: find the seed directory and
-- load verticals. Loaded with loadfile (lapis exec doesn't put this dir on the path).
--
-- Files may be laid out as a tree (verticals/<slug>.lua, from the repo or a tar) or
-- flat (verticals__<slug>.lua, from a ConfigMap, which can't hold sub-directories).
local M = {}

function M.dir(source)
    return (source and source:match("^@(.*/)")) or "/tmp/daybook-seed/"
end

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function M.load(dir, name)
    for _, p in ipairs({ dir .. "verticals/" .. name .. ".lua", dir .. "verticals__" .. name .. ".lua" }) do
        if exists(p) then return assert(loadfile(p))() end
    end
    error("vertical file not found: verticals/" .. name .. ".lua (in " .. dir .. ")")
end

-- The verticals to seed: the one asked for, else every one in verticals/index.lua.
function M.verticals(dir, slug)
    local slugs = (slug and slug ~= "") and { slug } or M.load(dir, "index")
    local out = {}
    for _, s in ipairs(slugs) do
        local v = M.load(dir, s)
        assert(type(v) == "table" and v.namespace and v.namespace.slug, "vertical " .. s .. " has no namespace")
        out[#out + 1] = v
    end
    return out, M.load(dir, "index")
end

M.DEMO_EMAIL = "demo@daybook.co.uk"
M.SAMPLE_DOMAIN = "sample.daybook.co.uk"

return M
