local Model = require("lapis.db.model").Model

local CartItemModel = Model:extend("cart_items", {
    timestamp = true,
    relations = {
        {"user", belongs_to = "UserModel", key = "user_id"},
        {"product", belongs_to = "StoreproductModel", key = "product_id"},
        {"variant", belongs_to = "ProductVariantModel", key = "variant_id"},
    }
})

return CartItemModel
