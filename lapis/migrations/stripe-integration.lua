local schema = require("lapis.db.schema")
local types = schema.types

return {
    -- Add stripe_customer_id to customers table
    [1] = function()
        pcall(function()
            schema.add_column("customers", "stripe_customer_id", types.varchar({ null = true, unique = true }))
        end)
    end,

    -- Add index for stripe_customer_id
    [2] = function()
        pcall(function()
            schema.create_index("customers", "stripe_customer_id")
        end)
    end
}
