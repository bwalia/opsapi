local Model = require("lapis.db.model").Model

local CategoryModel = Model:extend("categories", {
    timestamp = true,
    relations = {
        {"store", belongs_to = "StoreModel", key = "store_id"},
        {"products", has_many = "StoreproductModel", key = "category_id"}
    }
})

return CategoryModel
