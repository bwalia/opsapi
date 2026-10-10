local Model = require("lapis.db.model").Model

local PurchaseOrderItems = Model:extend("purchase_order_items", {
    timestamp = true
})

return PurchaseOrderItems
