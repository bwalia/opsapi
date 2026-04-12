local Model = require("lapis.db.model").Model

local AccountingVatReturns = Model:extend("accounting_vat_returns", {
    timestamp = true
})

return AccountingVatReturns
