local Model = require("lapis.db.model").Model

local CartModel = Model:extend("cart_sessions", {
    timestamp = true,
    relations = {
        {"user", belongs_to = "UserModel", key = "user_id"},
    }
})

return CartModel
