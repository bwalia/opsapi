-- Non-working days used for working-day maths: /api/v2/property-deals/holidays
-- (list/show/create/update/delete). Seeded with UK bank holidays on setup.
local sdk = require("helper.plugin-sdk")

return function(app)
    sdk.crud(app, "/holidays", {
        table = "property_deals_holidays",
        module = "property_deals_settings",
        fields = {
            jurisdiction = { type = "string", required = true, max = 40 },
            holiday_date = { type = "date", required = true, label = "Date" },
            name = { type = "string", required = true, max = 120 },
        },
        searchable = { "name" },
        filterable = { "jurisdiction", "holiday_date" },
        sortable = { "holiday_date", "name" },
        ui = { label = "Bank holidays", columns = { "holiday_date", "name", "jurisdiction" } },
    })
end
