-- The SRA's register of solicitors' firms, for the deal autopilot's conveyancers (property_deals/research.lua).
-- Free with a key the workspace registers itself (www.sra.org.uk/datasharing; the key is personal, so one per
-- workspace, in a "sra" data connector). Its terms let us store and reuse the data in our product with the SRA's
-- attribution and without sending advertising; each office carries its address, phone, email and website.
-- Reg.sync keeps a workspace copy of the offices of authorised firms that do residential property work
-- (property_deals_register_offices, refreshed daily); Reg.near finds the closest to a deal.
-- The V1 field names are read case-insensitively from their usual spellings (PracticeName, Offices, WorkArea...),
-- so a renamed field shows up as "0 firms read" in the connector's last error rather than as wrong data.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local Reg = {}

Reg.ATTRIBUTION = "Contains data from the Solicitors Regulation Authority (www.sra.org.uk/datasharing)"
local DEFAULT_URL = "https://sra-prod-apim.azure-api.net"
local PATH = "/datashare/api/V1/organisation/GetAll"
local STALE_HOURS = 24

local function keys(t)
    local out = {}
    for k, v in pairs(t) do if type(k) == "string" then out[k:lower():gsub("[^%w]", "")] = v end end
    return out
end

local function pick(t, ...)
    for _, k in ipairs({ ... }) do
        local v = t[k]
        if v ~= nil and v ~= cjson.null and v ~= "" then return v end
    end
end

local function str(v, max)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" then return nil end
    v = v:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return v ~= "" and U.cut(v, max or 200) or nil
end

local function postcode(v)
    v = v and v:upper():gsub("%s+", "")
    if not v or not v:match("^%a%a?%d[%dA-Z]?%d%a%a$") then return nil end
    return v:sub(1, -4) .. " " .. v:sub(-3)
end

local function email(v) return v and v:lower():match("^[%w%._%%+%-]+@[%w%.%-]+%.%a%a+$") or nil end

local function website(v)
    if not v then return nil end
    if not v:match("^https?://") then v = "https://" .. v end
    return v:match("^https?://[%w%.%-]+%.%a%a+") and v or nil
end

local function list_of(data)
    if type(data) ~= "table" then return {} end
    if data[1] ~= nil then return data end
    local l = keys(data)
    local v = pick(l, "organisations", "organisation", "data", "items", "results")
    return type(v) == "table" and v or {}
end

