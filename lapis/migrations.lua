local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
-- Use migration-utils for CLI-compatible utilities (UUID, timestamp, password hashing)
local MigrationUtils = require "helper.migration-utils"

-- Default admin password - CHANGE THIS AFTER FIRST LOGIN
local DEFAULT_ADMIN_PASSWORD = "Admin@123"
local ecommerce_migrations = require("ecommerce-migrations")
local production_schema_upgrade = require("production-schema-upgrade")
local order_management_migrations = require("migrations.order-management-enhancement")
local hospital_crm_migrations = require("migrations.hospital-crm")
local payment_tracking_migrations = require("migrations.payment-tracking")
local notification_migrations = require("migrations.notifications")
local review_migrations = require("migrations.reviews")
local customer_user_link_migrations = require("migrations.customer-user-link")
local stripe_integration_migrations = require("migrations.stripe-integration")
local delivery_partner_migrations = require("migrations.delivery-partner-system")
local geolocation_delivery_migrations = require("migrations.geolocation-delivery-system")
local multi_currency_migrations = require("migrations.multi-currency-support")
local fix_delivery_request_constraint = require("migrations.fix-delivery-request-constraint")
local chat_system_migrations = require("migrations.chat-system")
local rbac_enhancements_migrations = require("migrations.rbac-enhancements")
local namespace_system_migrations = require("migrations.namespace-system")
local services_module_migrations = require("migrations.services-module")
local chat_production_migrations = require("migrations.chat-system-production")
local kanban_project_migrations = require("migrations.kanban-project-system")
local kanban_enhancement_migrations = require("migrations.kanban-enhancements")
local menu_system_migrations = require("migrations.menu-system")
local secret_vault_migrations = require("migrations.secret-vault")
local bank_transaction_migrations = require("migrations.bank-transactions")
local push_notification_migrations = require("migrations.push-notifications")

