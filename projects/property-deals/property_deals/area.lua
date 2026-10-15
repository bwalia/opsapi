-- Official data about the area around a home, for the deal autopilot (property_deals/research.lua): free UK
-- government sources, no key, Open Government Licence (stored on the deal, shown to the whole team, with their
-- attribution). Each part is optional: one that doesn't answer is left out with a short reason.
--   planning   planning.data.gov.uk: conservation area, Article 4 direction, tree preservation zone, green belt and
--              flood zone at the point; listed buildings and brownfield sites within ~250 m
--   flood      Environment Agency: flood warnings in force within 3 km, flood-alert areas within 1 km
--   crime      police.uk: street-level crime within a mile, latest month, by category
--   prices     HM Land Registry UK House Price Index: the local authority's average price, by type, and the change
--              over a year (the authority from postcodes.io)
-- PLUGIN_PROPERTY_DEALS_OPEN_DATA_URL (tests only) sends every source to <url>/planning, /ea, /police and /lr.
local H = require("property_deals.http")
local U = require("property_deals.util")

local A = {}

A.ATTRIBUTION = {
    planning = "Contains data from planning.data.gov.uk (Open Government Licence v3.0); listed buildings © Historic England",
    flood = "This uses Environment Agency flood and river level data from the real-time data API (Beta)",
    crime = "Contains public sector information licensed under the Open Government Licence v3.0 (data.police.uk)",
    prices = "Contains HM Land Registry data © Crown copyright and database right. Open Government Licence v3.0",
}

local function base(real, test_path)
    local test = require("helper.plugin-sdk").env("PLUGIN_PROPERTY_DEALS_OPEN_DATA_URL")
    return test and test ~= "" and (test:gsub("/+$", "") .. test_path) or real
end

local function s(v) return type(v) == "string" and v ~= "" and v or nil end
local function list(v) return type(v) == "table" and v or {} end

local function get(url)
    return H.json(url, { timeout_ms = 10000 })
end

-- planning.data.gov.uk ------------------------------------------------------------------------------------------

local POINT_SETS = { "conservation-area", "article-4-direction-area", "tree-preservation-zone", "green-belt",
    "flood-risk-zone" }

