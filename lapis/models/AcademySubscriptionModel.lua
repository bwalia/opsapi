local Model = require("lapis.db.model").Model

local AcademySubscriptions = Model:extend("academy_subscriptions", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return AcademySubscriptions
