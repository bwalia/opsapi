-- NebulaDB Companies House index: a keyless, platform-hosted proxy over the UK
-- Companies House register (https://showcase.nebuladb.net by default). It lets
-- the deal finder search companies without each workspace holding its own
-- Companies House API key (unlike connectors.lua's ch(), which calls the
-- official API with a per-workspace key). Override the host with NEBULADB_URL
-- (declare `env NEBULADB_URL;` in nginx.conf for os.getenv to see it).
local H = require("property_deals.http")

local N = {}

N.BASE = ((os.getenv("NEBULADB_URL") or "https://showcase.nebuladb.net"):gsub("/+$", ""))

--- Search the Companies House index by name or number.
-- @return items (list, possibly empty) | nil, error, status
function N.companies_search(q)
    if type(q) ~= "string" or q:gsub("%s+", "") == "" then return {} end
    local url = N.BASE .. "/api/v1/companies-house/search?q=" .. ngx.escape_uri(q)
    local data, err, status = H.json(url, {})
    if not data then return nil, "NebulaDB unreachable: " .. tostring(err), status or 502 end
    return type(data.items) == "table" and data.items or {}
end

return N
