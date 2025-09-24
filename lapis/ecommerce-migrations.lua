-- Multi-tenant Ecommerce Database Migrations
local schema = require("lapis.db.schema")
local types = schema.types

return {
  -- Stores table - Enhanced for multi-tenancy
  [1] = function()
    schema.create_table("stores", {
      { "id",              types.serial },
      { "uuid",            types.varchar({ unique = true }) },
      { "user_id",         types.foreign_key },
      { "name",            types.varchar },
      { "description",     types.text({ null = true }) },
      { "slug",            types.varchar({ unique = true }) },
      { "logo_url",        types.varchar({ null = true }) },
      { "banner_url",      types.varchar({ null = true }) },
      { "contact_email",   types.varchar({ null = true }) },
      { "contact_phone",   types.varchar({ null = true }) },
      { "address",         types.text({ null = true }) },
      { "city",            types.varchar({ null = true }) },
      { "state",           types.varchar({ null = true }) },
      { "country",         types.varchar({ null = true }) },
      { "postal_code",     types.varchar({ null = true }) },
      { "status",          types.varchar({ default = "'active'" }) },
      { "settings",        types.text({ default = "'{}'" }) },
      { "tax_rate",        types.numeric({ default = 0 }) },
      { "currency",        types.varchar({ default = "'USD'" }) },
      { "timezone",        types.varchar({ default = "'UTC'" }) },
      { "is_verified",     types.boolean({ default = false }) },
      { "created_at",      types.time({ null = true }) },
      { "updated_at",      types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"
    })

    -- Create indexes for better performance
    schema.create_index("stores", "user_id")
    schema.create_index("stores", "status")
    schema.create_index("stores", "slug")
    schema.create_index("stores", "is_verified")
    schema.create_index("stores", "created_at")
  end,

  -- Categories table - Enhanced for better store organization
  [2] = function()
    schema.create_table("categories", {
      { "id",              types.serial },
      { "uuid",            types.varchar({ unique = true }) },
      { "store_id",        types.foreign_key },
      { "parent_id",       types.foreign_key({ null = true }) },
      { "name",            types.varchar },
      { "description",     types.text({ null = true }) },
      { "slug",            types.varchar({ null = true }) },
      { "image_url",       types.varchar({ null = true }) },
      { "sort_order",      types.integer({ default = 0 }) },
      { "is_active",       types.boolean({ default = true }) },
      { "meta_title",      types.varchar({ null = true }) },
      { "meta_description", types.text({ null = true }) },
      { "created_at",      types.time({ null = true }) },
      { "updated_at",      types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE",
      "FOREIGN KEY (parent_id) REFERENCES categories(id) ON DELETE SET NULL"
    })

    -- Create indexes for better performance
    schema.create_index("categories", "store_id")
    schema.create_index("categories", "parent_id")
    schema.create_index("categories", "is_active")
    schema.create_index("categories", "sort_order")
    schema.create_index("categories", "slug")

    -- Composite index for store categories
  end,

  -- Store Products table - Enhanced for better product management
  [3] = function()
    schema.create_table("storeproducts", {
      { "id",                 types.serial },
      { "uuid",               types.varchar({ unique = true }) },
      { "store_id",           types.foreign_key },
      { "category_id",        types.foreign_key({ null = true }) },
      { "name",               types.varchar },
      { "description",        types.text({ null = true }) },
      { "short_description",  types.text({ null = true }) },
      { "slug",               types.varchar({ null = true }) },
      { "sku",                types.varchar({ null = true }) },
      { "barcode",            types.varchar({ null = true }) },
      { "price",              types.numeric },
      { "compare_price",      types.numeric({ null = true }) },
      { "cost_price",         types.numeric({ null = true }) },
      { "track_inventory",    types.boolean({ default = true }) },
      { "inventory_quantity", types.integer({ default = 0 }) },
      { "low_stock_threshold", types.integer({ default = 5 }) },
      { "weight",             types.numeric({ null = true }) },
      { "dimensions",         types.varchar({ null = true }) },
      { "images",             types.text({ default = "'[]'" }) },
      { "variants",           types.text({ default = "'[]'" }) },
      { "tags",               types.text({ null = true }) },
      { "is_active",          types.boolean({ default = true }) },
      { "is_featured",        types.boolean({ default = false }) },
      { "is_digital",         types.boolean({ default = false }) },
      { "requires_shipping",  types.boolean({ default = true }) },
      { "seo_title",          types.varchar({ null = true }) },
      { "seo_description",    types.text({ null = true }) },
      { "sort_order",         types.integer({ default = 0 }) },
      { "rating_average",     types.numeric({ default = 0 }) },
      { "rating_count",       types.integer({ default = 0 }) },
      { "created_at",         types.time({ null = true }) },
      { "updated_at",         types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE",
      "FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL"
    })

    -- Create indexes for better performance
    schema.create_index("storeproducts", "store_id")
    schema.create_index("storeproducts", "category_id")
    schema.create_index("storeproducts", "sku")
    schema.create_index("storeproducts", "barcode")
    schema.create_index("storeproducts", "is_active")
    schema.create_index("storeproducts", "is_featured")
    schema.create_index("storeproducts", "price")
    schema.create_index("storeproducts", "inventory_quantity")
    schema.create_index("storeproducts", "rating_average")
    schema.create_index("storeproducts", "created_at")
    schema.create_index("storeproducts", "slug")

    -- Composite indexes for common queries
  end,

  -- Customers table
  [4] = function()
    schema.create_table("customers", {
      { "id",                types.serial },
      { "uuid",              types.varchar({ unique = true }) },
      { "email",             types.varchar },
      { "first_name",        types.varchar({ null = true }) },
      { "last_name",         types.varchar({ null = true }) },
      { "phone",             types.varchar({ null = true }) },
      { "date_of_birth",     types.date({ null = true }) },
      { "addresses",         types.text({ default = "'[]'" }) },
      { "notes",             types.text({ null = true }) },
      { "tags",              types.text({ null = true }) },
      { "accepts_marketing", types.boolean({ default = false }) },
      { "created_at",        types.time({ null = true }) },
      { "updated_at",        types.time({ null = true }) },
      "PRIMARY KEY (id)"
    })

  end,

  -- Orders table
  [5] = function()
    schema.create_table("orders", {
      { "id",                 types.serial },
      { "uuid",               types.varchar({ unique = true }) },
      { "store_id",           types.foreign_key },
      { "customer_id",        types.foreign_key({ null = true }) },
      { "order_number",       types.varchar({ unique = true }) },
      { "status",             types.varchar({ default = "'pending'" }) },
      { "financial_status",   types.varchar({ default = "'pending'" }) },
      { "fulfillment_status", types.varchar({ default = "'unfulfilled'" }) },
      { "subtotal",           types.numeric },
      { "tax_amount",         types.numeric({ default = 0 }) },
      { "shipping_amount",    types.numeric({ default = 0 }) },
      { "discount_amount",    types.numeric({ default = 0 }) },
      { "total_amount",       types.numeric },
      { "currency",           types.varchar({ default = "'USD'" }) },
      { "billing_address",    types.text({ null = true }) },
      { "shipping_address",   types.text({ null = true }) },
      { "customer_notes",     types.text({ null = true }) },
      { "internal_notes",     types.text({ null = true }) },
      { "processed_at",       types.time({ null = true }) },
      { "created_at",         types.time({ null = true }) },
      { "updated_at",         types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE",
      "FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL"
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
      { "id",            types.serial },
      { "uuid",          types.varchar({ unique = true }) },
      { "order_id",      types.foreign_key },
      { "product_id",    types.foreign_key },
      { "variant_id",    types.varchar({ null = true }) },
      { "quantity",      types.integer },
      { "price",         types.numeric },
      { "total",         types.numeric },
      { "product_title", types.varchar },
      { "variant_title", types.varchar({ null = true }) },
      { "sku",           types.varchar({ null = true }) },
      { "created_at",    types.time({ null = true }) },
      { "updated_at",    types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE",
      "FOREIGN KEY (product_id) REFERENCES storeproducts(id) ON DELETE CASCADE"
    })

    schema.create_index("orderitems", "order_id")
    schema.create_index("orderitems", "product_id")
  end,

  -- Product Variants table
  [7] = function()
    schema.create_table("product_variants", {
      { "id",                 types.serial },
      { "uuid",               types.varchar({ unique = true }) },
      { "product_id",         types.foreign_key },
      { "title",              types.varchar },
      { "option1",            types.varchar({ null = true }) },
      { "option2",            types.varchar({ null = true }) },
      { "option3",            types.varchar({ null = true }) },
      { "sku",                types.varchar({ null = true }) },
      { "price",              types.numeric({ null = true }) },
      { "compare_price",      types.numeric({ null = true }) },
      { "inventory_quantity", types.integer({ default = 0 }) },
      { "weight",             types.numeric({ null = true }) },
      { "image_url",          types.varchar({ null = true }) },
      { "is_active",          types.boolean({ default = true }) },
      { "position",           types.integer({ default = 0 }) },
      { "created_at",         types.time({ null = true }) },
      { "updated_at",         types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (product_id) REFERENCES storeproducts(id) ON DELETE CASCADE"
    })

    schema.create_index("product_variants", "product_id")
    schema.create_index("product_variants", "sku")
    schema.create_index("product_variants", "is_active")
  end,

  -- Inventory Transactions table for tracking stock changes
  [8] = function()
    schema.create_table("inventory_transactions", {
      { "id",            types.serial },
      { "uuid",          types.varchar({ unique = true }) },
      { "product_id",    types.foreign_key },
      { "variant_id",    types.foreign_key({ null = true }) },
      { "order_id",      types.foreign_key({ null = true }) },
      { "type",          types.varchar },
      { "quantity",      types.integer },
      { "reason",        types.varchar({ null = true }) },
      { "created_by",    types.foreign_key({ null = true }) },
      { "created_at",    types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (product_id) REFERENCES storeproducts(id) ON DELETE CASCADE",
      "FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON DELETE CASCADE",
      "FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE",
      "FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL"
    })

    schema.create_index("inventory_transactions", "product_id")
    schema.create_index("inventory_transactions", "variant_id")
    schema.create_index("inventory_transactions", "order_id")
    schema.create_index("inventory_transactions", "type")
    schema.create_index("inventory_transactions", "created_at")
  end,
  
  -- Cart Items table for authenticated user carts
  [9] = function()
    schema.create_table("cart_items", {
      { "id",             types.serial },
      { "user_id",        types.integer },
      { "cart_key",       types.varchar },
      { "product_uuid",   types.varchar },
      { "variant_uuid",   types.varchar({ null = true }) },
      { "name",           types.varchar },
      { "variant_title",  types.varchar({ null = true }) },
      { "price",          types.numeric },
      { "quantity",       types.integer },
      { "created_at",     types.time({ null = true }) },
      { "updated_at",     types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "UNIQUE (user_id, cart_key)"
    })

    schema.create_index("cart_items", "user_id")
    schema.create_index("cart_items", "product_uuid")
  end,

  -- Store Settings table for advanced store configuration
  [11] = function()
    schema.create_table("store_settings", {
      { "id",             types.serial },
      { "store_id",       types.foreign_key },
      { "key",            types.varchar },
      { "value",          types.text({ null = true }) },
      { "type",           types.varchar({ default = "'string'" }) },
      { "created_at",     types.time({ null = true }) },
      { "updated_at",     types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE",
      "UNIQUE (store_id, key)"
    })

    schema.create_index("store_settings", "store_id")
    schema.create_index("store_settings", "key")
  end,

  -- Product Reviews table
  [12] = function()
    schema.create_table("product_reviews", {
      { "id",             types.serial },
      { "uuid",           types.varchar({ unique = true }) },
      { "product_id",     types.foreign_key },
      { "customer_id",    types.foreign_key({ null = true }) },
      { "order_id",       types.foreign_key({ null = true }) },
      { "rating",         types.integer },
      { "title",          types.varchar({ null = true }) },
      { "review_text",    types.text({ null = true }) },
      { "is_verified",    types.boolean({ default = false }) },
      { "is_approved",    types.boolean({ default = false }) },
      { "helpful_count",  types.integer({ default = 0 }) },
      { "created_at",     types.time({ null = true }) },
      { "updated_at",     types.time({ null = true }) },
      "PRIMARY KEY (id)",
      "FOREIGN KEY (product_id) REFERENCES storeproducts(id) ON DELETE CASCADE",
      "FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE",
      "FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE"
    })

    schema.create_index("product_reviews", "product_id")
    schema.create_index("product_reviews", "customer_id")
    schema.create_index("product_reviews", "rating")
    schema.create_index("product_reviews", "is_approved")
    schema.create_index("product_reviews", "created_at")
  end
}
