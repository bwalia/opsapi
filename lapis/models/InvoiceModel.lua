local Model = require("lapis.db.model").Model

local Invoices = Model:extend("invoices", {
    timestamp = true
})

return Invoices
