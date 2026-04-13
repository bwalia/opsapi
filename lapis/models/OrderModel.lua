local Model = require("lapis.db.model").Model

local OrderModel = Model:extend("orders", {
    timestamp = true,
    relations = {
        {"store", belongs_to = "StoreModel", key = "store_id"},
        {"customer", belongs_to = "CustomerModel", key = "customer_id"},
        {"items", has_many = "OrderitemModel", key = "order_id"}
    }
})

return OrderModel