function A.planning(lat, lng)
    local url = base("https://www.planning.data.gov.uk", "/planning") .. "/entity.json?"
    local q = { "latitude=" .. lat, "longitude=" .. lng, "exclude_field=geometry", "limit=50" }
    for _, d in ipairs(POINT_SETS) do q[#q + 1] = "dataset=" .. d end
    local at, err = get(url .. table.concat(q, "&"))
    if not at then return nil, err end
    local out = { at_the_home = {}, listed_buildings = { count = 0, nearest = {} }, brownfield = { count = 0, sites = {} } }
    for _, e in ipairs(list(at.entities)) do
        out.at_the_home[#out.at_the_home + 1] = { dataset = s(e.dataset), name = s(e.name), reference = s(e.reference),
            level = s(e["flood-risk-level"]), url = s(e["documentation-url"]) }
    end
    -- ~250 m box for listed buildings (points) and brownfield sites (small areas).
    local dlat, dlng = 0.00225, 0.00225 / math.max(0.01, math.cos(math.rad(lat)))
    local box = string.format("POLYGON((%f %f,%f %f,%f %f,%f %f,%f %f))", lng - dlng, lat - dlat, lng + dlng, lat - dlat,
        lng + dlng, lat + dlat, lng - dlng, lat + dlat, lng - dlng, lat - dlat)
    local near = get(url .. "dataset=listed-building&dataset=brownfield-land&geometry_relation=intersects"
        .. "&exclude_field=geometry&limit=100&geometry=" .. ngx.escape_uri(box))
    for _, e in ipairs(near and list(near.entities) or {}) do
        if e.dataset == "listed-building" then
            local l = out.listed_buildings
            l.count = l.count + 1
            if #l.nearest < 5 then l.nearest[#l.nearest + 1] = { name = s(e.name), grade = s(e["listed-building-grade"]) } end
        elseif e.dataset == "brownfield-land" then
            local b = out.brownfield
            b.count = b.count + 1
            if #b.sites < 5 then b.sites[#b.sites + 1] = { name = s(e.name), notes = s(e.notes) or s(e["planning-permission-type"]) } end
        end
    end
    out.at_the_home, out.listed_buildings.nearest = U.array(out.at_the_home), U.array(out.listed_buildings.nearest)
    out.brownfield.sites = U.array(out.brownfield.sites)
    return out
end

-- Environment Agency -------------------------------------------------------------------------------------------

function A.flood(lat, lng)
    local url = base("https://environment.data.gov.uk/flood-monitoring", "/ea")
    local w, err = get(url .. "/id/floods?lat=" .. lat .. "&long=" .. lng .. "&dist=3")
    if not w then return nil, err end
    local out = { warnings = {}, alert_areas_within_1km = 0, alert_areas = {} }
    for _, i in ipairs(list(w.items)) do
        if #out.warnings < 5 then
            out.warnings[#out.warnings + 1] = { severity = s(i.severity), area = s(i.description), raised = s(i.timeRaised) }
        end
    end
    local a = get(url .. "/id/floodAreas?lat=" .. lat .. "&long=" .. lng .. "&dist=1")
    for _, i in ipairs(a and list(a.items) or {}) do
        out.alert_areas_within_1km = out.alert_areas_within_1km + 1
        if #out.alert_areas < 5 then out.alert_areas[#out.alert_areas + 1] = s(i.label) end
    end
    out.warnings, out.alert_areas = U.array(out.warnings), U.array(out.alert_areas)
    return out
end

-- police.uk ----------------------------------------------------------------------------------------------------

function A.crime(lat, lng)
    local url = base("https://data.police.uk/api", "/police")
    local rows, err = get(url .. "/crimes-street/all-crime?lat=" .. lat .. "&lng=" .. lng)
    if not rows then return nil, err end
    local by, month, total = {}, nil, 0
    for _, c in ipairs(list(rows)) do
        total = total + 1
        month = month or s(c.month)
        local k = s(c.category) or "other"
        by[k] = (by[k] or 0) + 1
    end
    local top = {}
    for k, n in pairs(by) do top[#top + 1] = { category = k, count = n } end
    table.sort(top, function(x, y) return x.count > y.count end)
    while #top > 6 do table.remove(top) end
    return { month = month, within_1_mile = total, top = U.array(top) }
end

-- UK House Price Index -----------------------------------------------------------------------------------------

-- "Bristol, City of" -> city-of-bristol; "Tower Hamlets" -> tower-hamlets
local function region_slug(name)
    local a, b = name:match("^(.-),%s*(.+)$")
    if a then name = b .. " " .. a end
    return (name:lower():gsub("[^%w]+", "-"):gsub("^-", ""):gsub("-$", ""))
end

function A.prices(district)
    if not district then return nil, "no local authority for this postcode" end
    local url = base("https://landregistry.data.gov.uk", "/lr") .. "/data/ukhpi/region/" .. region_slug(district) .. "/month/"
    -- The index is published about two months behind: take the newest month it has.
    local now = os.date("!*t")
    for back = 1, 5 do
        local y, m = now.year, now.month - back
        while m < 1 do m, y = m + 12, y - 1 end
        local d = get(url .. string.format("%04d-%02d", y, m) .. ".json")
        local t = d and type(d.result) == "table" and type(d.result.primaryTopic) == "table" and d.result.primaryTopic
        if t and tonumber(t.averagePrice) then
            return { area = district, month = s(t.refMonth) or string.format("%04d-%02d", y, m),
                average = tonumber(t.averagePrice), annual_change_pct = tonumber(t.percentageAnnualChange),
                detached = tonumber(t.averagePriceDetached), semi_detached = tonumber(t.averagePriceSemiDetached),
                terraced = tonumber(t.averagePriceTerraced), flat = tonumber(t.averagePriceFlatMaisonette) }
        end
    end
    return nil, "no price index for " .. district
end

--- Everything above for a point (and the postcode's local authority). Parts that fail are listed in `missing`.
function A.collect(lat, lng, district)
    local out, missing = { sources = {} }, {}
    for _, part in ipairs({ { "planning", A.planning, lat, lng }, { "flood", A.flood, lat, lng },
                            { "crime", A.crime, lat, lng }, { "prices", A.prices, district } }) do
        local name, fn = part[1], part[2]
        local ok, res, err = pcall(fn, part[3], part[4])
        if ok and res then
            out[name] = res
            out.sources[#out.sources + 1] = A.ATTRIBUTION[name]
        else
            if not ok then ngx.log(ngx.WARN, "[property_deals] area ", name, ": ", tostring(res)) end
            missing[#missing + 1] = name
        end
    end
    out.missing, out.sources = U.array(missing), U.array(out.sources)
    return out
end

return A
