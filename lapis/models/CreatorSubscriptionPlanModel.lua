local Model = require("lapis.db.model").Model

local CreatorSubscriptionPlans = Model:extend("creator_subscription_plans", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return CreatorSubscriptionPlans
