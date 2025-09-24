-- Production-Grade Database Schema Upgrade
-- This migration will transform the current schema to production standards
local schema = require("lapis.db.schema")
local types = schema.types

return {
  -- 26. Fix immediate orderitems variant_uuid issue
  ['26_fix_orderitems_variant_field'] = function()
    -- Add the missing variant_uuid column (with error handling)
    pcall(function()
      schema.add_column("orderitems", "variant_uuid", types.varchar({ null = true }))
    end)

    -- Copy data from variant_id to variant_uuid (if needed and column exists)
    local db = require("lapis.db")
    pcall(function()
      db.query("UPDATE orderitems SET variant_uuid = variant_id WHERE variant_id IS NOT NULL AND variant_uuid IS NULL")
    end)

    -- Add index for performance (with error handling)
    pcall(function()
      db.query("CREATE INDEX IF NOT EXISTS orderitems_variant_uuid_idx ON orderitems (variant_uuid)")
    end)
  end,

  -- 27. Add UUID extensions and improve data types
  ['27_enable_uuid_extensions'] = function()
    local db = require("lapis.db")
    -- Enable UUID generation in PostgreSQL
    db.query('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"')
    db.query('CREATE EXTENSION IF NOT EXISTS "pgcrypto"')

    -- Add function for generating UUIDs
    db.query([[
      CREATE OR REPLACE FUNCTION generate_uuid_v4()
      RETURNS UUID AS $$
      BEGIN
        RETURN gen_random_uuid();
      END;
      $$ LANGUAGE plpgsql;
    ]])
  end,

  -- 28. Improve stores table with proper constraints and types
  ['28_enhance_stores_table'] = function()
    local db = require("lapis.db")

    -- Add proper constraints (with error handling)
    pcall(function() db.query("ALTER TABLE stores ADD CONSTRAINT stores_name_not_empty CHECK (length(trim(name)) > 0)") end)
    pcall(function() db.query("ALTER TABLE stores ADD CONSTRAINT stores_slug_format CHECK (slug ~ '^[a-z0-9-]+$')") end)
    pcall(function() db.query("ALTER TABLE stores ADD CONSTRAINT stores_status_valid CHECK (status IN ('active', 'inactive', 'suspended'))") end)
    pcall(function() db.query("ALTER TABLE stores ADD CONSTRAINT stores_tax_rate_valid CHECK (tax_rate >= 0 AND tax_rate <= 1)") end)

    -- Add UUID default (with error handling)
    pcall(function() db.query("ALTER TABLE stores ALTER COLUMN uuid SET DEFAULT generate_uuid_v4()") end)

    -- Add performance indexes (check if they don't already exist)
    db.query("CREATE UNIQUE INDEX IF NOT EXISTS stores_uuid_unique_idx ON stores (uuid)")

    -- Full-text search index with error handling
    pcall(function()
      db.query("CREATE INDEX IF NOT EXISTS stores_name_search_idx ON stores USING gin(to_tsvector('english', name))")
    end)

    -- Note: created_at index already exists from ecommerce migrations
    db.query("CREATE INDEX IF NOT EXISTS stores_status_verified_idx ON stores (status, is_verified)")
  end,

  -- 29. Enhance products table with proper ecommerce fields
  ['29_enhance_products_table'] = function()
    -- Add missing ecommerce fields (with error handling for existing columns)
    pcall(function() schema.add_column("storeproducts", "meta_title", types.varchar({ null = true })) end)
    pcall(function() schema.add_column("storeproducts", "meta_description", types.text({ null = true })) end)
    pcall(function() schema.add_column("storeproducts", "vendor", types.varchar({ null = true })) end)
    pcall(function() schema.add_column("storeproducts", "product_type", types.varchar({ null = true })) end)
    pcall(function() schema.add_column("storeproducts", "published_at", types.time({ null = true })) end)
    pcall(function() schema.add_column("storeproducts", "min_price", types.numeric({ null = true })) end)
    pcall(function() schema.add_column("storeproducts", "max_price", types.numeric({ null = true })) end)
    pcall(function() schema.add_column("storeproducts", "total_inventory", types.integer({ default = 0 })) end)

    -- Add constraints (with error handling)
    local db = require("lapis.db")
    pcall(function() db.query("ALTER TABLE storeproducts ADD CONSTRAINT products_price_positive CHECK (price >= 0)") end)
    pcall(function() db.query("ALTER TABLE storeproducts ADD CONSTRAINT products_compare_price_valid CHECK (compare_price IS NULL OR compare_price >= price)") end)
    pcall(function() db.query("ALTER TABLE storeproducts ADD CONSTRAINT products_name_not_empty CHECK (length(trim(name)) > 0)") end)
    pcall(function() db.query("ALTER TABLE storeproducts ADD CONSTRAINT products_sku_format CHECK (sku IS NULL OR sku ~ '^[A-Z0-9-_]+$')") end)

    -- Add UUID default (with error handling)
    pcall(function() db.query("ALTER TABLE storeproducts ALTER COLUMN uuid SET DEFAULT generate_uuid_v4()") end)

    -- Enhanced indexes for search and filtering (avoid duplicates)
    db.query("CREATE INDEX IF NOT EXISTS storeproducts_store_active_idx ON storeproducts (store_id, is_active)")
    -- Note: price and created_at indexes already exist from ecommerce migrations
    -- Full-text search index with error handling
    pcall(function()
      db.query("CREATE INDEX IF NOT EXISTS storeproducts_name_search_idx ON storeproducts USING gin(to_tsvector('english', name))")
    end)

    -- For tags field, provide multiple indexing strategies based on usage:
    -- Try different indexing approaches with error handling

    -- Option 1: Full-text search index (most likely to work)
    pcall(function()
      db.query("CREATE INDEX IF NOT EXISTS storeproducts_tags_search_idx ON storeproducts USING gin(to_tsvector('english', COALESCE(tags, '')))")
    end)

    -- Option 2: Simple btree index for exact matches (fallback, always works)
    pcall(function()
      db.query("CREATE INDEX IF NOT EXISTS storeproducts_tags_btree_idx ON storeproducts (tags)")
    end)

    -- Option 3: If tags are JSON, try jsonb index (commented out, enable if needed)
    -- pcall(function()
    --   db.query("CREATE INDEX IF NOT EXISTS storeproducts_tags_jsonb_idx ON storeproducts USING gin(tags::jsonb)")
    -- end)

    db.query("CREATE INDEX IF NOT EXISTS storeproducts_published_at_idx ON storeproducts (published_at)")
  end,

  -- 30. Create comprehensive orders audit and tracking
  ['30_enhance_orders_tracking'] = function()
    -- Add comprehensive order tracking fields (with error handling for existing columns)
    pcall(function() schema.add_column("orders", "fulfillment_service", types.varchar({ default = "'manual'" })) end)
    pcall(function() schema.add_column("orders", "location_id", types.varchar({ null = true })) end)
    pcall(function() schema.add_column("orders", "source_name", types.varchar({ default = "'web'" })) end)
    pcall(function() schema.add_column("orders", "landing_site", types.varchar({ null = true })) end)
    pcall(function() schema.add_column("orders", "referring_site", types.varchar({ null = true })) end)
    pcall(function() schema.add_column("orders", "cancelled_at", types.time({ null = true })) end)
    pcall(function() schema.add_column("orders", "cancel_reason", types.varchar({ null = true })) end)
    pcall(function() schema.add_column("orders", "refunded_amount", types.numeric({ default = 0 })) end)
    pcall(function() schema.add_column("orders", "tags", types.text({ null = true })) end)

    -- Add constraints (with error handling)
    local db = require("lapis.db")
    pcall(function() db.query("ALTER TABLE orders ADD CONSTRAINT orders_total_positive CHECK (total_amount >= 0)") end)
    pcall(function() db.query("ALTER TABLE orders ADD CONSTRAINT orders_subtotal_positive CHECK (subtotal >= 0)") end)
    pcall(function() db.query("ALTER TABLE orders ADD CONSTRAINT orders_refunded_valid CHECK (refunded_amount >= 0 AND refunded_amount <= total_amount)") end)
    pcall(function() db.query("ALTER TABLE orders ADD CONSTRAINT orders_status_valid CHECK (status IN ('pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded'))") end)
    pcall(function() db.query("ALTER TABLE orders ADD CONSTRAINT orders_financial_status_valid CHECK (financial_status IN ('pending', 'authorized', 'partially_paid', 'paid', 'partially_refunded', 'refunded', 'voided'))") end)

    -- Add UUID default (with error handling)
    pcall(function() db.query("ALTER TABLE orders ALTER COLUMN uuid SET DEFAULT generate_uuid_v4()") end)

    -- Performance indexes (avoid duplicates from existing migrations)
    db.query("CREATE INDEX IF NOT EXISTS orders_store_status_idx ON orders (store_id, status)")
    db.query("CREATE INDEX IF NOT EXISTS orders_store_financial_status_idx ON orders (store_id, financial_status)")
    db.query("CREATE UNIQUE INDEX IF NOT EXISTS orders_payment_intent_unique_idx ON orders (payment_intent_id)")
    -- Note: created_at and order_number indexes already exist from ecommerce migrations
  end,

  -- 31. Create customers table with CRM integration
  ['31_enhance_customers_table'] = function()
    -- Add CRM fields to customers (with error handling for existing columns)
    -- Note: accepts_marketing, tags, notes already exist in ecommerce migrations
    pcall(function() schema.add_column("customers", "accepts_marketing", types.boolean({ default = false })) end)
    pcall(function() schema.add_column("customers", "marketing_opt_in_level", types.varchar({ default = "'single_opt_in'" })) end)
    pcall(function() schema.add_column("customers", "last_order_date", types.time({ null = true })) end)
    pcall(function() schema.add_column("customers", "orders_count", types.integer({ default = 0 })) end)
    pcall(function() schema.add_column("customers", "total_spent", types.numeric({ default = 0 })) end)
    pcall(function() schema.add_column("customers", "average_order_value", types.numeric({ default = 0 })) end)
    pcall(function() schema.add_column("customers", "tags", types.text({ null = true })) end)
    pcall(function() schema.add_column("customers", "notes", types.text({ null = true })) end)
    pcall(function() schema.add_column("customers", "verified_email", types.boolean({ default = false })) end)
    pcall(function() schema.add_column("customers", "tax_exempt", types.boolean({ default = false })) end)
    pcall(function() schema.add_column("customers", "state", types.varchar({ default = "'enabled'" })) end)

    -- Add constraints (with error handling)
    local db = require("lapis.db")
    pcall(function() db.query("ALTER TABLE customers ADD CONSTRAINT customers_email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$')") end)
    pcall(function() db.query("ALTER TABLE customers ADD CONSTRAINT customers_total_spent_positive CHECK (total_spent >= 0)") end)
    pcall(function() db.query("ALTER TABLE customers ADD CONSTRAINT customers_orders_count_positive CHECK (orders_count >= 0)") end)
    pcall(function() db.query("ALTER TABLE customers ADD CONSTRAINT customers_state_valid CHECK (state IN ('enabled', 'disabled', 'invited', 'declined'))") end)

    -- Add UUID default (with error handling)
    pcall(function() db.query("ALTER TABLE customers ALTER COLUMN uuid SET DEFAULT generate_uuid_v4()") end)

    -- CRM and performance indexes (avoid duplicates)
    db.query("CREATE UNIQUE INDEX IF NOT EXISTS customers_email_unique_idx ON customers (email)")
    db.query("CREATE INDEX IF NOT EXISTS customers_total_spent_idx ON customers (total_spent)")
    db.query("CREATE INDEX IF NOT EXISTS customers_orders_count_idx ON customers (orders_count)")
    db.query("CREATE INDEX IF NOT EXISTS customers_last_order_date_idx ON customers (last_order_date)")
    db.query("CREATE INDEX IF NOT EXISTS customers_accepts_marketing_idx ON customers (accepts_marketing)")
    -- Note: created_at index may already exist, using IF NOT EXISTS
  end,

  -- 32. Create inventory tracking and analytics tables
  ['32_create_inventory_analytics'] = function()
    -- Enhanced inventory transactions
    schema.create_table("inventory_movements", {
      { "id", types.serial },
      { "uuid", types.varchar({ unique = true }) },
      { "product_id", types.foreign_key },
      { "variant_uuid", types.varchar({ null = true }) },
      { "location_id", types.varchar({ null = true }) },
      { "quantity_change", types.integer },
      { "quantity_after", types.integer },
      { "movement_type", types.varchar }, -- 'sale', 'return', 'adjustment', 'transfer'
      { "reference_type", types.varchar({ null = true }) }, -- 'order', 'adjustment', etc.
      { "reference_id", types.varchar({ null = true }) },
      { "cost_per_item", types.numeric({ null = true }) },
      { "note", types.text({ null = true }) },
      { "created_at", types.time({ null = true }) },
      { "updated_at", types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (product_id) REFERENCES storeproducts(id) ON DELETE CASCADE"
    })

    -- Add constraints (with error handling)
    local db = require("lapis.db")
    pcall(function() db.query("ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movement_type_valid CHECK (movement_type IN ('sale', 'return', 'adjustment', 'transfer', 'restock'))") end)
    pcall(function() db.query("ALTER TABLE inventory_movements ADD CONSTRAINT inventory_quantity_after_positive CHECK (quantity_after >= 0)") end)

    -- Performance indexes
    db.query("CREATE INDEX IF NOT EXISTS inventory_movements_product_created_idx ON inventory_movements (product_id, created_at)")
    db.query("CREATE INDEX IF NOT EXISTS inventory_movements_type_idx ON inventory_movements (movement_type)")
    db.query("CREATE INDEX IF NOT EXISTS inventory_movements_reference_idx ON inventory_movements (reference_type, reference_id)")
    db.query("CREATE INDEX IF NOT EXISTS inventory_movements_created_at_idx ON inventory_movements (created_at)")
  end,

  -- 33. Create analytics and reporting tables
  ['33_create_analytics_tables'] = function()
     local db = require("lapis.db")
    -- Daily store analytics
    schema.create_table("store_analytics_daily", {
      { "id", types.serial },
      { "store_id", types.foreign_key },
      { "date", types.date },
      { "total_sales", types.numeric({ default = 0 }) },
      { "total_orders", types.integer({ default = 0 }) },
      { "total_items_sold", types.integer({ default = 0 }) },
      { "average_order_value", types.numeric({ default = 0 }) },
      { "new_customers", types.integer({ default = 0 }) },
      { "returning_customers", types.integer({ default = 0 }) },
      { "refunded_amount", types.numeric({ default = 0 }) },
      { "created_at", types.time({ null = true }) },
      { "updated_at", types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE",
      "UNIQUE(store_id, date)"
    })

    -- Product performance analytics
    schema.create_table("product_analytics_daily", {
      { "id", types.serial },
      { "product_id", types.foreign_key },
      { "date", types.date },
      { "views", types.integer({ default = 0 }) },
      { "units_sold", types.integer({ default = 0 }) },
      { "revenue", types.numeric({ default = 0 }) },
      { "conversion_rate", types.numeric({ default = 0 }) },
      { "inventory_end_of_day", types.integer({ default = 0 }) },
      { "created_at", types.time({ null = true }) },
      { "updated_at", types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (product_id) REFERENCES storeproducts(id) ON DELETE CASCADE",
      "UNIQUE(product_id, date)"
    })

    -- Performance indexes
    db.query("CREATE INDEX IF NOT EXISTS store_analytics_daily_store_date_idx ON store_analytics_daily (store_id, date)")
    db.query("CREATE INDEX IF NOT EXISTS store_analytics_daily_date_idx ON store_analytics_daily (date)")
    db.query("CREATE INDEX IF NOT EXISTS product_analytics_daily_product_date_idx ON product_analytics_daily (product_id, date)")
    db.query("CREATE INDEX IF NOT EXISTS product_analytics_daily_date_idx ON product_analytics_daily (date)")
  end,

  -- 34. Add data integrity triggers and functions
  ['34_create_data_integrity_functions'] = function()
    local db = require("lapis.db")

    -- Function to update customer stats when order is created/updated
    db.query([[
      CREATE OR REPLACE FUNCTION update_customer_stats()
      RETURNS TRIGGER AS $$
      BEGIN
        IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
          UPDATE customers SET
            orders_count = (
              SELECT COUNT(*) FROM orders
              WHERE customer_id = NEW.customer_id AND financial_status = 'paid'
            ),
            total_spent = (
              SELECT COALESCE(SUM(total_amount), 0) FROM orders
              WHERE customer_id = NEW.customer_id AND financial_status = 'paid'
            ),
            last_order_date = (
              SELECT MAX(created_at) FROM orders
              WHERE customer_id = NEW.customer_id AND financial_status = 'paid'
            )
          WHERE id = NEW.customer_id;

          UPDATE customers SET
            average_order_value = CASE
              WHEN orders_count > 0 THEN total_spent / orders_count
              ELSE 0
            END
          WHERE id = NEW.customer_id;
        END IF;

        RETURN COALESCE(NEW, OLD);
      END;
      $$ LANGUAGE plpgsql;
    ]])

    -- Trigger to update customer stats
    db.query([[
      CREATE TRIGGER trigger_update_customer_stats
      AFTER INSERT OR UPDATE OF financial_status, total_amount ON orders
      FOR EACH ROW
      EXECUTE FUNCTION update_customer_stats();
    ]])

    -- Function to update timestamps
    db.query([[
      CREATE OR REPLACE FUNCTION update_timestamp()
      RETURNS TRIGGER AS $$
      BEGIN
        NEW.updated_at = NOW();
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    ]])

    -- Add update timestamp triggers to all tables
    local tables = {"stores", "storeproducts", "orders", "orderitems", "customers", "categories"}
    for _, table in ipairs(tables) do
      db.query(string.format([[
        CREATE TRIGGER trigger_update_%s_timestamp
        BEFORE UPDATE ON %s
        FOR EACH ROW
        EXECUTE FUNCTION update_timestamp();
      ]], table, table))
    end
  end,

  -- 35. Create comprehensive indexes for performance
  ['35_create_performance_indexes'] = function()
    local db = require("lapis.db")

    -- Composite indexes for common queries (avoid duplicates)
    db.query("CREATE INDEX IF NOT EXISTS orders_store_created_status_idx ON orders (store_id, created_at, status)")
    db.query("CREATE INDEX IF NOT EXISTS orders_customer_created_idx ON orders (customer_id, created_at)")
    db.query("CREATE INDEX IF NOT EXISTS orderitems_product_created_idx ON orderitems (product_id, created_at)")
    db.query("CREATE INDEX IF NOT EXISTS storeproducts_store_active_created_idx ON storeproducts (store_id, is_active, created_at)")
    db.query("CREATE INDEX IF NOT EXISTS cart_items_user_updated_idx ON cart_items (user_id, updated_at)")

    -- Full-text search indexes with error handling
    pcall(function()
      db.query("CREATE INDEX IF NOT EXISTS products_fulltext_search_idx ON storeproducts USING gin(to_tsvector('english', name || ' ' || COALESCE(description, '')))")
    end)

    pcall(function()
      db.query("CREATE INDEX IF NOT EXISTS stores_fulltext_search_idx ON stores USING gin(to_tsvector('english', name || ' ' || COALESCE(description, '')))")
    end)
  end,

  -- 36. Add row-level security (RLS) for multi-tenancy - DISABLED
  ['36_enable_row_level_security'] = function()
    -- RLS policies disabled as they require specific role setup
    -- This can be enabled later when proper authentication roles are configured
    local db = require("lapis.db")

    -- Skip RLS setup for now
    print("Skipping RLS setup - requires proper authentication roles")
  end,

  -- 37. Fix invalid regex constraints with improper dash placement
  ['37_fix_regex_constraints'] = function()
    local db = require("lapis.db")

    -- Drop existing problematic constraints
    pcall(function() db.query("ALTER TABLE stores DROP CONSTRAINT IF EXISTS stores_slug_format") end)
    pcall(function() db.query("ALTER TABLE storeproducts DROP CONSTRAINT IF EXISTS products_sku_format") end)
    pcall(function() db.query("ALTER TABLE customers DROP CONSTRAINT IF EXISTS customers_email_format") end)

    -- Add corrected constraints with proper dash escaping/positioning
    pcall(function() db.query("ALTER TABLE stores ADD CONSTRAINT stores_slug_format CHECK (slug ~ '^[a-z0-9\\-]+$')") end)
    pcall(function() db.query("ALTER TABLE storeproducts ADD CONSTRAINT products_sku_format CHECK (sku IS NULL OR sku ~ '^[A-Z0-9\\-_]+$')") end)
    pcall(function() db.query("ALTER TABLE customers ADD CONSTRAINT customers_email_format CHECK (email ~* '^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$')") end)
  end,
}