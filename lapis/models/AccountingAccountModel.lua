local Model = require("lapis.db.model").Model

local AccountingAccounts = Model:extend("accounting_accounts", {
    timestamp = true
})

return AccountingAccounts
