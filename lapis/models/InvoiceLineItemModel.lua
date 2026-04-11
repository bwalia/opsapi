local Model = require("lapis.db.model").Model

local InvoiceLineItems = Model:extend("invoice_line_items", {
    timestamp = true
})

return InvoiceLineItems
