-- Matching score (SPEC §3.7): property ↔ buyer profile, 0–100, with a breakdown.
-- Default weights: budget fit 30, area fit 20, strategy fit 20, yield/discount vs
-- target 20, condition appetite 10 (plugin settings match_w_*). Each factor's fit
-- is 0–1 (unknown data = 0.5, so a thin profile neither wins nor loses); points =
-- weight × fit; score = points / total weight × 100. Any deal-breaker → 0.
-- Rules only: no model involved. Re-run when a property or profile changes.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local M = {}

M.DEFAULT_WEIGHTS = { budget = 30, area = 20, strategy = 20, yield = 20, condition = 10 }

local function n(v) if v == nil or v == db.NULL then return nil end return tonumber(v) end
local function list(v)
    v = U.json(v)
    if type(v) ~= "table" then return {} end
    return v
end

function M.weights(settings)
    settings = settings or {}
    local w = {}
    for k, d in pairs(M.DEFAULT_WEIGHTS) do w[k] = tonumber(settings["match_w_" .. k]) or d end
    return w
end

local function miles(lat1, lng1, lat2, lng2)
    local r = 3958.8
    local dlat, dlng = math.rad(lat2 - lat1), math.rad(lng2 - lng1)
    local a = math.sin(dlat / 2) ^ 2 + math.cos(math.rad(lat1)) * math.cos(math.rad(lat2)) * math.sin(dlng / 2) ^ 2
    return 2 * r * math.asin(math.sqrt(a))
end

local function in_polygon(lat, lng, pts)
    local inside, j = false, #pts
    for i = 1, #pts do
        local yi, xi, yj, xj = pts[i][1], pts[i][2], pts[j][1], pts[j][2]
        if ((yi > lat) ~= (yj > lat)) and (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) then inside = not inside end
        j = i
    end
    return inside
end

--- What strategies a property suits, from its facts.
local function strategies_for(p)
    local s = {}
    local need = ({ needs_work = true, poor = true, derelict = true, uninhabitable = true })[tostring(p.condition)]
    if n(p.est_rent_pcm) then s.btl = true end
    if need then s.flip, s.brr = true, true end
    if (n(p.bedrooms) or 0) >= 4 then s.hmo = true end
    local t = U.json(p.tenancy)
    if type(t) == "table" and next(t) then s.tenanted = true end
    local ptype = tostring(p.property_type or ""):lower()
    if ptype:find("block", 1, true) then s.blocks = true end
    if ptype:find("commercial", 1, true) then s.commercial, s.semi_commercial = true, true end
    if not next(s) then s.btl = true end -- a home with no facts is at least a possible let
    return s
end

local CONDITION_NEED = { excellent = 0, good = 0, fair = 1, dated = 1, needs_work = 2, poor = 2, derelict = 3, uninhabitable = 3 }
local APPETITE = { none = 0, light = 1, medium = 2, heavy = 3 }

