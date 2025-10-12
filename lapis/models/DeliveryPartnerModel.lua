local Model = require("lapis.db.model").Model

local DeliveryPartner = Model:extend("delivery_partners", {
    relations = {
        {"user", belongs_to = "User"},
        {"areas", has_many = "DeliveryPartnerArea"},
        {"assignments", has_many = "OrderDeliveryAssignment"},
        {"reviews", has_many = "DeliveryPartnerReview"}
    }
})

return DeliveryPartner
