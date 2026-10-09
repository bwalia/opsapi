-- Map / deal finder (SPEC §3.6):
--   GET /map?lat=&lng=&radius_miles=25&layers=properties,deals,leads,holdings
--   GET /map?polygon=lat,lng;lat,lng;lat,lng&layers=...
--   GET /properties/:id/card    the map's property card: summary, deal, yield/discount, top 3 matching buyers
-- Radius: bounding-box prefilter on (namespace_id, lat, lng), then exact haversine
-- distance. Polygon: Postgres' built-in polygon @> point (planar; fine at county
-- scale). Layers from data connectors (sold prices, EPC, listings, auction lots)
-- arrive with Phase 6 under the same `features` shape.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")

local MAX_FEATURES = 2000
local EARTH_MILES = 3958.8
local LAYERS = { properties = true, deals = true, leads = true, holdings = true }

local function haversine_sql(lat_col, lng_col, lat, lng)
    return string.format([[(%f * 2 * asin(sqrt(power(sin(radians(%s - %f) / 2), 2)
        + cos(radians(%f)) * cos(radians(%s)) * power(sin(radians(%s - %f) / 2), 2))))]],
        EARTH_MILES, lat_col, lat, lat, lat_col, lng_col, lng)
end

--- Parse "lat,lng;lat,lng;..." into a list of {lat,lng} (3..200 points).
local function parse_polygon(s)
    local pts = {}
    for lat, lng in tostring(s):gmatch("(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)") do
        lat, lng = tonumber(lat), tonumber(lng)
        if not lat or not lng or lat < -90 or lat > 90 or lng < -180 or lng > 180 then return nil end
        pts[#pts + 1] = { lat, lng }
    end
    if #pts < 3 or #pts > 200 then return nil end
    return pts
end

--- The area filter for a lat/lng column pair, and a distance expression (or NULL).
local function area(p, lat_col, lng_col)
    if p.polygon then
        local coords, minlat, maxlat, minlng, maxlng = {}, 90, -90, 180, -180
        for _, pt in ipairs(p.polygon) do
            coords[#coords + 1] = string.format("(%f,%f)", pt[2], pt[1])
            minlat, maxlat = math.min(minlat, pt[1]), math.max(maxlat, pt[1])
            minlng, maxlng = math.min(minlng, pt[2]), math.max(maxlng, pt[2])
        end
        return string.format("%s BETWEEN %f AND %f AND %s BETWEEN %f AND %f AND polygon '(%s)' @> point(%s, %s)",
            lat_col, minlat, maxlat, lng_col, minlng, maxlng, table.concat(coords, ","), lng_col, lat_col), "NULL"
    end
    local dlat = p.radius / 69.0
    local dlng = p.radius / math.max(0.01, 69.0 * math.cos(math.rad(p.lat)))
    local dist = haversine_sql(lat_col, lng_col, p.lat, p.lng)
    return string.format("%s BETWEEN %f AND %f AND %s BETWEEN %f AND %f AND %s <= %f",
        lat_col, p.lat - dlat, p.lat + dlat, lng_col, p.lng - dlng, p.lng + dlng, dist, p.radius), dist
end

local function params(self)
    local q = self.params
    local p = { layers = {} }
    for name in tostring(q.layers or "properties,deals"):gmatch("[%w_]+") do
        if not LAYERS[name] then return nil, { layers = "unknown layer '" .. name .. "' (properties, deals, leads, holdings)" } end
        p.layers[name] = true
    end
    if q.polygon and q.polygon ~= "" then
        p.polygon = parse_polygon(q.polygon)
        if not p.polygon then return nil, { polygon = "3 to 200 points as lat,lng;lat,lng;..." } end
        return p
    end
    p.lat, p.lng = tonumber(q.lat), tonumber(q.lng)
    if not p.lat or not p.lng or p.lat < -90 or p.lat > 90 or p.lng < -180 or p.lng > 180 then
        return nil, { lat = "lat and lng are required (or a polygon)" }
    end
    p.radius = tonumber(q.radius_miles) or 25
    if p.radius < 1 or p.radius > 100 then return nil, { radius_miles = "must be between 1 and 100" } end
    return p
end

return function(app)
    app:get("/map", sdk.handler({ permission = "property_deals_properties.read" }, function(self)
        local p, errs = params(self)
        if not p then return sdk.error(422, "Validation failed", errs) end
        local ns = db.escape_literal(sdk.namespace_id(self))
        local features, counts = {}, {}
        local function add(layer, rows)
            counts[layer] = #rows
            for _, r in ipairs(rows) do
                r.layer = layer
                features[#features + 1] = r
            end
        end

        local where, dist = area(p, "p.lat", "p.lng")
        if p.layers.properties or p.layers.deals then
            local rows = db.query([[
                SELECT p.uuid, p.lat, p.lng, p.address_line1 AS title, p.postcode AS subtitle, p.tenure, p.epc_rating,
                       p.bedrooms, p.est_market_value, ]] .. dist .. [[ AS distance_miles,
                       dl.uuid AS deal_uuid, dl.stage_key AS deal_stage, dl.health AS deal_health, cd.name AS deal_name
                FROM property_deals_properties p
                LEFT JOIN LATERAL (SELECT * FROM property_deals_deals d WHERE d.property_uuid = p.uuid AND d.status = 'active'
                                   ORDER BY d.created_at DESC LIMIT 1) dl ON TRUE
                LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
                WHERE p.namespace_id = ]] .. ns .. [[ AND p.lat IS NOT NULL AND ]] .. where .. [[
                ORDER BY distance_miles NULLS LAST LIMIT ]] .. (MAX_FEATURES + 1))
            local props, deals = {}, {}
            for _, r in ipairs(rows) do
                if r.deal_uuid then deals[#deals + 1] = r elseif p.layers.properties then props[#props + 1] = r end
            end
            if p.layers.deals then add("deals", deals) end
            if p.layers.properties then add("properties", props) end
        end
        if p.layers.leads then
            add("leads", db.query([[
                SELECT l.uuid, p.lat, p.lng, trim(l.first_name || ' ' || COALESCE(l.last_name, '')) AS title,
                       p.address_line1 AS subtitle, ld.lead_kind, ld.situation, ld.deadline_date, l.status,
                       ]] .. dist .. [[ AS distance_miles, p.uuid AS property_uuid
                FROM property_deals_lead_details ld
                JOIN crm_leads l ON l.uuid = ld.lead_uuid AND l.deleted_at IS NULL
                JOIN property_deals_properties p ON p.uuid = ld.property_uuid
                WHERE ld.namespace_id = ]] .. ns .. [[ AND p.lat IS NOT NULL AND ]] .. where .. [[
                ORDER BY distance_miles NULLS LAST LIMIT ]] .. MAX_FEATURES))
        end
        if p.layers.holdings then
            local hw, hd = area(p, "(h->>'lat')::float8", "(h->>'lng')::float8")
            add("holdings", db.query([[
                SELECT b.uuid, (h->>'lat')::float8 AS lat, (h->>'lng')::float8 AS lng,
                       COALESCE(h->>'address', 'Holding') AS title,
                       COALESCE(c.first_name || COALESCE(' ' || c.last_name, ''), a.name) AS subtitle,
                       ]] .. hd .. [[ AS distance_miles
                FROM property_deals_buyer_profiles b
                CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(b.holdings) = 'array' THEN b.holdings ELSE '[]' END) h
                LEFT JOIN crm_contacts c ON c.uuid = b.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = b.account_uuid
                WHERE b.namespace_id = ]] .. ns .. [[ AND (h->>'lat') IS NOT NULL AND (h->>'lng') IS NOT NULL AND ]] .. hw .. [[
                LIMIT ]] .. MAX_FEATURES))
        end
        local truncated = #features > MAX_FEATURES
        while #features > MAX_FEATURES do table.remove(features) end
        return sdk.ok({
            center = p.lat and { lat = p.lat, lng = p.lng } or cjson.null,
            radius_miles = p.radius or cjson.null, polygon = p.polygon and sdk.array(p.polygon) or cjson.null,
            features = sdk.array(features), counts = counts, truncated = truncated,
        })
    end))

    app:get("/properties/:id/card", sdk.handler({ permission = "property_deals_properties.read" }, function(self)
        local ns = sdk.namespace_id(self)
        if not U.is_uuid(self.params.id) then return sdk.not_found("Property") end
        local prop = U.one("SELECT * FROM property_deals_properties WHERE namespace_id = ? AND uuid = ?", ns, self.params.id)
        if not prop then return sdk.not_found("Property") end
        local deal = U.one([[
            SELECT dl.uuid, cd.name, dl.stage_key, dl.health, dl.money_at_risk, dl.offer_amount, dl.agreed_price
            FROM property_deals_deals dl JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
            WHERE dl.namespace_id = ? AND dl.property_uuid = ? AND dl.status = 'active' ORDER BY dl.created_at DESC LIMIT 1
        ]], ns, prop.uuid)
        local price = deal and tonumber(deal.agreed_price or deal.offer_amount)
        local value, rent = tonumber(prop.est_market_value), tonumber(prop.est_rent_pcm)
        local matches = db.query([[
            SELECT m.uuid, m.buyer_profile_uuid, m.score, m.breakdown, m.status,
                   COALESCE(c.first_name || COALESCE(' ' || c.last_name, ''), a.name) AS buyer_name
            FROM property_deals_matches m
            JOIN property_deals_buyer_profiles b ON b.uuid = m.buyer_profile_uuid
            LEFT JOIN crm_contacts c ON c.uuid = b.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = b.account_uuid
            WHERE m.namespace_id = ? AND m.property_uuid = ? ORDER BY m.score DESC LIMIT 3
        ]], ns, prop.uuid)
        return sdk.ok({
            property = prop, deal = deal or cjson.null,
            gross_yield_pct = (rent and (price or value)) and math.floor(rent * 12 / (price or value) * 1000 + 0.5) / 10 or cjson.null,
            discount_pct = (price and value and value > 0) and math.floor((1 - price / value) * 1000 + 0.5) / 10 or cjson.null,
            top_matches = sdk.array(matches),
        })
    end))
end
