local Model = require("lapis.db.model").Model

local ProductVariantModel = Model:extend("product_variants", {
    timestamp = true,
    relations = {
        {"product", belongs_to = "StoreproductModel", key = "product_id"},
    }
})

return ProductVariantModel
