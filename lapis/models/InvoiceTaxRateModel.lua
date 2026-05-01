local Model = require("lapis.db.model").Model

local InvoiceTaxRates = Model:extend("invoice_tax_rates", {
    timestamp = true
})

return InvoiceTaxRates
