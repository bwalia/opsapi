local Model = require("lapis.db.model").Model

local CustomerModel = Model:extend("customers", {
    timestamp = true,
    relations = {
        {"orders", has_many = "OrderModel", key = "customer_id"}
    }
})

return CustomerModel
