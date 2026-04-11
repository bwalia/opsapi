local Model = require("lapis.db.model").Model

local InvoiceSequences = Model:extend("invoice_sequences", {
    timestamp = true
})

return InvoiceSequences
