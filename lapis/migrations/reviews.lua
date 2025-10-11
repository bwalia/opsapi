local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Create store_reviews table
    [1] = function()
        -- Check if table already exists
        local existing = db.query([[
            SELECT EXISTS (
                SELECT FROM information_schema.tables
                WHERE table_name = 'store_reviews'
            ) as exists
        ]])

        if existing and existing[1] and existing[1].exists then
            return -- Table already exists, skip
        end

        schema.create_table("store_reviews", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"store_id", types.foreign_key},
            {"user_id", types.foreign_key},
            {"order_id", types.foreign_key({ null = true })},
            {"rating", types.integer},  -- 1-5
            {"title", types.varchar({ null = true })},
            {"comment", types.text({ null = true })},
            {"is_verified_purchase", types.boolean({ default = false })},
            {"created_at", types.time},
            {"updated_at", types.time},
            "PRIMARY KEY (id)",
            "CHECK (rating >= 1 AND rating <= 5)"
        })
    end,

    -- Add indexes for store_reviews
    [2] = function()
        pcall(function() schema.create_index("store_reviews", "uuid") end)
        pcall(function() schema.create_index("store_reviews", "store_id") end)
        pcall(function() schema.create_index("store_reviews", "user_id") end)
        pcall(function() schema.create_index("store_reviews", "order_id") end)
        pcall(function() schema.create_index("store_reviews", "rating") end)
        pcall(function() schema.create_index("store_reviews", "created_at") end)
    end,

    -- Create product_reviews table
    [3] = function()
        -- Check if table already exists
        local existing = db.query([[
            SELECT EXISTS (
                SELECT FROM information_schema.tables
                WHERE table_name = 'product_reviews'
            ) as exists
        ]])

        if existing and existing[1] and existing[1].exists then
            return -- Table already exists, skip
        end

        schema.create_table("product_reviews", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"product_id", types.foreign_key},
            {"user_id", types.foreign_key},
            {"order_id", types.foreign_key({ null = true })},
            {"rating", types.integer},  -- 1-5
            {"title", types.varchar({ null = true })},
            {"comment", types.text({ null = true })},
            {"is_verified_purchase", types.boolean({ default = false })},
            {"created_at", types.time},
            {"updated_at", types.time},
            "PRIMARY KEY (id)",
            "CHECK (rating >= 1 AND rating <= 5)"
        })
    end,

    -- Add indexes for product_reviews
    [4] = function()
        pcall(function() schema.create_index("product_reviews", "uuid") end)
        pcall(function() schema.create_index("product_reviews", "product_id") end)
        pcall(function() schema.create_index("product_reviews", "user_id") end)
        pcall(function() schema.create_index("product_reviews", "order_id") end)
        pcall(function() schema.create_index("product_reviews", "rating") end)
        pcall(function() schema.create_index("product_reviews", "created_at") end)
    end
}
