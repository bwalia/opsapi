-- Buyer profiles on an existing CRM contact or company:
-- /api/v2/property-deals/buyer-profiles (list/show/create/update/delete).
-- Exactly one of contact_uuid / account_uuid; both must be in this workspace.
local sdk = require("helper.plugin-sdk")

return function(app)
    sdk.crud(app, "/buyer-profiles", {
        table = "property_deals_buyer_profiles",
        module = "property_deals_buyers",
        fields = {
            contact_uuid = { type = "uuid", label = "Contact" },
            account_uuid = { type = "uuid", label = "Company" },
            entity_type = { enum = { "person", "ltd_spv", "overseas_company", "pension_ssas_sipp", "trust_family_office" } },
            capital_band = { type = "string", max = 30 },
            funds_location = { type = "string", max = 120 },
            pof_status = { enum = { "none", "requested", "received", "verified", "expired" }, label = "Proof of funds" },
            pof_expires_on = { type = "date" },
            funding_route = { enum = { "cash", "mortgage", "bridging", "cash_then_refinance" } },
            speed_to_commit_days = { type = "integer", min = 0 },
            strategies = { type = "json", label = "Strategies (btl, brr, flip, hmo, blocks, semi_commercial, commercial, tenanted)" },
            areas = { type = "json", label = "Areas [{type: radius, lat, lng, miles} | {type: polygon, points: [[lat,lng]...]}]" },
            price_min = { type = "number", min = 0 },
            price_max = { type = "number", min = 0 },
            min_discount_pct = { type = "number", min = 0, max = 100 },
            min_yield_pct = { type = "number", min = 0, max = 100 },
            refurb_appetite = { enum = { "none", "light", "medium", "heavy" } },
            top_priority = { type = "string", max = 120 },
            deal_breakers = { type = "json" },
            preferred_channel = { enum = { "email", "phone", "whatsapp", "sms" } },
            timezone = { type = "string", max = 60 },
            holdings = { type = "json" },
            active = { type = "boolean" },
            notes = { type = "text" },
        },
        filterable = { "contact_uuid", "account_uuid", "entity_type", "pof_status", "funding_route", "active" },
        sortable = { "price_max", "pof_expires_on", "created_at", "updated_at" },
        searchable = { "top_priority", "notes" },
        ui = { label = "Buyer profiles", columns = { "entity_type", "pof_status", "funding_route", "price_max", "active" } },
    })
end
