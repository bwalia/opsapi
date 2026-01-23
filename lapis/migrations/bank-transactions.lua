--[[
    Bank Transactions Migration
    ===========================

    Creates the bank_transactions table for tracking financial transactions.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

-- Helper to check if table exists
local function table_exists(table_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_name = ?
        ) as exists
    ]], table_name)
    return result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create bank_transactions table
    -- ========================================
    [1] = function()
        if table_exists("bank_transactions") then return end

        schema.create_table("bank_transactions", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_id", types.varchar },

            -- Transaction Details
            { "transaction_date", "date NOT NULL" },
            { "description", types.text },
            { "money_in", "decimal(15,2) DEFAULT 0.00" },
            { "money_out", "decimal(15,2) DEFAULT 0.00" },
            { "balance", "decimal(15,2) NOT NULL" },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (user_id) REFERENCES users(uuid) ON DELETE CASCADE"
        })
    end,

    -- ========================================
    -- [2] Create bank_transactions indexes
    -- ========================================
    [2] = function()
        pcall(function() schema.create_index("bank_transactions", "uuid") end)
        pcall(function() schema.create_index("bank_transactions", "user_id") end)
        pcall(function() schema.create_index("bank_transactions", "transaction_date") end)

        -- Composite index for common queries
        pcall(function()
            db.query([[
                CREATE INDEX bank_transactions_user_date_idx
                ON bank_transactions (user_id, transaction_date DESC)
            ]])
        end)
    end,
}
