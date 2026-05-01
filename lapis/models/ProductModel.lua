local Model = require("lapis.db.model").Model

local ProductModel = Model:extend("products", {
    timestamp = true
})

return ProductModel
