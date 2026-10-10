local Model = require("lapis.db.model").Model

local PurchaseOrders = Model:extend("purchase_orders", {
    timestamp = true
})

return PurchaseOrders
