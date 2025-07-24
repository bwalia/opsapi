local Model = require("lapis.db.model").Model

local StoreproductModel = Model:extend("storeproducts", {
    timestamp = true,
    relations = {
        {"store", belongs_to = "StoreModel", key = "store_id"},
        {"category", belongs_to = "CategoryModel", key = "category_id"},
        {"variants", has_many = "ProductVariantModel", key = "product_id"},
        {"orderitems", has_many = "OrderitemModel", key = "product_id"}
    }
})

return StoreproductModel