--- Deal-breakers a profile lists that this property hits.
local function breakers(p, profile)
    local hit = {}
    local issues = {}
    for _, i in ipairs(list(p.known_issues)) do issues[tostring(i):lower()] = true end
    for _, b in ipairs(list(profile.deal_breakers)) do
        local key = tostring(b):lower()
        if issues[key] then hit[#hit + 1] = key
        elseif key == "leasehold" and p.tenure == "leasehold" then hit[#hit + 1] = key
        elseif key == "short_lease" and p.tenure == "leasehold" and (n(p.lease_years_left) or 999) < 85 then hit[#hit + 1] = key
        elseif key == "tenanted" and strategies_for(p).tenanted then hit[#hit + 1] = key
        elseif (key == "flood_risk" or key == "high_flood_risk") and tostring(p.flood_risk):lower():find("high", 1, true) then
            hit[#hit + 1] = key
        elseif key == "epc_f_g" and (p.epc_rating == "F" or p.epc_rating == "G") then hit[#hit + 1] = key
        end
    end
    return hit
end

--- Score one pair. ctx: { price, value (comps median or estimate) }.
function M.score(p, profile, weights, ctx)
    ctx = ctx or {}
    local f = {}
    local price = ctx.price or n(p.est_market_value)

    -- Budget: inside [min, max] = 1, fading to 0 at 20% outside.
    local lo, hi = n(profile.price_min), n(profile.price_max)
    if not price or (not lo and not hi) then
        f.budget = { fit = 0.5, why = not price and "No price yet" or "No budget on the profile" }
    else
        local fit, why = 1, "Within budget"
        if hi and price > hi then fit = math.max(0, 1 - (price - hi) / (hi * 0.2)); why = string.format("£%.0f over budget", price - hi)
        elseif lo and price < lo then fit = math.max(0, 1 - (lo - price) / (lo * 0.2)); why = "Below their minimum" end
        f.budget = { fit = fit, why = why }
    end

    -- Area: inside any area = 1; radius areas fade to 0 at twice the radius.
    local areas = list(profile.areas)
    local lat, lng = n(p.lat), n(p.lng)
    if #areas == 0 then f.area = { fit = 0.5, why = "No areas on the profile" }
    elseif not lat or not lng then f.area = { fit = 0.5, why = "Property has no location" }
    else
        local best, why = 0, "Outside their areas"
        for _, a in ipairs(areas) do
            if type(a) == "table" then
                if a.type == "polygon" and type(a.points) == "table" and #a.points >= 3 then
                    if in_polygon(lat, lng, a.points) then best, why = 1, "Inside " .. tostring(a.name or "their area") end
                elseif n(a.lat) and n(a.lng) then
                    local r = n(a.miles) or 10
                    local d = miles(lat, lng, n(a.lat), n(a.lng))
                    local fit = d <= r and 1 or math.max(0, 1 - (d - r) / r)
                    if fit > best then best, why = fit, string.format("%.1f miles from %s", d, tostring(a.name or "their centre")) end
                end
            end
        end
        f.area = { fit = best, why = why }
    end

    -- Strategy: any overlap with what the property suits.
    local wants = list(profile.strategies)
    if #wants == 0 then f.strategy = { fit = 0.5, why = "No strategies on the profile" }
    else
        local suits, hit = strategies_for(p), nil
        for _, s in ipairs(wants) do if suits[tostring(s):lower()] then hit = tostring(s):lower(); break end end
        f.strategy = hit and { fit = 1, why = "Suits " .. hit } or { fit = 0, why = "Doesn't suit their strategies" }
    end

    -- Yield and discount against their minimums.
    local rent, value = n(p.est_rent_pcm), ctx.value or n(p.est_market_value)
    local parts, whys = {}, {}
    local min_y, min_d = n(profile.min_yield_pct), n(profile.min_discount_pct)
    if min_y then
        if rent and price and price > 0 then
            local y = rent * 12 / price * 100
            parts[#parts + 1] = math.min(1, y / min_y)
            whys[#whys + 1] = string.format("yield %.1f%% (wants %.1f%%)", y, min_y)
        else parts[#parts + 1] = 0.5; whys[#whys + 1] = "no rent estimate" end
    end
    if min_d then
        if value and price and value > 0 then
            local d = (value - price) / value * 100
            parts[#parts + 1] = math.max(0, math.min(1, d / min_d))
            whys[#whys + 1] = string.format("discount %.1f%% (wants %.1f%%)", d, min_d)
        else parts[#parts + 1] = 0.5; whys[#whys + 1] = "no market value" end
    end
    if #parts == 0 then f.yield = { fit = 0.5, why = "No yield or discount target" }
    else
        local s = 0
        for _, v in ipairs(parts) do s = s + v end
        f.yield = { fit = s / #parts, why = table.concat(whys, "; ") }
    end

    -- Condition vs refurb appetite.
    local need, appetite = CONDITION_NEED[tostring(p.condition)], APPETITE[tostring(profile.refurb_appetite)]
    if not need or not appetite then f.condition = { fit = 0.5, why = "Condition or appetite unknown" }
    elseif appetite >= need then f.condition = { fit = 1, why = "Within their refurb appetite" }
    else f.condition = { fit = math.max(0, 1 - (need - appetite) / 3), why = "More work than they want" } end

    local total, points = 0, 0
    local breakdown = {}
    for k, w in pairs(weights) do
        local fit = f[k] and f[k].fit or 0.5
        total = total + w
        points = points + w * fit
        breakdown[k] = { weight = w, fit = math.floor(fit * 100 + 0.5) / 100, points = math.floor(w * fit * 10 + 0.5) / 10,
            why = f[k] and f[k].why }
    end
    local hit = breakers(p, profile)
    local score = total > 0 and math.floor(points / total * 1000 + 0.5) / 10 or 0
    if #hit > 0 then score = 0 end
    breakdown.deal_breakers = U.array(hit)
    return score, breakdown
end

local function context(ns, p)
    local deal = U.one([[SELECT COALESCE(agreed_price, offer_amount) AS price FROM property_deals_deals
        WHERE namespace_id = ? AND property_uuid = ? AND status = 'active' ORDER BY created_at DESC LIMIT 1]], ns, p.uuid)
    local comps = require("property_deals.market").comps(ns, n(p.lat), n(p.lng), { property_type = p.property_type ~= db.NULL and p.property_type or nil })
    return { price = deal and n(deal.price), value = n(p.est_market_value) or (comps and comps.median) }
end

local function store(ns, p, b, score, breakdown)
    db.query([[
        INSERT INTO property_deals_matches (namespace_id, property_uuid, buyer_profile_uuid, score, breakdown, computed_at)
        VALUES (?, ?, ?, ?, ?::jsonb, NOW())
        ON CONFLICT (property_uuid, buyer_profile_uuid) DO UPDATE SET score = EXCLUDED.score,
            breakdown = EXCLUDED.breakdown, computed_at = NOW(), updated_at = NOW()
    ]], ns, p.uuid, b.uuid, score, cjson.encode(breakdown))
end

--- Recompute matches for one property, one profile, or (neither) the workspace.
-- @return number of pairs scored
function M.recompute(ns, opts, settings)
    opts = opts or {}
    local w = M.weights(settings)
    local props = db.query("SELECT * FROM property_deals_properties WHERE namespace_id = ?"
        .. (opts.property_uuid and " AND uuid = " .. db.escape_literal(opts.property_uuid) or ""), ns)
    local profiles = db.query("SELECT * FROM property_deals_buyer_profiles WHERE namespace_id = ? AND active"
        .. (opts.buyer_profile_uuid and " AND uuid = " .. db.escape_literal(opts.buyer_profile_uuid) or ""), ns)
    local count = 0
    for _, p in ipairs(props) do
        local ctx = context(ns, p)
        for _, b in ipairs(profiles) do
            local score, breakdown = M.score(p, b, w, ctx)
            store(ns, p, b, score, breakdown)
            count = count + 1
        end
    end
    return count
end

return M
