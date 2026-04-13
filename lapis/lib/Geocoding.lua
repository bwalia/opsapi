--[[
    Professional Geocoding Service

    This module provides address geocoding using multiple providers with fallback:
    1. OpenStreetMap Nominatim (Free, no API key required)
    2. Google Maps Geocoding API (Paid, high accuracy - future implementation)
    3. Database cache to minimize API calls

    Author: Senior Backend Engineer
    Date: 2025-01-26
]]--

local http = require("resty.http")
local cjson = require("cjson")
local db = require("lapis.db")

local Geocoding = {}
Geocoding.__index = Geocoding

-- Initialize geocoding service
function Geocoding.new()
    local self = setmetatable({}, Geocoding)
    self.nominatim_base_url = "https://nominatim.openstreetmap.org"
    self.user_agent = "KisaanMultiTenantPlatform/1.0"
    self.cache_enabled = true
    return self
end

-- Format address object into a searchable string
function Geocoding:formatAddress(address_obj)
    if type(address_obj) ~= "table" then
        return nil, "Address must be a table"
    end

    local parts = {}

    -- Build address string from components
    if address_obj.address1 and address_obj.address1 ~= "" then
        table.insert(parts, address_obj.address1)
    end

    if address_obj.address2 and address_obj.address2 ~= "" then
        table.insert(parts, address_obj.address2)
    end

    if address_obj.city and address_obj.city ~= "" then
        table.insert(parts, address_obj.city)
    end

    if address_obj.state and address_obj.state ~= "" then
        table.insert(parts, address_obj.state)
    end

    if address_obj.zip and address_obj.zip ~= "" then
        table.insert(parts, address_obj.zip)
    end

    if address_obj.country and address_obj.country ~= "" then
        table.insert(parts, address_obj.country)
    end

    if #parts == 0 then
        return nil, "Address is empty"
    end

    return table.concat(parts, ", "), nil
end

-- Check geocoding cache in database
function Geocoding:checkCache(address_str)
    if not self.cache_enabled then
        return nil
    end

    local result = db.query([[
        SELECT latitude, longitude, cached_at
        FROM geocoding_cache
        WHERE address_hash = MD5(?)
        AND cached_at > NOW() - INTERVAL '30 days'
        LIMIT 1
    ]], address_str)

    if result and #result > 0 then
        ngx.log(ngx.INFO, "Geocoding cache hit for address")
        return {
            lat = tonumber(result[1].latitude),
            lng = tonumber(result[1].longitude),
            source = "cache"
        }
    end

    return nil
end

-- Save geocoding result to cache
function Geocoding:saveCache(address_str, lat, lng)
    if not self.cache_enabled then
        return
    end

    pcall(function()
        db.query([[
            INSERT INTO geocoding_cache (address_hash, address_text, latitude, longitude, cached_at)
            VALUES (MD5(?), ?, ?, ?, NOW())
            ON CONFLICT (address_hash)
            DO UPDATE SET
                latitude = EXCLUDED.latitude,
                longitude = EXCLUDED.longitude,
                cached_at = NOW()
        ]], address_str, address_str, lat, lng)
    end)
end

-- Geocode address using OpenStreetMap Nominatim
function Geocoding:geocodeWithNominatim(address_str)
    local httpc = http.new()
    httpc:set_timeout(10000) -- 10 second timeout

    local url = self.nominatim_base_url .. "/search"
    local params = {
        q = address_str,
        format = "json",
        limit = "1",
        addressdetails = "1"
    }

    -- Build query string
    local query_parts = {}
    for k, v in pairs(params) do
        table.insert(query_parts, ngx.escape_uri(k) .. "=" .. ngx.escape_uri(v))
    end
    local query_string = table.concat(query_parts, "&")

    local full_url = url .. "?" .. query_string

    ngx.log(ngx.INFO, "Geocoding with Nominatim: " .. address_str)

    local res, err = httpc:request_uri(full_url, {
        method = "GET",
        headers = {
            ["User-Agent"] = self.user_agent,
            ["Accept"] = "application/json"
        },
        ssl_verify = false
    })

    if not res then
        ngx.log(ngx.ERR, "Nominatim request failed: " .. (err or "unknown error"))
        return nil, "Geocoding request failed"
    end

    if res.status ~= 200 then
        ngx.log(ngx.ERR, "Nominatim returned status: " .. res.status)
        return nil, "Geocoding service error"
    end

    local ok, results = pcall(cjson.decode, res.body)
    if not ok or not results or #results == 0 then
        ngx.log(ngx.WARN, "Nominatim returned no results for: " .. address_str)
        return nil, "Address not found"
    end

    local result = results[1]
    local lat = tonumber(result.lat)
    local lng = tonumber(result.lon)

    if not lat or not lng then
        return nil, "Invalid coordinates in response"
    end

    ngx.log(ngx.INFO, string.format("Geocoded to: %f, %f", lat, lng))

    return {
        lat = lat,
        lng = lng,
        display_name = result.display_name,
        source = "nominatim"
    }
end

-- Main geocoding function with caching and fallback
function Geocoding:geocode(address_obj_or_str)
    local address_str
    local err

    -- Handle both table and string input
    if type(address_obj_or_str) == "table" then
        address_str, err = self:formatAddress(address_obj_or_str)
        if not address_str then
            return nil, err
        end
    elseif type(address_obj_or_str) == "string" then
        address_str = address_obj_or_str
    else
        return nil, "Address must be a table or string"
    end

    -- Check cache first
    local cached = self:checkCache(address_str)
    if cached then
        return cached
    end

    -- Try Nominatim
    local result, geocode_err = self:geocodeWithNominatim(address_str)
    if result then
        -- Save to cache
        self:saveCache(address_str, result.lat, result.lng)
        return result
    end

    -- Geocoding failed
    ngx.log(ngx.ERR, "Geocoding failed for: " .. address_str .. " - " .. (geocode_err or "unknown error"))
    return nil, geocode_err
end

-- Create geocoding_cache table if it doesn't exist
function Geocoding:ensureCacheTable()
    pcall(function()
        db.query([[
            CREATE TABLE IF NOT EXISTS geocoding_cache (
                id SERIAL PRIMARY KEY,
                address_hash VARCHAR(32) UNIQUE NOT NULL,
                address_text TEXT NOT NULL,
                latitude NUMERIC(10, 8) NOT NULL,
                longitude NUMERIC(11, 8) NOT NULL,
                cached_at TIMESTAMP NOT NULL DEFAULT NOW(),
                created_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE INDEX IF NOT EXISTS idx_geocoding_cache_hash ON geocoding_cache(address_hash)
        ]])

        db.query([[
            CREATE INDEX IF NOT EXISTS idx_geocoding_cache_cached_at ON geocoding_cache(cached_at)
        ]])
    end)
end

return Geocoding
