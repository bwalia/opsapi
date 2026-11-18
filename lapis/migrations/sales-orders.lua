--[[
    Sales orders (core; queries/SalesOrderQueries.lua)
    ==================================================
    [1] orders.source: how a Stores & Products order came in: phone | in_person | email (created by staff on the
        Sales Orders page), pos (a point-of-sale screen), NULL = online store checkout. Skipped where the orders
        table isn't deployed. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        if not db.query("SELECT to_regclass('orders') IS NOT NULL AS ok")[1].ok then return end
        db.query("ALTER TABLE orders ADD COLUMN IF NOT EXISTS source VARCHAR(30)")
    end,
}