local function work_areas(o)
    local v = pick(o, "workarea", "workareas", "areasoflaw", "areaoflaw", "areasofpractice")
    local out = {}
    if type(v) == "string" then
        for part in v:gmatch("[^,;|]+") do out[#out + 1] = str(part) end
    elseif type(v) == "table" then
        for _, x in ipairs(v) do
            if type(x) == "table" then x = pick(keys(x), "name", "description", "workarea", "value") end
            out[#out + 1] = str(x)
        end
    end
    return out
end

-- Residential conveyancing: the register's work area "Property - residential" (or anything naming conveyancing).
local function residential(areas)
    for _, a in ipairs(areas) do
        local l = a:lower()
        if (l:find("property", 1, true) and l:find("residential", 1, true)) or l:find("conveyanc", 1, true) then
            return true
        end
    end
    return false
end

local function authorised(o)
    local s = str(pick(o, "authorisationstatus", "status"))
    return s == nil or s:lower():match("^authori[sz]ed") ~= nil
end

--- Offices of authorised firms doing residential property work, from a GetAll answer.
function Reg.parse(data)
    local out = {}
    for _, org in ipairs(list_of(data)) do
        if type(org) == "table" then
            local o = keys(org)
            if authorised(o) and residential(work_areas(o)) then
                local ref = str(pick(o, "sranumber", "sraid", "organisationid", "id"), 40)
                local name = str(pick(o, "practicename", "organisationname", "name", "tradingname"))
                local offices = pick(o, "offices", "office")
                offices = type(offices) == "table" and (offices[1] ~= nil and offices or { offices }) or { org }
                for i, off in ipairs(offices) do
                    if type(off) == "table" and ref and name then
                        local f = keys(off)
                        local addr = {}
                        for _, k in ipairs({ "address1", "address2", "address3", "address4", "addressline1",
                                             "addressline2", "addressline3" }) do
                            addr[#addr + 1] = str(pick(f, k), 120)
                        end
                        out[#out + 1] = {
                            firm_ref = ref, firm_name = name,
                            office_ref = str(pick(f, "officeid", "officesranumber", "id"), 60) or (ref .. ":" .. i),
                            address = #addr > 0 and table.concat(addr, ", ") or nil,
                            town = str(pick(f, "town", "city"), 80),
                            postcode = postcode(str(pick(f, "postcode", "postalcode"), 12)),
                            phone = str(pick(f, "phonenumber", "telephonenumber", "telephone", "phone")
                                or pick(o, "phonenumber", "telephonenumber", "telephone", "phone"), 40),
                            email = email(str(pick(f, "email", "emailaddress") or pick(o, "email", "emailaddress"), 200)),
                            website = website(str(pick(f, "website", "websiteaddress", "web")
                                or pick(o, "website", "websiteaddress", "web"), 300)),
                        }
                    end
                end
            end
        end
    end
    return out
end

--- Refresh the workspace's copy of the register (points already found are kept). @return offices | nil, err
function Reg.sync(ns, conn)
    local C = require("property_deals.connectors")
    local key = C.secret(conn)
    if not key then return nil, "The SRA connector has no key" end
    local cfg = U.json(conn.config) or {}
    local url = ((type(cfg.base_url) == "string" and cfg.base_url ~= "" and cfg.base_url) or DEFAULT_URL):gsub("/+$", "")
    local res, err = require("property_deals.http").request(url .. PATH, { method = "GET",
        headers = { ["Ocp-Apim-Subscription-Key"] = key, Accept = "application/json" } }, 120000)
    local why
    if not res then
        ngx.log(ngx.WARN, "[property_deals] SRA register: ", tostring(err))
        why = "could not reach the SRA"
    elseif res.status >= 300 then
        ngx.log(ngx.WARN, "[property_deals] SRA register answered HTTP ", res.status)
        why = "the SRA answered HTTP " .. res.status .. (res.status == 401 and " (check the key)" or "")
    end
    local data = not why and require("cjson.safe").decode(res.body or "")
    local offices = data and Reg.parse(data) or {}
    if not why and #offices == 0 then why = "no firms could be read from the SRA's answer" end
    if why then
        db.update("property_deals_connectors", { last_error = why, updated_at = db.raw("NOW()") }, { id = conn.id })
        return nil, why
    end
    U.tx(function()
        local old = {}
        for _, r in ipairs(db.query([[SELECT office_ref, postcode, lat, lng, geocoded_at FROM property_deals_register_offices
            WHERE namespace_id = ? AND register = 'sra']], ns)) do old[r.office_ref] = r end
        db.query("DELETE FROM property_deals_register_offices WHERE namespace_id = ? AND register = 'sra'", ns)
        for i = 1, #offices, 200 do
            local rows = {}
            for j = i, math.min(i + 199, #offices) do
                local o = offices[j]
                local was = old[o.office_ref]
                local keep = was and was.postcode == (o.postcode or db.NULL)
                rows[#rows + 1] = db.interpolate_query("(?, 'sra', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", ns, o.firm_ref,
                    o.firm_name, o.office_ref, o.address or db.NULL, o.town or db.NULL, o.postcode or db.NULL,
                    o.phone or db.NULL, o.email or db.NULL, o.website or db.NULL,
                    keep and was.lat or db.NULL, keep and was.lng or db.NULL, keep and was.geocoded_at or db.NULL)
            end
            db.query([[INSERT INTO property_deals_register_offices (namespace_id, register, firm_ref, firm_name, office_ref,
                address, town, postcode, phone, email, website, lat, lng, geocoded_at) VALUES ]] .. table.concat(rows, ", ")
                .. " ON CONFLICT (namespace_id, register, office_ref) DO NOTHING")
        end
    end)
    db.update("property_deals_connectors", { last_run_at = db.raw("NOW()"), last_error = db.NULL,
        records_count = #offices, updated_at = db.raw("NOW()") }, { id = conn.id })
    return #offices
end

--- The SRA connector, synced if its copy is older than a day. @return conn | nil, why
function Reg.ready(ns)
    local conn = require("property_deals.connectors").of_kind(ns, "sra")
    if not conn then return nil, "Add the SRA register (a free key) in Deals settings → Data connectors" end
    local fresh = U.one([[SELECT 1 FROM property_deals_register_offices WHERE namespace_id = ? AND register = 'sra'
        AND fetched_at > NOW() - make_interval(hours => ?) LIMIT 1]], ns, STALE_HOURS)
    if not fresh then
        local n, err = Reg.sync(ns, conn)
        if not n then return nil, "SRA register: " .. err end
    end
    return conn
end

--- Nearest offices with an email, one per firm, within `radius` miles of the point.
-- ponytail: offices are put on the map by postcode area (YO, LS...) as deals need them, so a firm just over an
-- area border is found once a deal in its own area has been researched; geocode neighbouring areas if that bites.
function Reg.near(ns, lat, lng, home_postcode, radius, limit)
    local area = home_postcode and home_postcode:upper():match("^(%a%a?)%d")
    if area then
        local need = db.query([[SELECT DISTINCT postcode FROM property_deals_register_offices WHERE namespace_id = ?
            AND register = 'sra' AND geocoded_at IS NULL AND postcode ~ ? LIMIT 300]], ns, "^" .. area .. "[0-9]")
        local codes = {}
        for _, r in ipairs(need) do codes[#codes + 1] = r.postcode end
        if #codes > 0 then
            local points = require("property_deals.connectors").geocode(ns, codes)
            for _, c in ipairs(codes) do
                local p = points[c]
                db.query([[UPDATE property_deals_register_offices SET lat = ?, lng = ?, geocoded_at = NOW()
                    WHERE namespace_id = ? AND register = 'sra' AND postcode = ?]],
                    p and p.lat or db.NULL, p and p.lng or db.NULL, ns, c)
            end
        end
    end
    local dlat, dlng = radius / 69.0, radius / math.max(0.01, 69.0 * math.cos(math.rad(lat)))
    local dist = U.miles_sql("lat", "lng", lat, lng)
    return db.query([[
        SELECT * FROM (
            SELECT DISTINCT ON (firm_ref) *, ]] .. dist .. [[ AS distance_miles FROM property_deals_register_offices
            WHERE namespace_id = ? AND register = 'sra' AND email IS NOT NULL AND lat IS NOT NULL
              AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ? AND ]] .. dist .. [[ <= ?
            ORDER BY firm_ref, distance_miles
        ) nearest ORDER BY distance_miles LIMIT ?
    ]], ns, lat - dlat, lat + dlat, lng - dlng, lng + dlng, radius, limit)
end

return Reg
