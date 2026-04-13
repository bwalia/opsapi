-- Schema Update Script for Existing Multi-tenant Ecommerce Systems
-- This script safely updates existing tables to the new enhanced schema

local db = require("lapis.db")

local SchemaUpdates = {}

-- Update stores table with new columns
function SchemaUpdates.updateStoresTable()
    -- Check if new columns exist before adding them
    local columns_to_add = {
        { "contact_email", "VARCHAR" },
        { "contact_phone", "VARCHAR" },
        { "address", "TEXT" },
        { "city", "VARCHAR" },
        { "state", "VARCHAR" },
        { "country", "VARCHAR" },
        { "postal_code", "VARCHAR" },
        { "tax_rate", "NUMERIC DEFAULT 0" },
        { "currency", "VARCHAR DEFAULT 'USD'" },
        { "timezone", "VARCHAR DEFAULT 'UTC'" },
        { "is_verified", "BOOLEAN DEFAULT FALSE" }
    }

    for _, column in ipairs(columns_to_add) do
        local exists = db.select(
            "column_name FROM information_schema.columns WHERE table_name = 'stores' AND column_name = ?",
            column[1]
        )
        if not exists or #exists == 0 then
            db.query("ALTER TABLE stores ADD COLUMN " .. column[1] .. " " .. column[2])
            print("Added column " .. column[1] .. " to stores table")
        end
    end
end

-- Update storeproducts table with new columns
function SchemaUpdates.updateStoreproductsTable()
    local columns_to_add = {
        { "short_description", "TEXT" },
        { "barcode", "VARCHAR" },
        { "low_stock_threshold", "INTEGER DEFAULT 5" },
        { "dimensions", "VARCHAR" },
        { "is_digital", "BOOLEAN DEFAULT FALSE" },
        { "requires_shipping", "BOOLEAN DEFAULT TRUE" },
        { "sort_order", "INTEGER DEFAULT 0" },
        { "rating_average", "NUMERIC DEFAULT 0" },
        { "rating_count", "INTEGER DEFAULT 0" }
    }

    for _, column in ipairs(columns_to_add) do
        local exists = db.select(
            "column_name FROM information_schema.columns WHERE table_name = 'storeproducts' AND column_name = ?",
            column[1]
        )
        if not exists or #exists == 0 then
            db.query("ALTER TABLE storeproducts ADD COLUMN " .. column[1] .. " " .. column[2])
            print("Added column " .. column[1] .. " to storeproducts table")
        end
    end

    -- Add new indexes
    local indexes_to_add = {
        { "idx_storeproducts_barcode", "barcode" },
        { "idx_storeproducts_rating", "rating_average" },
        { "idx_storeproducts_sort_order", "sort_order" },
        { "idx_storeproducts_slug", "slug" },
        { "idx_storeproducts_store_active", "store_id, is_active" },
        { "idx_storeproducts_store_category_active", "store_id, category_id, is_active" },
        { "idx_storeproducts_store_featured_active", "store_id, is_featured, is_active" },
        { "idx_storeproducts_active_price", "is_active, price" }
    }

    for _, index in ipairs(indexes_to_add) do
        local exists = db.select(
            "indexname FROM pg_indexes WHERE tablename = 'storeproducts' AND indexname = ?",
            index[1]
        )
        if not exists or #exists == 0 then
            db.query("CREATE INDEX " .. index[1] .. " ON storeproducts (" .. index[2] .. ")")
            print("Created index " .. index[1])
        end
    end
end

-- Update categories table with new columns
function SchemaUpdates.updateCategoriesTable()
    local columns_to_add = {
        { "parent_id", "INTEGER REFERENCES categories(id) ON DELETE SET NULL" },
        { "meta_title", "VARCHAR" },
        { "meta_description", "TEXT" }
    }

    for _, column in ipairs(columns_to_add) do
        local exists = db.select(
            "column_name FROM information_schema.columns WHERE table_name = 'categories' AND column_name = ?",
            column[1]
        )
        if not exists or #exists == 0 then
            db.query("ALTER TABLE categories ADD COLUMN " .. column[1] .. " " .. column[2])
            print("Added column " .. column[1] .. " to categories table")
        end
    end

    -- Add indexes
    local indexes_to_add = {
        { "idx_categories_parent_id", "parent_id" },
        { "idx_categories_store_active_sort", "store_id, is_active, sort_order" }
    }

    for _, index in ipairs(indexes_to_add) do
        local indexName = index[1]
        local indexColumns = index[2]:match("%S") and index[2] or nil  -- Trim and check if non-empty
        if indexColumns then
            local exists = db.select(
                "indexname FROM pg_indexes WHERE tablename = 'categories' AND indexname = ?",
                indexName
            )
            if not exists or #exists == 0 then
                local sql = "CREATE INDEX " .. indexName .. " ON categories (" .. indexColumns .. ")"
                print("Creating index with SQL: " .. sql)
                db.query(sql)
                print("Created index " .. indexName)
            end
        else
            print("Skipping creation of index " .. indexName .. " due to empty columns list")
        end
    end
