local db = require("lapis.db")
local cjson = require("cjson")

local DeliveryPartnerAreaQueries = {}

-- Add service area for delivery partner
function DeliveryPartnerAreaQueries.create(params)
    local area = db.insert("delivery_partner_areas", {
        delivery_partner_id = params.delivery_partner_id,
        country = params.country or 'India',
        state = params.state,
        city = params.city,
        postal_codes = params.postal_codes or '[]',
        is_active = params.is_active ~= nil and params.is_active or true,
        created_at = db.format_date()
    })

    return area
end

-- Get areas for delivery partner
function DeliveryPartnerAreaQueries.findByPartnerId(delivery_partner_id)
    return db.select("* FROM delivery_partner_areas WHERE delivery_partner_id = ? AND is_active = true ORDER BY state, city", delivery_partner_id)
end

-- Check if delivery partner serves an area
function DeliveryPartnerAreaQueries.servesArea(delivery_partner_id, city, state, country)
    country = country or 'India'
    local result = db.select([[
        * FROM delivery_partner_areas
        WHERE delivery_partner_id = ?
        AND city = ?
        AND state = ?
        AND country = ?
        AND is_active = true
        LIMIT 1
    ]], delivery_partner_id, city, state, country)

    return result and #result > 0
end

-- Update service area
function DeliveryPartnerAreaQueries.update(id, params)
    db.update("delivery_partner_areas", params, "id = ?", id)
end

-- Delete service area
function DeliveryPartnerAreaQueries.delete(id)
    db.update("delivery_partner_areas", { is_active = false }, "id = ?", id)
end

-- Add postal codes to area
function DeliveryPartnerAreaQueries.addPostalCodes(area_id, postal_codes)
    local area = db.select("* FROM delivery_partner_areas WHERE id = ?", area_id)
    if not area or #area == 0 then
        return nil, "Area not found"
    end

    local current_codes = cjson.decode(area[1].postal_codes or '[]')

    -- Merge new postal codes
    for _, code in ipairs(postal_codes) do
        local exists = false
        for _, existing_code in ipairs(current_codes) do
            if existing_code == code then
                exists = true
                break
            end
        end
        if not exists then
            table.insert(current_codes, code)
        end
    end

    db.update("delivery_partner_areas", {
        postal_codes = cjson.encode(current_codes)
    }, "id = ?", area_id)

    return true
end

-- Get all unique cities served by delivery partners
function DeliveryPartnerAreaQueries.getAllCities()
    return db.query([[
        SELECT DISTINCT state, city, country
        FROM delivery_partner_areas
        WHERE is_active = true
        ORDER BY country, state, city
    ]])
end

return DeliveryPartnerAreaQueries
