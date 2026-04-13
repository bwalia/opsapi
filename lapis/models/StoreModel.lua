local Model = require("lapis.db.model").Model

local StoreModel = Model:extend("stores", {
    timestamp = true,
    relations = {
        {"owner", belongs_to = "UserModel", key = "user_id"},
        {"products", has_many = "StoreproductModel", key = "store_id"},
        {"categories", has_many = "CategoryModel", key = "store_id"},
        {"orders", has_many = "OrderModel", key = "store_id"}
    }
})

return StoreModel