end

-- Create new tables if they don't exist
function SchemaUpdates.createNewTables()
    -- Check if cart_sessions table exists
    local cart_sessions_exists = db.select(
        "table_name FROM information_schema.tables WHERE table_name = 'cart_sessions'"
    )
    if not cart_sessions_exists or #cart_sessions_exists == 0 then
        db.query([[
            CREATE TABLE cart_sessions (
                id SERIAL PRIMARY KEY,
                session_id VARCHAR(128) UNIQUE NOT NULL,
                user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
                cart_data TEXT DEFAULT '{}',
                expires_at TIMESTAMP NOT NULL,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query("CREATE INDEX idx_cart_sessions_session_id ON cart_sessions (session_id)")
        db.query("CREATE INDEX idx_cart_sessions_user_id ON cart_sessions (user_id)")
        db.query("CREATE INDEX idx_cart_sessions_expires_at ON cart_sessions (expires_at)")
        print("Created cart_sessions table")
    end

    -- Check if cart_items table exists
    local cart_items_exists = db.select("table_name FROM information_schema.tables WHERE table_name = 'cart_items'")
    if not cart_items_exists or #cart_items_exists == 0 then
        db.query([[
            CREATE TABLE cart_items (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(36) UNIQUE NOT NULL,
                session_id VARCHAR(128) NOT NULL,
                user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
                product_id INTEGER NOT NULL REFERENCES storeproducts(id) ON DELETE CASCADE,
                variant_id INTEGER REFERENCES product_variants(id) ON DELETE CASCADE,
                quantity INTEGER DEFAULT 1,
                price_at_time DECIMAL(10,2) NOT NULL,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query("CREATE INDEX idx_cart_items_session_id ON cart_items (session_id)")
        db.query("CREATE INDEX idx_cart_items_user_id ON cart_items (user_id)")
        db.query("CREATE INDEX idx_cart_items_product_id ON cart_items (product_id)")
        print("Created cart_items table")
    end

    -- Check if product_reviews table exists
    local reviews_exists = db.select("table_name FROM information_schema.tables WHERE table_name = 'product_reviews'")
    if not reviews_exists or #reviews_exists == 0 then
        db.query([[
            CREATE TABLE product_reviews (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(36) UNIQUE NOT NULL,
                product_id INTEGER NOT NULL REFERENCES storeproducts(id) ON DELETE CASCADE,
                customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE,
                order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
                rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
                title VARCHAR(255),
                review_text TEXT,
                is_verified BOOLEAN DEFAULT FALSE,
                is_approved BOOLEAN DEFAULT FALSE,
                helpful_count INTEGER DEFAULT 0,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query("CREATE INDEX idx_product_reviews_product_id ON product_reviews (product_id)")
        db.query("CREATE INDEX idx_product_reviews_customer_id ON product_reviews (customer_id)")
        db.query("CREATE INDEX idx_product_reviews_rating ON product_reviews (rating)")
        db.query("CREATE INDEX idx_product_reviews_approved ON product_reviews (is_approved)")
        print("Created product_reviews table")
    end

    -- Check if store_settings table exists
    local settings_exists = db.select("table_name FROM information_schema.tables WHERE table_name = 'store_settings'")
    if not settings_exists or #settings_exists == 0 then
        db.query([[
            CREATE TABLE store_settings (
                id SERIAL PRIMARY KEY,
                store_id INTEGER NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
                key VARCHAR(100) NOT NULL,
                value TEXT,
                type VARCHAR(20) DEFAULT 'string',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                UNIQUE (store_id, key)
            )
        ]])

        db.query("CREATE INDEX idx_store_settings_store_id ON store_settings (store_id)")
        db.query("CREATE INDEX idx_store_settings_key ON store_settings (key)")
        print("Created store_settings table")
    end
end

-- Update existing products to have slugs if they don't
function SchemaUpdates.generateMissingSlugs()
    local products = db.select("id, name, slug FROM storeproducts WHERE slug IS NULL OR slug = ''")
    for _, product in ipairs(products) do
        local slug = string.lower(product.name):gsub("[^a-z0-9-]", "-"):gsub("-+", "-")
        db.query("UPDATE storeproducts SET slug = ? WHERE id = ?", slug, product.id)
    end
    print("Generated slugs for " .. #products .. " products")
end

-- Main update function
function SchemaUpdates.runAll()
    print("Starting schema updates...")

    SchemaUpdates.updateStoresTable()
    SchemaUpdates.updateStoreproductsTable()
    SchemaUpdates.updateCategoriesTable()
    SchemaUpdates.createNewTables()
    SchemaUpdates.generateMissingSlugs()

    print("Schema updates completed successfully!")
end

return SchemaUpdates
