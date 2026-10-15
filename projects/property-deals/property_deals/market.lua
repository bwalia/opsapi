-- Market data cache (property_deals_market_records): what connectors and CSV
-- imports bring in, the comparables behind a property card, and enriching a
-- workspace property from the EPC register (a deterministic lookup, not AI).
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local M = {}

M.TYPES = { sold_price = true, epc = true, listing = true, auction_lot = true, other = true }

-- Dates are parsed by Postgres (any format it reads), once per distinct value and outside the
-- import's transaction: a bad one is NULL, not an aborted import.
local function date_or_null(v, memo)
    if type(v) ~= "string" or v == "" then return db.NULL end
    v = v:gsub("^%a%a%a,%s*", "")
    if memo[v] == nil then
        local ok, r = pcall(U.one, "SELECT ?::date::text AS d", v)
        memo[v] = ok and r and r.d or db.NULL
    end
    return memo[v]
end

local function num(v)
    local n = tonumber(v)
    return n or db.NULL
end

local COLUMNS = "namespace_id, connector_uuid, source, record_type, external_id, address, postcode, lat, lng, "
    .. "property_type, tenure, bedrooms, price, event_date, epc_rating, status, cash_only, url, data"
local BATCH = 500

--- Insert or refresh records. A price change keeps the old price in previous_price
-- (the deal scout's "reduced" signal). All or nothing: one transaction, in batches of 500
-- (a record repeated in the input counts once, the last one wins). @return number of rows inserted or changed
function M.upsert(ns, conn, records)
    local Connectors = require("property_deals.connectors")
    local missing = {}
    for _, r in ipairs(records) do
        if (not r.lat or not r.lng) and r.postcode then missing[#missing + 1] = r.postcode end
    end
    local geo = #missing > 0 and Connectors.geocode(ns, missing) or {}
    local source = (conn and conn.kind) or nil
    local rows, at, dates = {}, {}, {}
    for _, r in ipairs(records) do
        if r.external_id and M.TYPES[r.record_type or ""] then
            local g = r.postcode and geo[tostring(r.postcode):upper()]
            local lat, lng = tonumber(r.lat) or (g and g.lat), tonumber(r.lng) or (g and g.lng)
            local src = source or r.source or "csv"
            local id = U.cut(U.utf8(tostring(r.external_id)), 255)
            local values = db.interpolate_query("(" .. string.rep("?, ", 13) .. "?::date, ?, ?, ?, ?, ?::jsonb)",
                ns, conn and conn.uuid or db.NULL, src, r.record_type, id, r.address or db.NULL,
                r.postcode or db.NULL, lat or db.NULL, lng or db.NULL, r.property_type or db.NULL, r.tenure or db.NULL,
                num(r.bedrooms), num(r.price), date_or_null(r.event_date, dates), r.epc_rating or db.NULL,
                r.status or db.NULL, r.cash_only == true, r.url or db.NULL, cjson.encode(r.data or {}))
            local key = src .. "\0" .. id
            if at[key] then rows[at[key]] = values else rows[#rows + 1] = values; at[key] = #rows end
        end
    end
    return U.tx(function()
        local stored = 0
        for i = 1, #rows, BATCH do
            local res = db.query("INSERT INTO property_deals_market_records (" .. COLUMNS .. ") VALUES "
                .. table.concat(rows, ", ", i, math.min(i + BATCH - 1, #rows)) .. [[
                ON CONFLICT (namespace_id, source, external_id) DO UPDATE SET
                    previous_price = CASE WHEN EXCLUDED.price IS DISTINCT FROM property_deals_market_records.price
                                          THEN property_deals_market_records.price
                                          ELSE property_deals_market_records.previous_price END,
                    price = EXCLUDED.price, status = EXCLUDED.status, cash_only = EXCLUDED.cash_only,
                    address = EXCLUDED.address, lat = COALESCE(EXCLUDED.lat, property_deals_market_records.lat),
                    lng = COALESCE(EXCLUDED.lng, property_deals_market_records.lng), data = EXCLUDED.data,
                    epc_rating = EXCLUDED.epc_rating, fetched_at = NOW(), updated_at = NOW()
                WHERE property_deals_market_records.price IS DISTINCT FROM EXCLUDED.price
                   OR property_deals_market_records.status IS DISTINCT FROM EXCLUDED.status
                   OR property_deals_market_records.cash_only IS DISTINCT FROM EXCLUDED.cash_only
                   OR property_deals_market_records.lat IS NULL
                RETURNING id
            ]])
            stored = stored + #res
        end
        return stored
    end)
end

--- Sold-price comparables near a point: median, count, the window used.
function M.comps(ns, lat, lng, opts)
    opts = opts or {}
    if not lat or not lng then return nil end
    local miles, months = opts.radius_miles or 1, opts.months or 24
    local dlat, dlng = miles / 69.0, miles / math.max(0.01, 69.0 * math.cos(math.rad(lat)))
    local type_sql = opts.property_type and " AND LOWER(property_type) = LOWER(" .. db.escape_literal(opts.property_type) .. ")" or ""
    local r = U.one([[
        SELECT COUNT(*)::int AS n, percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::float AS median,
               MIN(event_date)::text AS from_date, MAX(event_date)::text AS to_date
        FROM property_deals_market_records
        WHERE namespace_id = ? AND record_type = 'sold_price' AND price IS NOT NULL
          AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?
          AND ]] .. U.miles_sql("lat", "lng", lat, lng) .. [[ <= ?
          AND (event_date IS NULL OR event_date >= CURRENT_DATE - make_interval(months => ?))]] .. type_sql,
        ns, lat - dlat, lat + dlat, lng - dlng, lng + dlng, miles, months)
    if not r or r.n == 0 then return { count = 0, radius_miles = miles, months = months } end
    return { count = r.n, median = r.median, radius_miles = miles, months = months, from = r.from_date, to = r.to_date }
end

local function norm(s)
    return (tostring(s or ""):upper():gsub("[^%w ]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- Look the property up in the EPC register (and fetch nearby sold prices) when
-- the workspace has those connectors. Fills epc_rating / certificate / expiry when
-- a certificate's address matches. @return { epc = record|nil, sold_prices = n } | nil, err
function M.enrich_property(ns, property_uuid)
    local Connectors = require("property_deals.connectors")
    local p = U.one("SELECT * FROM property_deals_properties WHERE namespace_id = ? AND uuid = ?", ns, property_uuid)
    if not p then return nil, "Property not found" end
    local out = { sold_prices = 0 }
    -- On the map: prefer Google street-level geocode, else the postcode centre (postcodes.io).
    if p.lat == db.NULL or p.lng == db.NULL or not p.lat or not p.lng then
        local g = Connectors.geocode_address(ns, {
            address_line1 = p.address_line1 ~= db.NULL and p.address_line1 or nil,
            address_line2 = p.address_line2 ~= db.NULL and p.address_line2 or nil,
            town = p.town ~= db.NULL and p.town or nil,
            county = p.county ~= db.NULL and p.county or nil,
            postcode = p.postcode ~= db.NULL and p.postcode or nil,
            country = p.country ~= db.NULL and p.country or "GB",
        })
        if not g and p.postcode and p.postcode ~= db.NULL then
            g = Connectors.geocode(ns, { p.postcode })[tostring(p.postcode):upper():gsub("%s+", " ")]
            if g then g.source = "postcodes.io" end
        end
        if g then
            db.update("property_deals_properties", { lat = g.lat, lng = g.lng, updated_at = db.raw("NOW()") }, { id = p.id })
            out.geocoded = true
            out.geocode_source = g.source
            p.lat, p.lng = g.lat, g.lng
        end
    end
    if p.postcode == db.NULL or not p.postcode then
        if out.geocoded then return out end
        return nil, "The property has no postcode"
    end
    local pp = Connectors.of_kind(ns, "price_paid")
    if pp then
        local r = Connectors.run(ns, pp, { postcode = p.postcode })
        out.sold_prices = r and r.fetched or 0
    end
    local epc = Connectors.of_kind(ns, "epc")
    if epc then
        local r, err = Connectors.run(ns, epc, { postcode = p.postcode })
        if not r then out.epc_error = err end
        local want = norm(p.address_line1)
        local best
        for _, rec in ipairs(db.query([[
            SELECT * FROM property_deals_market_records WHERE namespace_id = ? AND record_type = 'epc'
              AND UPPER(REPLACE(postcode, ' ', '')) = UPPER(REPLACE(?, ' ', '')) ORDER BY event_date DESC NULLS LAST
        ]], ns, p.postcode)) do
            local have = norm(rec.address)
            if want ~= "" and (have == want or have:sub(1, #want + 1) == want .. " ") then best = rec; break end
        end
        if best then
            local d = U.json(best.data) or {}
            local changes = { updated_at = db.raw("NOW()") }
            if best.epc_rating ~= db.NULL then changes.epc_rating = best.epc_rating end
            if d.certificate_number then changes.epc_certificate_number = tostring(d.certificate_number):sub(1, 40) end
            if d.expires_on then changes.epc_expires_on = d.expires_on end
            if (p.floor_area_sqm == db.NULL or not p.floor_area_sqm) and d.floor_area_sqm then changes.floor_area_sqm = d.floor_area_sqm end
            local meta = U.json(p.metadata) or {}
            meta.epc_source = { market_record_uuid = best.uuid, matched_address = best.address, at = require("property_deals.workdays").now() }
            changes.metadata = cjson.encode(meta)
            db.update("property_deals_properties", changes, { id = p.id })
            out.epc = { rating = best.epc_rating, certificate_number = d.certificate_number, expires_on = d.expires_on,
                address = best.address }
        end
    end
    return out
end

return M
