-- Deal scout (SPEC §3.6): re-runs every saved search against the market data
-- (listings and auction lots from connectors / CSV) and alerts the owner about
--   new        first seen since the last run (the first run only sets the baseline)
--   reduced    price lower than before
--   stale      on the market longer than the search's stale_after_days
--   cash_only  marked cash buyers only
-- Each home + kind + price alerts once (unique index), so re-runs are quiet.
-- Also syncs connectors that have sync_enabled for the postcodes the workspace cares about.
local db = require("lapis.db")
local U = require("property_deals.util")

local S = {}

local function area_sql(s)
    local poly = U.json(s.polygon)
    if type(poly) == "table" and #poly >= 3 then
        local coords, minlat, maxlat, minlng, maxlng = {}, 90, -90, 180, -180
        for _, pt in ipairs(poly) do
            local lat, lng = tonumber(pt[1]), tonumber(pt[2])
            if lat and lng then
                coords[#coords + 1] = string.format("(%f,%f)", lng, lat)
                minlat, maxlat = math.min(minlat, lat), math.max(maxlat, lat)
                minlng, maxlng = math.min(minlng, lng), math.max(maxlng, lng)
            end
        end
        return string.format("m.lat BETWEEN %f AND %f AND m.lng BETWEEN %f AND %f AND polygon '(%s)' @> point(m.lng, m.lat)",
            minlat, maxlat, minlng, maxlng, table.concat(coords, ","))
    end
    local lat, lng, r = tonumber(s.lat), tonumber(s.lng), tonumber(s.radius_miles) or 25
    local dlat, dlng = r / 69.0, r / math.max(0.01, 69.0 * math.cos(math.rad(lat)))
    return string.format("m.lat BETWEEN %f AND %f AND m.lng BETWEEN %f AND %f AND "
        .. "earth_distance(ll_to_earth(m.lat, m.lng), ll_to_earth(%f, %f)) <= %f",
        lat - dlat, lat + dlat, lng - dlng, lng + dlng, lat, lng, r * 1609.344)
end

local function filters_sql(s)
    local f = U.json(s.filters) or {}
    local w = {}
    if tonumber(f.min_price) then w[#w + 1] = "m.price >= " .. tonumber(f.min_price) end
    if tonumber(f.max_price) then w[#w + 1] = "m.price <= " .. tonumber(f.max_price) end
    if tonumber(f.min_bedrooms) then w[#w + 1] = "m.bedrooms >= " .. tonumber(f.min_bedrooms) end
    local types = type(f.record_types) == "table" and f.record_types or { "listing", "auction_lot" }
    local lits = {}
    for _, t in ipairs(types) do lits[#lits + 1] = db.escape_literal(tostring(t)) end
    w[#w + 1] = "m.record_type IN (" .. table.concat(lits, ",") .. ")"
    if type(f.property_types) == "table" and #f.property_types > 0 then
        local pts = {}
        for _, t in ipairs(f.property_types) do pts[#pts + 1] = db.escape_literal(tostring(t):lower()) end
        w[#w + 1] = "LOWER(m.property_type) IN (" .. table.concat(pts, ",") .. ")"
    end
    return table.concat(w, " AND ")
end

--- Run one saved search. @return { new, reduced, stale, cash_only }
function S.run_search(ns, s)
    local since = s.last_run_at ~= db.NULL and s.last_run_at or s.created_at
    local base = "FROM property_deals_market_records m WHERE m.namespace_id = " .. db.escape_literal(ns)
        .. " AND m.lat IS NOT NULL AND " .. area_sql(s) .. " AND " .. filters_sql(s)
        .. " AND COALESCE(m.status, '') NOT IN ('sold', 'withdrawn', 'removed')"
    local out = { new = 0, reduced = 0, stale = 0, cash_only = 0 }
    local function alert(kind, detail_sql, where)
        local rows = db.query([[
            INSERT INTO property_deals_scout_alerts (namespace_id, saved_search_uuid, market_record_uuid, kind, detail,
                price, previous_price)
            SELECT ]] .. db.escape_literal(ns) .. ", " .. db.escape_literal(s.uuid) .. ", m.uuid, '" .. kind .. "', "
                .. detail_sql .. [[, m.price, m.previous_price ]] .. base .. " AND " .. where .. [[
            ON CONFLICT DO NOTHING RETURNING id
        ]])
        out[kind] = #rows
    end
    local since_lit = db.escape_literal(since)
    alert("new", "COALESCE(m.address, m.postcode)", "m.first_seen_at > " .. since_lit .. "::timestamptz")
    alert("reduced", "'£' || m.previous_price::bigint || ' → £' || m.price::bigint",
        "m.previous_price IS NOT NULL AND m.price < m.previous_price AND m.updated_at > " .. since_lit .. "::timestamptz")
    alert("stale", "'on the market ' || (CURRENT_DATE - m.first_seen_at::date) || ' days'",
        "m.first_seen_at < NOW() - make_interval(days => " .. (tonumber(s.stale_after_days) or 90) .. ")")
    alert("cash_only", "'cash buyers only'", "m.cash_only")
    db.update("property_deals_saved_searches", { last_run_at = db.raw("NOW()") }, { id = s.id })
    return out
end

function S.run(ns, settings)
    local total = { searches = 0, alerts = 0 }
    for _, s in ipairs(db.query("SELECT * FROM property_deals_saved_searches WHERE namespace_id = ? AND alerts", ns)) do
        local r = S.run_search(ns, s)
        local n = r.new + r.reduced + r.stale + r.cash_only
        total.searches, total.alerts = total.searches + 1, total.alerts + n
        if n > 0 and s.owner_user_uuid ~= db.NULL then
            local parts = {}
            for _, k in ipairs({ "new", "reduced", "stale", "cash_only" }) do
                if r[k] > 0 then parts[#parts + 1] = r[k] .. " " .. k:gsub("_", " ") end
            end
            require("property_deals.notify").send(ns, { s.owner_user_uuid }, { kind = "scout_alert",
                event = "property_deals.saved_search.alerts", route = "saved_search", uuid = s.uuid,
                title = "Deal scout: " .. s.name, body = table.concat(parts, ", ") })
        end
    end
    return total
end

--- Fetch fresh data for the postcodes the workspace cares about: its active deals'
-- properties and its saved searches' pins (nearest postcode). At most 25 per run.
function S.sync(ns)
    local C = require("property_deals.connectors")
    local conns = db.query([[SELECT * FROM property_deals_connectors WHERE namespace_id = ? AND enabled AND sync_enabled
        AND kind IN ('price_paid', 'epc')]], ns)
    if #conns == 0 then return { connectors = 0, postcodes = 0, stored = 0 } end
    local postcodes, seen = {}, {}
    local function add(p) if p and not seen[p] and #postcodes < 25 then seen[p] = true; postcodes[#postcodes + 1] = p end end
    for _, r in ipairs(db.query([[
        SELECT DISTINCT p.postcode FROM property_deals_deals d JOIN property_deals_properties p ON p.uuid = d.property_uuid
        WHERE d.namespace_id = ? AND d.status = 'active' AND p.postcode IS NOT NULL
    ]], ns)) do add(r.postcode) end
    for _, s in ipairs(db.query("SELECT lat, lng FROM property_deals_saved_searches WHERE namespace_id = ? AND lat IS NOT NULL", ns)) do
        local ok, p = pcall(C.reverse_geocode, ns, s.lat, s.lng)
        if ok then add(p) end
    end
    local stored = 0
    for _, c in ipairs(conns) do
        for _, p in ipairs(postcodes) do
            local r = C.run(ns, c, { postcode = p })
            if r then stored = stored + r.stored end
        end
    end
    return { connectors = #conns, postcodes = #postcodes, stored = stored }
end

return S
