local Model = require("lapis.db.model").Model

local AccountingJournalEntries = Model:extend("accounting_journal_entries", {
    timestamp = true
})

return AccountingJournalEntries
