-- The workspace playbook (property_deals_playbooks): seeded from seed/playbook.lua the first time it is
-- read or the workspace is set up, then the workspace's own. Never overwritten.
local db = require("lapis.db")
local U = require("property_deals.util")

local PB = {}

function PB.ensure(ns)
    if U.one("SELECT 1 FROM property_deals_playbooks WHERE namespace_id = ? LIMIT 1", ns) then return 0 end
    local n = 0
    for i, s in ipairs(require("property_deals.seed.playbook")) do
        db.query([[INSERT INTO property_deals_playbooks (namespace_id, key, title, body, position)
            VALUES (?, ?, ?, ?, ?) ON CONFLICT (namespace_id, key) DO NOTHING]], ns, s.key, s.title,
            (s.body:gsub("^%s+", ""):gsub("%s+$", "")), i)
        n = n + 1
    end
    return n
end

function PB.list(ns)
    PB.ensure(ns)
    return U.array(db.query([[
        SELECT uuid, key, title, body, position, updated_by_user_uuid, updated_at
        FROM property_deals_playbooks WHERE namespace_id = ? ORDER BY position, key
    ]], ns))
end

--- The whole playbook as one markdown text (capped), for prompts.
function PB.text(ns, max)
    local parts = {}
    for _, s in ipairs(PB.list(ns)) do parts[#parts + 1] = "## " .. s.title .. "\n" .. s.body end
    local t = table.concat(parts, "\n\n")
    return #t > (max or 12000) and (t:sub(1, max or 12000) .. "\n…") or t
end

return PB