return {
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
            -- Hash the default admin password using pgcrypto (dynamic, not static)
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

        local deliveryPartnerRoleExists = db.select("id from roles where role_name = ?", "delivery_partner")
        if not deliveryPartnerRoleExists or #deliveryPartnerRoleExists == 0 then
            db.query([[
        INSERT INTO roles (uuid, role_name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      ]], MigrationUtils.generateUUID(), "delivery_partner", MigrationUtils.getCurrentTimestamp(),
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
    ['11_create_products'] = function()
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
    end,

    -- Ecommerce migrations
    ['12_create_stores'] = ecommerce_migrations[1],
    ['13_create_categories'] = ecommerce_migrations[2],
    ['14_create_storeproducts'] = ecommerce_migrations[3],
    ['15_create_customers'] = ecommerce_migrations[4],
    ['16_create_orders'] = ecommerce_migrations[5],
    ['17_create_orderitems'] = ecommerce_migrations[6],
    ['18_create_product_variants'] = ecommerce_migrations[7],
    ['19_create_inventory_transactions'] = ecommerce_migrations[8],
    ['20_create_cart_items'] = ecommerce_migrations[9],
    ['21_create_store_settings'] = ecommerce_migrations[10],
    ['22_create_product_reviews'] = ecommerce_migrations[11],
    ['23_alter_store_table'] = ecommerce_migrations[13],
    ['38_alter_category_table'] = ecommerce_migrations[14],

    ['24_add_oauth_fields_to_users'] = function()
        schema.add_column("users", "oauth_provider", types.varchar({ null = true }))
        schema.add_column("users", "oauth_id", types.varchar({ null = true }))
        schema.create_index("users", "oauth_provider", "oauth_id")
    end,

    ['25_add_payment_fields_to_orders'] = function()
        schema.add_column("orders", "payment_intent_id", types.text({ null = true }))
        schema.add_column("orders", "payment_status", types.varchar({ default = "pending" }))
        schema.add_column("orders", "payment_method", types.varchar({ default = "stripe" }))
        schema.add_column("orders", "stripe_customer_id", types.text({ null = true }))
        schema.create_index("orders", "payment_intent_id")
        schema.create_index("orders", "payment_status")
    end,

    -- Production-Grade Database Schema Upgrades
    ['26_fix_orderitems_variant_field'] = production_schema_upgrade['26_fix_orderitems_variant_field'],
    ['27_enable_uuid_extensions'] = production_schema_upgrade['27_enable_uuid_extensions'],
    ['28_enhance_stores_table'] = production_schema_upgrade['28_enhance_stores_table'],
    ['29_enhance_products_table'] = production_schema_upgrade['29_enhance_products_table'],
    ['30_enhance_orders_tracking'] = production_schema_upgrade['30_enhance_orders_tracking'],
    ['31_enhance_customers_table'] = production_schema_upgrade['31_enhance_customers_table'],
    ['32_create_inventory_analytics'] = production_schema_upgrade['32_create_inventory_analytics'],
    ['33_create_analytics_tables'] = production_schema_upgrade['33_create_analytics_tables'],
    ['34_create_data_integrity_functions'] = production_schema_upgrade['34_create_data_integrity_functions'],
    ['35_create_performance_indexes'] = production_schema_upgrade['35_create_performance_indexes'],
    ['36_enable_row_level_security'] = production_schema_upgrade['36_enable_row_level_security'],
    ['37_fix_regex_constraints'] = production_schema_upgrade['37_fix_regex_constraints'],

    -- Order Management Enhancement Migrations (Professional Seller Dashboard)
    ['39_create_order_history_table'] = order_management_migrations[1],
    ['40_create_notifications_table'] = order_management_migrations[2],
    ['41_create_shipping_tracking_table'] = order_management_migrations[3],
    ['42_create_order_refunds_table'] = order_management_migrations[4],
    ['43_add_tracking_fields_to_orders'] = order_management_migrations[5],
    ['44_create_seller_note_templates'] = order_management_migrations[6],
    ['45_create_order_tags_table'] = order_management_migrations[7],
    ['46_add_seller_order_indexes'] = order_management_migrations[8],

    -- Hospital CRM Migrations
    ['47_create_hospitals_table'] = hospital_crm_migrations[1],
    ['48_create_patients_table'] = hospital_crm_migrations[2],
    ['49_create_patient_health_records_table'] = hospital_crm_migrations[3],
    ['50_create_hospital_staff_table'] = hospital_crm_migrations[4],
    ['51_create_patient_assignments_table'] = hospital_crm_migrations[5],
    ['52_create_patient_appointments_table'] = hospital_crm_migrations[6],
    ['53_create_patient_documents_table'] = hospital_crm_migrations[7],
    -- Payment Tracking & Webhook Support
    ['54_create_payments_table'] = payment_tracking_migrations[1],
    ['55_add_payment_indexes'] = payment_tracking_migrations[2],
    ['56_add_payment_id_to_orders'] = payment_tracking_migrations[3],
    ['57_update_order_status_enum'] = payment_tracking_migrations[4],
    ['58_create_order_status_history'] = payment_tracking_migrations[5],
    ['59_add_status_history_indexes'] = payment_tracking_migrations[6],
    ['60_add_tracking_to_orders'] = payment_tracking_migrations[7],
    ['61_create_refunds_table'] = payment_tracking_migrations[8],
    ['62_add_refund_indexes'] = payment_tracking_migrations[9],
    ['63_fix_order_status_constraint'] = payment_tracking_migrations[10],

    -- Notifications System
    ['64_create_notifications_table'] = notification_migrations[1],
    ['65_add_notification_indexes'] = notification_migrations[2],
    ['66_create_notification_preferences'] = notification_migrations[3],

    -- Reviews System
    ['67_create_store_reviews_table'] = review_migrations[1],
    ['68_add_store_review_indexes'] = review_migrations[2],
    ['69_create_product_reviews_table'] = review_migrations[3],
    ['70_add_product_review_indexes'] = review_migrations[4],

    -- Customer-User Link
    ['71_add_user_id_to_customers'] = customer_user_link_migrations[1],
    ['72_add_customer_user_id_index'] = customer_user_link_migrations[2],
    ['73_migrate_customer_user_data'] = customer_user_link_migrations[3],

    -- Stripe Integration
    ['74_add_stripe_customer_id_to_customers'] = stripe_integration_migrations[1],
    ['75_add_stripe_customer_id_index'] = stripe_integration_migrations[2],

    -- Delivery Partner System
    ['76_create_delivery_partners_table'] = delivery_partner_migrations[1],
    ['77_add_delivery_partners_indexes'] = delivery_partner_migrations[2],
    ['78_create_delivery_partner_areas_table'] = delivery_partner_migrations[3],
    ['79_add_delivery_partner_areas_indexes'] = delivery_partner_migrations[4],
    ['80_create_store_delivery_partners_table'] = delivery_partner_migrations[5],
    ['81_add_store_delivery_partners_indexes'] = delivery_partner_migrations[6],
    ['82_create_order_delivery_assignments_table'] = delivery_partner_migrations[7],
    ['83_add_order_delivery_assignments_indexes'] = delivery_partner_migrations[8],
    ['84_create_delivery_requests_table'] = delivery_partner_migrations[9],
    ['85_add_delivery_requests_indexes'] = delivery_partner_migrations[10],
    ['86_create_delivery_partner_reviews_table'] = delivery_partner_migrations[11],
    ['87_add_delivery_partner_reviews_indexes'] = delivery_partner_migrations[12],
    ['88_add_delivery_partner_constraints'] = delivery_partner_migrations[13],
    ['89_add_can_self_ship_to_stores'] = delivery_partner_migrations[14],
    ['90_add_delivery_partner_id_to_orders'] = delivery_partner_migrations[15],

    -- Geolocation-Based Delivery Partner System (PostGIS)
    ['91_enable_postgis_extension'] = geolocation_delivery_migrations[1],
    ['92_add_geolocation_to_delivery_partners'] = geolocation_delivery_migrations[2],
    ['93_create_delivery_partners_location_index'] = geolocation_delivery_migrations[3],
    ['94_create_delivery_partner_location_trigger'] = geolocation_delivery_migrations[4],
    ['95_add_geolocation_to_orders'] = geolocation_delivery_migrations[5],
    ['96_create_orders_location_indexes'] = geolocation_delivery_migrations[6],
    ['97_create_order_locations_trigger'] = geolocation_delivery_migrations[7],
    ['98_create_find_nearby_partners_function'] = geolocation_delivery_migrations[8],
    ['99_create_can_service_location_function'] = geolocation_delivery_migrations[9],
    ['100_create_delivery_partner_notifications_table'] = geolocation_delivery_migrations[10],
    ['101_add_notifications_indexes'] = geolocation_delivery_migrations[11],
    ['102_create_delivery_partner_geo_stats_view'] = geolocation_delivery_migrations[12],
    ['103_add_geolocation_documentation'] = geolocation_delivery_migrations[13],
    ['104_create_calculate_delivery_fee_function'] = geolocation_delivery_migrations[14],
    ['105_add_coordinate_validation_constraints'] = geolocation_delivery_migrations[15],

    -- Multi-Currency Support
    ['106_add_currency_to_store_products'] = multi_currency_migrations[1],
    ['107_add_currency_to_cart_items'] = multi_currency_migrations[2],
    ['108_add_currency_to_order_items'] = multi_currency_migrations[3],
    ['109_add_currency_to_delivery_requests'] = multi_currency_migrations[4],
    ['110_add_currency_to_order_delivery_assignments'] = multi_currency_migrations[5],
    ['111_add_currency_to_order_refunds'] = multi_currency_migrations[6],
    ['112_add_preferred_currency_to_delivery_partners'] = multi_currency_migrations[7],
    ['113_add_currency_preferences_to_users'] = multi_currency_migrations[8],
    ['114_create_supported_currencies_table'] = multi_currency_migrations[9],
    ['115_populate_supported_currencies'] = multi_currency_migrations[10],
    ['116_add_currency_indexes'] = multi_currency_migrations[11],

    -- Fix Delivery Request Constraint
    ['117_fix_delivery_request_unique_constraint'] = fix_delivery_request_constraint[1],

    -- Chat System (Slack-like messaging)
    ['118_create_chat_channels_table'] = chat_system_migrations[1],
    ['119_add_chat_channels_indexes'] = chat_system_migrations[2],
    ['120_create_chat_channel_members_table'] = chat_system_migrations[3],
    ['121_add_chat_channel_members_indexes'] = chat_system_migrations[4],
    ['122_create_chat_messages_table'] = chat_system_migrations[5],
    ['123_add_chat_messages_indexes'] = chat_system_migrations[6],
    ['124_create_chat_message_reactions_table'] = chat_system_migrations[7],
    ['125_add_chat_message_reactions_indexes'] = chat_system_migrations[8],
    ['126_create_chat_read_receipts_table'] = chat_system_migrations[9],
    ['127_add_chat_read_receipts_indexes'] = chat_system_migrations[10],
    ['128_create_chat_typing_indicators_table'] = chat_system_migrations[11],
    ['129_add_chat_typing_indicators_indexes'] = chat_system_migrations[12],
    ['130_add_chat_constraints'] = chat_system_migrations[13],
    ['131_add_chat_foreign_keys'] = chat_system_migrations[14],
    ['132_create_chat_file_attachments_table'] = chat_system_migrations[15],
    ['133_add_chat_file_attachments_indexes'] = chat_system_migrations[16],
    ['134_create_chat_user_presence_table'] = chat_system_migrations[17],
    ['135_add_chat_user_presence_indexes'] = chat_system_migrations[18],
    ['136_create_chat_bookmarks_table'] = chat_system_migrations[19],
    ['137_add_chat_bookmarks_indexes'] = chat_system_migrations[20],
    ['138_create_chat_drafts_table'] = chat_system_migrations[21],
    ['139_add_chat_drafts_indexes'] = chat_system_migrations[22],
    ['140_create_chat_mentions_table'] = chat_system_migrations[23],
    ['141_add_chat_mentions_indexes'] = chat_system_migrations[24],
    ['142_create_chat_channel_invites_table'] = chat_system_migrations[25],
    ['143_add_chat_channel_invites_indexes'] = chat_system_migrations[26],
    ['144_add_chat_presence_constraints'] = chat_system_migrations[27],
    ['145_create_chat_channel_last_message_trigger'] = chat_system_migrations[28],
    ['146_create_chat_reply_count_trigger'] = chat_system_migrations[29],
    ['147_create_chat_unread_counts_view'] = chat_system_migrations[30],
    ['148_ensure_last_read_at_column'] = chat_system_migrations[31],
    ['149_fix_chat_default_values'] = chat_system_migrations[32],

    -- RBAC Enhancements (Dashboard Role-Based Access Control)
    ['150_add_description_to_roles'] = rbac_enhancements_migrations[1],
    ['151_seed_dashboard_modules'] = rbac_enhancements_migrations[2],

    -- Multi-Tenant Namespace System (User-First Architecture)
    -- Users are GLOBAL, then join/create namespaces
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
    ['164_add_namespace_id_to_stores'] = namespace_system_migrations[13],
    ['165_add_namespace_id_to_orders'] = namespace_system_migrations[14],
    ['166_add_namespace_id_to_customers'] = namespace_system_migrations[15],
    ['167_add_namespace_id_to_categories'] = namespace_system_migrations[16],
    ['168_add_namespace_id_to_storeproducts'] = namespace_system_migrations[17],
    ['169_add_namespace_id_to_chat_channels'] = namespace_system_migrations[18],
    ['170_add_namespace_id_to_delivery_partners'] = namespace_system_migrations[19],
    ['171_add_namespace_id_to_notifications'] = namespace_system_migrations[20],
    ['172_add_namespace_id_to_enquiries'] = namespace_system_migrations[21],
    ['173_seed_default_namespace_and_roles'] = namespace_system_migrations[22],
    ['174_add_admin_to_system_namespace'] = namespace_system_migrations[23],
    ['175_migrate_existing_data_to_namespace'] = namespace_system_migrations[24],
    ['176_add_existing_users_to_namespace'] = namespace_system_migrations[25],
    ['177_create_namespace_audit_logs_table'] = namespace_system_migrations[26],
    ['178_add_namespace_audit_logs_indexes'] = namespace_system_migrations[27],
    ['179_ensure_namespace_columns_on_all_tables'] = namespace_system_migrations[28],

    -- Services Module (GitHub Workflow Integration with Secure Secrets)
    ['180_create_namespace_services_table'] = services_module_migrations[1],
    ['181_add_namespace_services_indexes'] = services_module_migrations[2],
    ['182_create_namespace_service_secrets_table'] = services_module_migrations[3],
    ['183_add_namespace_service_secrets_indexes'] = services_module_migrations[4],
    ['184_create_namespace_service_deployments_table'] = services_module_migrations[5],
    ['185_add_namespace_service_deployments_indexes'] = services_module_migrations[6],
    ['186_create_namespace_service_variables_table'] = services_module_migrations[7],
    ['187_add_namespace_service_variables_indexes'] = services_module_migrations[8],
    ['188_add_services_permission_to_roles'] = services_module_migrations[9],
    ['189_create_namespace_github_integrations_table'] = services_module_migrations[10],
    ['190_add_namespace_github_integrations_indexes'] = services_module_migrations[11],
    ['191_add_github_integration_id_to_services'] = services_module_migrations[12],

    -- Chat System Production Enhancements (Scalability & Performance)
    ['192_add_chat_fulltext_search'] = chat_production_migrations[1],
    ['193_add_chat_brin_indexes'] = chat_production_migrations[2],
    ['194_add_chat_composite_indexes'] = chat_production_migrations[3],
    ['195_create_message_delivery_tracking'] = chat_production_migrations[4],
    ['196_create_channel_stats_materialized_view'] = chat_production_migrations[5],
    ['197_create_refresh_channel_stats_function'] = chat_production_migrations[6],
    ['198_enhance_mention_processing'] = chat_production_migrations[7],
    ['199_add_mention_indexes'] = chat_production_migrations[8],
    ['200_create_message_archive_table'] = chat_production_migrations[9],
    ['201_create_bulk_unread_counts_function'] = chat_production_migrations[10],
    ['202_create_message_edit_history'] = chat_production_migrations[11],
    ['203_add_chat_data_integrity_constraints'] = chat_production_migrations[12],
    ['204_create_keyset_pagination_function'] = chat_production_migrations[13],
    ['205_add_user_presence_functions'] = chat_production_migrations[14],
    ['206_add_chat_data_quality_constraints'] = chat_production_migrations[15],
    ['207_create_user_channels_view'] = chat_production_migrations[16],
    ['208_add_channel_mention_support'] = chat_production_migrations[17],
    ['209_add_chat_metrics_table'] = chat_production_migrations[18],

    -- Kanban Project Management System (Integrated with Chat)
    ['210_create_kanban_projects_table'] = kanban_project_migrations[1],
    ['211_add_kanban_projects_indexes'] = kanban_project_migrations[2],
    ['212_create_kanban_project_members_table'] = kanban_project_migrations[3],
    ['213_add_kanban_project_members_indexes'] = kanban_project_migrations[4],
    ['214_create_kanban_boards_table'] = kanban_project_migrations[5],
    ['215_add_kanban_boards_indexes'] = kanban_project_migrations[6],
    ['216_create_kanban_columns_table'] = kanban_project_migrations[7],
    ['217_add_kanban_columns_indexes'] = kanban_project_migrations[8],
    ['218_create_kanban_tasks_table'] = kanban_project_migrations[9],
    ['219_add_kanban_tasks_indexes'] = kanban_project_migrations[10],
    ['220_create_kanban_task_assignees_table'] = kanban_project_migrations[11],
    ['221_add_kanban_task_assignees_indexes'] = kanban_project_migrations[12],
    ['222_create_kanban_task_labels_table'] = kanban_project_migrations[13],
    ['223_add_kanban_task_labels_indexes'] = kanban_project_migrations[14],
    ['224_create_kanban_task_label_links_table'] = kanban_project_migrations[15],
    ['225_add_kanban_task_label_links_indexes'] = kanban_project_migrations[16],
    ['226_create_kanban_task_comments_table'] = kanban_project_migrations[17],
    ['227_add_kanban_task_comments_indexes'] = kanban_project_migrations[18],
    ['228_create_kanban_task_attachments_table'] = kanban_project_migrations[19],
    ['229_add_kanban_task_attachments_indexes'] = kanban_project_migrations[20],
    ['230_create_kanban_task_checklists_table'] = kanban_project_migrations[21],
    ['231_add_kanban_task_checklists_indexes'] = kanban_project_migrations[22],
    ['232_create_kanban_checklist_items_table'] = kanban_project_migrations[23],
    ['233_add_kanban_checklist_items_indexes'] = kanban_project_migrations[24],
    ['234_create_kanban_task_activities_table'] = kanban_project_migrations[25],
    ['235_add_kanban_task_activities_indexes'] = kanban_project_migrations[26],
    ['236_create_kanban_sprints_table'] = kanban_project_migrations[27],
    ['237_add_kanban_sprints_indexes'] = kanban_project_migrations[28],
    ['238_add_sprint_id_to_kanban_tasks'] = kanban_project_migrations[29],
    ['239_create_kanban_count_triggers'] = kanban_project_migrations[30],
    ['240_create_kanban_comment_count_trigger'] = kanban_project_migrations[31],
    ['241_create_kanban_checklist_count_triggers'] = kanban_project_migrations[32],
    ['242_create_kanban_task_search'] = kanban_project_migrations[33],
    ['243_add_kanban_module_permissions'] = kanban_project_migrations[34],
    ['244_create_kanban_assignee_count_trigger'] = kanban_project_migrations[35],
    ['245_create_kanban_member_count_trigger'] = kanban_project_migrations[36],
    ['246_create_kanban_attachment_count_trigger'] = kanban_project_migrations[37],
    ['247_create_kanban_label_usage_trigger'] = kanban_project_migrations[38],
    ['248_create_kanban_board_count_triggers'] = kanban_project_migrations[39],
    ['249_create_kanban_comment_reply_trigger'] = kanban_project_migrations[40],

    -- Kanban Project Enhancements (Time Tracking, Notifications, Sprint Burndown)
    ['250_create_kanban_time_entries_table'] = kanban_enhancement_migrations[1],
    ['251_add_kanban_time_entries_indexes'] = kanban_enhancement_migrations[2],
    ['252_create_kanban_notifications_table'] = kanban_enhancement_migrations[3],
    ['253_add_kanban_notifications_indexes'] = kanban_enhancement_migrations[4],
    ['254_create_kanban_notification_preferences_table'] = kanban_enhancement_migrations[5],
    ['255_create_kanban_project_activity_feed_view'] = kanban_enhancement_migrations[6],
    ['256_create_kanban_sprint_burndown_table'] = kanban_enhancement_migrations[7],
    ['257_add_sprint_retrospective_fields'] = kanban_enhancement_migrations[8],
    ['258_create_task_time_spent_trigger'] = kanban_enhancement_migrations[9],
    ['259_create_project_budget_spent_trigger'] = kanban_enhancement_migrations[10],
    ['260_create_due_date_notification_function'] = kanban_enhancement_migrations[11],
    ['261_kanban_enhancements_complete'] = kanban_enhancement_migrations[12],
    ['262_fix_kanban_nullable_fk_defaults'] = kanban_enhancement_migrations[13],
    ['271_add_duration_seconds_to_time_entries'] = kanban_enhancement_migrations[14],

    -- Menu System (Backend-driven navigation with Multi-Tenant support)
    ['263_create_menu_items_table'] = menu_system_migrations[1],
    ['264_add_menu_items_indexes'] = menu_system_migrations[2],
    ['265_create_namespace_menu_config_table'] = menu_system_migrations[3],
    ['266_add_namespace_menu_config_indexes'] = menu_system_migrations[4],
    ['267_seed_default_menu_items'] = menu_system_migrations[5],
    ['268_add_new_modules_to_modules_table'] = menu_system_migrations[6],
    ['269_update_namespace_roles_default_permissions'] = menu_system_migrations[7],
    ['270_init_namespace_menu_configs'] = menu_system_migrations[8],
    ['288_add_vault_menu_item'] = menu_system_migrations[9],

    -- Secret Vault System (User-Provided Encryption Keys)
    ['272_create_namespace_secret_vaults_table'] = secret_vault_migrations[1],
    ['273_add_namespace_secret_vaults_indexes'] = secret_vault_migrations[2],
    ['274_create_namespace_vault_folders_table'] = secret_vault_migrations[3],
    ['275_add_namespace_vault_folders_indexes'] = secret_vault_migrations[4],
    ['276_create_namespace_vault_secrets_table'] = secret_vault_migrations[5],
    ['277_add_namespace_vault_secrets_indexes'] = secret_vault_migrations[6],
    ['278_create_namespace_vault_shares_table'] = secret_vault_migrations[7],
    ['279_add_namespace_vault_shares_indexes'] = secret_vault_migrations[8],
    ['280_create_namespace_vault_access_logs_table'] = secret_vault_migrations[9],
    ['281_add_namespace_vault_access_logs_indexes'] = secret_vault_migrations[10],
    ['282_create_vault_secrets_count_trigger'] = secret_vault_migrations[11],
    ['283_create_share_count_trigger'] = secret_vault_migrations[12],
    ['284_add_vault_permissions_to_roles'] = secret_vault_migrations[13],
    ['285_add_vault_module'] = secret_vault_migrations[14],
    ['286_create_expired_shares_cleanup_function'] = secret_vault_migrations[15],
    ['287_create_secret_rotation_reminder_view'] = secret_vault_migrations[16],
    ['289_fix_vault_folder_id_default'] = secret_vault_migrations[17],

    -- Bank Transactions System
    ['290_create_bank_transactions_table'] = bank_transaction_migrations[1],
    ['291_add_bank_transactions_indexes'] = bank_transaction_migrations[2],
    ['294_add_document_uuid_to_bank_transactions'] = bank_transaction_migrations[3],

    -- Push Notifications (FCM Device Tokens)
    ['292_create_device_tokens_table'] = push_notification_migrations[1],
    ['293_add_device_tokens_indexes'] = push_notification_migrations[2],

    -- Fetch Custom Migrations from OPSAPI_CUSTOM_MIGRATIONS_DIR if set
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
