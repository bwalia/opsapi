local Model = require("lapis.db.model").Model

local OrderitemModel = Model:extend("orderitems", {
    timestamp = true,
    relations = {
        {"order", belongs_to = "OrderModel", key = "order_id"},
        {"product", belongs_to = "StoreproductModel", key = "product_id"}
    }
})

return OrderitemModel
