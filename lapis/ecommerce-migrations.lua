-- Multi-tenant Ecommerce Database Migrations
local schema = require("lapis.db.schema")

return {
  -- Stores table
  [1] = function()
    schema.create_table("stores", {
      { "id",          "serial" },
      { "uuid",        "varchar(36) NOT NULL UNIQUE" },
      { "user_id",     "integer NOT NULL REFERENCES users(id)" },
      { "name",        "varchar(255) NOT NULL" },
      { "description", "text" },
      { "slug",        "varchar(255) UNIQUE" },
      { "logo_url",    "varchar(500)" },
      { "banner_url",  "varchar(500)" },
      { "status",      "varchar(20) DEFAULT 'active'" },
      { "settings",    "jsonb DEFAULT '{}'" },
      { "created_at",  "timestamp DEFAULT NOW()" },
      { "updated_at",  "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("stores", "user_id")
    schema.create_index("stores", "status")
    schema.create_index("stores", "slug")
  end,

  -- Categories table
  [2] = function()
    schema.create_table("categories", {
      { "id",          "serial" },
      { "uuid",        "varchar(36) NOT NULL UNIQUE" },
      { "store_id",    "integer NOT NULL REFERENCES stores(id) ON DELETE CASCADE" },
      { "name",        "varchar(255) NOT NULL" },
      { "description", "text" },
      { "slug",        "varchar(255)" },
      { "image_url",   "varchar(500)" },
      { "sort_order",  "integer DEFAULT 0" },
      { "is_active",   "boolean DEFAULT true" },
      { "created_at",  "timestamp DEFAULT NOW()" },
      { "updated_at",  "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("categories", "store_id")
    schema.create_index("categories", "is_active")
    schema.create_index("categories", "sort_order")
    schema.create_index("categories", "slug")
  end,

  -- Store Products table
  [3] = function()
    schema.create_table("storeproducts", {
      { "id",                 "serial" },
      { "uuid",               "varchar(36) NOT NULL UNIQUE" },
      { "store_id",           "integer NOT NULL REFERENCES stores(id) ON DELETE CASCADE" },
      { "category_id",        "integer REFERENCES categories(id)" },
      { "name",               "varchar(255) NOT NULL" },
      { "description",        "text" },
      { "slug",               "varchar(255)" },
      { "sku",                "varchar(100)" },
      { "price",              "decimal(10,2) NOT NULL" },
      { "compare_price",      "decimal(10,2)" },
      { "cost_price",         "decimal(10,2)" },
      { "track_inventory",    "boolean DEFAULT true" },
      { "inventory_quantity", "integer DEFAULT 0" },
      { "weight",             "decimal(8,2)" },
      { "images",             "jsonb DEFAULT '[]'" },
      { "variants",           "jsonb DEFAULT '[]'" },
      { "tags",               "varchar(500)" },
      { "is_active",          "boolean DEFAULT true" },
      { "is_featured",        "boolean DEFAULT false" },
      { "seo_title",          "varchar(255)" },
      { "seo_description",    "text" },
      { "created_at",         "timestamp DEFAULT NOW()" },
      { "updated_at",         "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("storeproducts", "store_id")
    schema.create_index("storeproducts", "category_id")
    schema.create_index("storeproducts", "sku")
    schema.create_index("storeproducts", "is_active")
    schema.create_index("storeproducts", "is_featured")
    schema.create_index("storeproducts", "price")
    schema.create_index("storeproducts", "created_at")
  end,

  -- Customers table
  [4] = function()
    schema.create_table("customers", {
      { "id",                "serial" },
      { "uuid",              "varchar(36) NOT NULL UNIQUE" },
      { "email",             "varchar(255) NOT NULL" },
      { "first_name",        "varchar(100)" },
      { "last_name",         "varchar(100)" },
      { "phone",             "varchar(20)" },
      { "date_of_birth",     "date" },
      { "addresses",         "jsonb DEFAULT '[]'" },
      { "notes",             "text" },
      { "tags",              "varchar(500)" },
      { "accepts_marketing", "boolean DEFAULT false" },
      { "created_at",        "timestamp DEFAULT NOW()" },
      { "updated_at",        "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("customers", "email", { unique = true })
  end,

  -- Orders table
  [5] = function()
    schema.create_table("orders", {
      { "id",                 "serial" },
      { "uuid",               "varchar(36) NOT NULL UNIQUE" },
      { "store_id",           "integer NOT NULL REFERENCES stores(id)" },
      { "customer_id",        "integer REFERENCES customers(id)" },
      { "order_number",       "varchar(50) NOT NULL UNIQUE" },
      { "status",             "varchar(20) DEFAULT 'pending'" },
      { "financial_status",   "varchar(20) DEFAULT 'pending'" },
      { "fulfillment_status", "varchar(20) DEFAULT 'unfulfilled'" },
      { "subtotal",           "decimal(10,2) NOT NULL" },
      { "tax_amount",         "decimal(10,2) DEFAULT 0" },
      { "shipping_amount",    "decimal(10,2) DEFAULT 0" },
      { "discount_amount",    "decimal(10,2) DEFAULT 0" },
      { "total_amount",       "decimal(10,2) NOT NULL" },
      { "currency",           "varchar(3) DEFAULT 'USD'" },
      { "billing_address",    "jsonb" },
      { "shipping_address",   "jsonb" },
      { "customer_notes",     "text" },
      { "internal_notes",     "text" },
      { "processed_at",       "timestamp" },
      { "created_at",         "timestamp DEFAULT NOW()" },
      { "updated_at",         "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("orders", "store_id")
    schema.create_index("orders", "customer_id")
    schema.create_index("orders", "status")
    schema.create_index("orders", "financial_status")
    schema.create_index("orders", "fulfillment_status")
    schema.create_index("orders", "order_number", { unique = true })
    schema.create_index("orders", "created_at")
    schema.create_index("orders", "processed_at")
  end,

  -- Order Items table
  [6] = function()
    schema.create_table("orderitems", {
      { "id",            "serial" },
      { "uuid",          "varchar(36) NOT NULL UNIQUE" },
      { "order_id",      "integer NOT NULL REFERENCES orders(id) ON DELETE CASCADE" },
      { "product_id",    "integer NOT NULL REFERENCES storeproducts(id)" },
      { "variant_id",    "varchar(100)" },
      { "quantity",      "integer NOT NULL" },
      { "price",         "decimal(10,2) NOT NULL" },
      { "total",         "decimal(10,2) NOT NULL" },
      { "product_title", "varchar(255) NOT NULL" },
      { "variant_title", "varchar(255)" },
      { "sku",           "varchar(100)" },
      { "created_at",    "timestamp DEFAULT NOW()" },
      { "updated_at",    "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("orderitems", "order_id")
    schema.create_index("orderitems", "product_id")
  end,

  -- Product Variants table
  [7] = function()
    schema.create_table("product_variants", {
      { "id",                 "serial" },
      { "uuid",               "varchar(36) NOT NULL UNIQUE" },
      { "product_id",         "integer NOT NULL REFERENCES storeproducts(id) ON DELETE CASCADE" },
      { "title",              "varchar(255) NOT NULL" },
      { "option1",            "varchar(100)" }, -- e.g., Size
      { "option2",            "varchar(100)" }, -- e.g., Color
      { "option3",            "varchar(100)" }, -- e.g., Material
      { "sku",                "varchar(100)" },
      { "price",              "decimal(10,2)" },
      { "compare_price",      "decimal(10,2)" },
      { "inventory_quantity", "integer DEFAULT 0" },
      { "weight",             "decimal(8,2)" },
      { "image_url",          "varchar(500)" },
      { "is_active",          "boolean DEFAULT true" },
      { "position",           "integer DEFAULT 0" },
      { "created_at",         "timestamp DEFAULT NOW()" },
      { "updated_at",         "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("product_variants", "product_id")
    schema.create_index("product_variants", "sku")
    schema.create_index("product_variants", "is_active")
  end,

  -- Inventory Transactions table for tracking stock changes
  [8] = function()
    schema.create_table("inventory_transactions", {
      { "id",            "serial" },
      { "uuid",          "varchar(36) NOT NULL UNIQUE" },
      { "product_id",    "integer NOT NULL REFERENCES storeproducts(id)" },
      { "variant_id",    "integer REFERENCES product_variants(id)" },
      { "order_id",      "integer REFERENCES orders(id)" },
      { "type",          "varchar(20) NOT NULL" }, -- 'sale', 'restock', 'adjustment'
      { "quantity",      "integer NOT NULL" },
      { "reason",        "varchar(255)" },
      { "created_at",    "timestamp DEFAULT NOW()" },
      "PRIMARY KEY (id)"
    })

    schema.create_index("inventory_transactions", "product_id")
    schema.create_index("inventory_transactions", "variant_id")
    schema.create_index("inventory_transactions", "order_id")
    schema.create_index("inventory_transactions", "type")
    schema.create_index("inventory_transactions", "created_at")
  end
}
