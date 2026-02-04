--[[
  Conditional Migrations System

  This migration file uses PROJECT_CODE environment variable to conditionally
  create only the required tables for each project.

  Usage:
    PROJECT_CODE=tax_copilot   → Only core + tax tables
    PROJECT_CODE=ecommerce     → Core + ecommerce + delivery tables
    PROJECT_CODE=all           → All tables (default, backward compatible)

  See helper/project-config.lua for full configuration options.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"
local ProjectConfig = require "helper.project-config"

-- Print project configuration at migration start
ProjectConfig.printConfig()

-- Default admin password - CHANGE THIS AFTER FIRST LOGIN
local DEFAULT_ADMIN_PASSWORD = "Admin@123"

-- =============================================================================
-- CONDITIONAL MIGRATION LOADERS
-- =============================================================================

-- Helper function to create a no-op migration
local function skip_migration(_name)
    return function()
        -- Migration skipped based on PROJECT_CODE
    end
end

-- Helper function to conditionally load migration modules
local function load_if_enabled(feature, module_name)
    if ProjectConfig.isFeatureEnabled(feature) then
        local ok, module = pcall(require, module_name)
        if ok then
            return module
        else
            print("[Migration] Warning: Could not load module " .. module_name .. ": " .. tostring(module))
            return {}
        end
    end
    return nil  -- Feature not enabled
end

-- =============================================================================
-- LOAD FEATURE-SPECIFIC MIGRATIONS (only if feature is enabled)
-- =============================================================================

-- Ecommerce
local ecommerce_migrations = load_if_enabled(ProjectConfig.FEATURES.ECOMMERCE, "ecommerce-migrations") or {}
local production_schema_upgrade = load_if_enabled(ProjectConfig.FEATURES.ECOMMERCE, "production-schema-upgrade") or {}
local order_management_migrations = load_if_enabled(ProjectConfig.FEATURES.ECOMMERCE, "migrations.order-management-enhancement") or {}
local payment_tracking_migrations = load_if_enabled(ProjectConfig.FEATURES.ECOMMERCE, "migrations.payment-tracking") or {}
local stripe_integration_migrations = load_if_enabled(ProjectConfig.FEATURES.ECOMMERCE, "migrations.stripe-integration") or {}
local multi_currency_migrations = load_if_enabled(ProjectConfig.FEATURES.ECOMMERCE, "migrations.multi-currency-support") or {}
local customer_user_link_migrations = load_if_enabled(ProjectConfig.FEATURES.ECOMMERCE, "migrations.customer-user-link") or {}

-- Delivery
local delivery_partner_migrations = load_if_enabled(ProjectConfig.FEATURES.DELIVERY, "migrations.delivery-partner-system") or {}
local geolocation_delivery_migrations = load_if_enabled(ProjectConfig.FEATURES.DELIVERY, "migrations.geolocation-delivery-system") or {}
local fix_delivery_request_constraint = load_if_enabled(ProjectConfig.FEATURES.DELIVERY, "migrations.fix-delivery-request-constraint") or {}

-- Hospital
local hospital_crm_migrations = load_if_enabled(ProjectConfig.FEATURES.HOSPITAL, "migrations.hospital-crm") or {}

-- Notifications
local notification_migrations = load_if_enabled(ProjectConfig.FEATURES.NOTIFICATIONS, "migrations.notifications") or {}
local push_notification_migrations = load_if_enabled(ProjectConfig.FEATURES.NOTIFICATIONS, "migrations.push-notifications") or {}

-- Reviews
local review_migrations = load_if_enabled(ProjectConfig.FEATURES.REVIEWS, "migrations.reviews") or {}

-- Chat
local chat_system_migrations = load_if_enabled(ProjectConfig.FEATURES.CHAT, "migrations.chat-system") or {}
local chat_production_migrations = load_if_enabled(ProjectConfig.FEATURES.CHAT, "migrations.chat-system-production") or {}

-- Kanban
local kanban_project_migrations = load_if_enabled(ProjectConfig.FEATURES.KANBAN, "migrations.kanban-project-system") or {}
local kanban_enhancement_migrations = load_if_enabled(ProjectConfig.FEATURES.KANBAN, "migrations.kanban-enhancements") or {}

-- Menu (usually enabled for most projects)
local menu_system_migrations = load_if_enabled(ProjectConfig.FEATURES.MENU, "migrations.menu-system") or {}

-- Vault
local secret_vault_migrations = load_if_enabled(ProjectConfig.FEATURES.VAULT, "migrations.secret-vault") or {}

-- Services
local services_module_migrations = load_if_enabled(ProjectConfig.FEATURES.SERVICES, "migrations.services-module") or {}

-- Bank Transactions (standalone feature)
local bank_transaction_migrations = load_if_enabled(ProjectConfig.FEATURES.BANK_TRANSACTIONS, "migrations.bank-transactions") or {}

-- Core enhancements (always load for namespace/rbac)
local rbac_enhancements_migrations = require("migrations.rbac-enhancements")
local namespace_system_migrations = require("migrations.namespace-system")

-- Tax Copilot (new)
local tax_copilot_migrations = load_if_enabled(ProjectConfig.FEATURES.TAX_COPILOT, "migrations.tax-copilot-system") or {}

-- =============================================================================
-- HELPER FUNCTIONS FOR CONDITIONAL MIGRATIONS
-- =============================================================================

-- Returns the migration function or a skip function
local function conditional(feature, migration_func)
    if ProjectConfig.isFeatureEnabled(feature) and migration_func then
        return migration_func
    end
    return skip_migration(feature)
end

-- Returns the migration from an array or a skip function
local function conditional_array(feature, migrations_array, index)
    if ProjectConfig.isFeatureEnabled(feature) and migrations_array and migrations_array[index] then
        return migrations_array[index]
    end
    return skip_migration(feature .. "[" .. tostring(index) .. "]")
end

-- =============================================================================
-- MIGRATIONS TABLE
-- =============================================================================

return {
    -- =========================================================================
    -- CORE MIGRATIONS (Always run - these are required for any project)
    -- =========================================================================

    ['01_create_users'] = function()
        schema.create_table("users", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "first_name", types.varchar }, { "last_name", types.varchar }, { "email", types.varchar({
            unique = true
        }) }, { "username", types.varchar({
            unique = true
        }) }, { "password", types.text }, { "phone_no", types.text({
            null = true
        }) }, { "address", types.text({
            null = true
        }) }, {
            "active",
            types.boolean,
            default = false
        }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
        local adminExists = db.select("id from users where username = ?", "administrative")
        if not adminExists or #adminExists == 0 then
            local hashedPassword = MigrationUtils.hashPassword(DEFAULT_ADMIN_PASSWORD)
            db.query([[
        INSERT INTO users (uuid, first_name, last_name, username, password, email, active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], MigrationUtils.generateUUID(), "Super", "User", "administrative", hashedPassword,
                "administrative@admin.com", true, MigrationUtils.getCurrentTimestamp(),
                MigrationUtils.getCurrentTimestamp())
        end
    end,

    ['02_create_roles'] = function()
        schema.create_table("roles", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "role_name", types.varchar({
            unique = true
        }) }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
        local adminRoleExists = db.select("id from roles where role_name = ?", "administrative")
        if not adminRoleExists or #adminRoleExists == 0 then
            db.query([[
        INSERT INTO roles (uuid, role_name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      ]], MigrationUtils.generateUUID(), "administrative", MigrationUtils.getCurrentTimestamp(),
                MigrationUtils.getCurrentTimestamp())
        end

        -- Only create ecommerce roles if ecommerce is enabled
        if ProjectConfig.isEcommerceEnabled() then
            local sellerRoleExists = db.select("id from roles where role_name = ?", "seller")
            if not sellerRoleExists or #sellerRoleExists == 0 then
                db.query([[
            INSERT INTO roles (uuid, role_name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
          ]], MigrationUtils.generateUUID(), "seller", MigrationUtils.getCurrentTimestamp(),
                    MigrationUtils.getCurrentTimestamp())
            end

            local buyerRoleExists = db.select("id from roles where role_name = ?", "buyer")
            if not buyerRoleExists or #buyerRoleExists == 0 then
                db.query([[
            INSERT INTO roles (uuid, role_name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
          ]], MigrationUtils.generateUUID(), "buyer", MigrationUtils.getCurrentTimestamp(),
                    MigrationUtils.getCurrentTimestamp())
            end
        end

        -- Only create delivery role if delivery is enabled
        if ProjectConfig.isDeliveryEnabled() then
            local deliveryPartnerRoleExists = db.select("id from roles where role_name = ?", "delivery_partner")
            if not deliveryPartnerRoleExists or #deliveryPartnerRoleExists == 0 then
                db.query([[
            INSERT INTO roles (uuid, role_name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
          ]], MigrationUtils.generateUUID(), "delivery_partner", MigrationUtils.getCurrentTimestamp(),
                    MigrationUtils.getCurrentTimestamp())
            end
        end

        -- Create member role for all projects
        local memberRoleExists = db.select("id from roles where role_name = ?", "member")
        if not memberRoleExists or #memberRoleExists == 0 then
            db.query([[
        INSERT INTO roles (uuid, role_name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      ]], MigrationUtils.generateUUID(), "member", MigrationUtils.getCurrentTimestamp(),
                MigrationUtils.getCurrentTimestamp())
        end
    end,

    ['02create_user__roles'] = function()
        schema.create_table("user__roles", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "role_id", types.foreign_key }, { "user_id", types.foreign_key }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)", "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
            "FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE" })
        local roleExists = db.select("id from user__roles where role_id = ? and user_id = ?", 1, 1)
        if not roleExists or #roleExists == 0 then
            db.query([[
        INSERT INTO user__roles (uuid, role_id, user_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
      ]], MigrationUtils.generateUUID(), 1, 1, MigrationUtils.getCurrentTimestamp(), MigrationUtils.getCurrentTimestamp())
        end
    end,

    ['03create_modules'] = function()
        schema.create_table("modules", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "machine_name", types.varchar({
            unique = true
        }) }, { "name", types.varchar }, { "description", types.text({
            null = true
        }) }, { "priority", types.varchar }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
    end,

    ['04create_permissions'] = function()
        schema.create_table("permissions", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "module_id", types.foreign_key }, { "permissions", types.text({
            null = true
        }) }, { "role_id", types.foreign_key }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)", "FOREIGN KEY (module_id) REFERENCES modules(id) ON DELETE CASCADE",
            "FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE" })
    end,

    ['05create_groups'] = function()
        schema.create_table("groups", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "machine_name", types.varchar({
            unique = true
        }) }, { "name", types.varchar }, { "description", types.text({
            null = true
        }) }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
    end,

    ['06create_user__groups'] = function()
        schema.create_table("user__groups", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "user_id", types.foreign_key }, { "group_id", types.foreign_key }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)", "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
            "FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE" })
    end,

    ['07create_secrets'] = function()
        schema.create_table("secrets", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "secret", types.varchar }, { "name", types.varchar }, { "description", types.text({
            null = true
        }) }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
    end,

    ['03_create_templates'] = function()
        schema.create_table("templates", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "code", types.varchar }, { "template_content", types.text }, { "template_type", types.varchar({
            null = true
        }) }, { "description", types.text({
            null = true
        }) }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
    end,

    ['04_create_projects'] = function()
        schema.create_table("projects", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "name", types.varchar }, { "start_date", types.date({
            null = true
        }) }, { "budget", types.double({
            null = true
        }) }, { "deadline_date", types.date({
            null = true
        }) }, { "active", types.boolean }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
    end,

    ['05_create_project__templates'] = function()
        schema.create_table("project__templates", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "project_id", types.foreign_key }, { "template_id", types.foreign_key }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)", "FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE",
            "FOREIGN KEY (template_id) REFERENCES templates(id) ON DELETE CASCADE" })
    end,

    ['06_create_documents'] = function()
        schema.create_table("documents", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "excerpt", types.text({
            null = true
        }) }, { "title", types.varchar }, { "sub_title", types.varchar({
            null = true
        }) }, { "slug", types.text({
            unique = true,
            null = true
        }) }, { "status", types.boolean }, { "meta_title", types.varchar({
            null = true
        }) }, { "meta_description", types.varchar({
            null = true
        }) }, { "meta_keywords", types.text({
            null = true
        }) }, { "user_id", types.foreign_key }, { "published_date", types.date({
            null = true
        }) }, { "content", types.text({
            null = true
        }) }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)", "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE" })
    end,

    ['07_create_tags'] = function()
        schema.create_table("tags", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "name", types.varchar({
            unique = true
        }) }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)" })
    end,

    ['08_create_blog__tags'] = function()
        schema.create_table("document__tags", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "document_id", types.foreign_key }, { "tag_id", types.foreign_key }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (document_id, tag_id)",
            "FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE",
            "FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE" })
    end,

    ['09_create_images'] = function()
        schema.create_table("images", { { "id", types.serial }, { "uuid", types.varchar({
            unique = true
        }) }, { "document_id", types.foreign_key }, { "url", types.text }, { "alt_text", types.text({
            null = true
        }) }, { "is_cover", types.boolean({
            default = false
        }) }, { "created_at", types.time({
            null = true
        }) }, { "updated_at", types.time({
            null = true
        }) }, "PRIMARY KEY (id)", "FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE" })
    end,

    ['10_create_enquiries'] = function()
        schema.create_table("enquiries", {
            { "id",         types.serial },
            { "uuid",       types.varchar({ unique = true }) },
            { "name",       types.varchar },
            { "email",      types.varchar },
            { "phone_no",   types.varchar },
            { "comments",   types.text({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) }
        })
    end,

    -- Products table (conditionally for ecommerce)
    ['11_create_products'] = conditional(ProjectConfig.FEATURES.ECOMMERCE, function()
        schema.create_table("products", {
            { "id",                types.serial },
            { "uuid",              types.varchar({ unique = true }) },
            { "name",              types.varchar },
            { "description",       types.text({ null = true }) },
            { "SKU",               types.varchar },
            { "price",             types.varchar },
            { "quantity_in_stock", types.varchar },
            { "manufacturer",      types.varchar },
            { "status",            types.varchar },
            { "created_at",        types.time({ null = true }) },
            { "updated_at",        types.time({ null = true }) }
        })
    end),

    -- =========================================================================
    -- ECOMMERCE MIGRATIONS (Only if ECOMMERCE feature is enabled)
    -- =========================================================================

    ['12_create_stores'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 1),
    ['13_create_categories'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 2),
    ['14_create_storeproducts'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 3),
    ['15_create_customers'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 4),
    ['16_create_orders'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 5),
    ['17_create_orderitems'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 6),
    ['18_create_product_variants'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 7),
    ['19_create_inventory_transactions'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 8),
    ['20_create_cart_items'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 9),
    ['21_create_store_settings'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 10),
    ['22_create_product_reviews'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 11),
    ['23_alter_store_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 13),
    ['38_alter_category_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, ecommerce_migrations, 14),

    -- OAuth (always needed for auth)
    ['24_add_oauth_fields_to_users'] = function()
        schema.add_column("users", "oauth_provider", types.varchar({ null = true }))
        schema.add_column("users", "oauth_id", types.varchar({ null = true }))
        schema.create_index("users", "oauth_provider", "oauth_id")
    end,

    -- Payment fields (conditional on ecommerce)
    ['25_add_payment_fields_to_orders'] = conditional(ProjectConfig.FEATURES.ECOMMERCE, function()
        schema.add_column("orders", "payment_intent_id", types.text({ null = true }))
        schema.add_column("orders", "payment_status", types.varchar({ default = "pending" }))
        schema.add_column("orders", "payment_method", types.varchar({ default = "stripe" }))
        schema.add_column("orders", "stripe_customer_id", types.text({ null = true }))
        schema.create_index("orders", "payment_intent_id")
        schema.create_index("orders", "payment_status")
    end),

    -- Production Schema Upgrades (conditional on ecommerce)
    ['26_fix_orderitems_variant_field'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '26_fix_orderitems_variant_field'),
    ['27_enable_uuid_extensions'] = production_schema_upgrade and production_schema_upgrade['27_enable_uuid_extensions'] or skip_migration("uuid_ext"),
    ['28_enhance_stores_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '28_enhance_stores_table'),
    ['29_enhance_products_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '29_enhance_products_table'),
    ['30_enhance_orders_tracking'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '30_enhance_orders_tracking'),
    ['31_enhance_customers_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '31_enhance_customers_table'),
    ['32_create_inventory_analytics'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '32_create_inventory_analytics'),
    ['33_create_analytics_tables'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '33_create_analytics_tables'),
    ['34_create_data_integrity_functions'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '34_create_data_integrity_functions'),
    ['35_create_performance_indexes'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '35_create_performance_indexes'),
    ['36_enable_row_level_security'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '36_enable_row_level_security'),
    ['37_fix_regex_constraints'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, production_schema_upgrade, '37_fix_regex_constraints'),

    -- Order Management (conditional on ecommerce)
    ['39_create_order_history_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 1),
    ['40_create_notifications_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 2),
    ['41_create_shipping_tracking_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 3),
    ['42_create_order_refunds_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 4),
    ['43_add_tracking_fields_to_orders'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 5),
    ['44_create_seller_note_templates'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 6),
    ['45_create_order_tags_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 7),
    ['46_add_seller_order_indexes'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, order_management_migrations, 8),

    -- Hospital CRM (conditional)
    ['47_create_hospitals_table'] = conditional_array(ProjectConfig.FEATURES.HOSPITAL, hospital_crm_migrations, 1),
    ['48_create_patients_table'] = conditional_array(ProjectConfig.FEATURES.HOSPITAL, hospital_crm_migrations, 2),
    ['49_create_patient_health_records_table'] = conditional_array(ProjectConfig.FEATURES.HOSPITAL, hospital_crm_migrations, 3),
    ['50_create_hospital_staff_table'] = conditional_array(ProjectConfig.FEATURES.HOSPITAL, hospital_crm_migrations, 4),
    ['51_create_patient_assignments_table'] = conditional_array(ProjectConfig.FEATURES.HOSPITAL, hospital_crm_migrations, 5),
    ['52_create_patient_appointments_table'] = conditional_array(ProjectConfig.FEATURES.HOSPITAL, hospital_crm_migrations, 6),
    ['53_create_patient_documents_table'] = conditional_array(ProjectConfig.FEATURES.HOSPITAL, hospital_crm_migrations, 7),

    -- Payment Tracking (conditional on ecommerce)
    ['54_create_payments_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 1),
    ['55_add_payment_indexes'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 2),
    ['56_add_payment_id_to_orders'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 3),
    ['57_update_order_status_enum'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 4),
    ['58_create_order_status_history'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 5),
    ['59_add_status_history_indexes'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 6),
    ['60_add_tracking_to_orders'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 7),
    ['61_create_refunds_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 8),
    ['62_add_refund_indexes'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 9),
    ['63_fix_order_status_constraint'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, payment_tracking_migrations, 10),

    -- Notifications (conditional)
    ['64_create_notifications_table'] = conditional_array(ProjectConfig.FEATURES.NOTIFICATIONS, notification_migrations, 1),
    ['65_add_notification_indexes'] = conditional_array(ProjectConfig.FEATURES.NOTIFICATIONS, notification_migrations, 2),
    ['66_create_notification_preferences'] = conditional_array(ProjectConfig.FEATURES.NOTIFICATIONS, notification_migrations, 3),

    -- Reviews (conditional)
    ['67_create_store_reviews_table'] = conditional_array(ProjectConfig.FEATURES.REVIEWS, review_migrations, 1),
    ['68_add_store_review_indexes'] = conditional_array(ProjectConfig.FEATURES.REVIEWS, review_migrations, 2),
    ['69_create_product_reviews_table'] = conditional_array(ProjectConfig.FEATURES.REVIEWS, review_migrations, 3),
    ['70_add_product_review_indexes'] = conditional_array(ProjectConfig.FEATURES.REVIEWS, review_migrations, 4),

    -- Customer-User Link (conditional on ecommerce)
    ['71_add_user_id_to_customers'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, customer_user_link_migrations, 1),
    ['72_add_customer_user_id_index'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, customer_user_link_migrations, 2),
    ['73_migrate_customer_user_data'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, customer_user_link_migrations, 3),

    -- Stripe Integration (conditional on ecommerce)
    ['74_add_stripe_customer_id_to_customers'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, stripe_integration_migrations, 1),
    ['75_add_stripe_customer_id_index'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, stripe_integration_migrations, 2),

    -- Delivery Partner System (conditional)
    ['76_create_delivery_partners_table'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 1),
    ['77_add_delivery_partners_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 2),
    ['78_create_delivery_partner_areas_table'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 3),
    ['79_add_delivery_partner_areas_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 4),
    ['80_create_store_delivery_partners_table'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 5),
    ['81_add_store_delivery_partners_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 6),
    ['82_create_order_delivery_assignments_table'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 7),
    ['83_add_order_delivery_assignments_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 8),
    ['84_create_delivery_requests_table'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 9),
    ['85_add_delivery_requests_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 10),
    ['86_create_delivery_partner_reviews_table'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 11),
    ['87_add_delivery_partner_reviews_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 12),
    ['88_add_delivery_partner_constraints'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 13),
    ['89_add_can_self_ship_to_stores'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 14),
    ['90_add_delivery_partner_id_to_orders'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, delivery_partner_migrations, 15),

    -- Geolocation Delivery (conditional)
    ['91_enable_postgis_extension'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 1),
    ['92_add_geolocation_to_delivery_partners'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 2),
    ['93_create_delivery_partners_location_index'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 3),
    ['94_create_delivery_partner_location_trigger'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 4),
    ['95_add_geolocation_to_orders'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 5),
    ['96_create_orders_location_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 6),
    ['97_create_order_locations_trigger'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 7),
    ['98_create_find_nearby_partners_function'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 8),
    ['99_create_can_service_location_function'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 9),
    ['100_create_delivery_partner_notifications_table'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 10),
    ['101_add_notifications_indexes'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 11),
    ['102_create_delivery_partner_geo_stats_view'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 12),
    ['103_add_geolocation_documentation'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 13),
    ['104_create_calculate_delivery_fee_function'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 14),
    ['105_add_coordinate_validation_constraints'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, geolocation_delivery_migrations, 15),

    -- Multi-Currency (conditional)
    ['106_add_currency_to_store_products'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 1),
    ['107_add_currency_to_cart_items'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 2),
    ['108_add_currency_to_order_items'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 3),
    ['109_add_currency_to_delivery_requests'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, multi_currency_migrations, 4),
    ['110_add_currency_to_order_delivery_assignments'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, multi_currency_migrations, 5),
    ['111_add_currency_to_order_refunds'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 6),
    ['112_add_preferred_currency_to_delivery_partners'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, multi_currency_migrations, 7),
    ['113_add_currency_preferences_to_users'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 8),
    ['114_create_supported_currencies_table'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 9),
    ['115_populate_supported_currencies'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 10),
    ['116_add_currency_indexes'] = conditional_array(ProjectConfig.FEATURES.ECOMMERCE, multi_currency_migrations, 11),

    ['117_fix_delivery_request_unique_constraint'] = conditional_array(ProjectConfig.FEATURES.DELIVERY, fix_delivery_request_constraint, 1),

    -- Chat System (conditional)
    ['118_create_chat_channels_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 1),
    ['119_add_chat_channels_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 2),
    ['120_create_chat_channel_members_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 3),
    ['121_add_chat_channel_members_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 4),
    ['122_create_chat_messages_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 5),
    ['123_add_chat_messages_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 6),
    ['124_create_chat_message_reactions_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 7),
    ['125_add_chat_message_reactions_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 8),
    ['126_create_chat_read_receipts_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 9),
    ['127_add_chat_read_receipts_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 10),
    ['128_create_chat_typing_indicators_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 11),
    ['129_add_chat_typing_indicators_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 12),
    ['130_add_chat_constraints'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 13),
    ['131_add_chat_foreign_keys'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 14),
    ['132_create_chat_file_attachments_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 15),
    ['133_add_chat_file_attachments_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 16),
    ['134_create_chat_user_presence_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 17),
    ['135_add_chat_user_presence_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 18),
    ['136_create_chat_bookmarks_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 19),
    ['137_add_chat_bookmarks_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 20),
    ['138_create_chat_drafts_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 21),
    ['139_add_chat_drafts_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 22),
    ['140_create_chat_mentions_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 23),
    ['141_add_chat_mentions_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 24),
    ['142_create_chat_channel_invites_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 25),
    ['143_add_chat_channel_invites_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 26),
    ['144_add_chat_presence_constraints'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 27),
    ['145_create_chat_channel_last_message_trigger'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 28),
    ['146_create_chat_reply_count_trigger'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 29),
    ['147_create_chat_unread_counts_view'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 30),
    ['148_ensure_last_read_at_column'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 31),
    ['149_fix_chat_default_values'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_system_migrations, 32),

    -- RBAC Enhancements (always needed)
    ['150_add_description_to_roles'] = rbac_enhancements_migrations[1],
    ['151_seed_dashboard_modules'] = rbac_enhancements_migrations[2],

    -- Namespace System (always needed)
    ['152_create_namespaces_table'] = namespace_system_migrations[1],
    ['153_add_namespaces_indexes'] = namespace_system_migrations[2],
    ['154_create_namespace_members_table'] = namespace_system_migrations[3],
    ['155_add_namespace_members_indexes'] = namespace_system_migrations[4],
    ['156_create_namespace_roles_table'] = namespace_system_migrations[5],
    ['157_add_namespace_roles_indexes'] = namespace_system_migrations[6],
    ['158_create_namespace_user_roles_table'] = namespace_system_migrations[7],
    ['159_add_namespace_user_roles_indexes'] = namespace_system_migrations[8],
    ['160_create_namespace_invitations_table'] = namespace_system_migrations[9],
    ['161_add_namespace_invitations_indexes'] = namespace_system_migrations[10],
    ['162_create_user_namespace_settings_table'] = namespace_system_migrations[11],
    ['163_add_user_namespace_settings_indexes'] = namespace_system_migrations[12],
    ['164_add_namespace_id_to_stores'] = conditional(ProjectConfig.FEATURES.ECOMMERCE, namespace_system_migrations[13]),
    ['165_add_namespace_id_to_orders'] = conditional(ProjectConfig.FEATURES.ECOMMERCE, namespace_system_migrations[14]),
    ['166_add_namespace_id_to_customers'] = conditional(ProjectConfig.FEATURES.ECOMMERCE, namespace_system_migrations[15]),
    ['167_add_namespace_id_to_categories'] = conditional(ProjectConfig.FEATURES.ECOMMERCE, namespace_system_migrations[16]),
    ['168_add_namespace_id_to_storeproducts'] = conditional(ProjectConfig.FEATURES.ECOMMERCE, namespace_system_migrations[17]),
    ['169_add_namespace_id_to_chat_channels'] = conditional(ProjectConfig.FEATURES.CHAT, namespace_system_migrations[18]),
    ['170_add_namespace_id_to_delivery_partners'] = conditional(ProjectConfig.FEATURES.DELIVERY, namespace_system_migrations[19]),
    ['171_add_namespace_id_to_notifications'] = conditional(ProjectConfig.FEATURES.NOTIFICATIONS, namespace_system_migrations[20]),
    ['172_add_namespace_id_to_enquiries'] = namespace_system_migrations[21],
    ['173_seed_default_namespace_and_roles'] = namespace_system_migrations[22],
    ['174_add_admin_to_system_namespace'] = namespace_system_migrations[23],
    ['175_migrate_existing_data_to_namespace'] = namespace_system_migrations[24],
    ['176_add_existing_users_to_namespace'] = namespace_system_migrations[25],
    ['177_create_namespace_audit_logs_table'] = namespace_system_migrations[26],
    ['178_add_namespace_audit_logs_indexes'] = namespace_system_migrations[27],
    ['179_ensure_namespace_columns_on_all_tables'] = namespace_system_migrations[28],

    -- Services Module (conditional)
    ['180_create_namespace_services_table'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 1),
    ['181_add_namespace_services_indexes'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 2),
    ['182_create_namespace_service_secrets_table'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 3),
    ['183_add_namespace_service_secrets_indexes'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 4),
    ['184_create_namespace_service_deployments_table'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 5),
    ['185_add_namespace_service_deployments_indexes'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 6),
    ['186_create_namespace_service_variables_table'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 7),
    ['187_add_namespace_service_variables_indexes'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 8),
    ['188_add_services_permission_to_roles'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 9),
    ['189_create_namespace_github_integrations_table'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 10),
    ['190_add_namespace_github_integrations_indexes'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 11),
    ['191_add_github_integration_id_to_services'] = conditional_array(ProjectConfig.FEATURES.SERVICES, services_module_migrations, 12),

    -- Chat Production (conditional)
    ['192_add_chat_fulltext_search'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 1),
    ['193_add_chat_brin_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 2),
    ['194_add_chat_composite_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 3),
    ['195_create_message_delivery_tracking'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 4),
    ['196_create_channel_stats_materialized_view'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 5),
    ['197_create_refresh_channel_stats_function'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 6),
    ['198_enhance_mention_processing'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 7),
    ['199_add_mention_indexes'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 8),
    ['200_create_message_archive_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 9),
    ['201_create_bulk_unread_counts_function'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 10),
    ['202_create_message_edit_history'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 11),
    ['203_add_chat_data_integrity_constraints'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 12),
    ['204_create_keyset_pagination_function'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 13),
    ['205_add_user_presence_functions'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 14),
    ['206_add_chat_data_quality_constraints'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 15),
    ['207_create_user_channels_view'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 16),
    ['208_add_channel_mention_support'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 17),
    ['209_add_chat_metrics_table'] = conditional_array(ProjectConfig.FEATURES.CHAT, chat_production_migrations, 18),

    -- Kanban (conditional)
    ['210_create_kanban_projects_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 1),
    ['211_add_kanban_projects_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 2),
    ['212_create_kanban_project_members_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 3),
    ['213_add_kanban_project_members_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 4),
    ['214_create_kanban_boards_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 5),
    ['215_add_kanban_boards_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 6),
    ['216_create_kanban_columns_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 7),
    ['217_add_kanban_columns_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 8),
    ['218_create_kanban_tasks_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 9),
    ['219_add_kanban_tasks_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 10),
    ['220_create_kanban_task_assignees_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 11),
    ['221_add_kanban_task_assignees_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 12),
    ['222_create_kanban_task_labels_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 13),
    ['223_add_kanban_task_labels_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 14),
    ['224_create_kanban_task_label_links_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 15),
    ['225_add_kanban_task_label_links_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 16),
    ['226_create_kanban_task_comments_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 17),
    ['227_add_kanban_task_comments_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 18),
    ['228_create_kanban_task_attachments_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 19),
    ['229_add_kanban_task_attachments_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 20),
    ['230_create_kanban_task_checklists_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 21),
    ['231_add_kanban_task_checklists_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 22),
    ['232_create_kanban_checklist_items_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 23),
    ['233_add_kanban_checklist_items_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 24),
    ['234_create_kanban_task_activities_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 25),
    ['235_add_kanban_task_activities_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 26),
    ['236_create_kanban_sprints_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 27),
    ['237_add_kanban_sprints_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 28),
    ['238_add_sprint_id_to_kanban_tasks'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 29),
    ['239_create_kanban_count_triggers'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 30),
    ['240_create_kanban_comment_count_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 31),
    ['241_create_kanban_checklist_count_triggers'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 32),
    ['242_create_kanban_task_search'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 33),
    ['243_add_kanban_module_permissions'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 34),
    ['244_create_kanban_assignee_count_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 35),
    ['245_create_kanban_member_count_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 36),
    ['246_create_kanban_attachment_count_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 37),
    ['247_create_kanban_label_usage_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 38),
    ['248_create_kanban_board_count_triggers'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 39),
    ['249_create_kanban_comment_reply_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_project_migrations, 40),
    ['250_create_kanban_time_entries_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 1),
    ['251_add_kanban_time_entries_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 2),
    ['252_create_kanban_notifications_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 3),
    ['253_add_kanban_notifications_indexes'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 4),
    ['254_create_kanban_notification_preferences_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 5),
    ['255_create_kanban_project_activity_feed_view'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 6),
    ['256_create_kanban_sprint_burndown_table'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 7),
    ['257_add_sprint_retrospective_fields'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 8),
    ['258_create_task_time_spent_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 9),
    ['259_create_project_budget_spent_trigger'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 10),
    ['260_create_due_date_notification_function'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 11),
    ['261_kanban_enhancements_complete'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 12),
    ['262_fix_kanban_nullable_fk_defaults'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 13),
    ['271_add_duration_seconds_to_time_entries'] = conditional_array(ProjectConfig.FEATURES.KANBAN, kanban_enhancement_migrations, 14),

    -- Menu System (conditional)
    ['263_create_menu_items_table'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 1),
    ['264_add_menu_items_indexes'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 2),
    ['265_create_namespace_menu_config_table'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 3),
    ['266_add_namespace_menu_config_indexes'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 4),
    ['267_seed_default_menu_items'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 5),
    ['268_add_new_modules_to_modules_table'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 6),
    ['269_update_namespace_roles_default_permissions'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 7),
    ['270_init_namespace_menu_configs'] = conditional_array(ProjectConfig.FEATURES.MENU, menu_system_migrations, 8),
    ['288_add_vault_menu_item'] = conditional_array(ProjectConfig.FEATURES.VAULT, menu_system_migrations, 9),

    -- Secret Vault (conditional)
    ['272_create_namespace_secret_vaults_table'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 1),
    ['273_add_namespace_secret_vaults_indexes'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 2),
    ['274_create_namespace_vault_folders_table'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 3),
    ['275_add_namespace_vault_folders_indexes'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 4),
    ['276_create_namespace_vault_secrets_table'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 5),
    ['277_add_namespace_vault_secrets_indexes'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 6),
    ['278_create_namespace_vault_shares_table'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 7),
    ['279_add_namespace_vault_shares_indexes'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 8),
    ['280_create_namespace_vault_access_logs_table'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 9),
    ['281_add_namespace_vault_access_logs_indexes'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 10),
    ['282_create_vault_secrets_count_trigger'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 11),
    ['283_create_share_count_trigger'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 12),
    ['284_add_vault_permissions_to_roles'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 13),
    ['285_add_vault_module'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 14),
    ['286_create_expired_shares_cleanup_function'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 15),
    ['287_create_secret_rotation_reminder_view'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 16),
    ['289_fix_vault_folder_id_default'] = conditional_array(ProjectConfig.FEATURES.VAULT, secret_vault_migrations, 17),

    -- Bank Transactions (standalone)
    ['290_create_bank_transactions_table'] = conditional_array(ProjectConfig.FEATURES.BANK_TRANSACTIONS, bank_transaction_migrations, 1),
    ['291_add_bank_transactions_indexes'] = conditional_array(ProjectConfig.FEATURES.BANK_TRANSACTIONS, bank_transaction_migrations, 2),
    ['294_add_document_uuid_to_bank_transactions'] = conditional_array(ProjectConfig.FEATURES.BANK_TRANSACTIONS, bank_transaction_migrations, 3),

    -- Push Notifications (conditional)
    ['292_create_device_tokens_table'] = conditional_array(ProjectConfig.FEATURES.NOTIFICATIONS, push_notification_migrations, 1),
    ['293_add_device_tokens_indexes'] = conditional_array(ProjectConfig.FEATURES.NOTIFICATIONS, push_notification_migrations, 2),

    -- =========================================================================
    -- TAX COPILOT SYSTEM (Only if TAX_COPILOT feature is enabled)
    -- =========================================================================

    ['300_tax_create_bank_accounts'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 1),
    ['301_tax_add_bank_accounts_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 2),
    ['302_tax_create_hmrc_categories'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 3),
    ['303_tax_seed_hmrc_categories'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 4),
    ['304_tax_create_categories'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 5),
    ['305_tax_seed_categories'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 6),
    ['306_tax_add_categories_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 7),
    ['307_tax_create_statements'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 8),
    ['308_tax_add_statements_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 9),
    ['309_tax_create_transactions'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 10),
    ['310_tax_add_transactions_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 11),
    ['311_tax_create_returns'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 12),
    ['312_tax_add_returns_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 13),
    ['313_tax_create_audit_logs'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 14),
    ['314_tax_add_audit_logs_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 15),
    ['315_tax_create_support_conversations'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 16),
    ['316_tax_add_support_conversations_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 17),
    ['317_tax_create_support_messages'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 18),
    ['318_tax_add_support_messages_indexes'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 19),
    ['319_tax_add_foreign_keys'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 20),
    ['320_tax_create_roles'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 21),
    ['321_tax_add_module'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 22),
    ['322_tax_migration_complete'] = conditional_array(ProjectConfig.FEATURES.TAX_COPILOT, tax_copilot_migrations, 23),

    -- Custom migrations
    ['custom_migrations'] = function()
        local custom_migrations_dir = os.getenv("OPSAPI_CUSTOM_MIGRATIONS_DIR")
        if custom_migrations_dir then
            local lfs = require("lfs")
            for file in lfs.dir(custom_migrations_dir) do
                if file:match("%.lua$") then
                    local migration_path = custom_migrations_dir .. "/" .. file
                    local migration_func = dofile(migration_path)
                    if type(migration_func) == "function" then
                        migration_func(schema, db, MigrationUtils)
                    end
                end
            end
        end
    end
}
