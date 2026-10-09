-- Property <-> buyer matches (scores are computed by the matcher, Phase 6):
--   GET /matches, /matches/:id   ?property_uuid=&buyer_profile_uuid=&status=  sort=score
--   PUT /matches/:id             status: interested | declined (sending goes through an approval)
local sdk = require("helper.plugin-sdk")

return function(app)
    sdk.crud(app, "/matches", {
        table = "property_deals_matches",
        module = "property_deals_buyers",
        only = { "list", "show", "update" },
        fields = {
            property_uuid = { type = "uuid" },
            buyer_profile_uuid = { type = "uuid" },
            status = { enum = { "suggested", "interested", "declined" } },
        },
        filterable = { "property_uuid", "buyer_profile_uuid", "status" },
        sortable = { "score", "computed_at", "sent_at" },
    })
end
