--[[
    Give old statements their tax year (tax_copilot).

    File your tax, the year's transactions and the reports only count statements
    stamped with that year (tax_statements.tax_year). Since #830 the extract step
    stamps it; statements uploaded before that have none, so they drop out of
    every year until their per-statement calculation runs. Same rule as the
    extract step and tax-calculate's statementYear: period end, then period
    start, then the latest transaction date. An existing year is never changed.
]]

local db = require("lapis.db")

return {
    [1] = function()
        if #db.select("1 FROM information_schema.tables WHERE table_name = 'tax_statements'") == 0 then return end
        local TaxCalc = require("lib.tax-calc")
        local rows = db.query([[
            SELECT s.id, s.period_start::text AS ps, s.period_end::text AS pe,
                   (SELECT MAX(transaction_date)::text FROM tax_transactions WHERE statement_id = s.id) AS last
            FROM tax_statements s WHERE s.tax_year IS NULL OR s.tax_year = ''
        ]])
        local stamped = 0
        for _, r in ipairs(rows) do
            local year = TaxCalc.tax_year_for_date(r.pe) or TaxCalc.tax_year_for_date(r.ps)
                or TaxCalc.tax_year_for_date(r.last)
            if year then
                db.query([[UPDATE tax_statements SET tax_year = ?
                    WHERE id = ? AND (tax_year IS NULL OR tax_year = '')]], year, r.id)
                stamped = stamped + 1
            end
        end
        print(string.format("[tax-statement-year-backfill] %d of %d statements stamped", stamped, #rows))
    end,
}
