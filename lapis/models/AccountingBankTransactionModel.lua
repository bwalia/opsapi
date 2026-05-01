local Model = require("lapis.db.model").Model

local AccountingBankTransactions = Model:extend("accounting_bank_transactions", {
    timestamp = true
})

return AccountingBankTransactions
