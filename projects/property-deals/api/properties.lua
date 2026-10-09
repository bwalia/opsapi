-- Properties: /api/v2/property-deals/properties (list/show/create/update/delete).
-- One property can be on many leads and deals.
local sdk = require("helper.plugin-sdk")

local ISSUES = "spray_foam, non_standard_construction, short_lease, knotweed, subsidence, shale_floors, "
    .. "cladding, sitting_tenant, other"

return function(app)
    sdk.crud(app, "/properties", {
        table = "property_deals_properties",
        module = "property_deals_properties",
        fields = {
            address_line1 = { type = "string", required = true, label = "Address" },
            address_line2 = { type = "string" },
            town = { type = "string", max = 120 },
            county = { type = "string", max = 120 },
            postcode = { type = "string", max = 16 },
            country = { type = "string", min = 2, max = 2 },
            uprn = { type = "string", max = 20, label = "UPRN" },
            lat = { type = "number", min = -90, max = 90 },
            lng = { type = "number", min = -180, max = 180 },
            title_number = { type = "string", max = 30 },
            tenure = { enum = { "freehold", "leasehold", "share_of_freehold", "commonhold", "unknown" } },
            lease_years_left = { type = "integer", min = 0 },
            ground_rent = { type = "number", min = 0 },
            service_charge = { type = "number", min = 0 },
            property_type = { type = "string", max = 40 },
            bedrooms = { type = "integer", min = 0, max = 100 },
            bathrooms = { type = "integer", min = 0, max = 100 },
            floor_area_sqm = { type = "number", min = 0 },
            epc_rating = { enum = { "A", "B", "C", "D", "E", "F", "G" }, label = "EPC rating" },
            epc_certificate_number = { type = "string", max = 40 },
            epc_expires_on = { type = "date" },
            council_tax_band = { type = "string", max = 2 },
            condition = { type = "string", max = 30 },
            known_issues = { type = "json", label = "Known issues (" .. ISSUES .. ")" },
            known_issues_note = { type = "text" },
            tenancy = { type = "json", label = "Tenancy {rent_pcm, arrears, end_date}" },
            flood_risk = { type = "string", max = 30 },
            mining_risk = { type = "string", max = 30 },
            est_market_value = { type = "number", min = 0 },
            est_rent_pcm = { type = "number", min = 0 },
            refurb_estimate = { type = "number", min = 0 },
            end_value = { type = "number", min = 0 },
            notes = { type = "text" },
            metadata = { type = "json" },
        },
        searchable = { "address_line1", "address_line2", "town", "postcode", "uprn", "title_number" },
        filterable = { "postcode", "tenure", "epc_rating", "property_type", "uprn", "town" },
        sortable = { "address_line1", "postcode", "est_market_value", "created_at", "updated_at" },
        ui = {
            label = "Properties",
            columns = { "address_line1", "postcode", "tenure", "epc_rating", "est_market_value" },
        },
    })
end
