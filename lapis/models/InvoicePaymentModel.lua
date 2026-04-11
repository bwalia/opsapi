local Model = require("lapis.db.model").Model

local InvoicePayments = Model:extend("invoice_payments", {
    timestamp = true
})

return InvoicePayments
