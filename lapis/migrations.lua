local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local Global = require "helper.global"
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
            db.query([[
        INSERT INTO users (uuid, first_name, last_name, username, password, email, active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], Global.generateStaticUUID(), "Super", "User", "administrative", Global.hashPassword("Admin@123"),
                "administrative@admin.com", true, Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
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
      ]], Global.generateStaticUUID(), "administrative", Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
        end

        local sellerRoleExists = db.select("id from roles where role_name = ?", "seller")
        if not sellerRoleExists or #sellerRoleExists == 0 then
            db.query([[
        INSERT INTO roles (uuid, role_name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      ]], Global.generateStaticUUID(), "seller", Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
        end

        local buyerRoleExists = db.select("id from roles where role_name = ?", "buyer")
        if not buyerRoleExists or #buyerRoleExists == 0 then
            db.query([[
        INSERT INTO roles (uuid, role_name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      ]], Global.generateStaticUUID(), "buyer", Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
        end

        local deliveryPartnerRoleExists = db.select("id from roles where role_name = ?", "delivery_partner")
        if not deliveryPartnerRoleExists or #deliveryPartnerRoleExists == 0 then
            db.query([[
        INSERT INTO roles (uuid, role_name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      ]], Global.generateStaticUUID(), "delivery_partner", Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
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
      ]], Global.generateStaticUUID(), 1, 1, Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
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

}
