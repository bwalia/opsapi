local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Add user_id to customers table
    [1] = function()
        pcall(function()
            schema.add_column("customers", "user_id", types.foreign_key({ null = true }))
        end)
    end,

    -- Add index for user_id
    [2] = function()
        pcall(function()
            schema.create_index("customers", "user_id")
        end)
    end,

    -- Migrate existing customer data to link with users by email
    [3] = function()
        db.query([[
            UPDATE customers c
            SET user_id = u.id
            FROM users u
            WHERE c.email = u.email
            AND c.user_id IS NULL
        ]])
    end
}
