local Model = require("lapis.db.model").Model

local StoreproductModel = Model:extend("storeproducts", {
    timestamp = true,
    relations = {
        {"store", belongs_to = "StoreModel", key = "store_id"},
        {"category", belongs_to = "CategoryModel", key = "category_id"}
    }
})

return StoreproductModel
