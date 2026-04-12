local Model = require("lapis.db.model").Model

local AccountingExpenses = Model:extend("accounting_expenses", {
    timestamp = true
})

return AccountingExpenses
