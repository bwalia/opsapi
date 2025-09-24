-- Production Database Schema Deployment Script
-- Run this script to upgrade your database to production-ready standards
--
-- Usage: lapis migrate production-deployment
--
-- This script safely applies all production schema upgrades including:
-- - Fix for orderitems variant_uuid column (immediate issue)
-- - UUID extensions and proper data types
-- - Enhanced constraints and validation
-- - CRM integration fields
-- - Analytics and reporting tables
-- - Performance optimization indexes
-- - Row-level security implementation

local config = require("lapis.config").get()
local migrations = require("lapis.db.migrations")

print("🚀 Starting Production Database Schema Upgrade...")
print("Database: " .. (config.database or "localhost"))
print()

-- List of production migrations to apply
local production_migrations = {
    "26_fix_orderitems_variant_field",
    "27_enable_uuid_extensions",
    "28_enhance_stores_table",
    "29_enhance_products_table",
    "30_enhance_orders_tracking",
    "31_enhance_customers_table",
    "32_create_inventory_analytics",
    "33_create_analytics_tables",
    "34_create_data_integrity_functions",
    "35_create_performance_indexes",
    "36_enable_row_level_security"
}

print("Production migrations to apply:")
for i, migration in ipairs(production_migrations) do
    print("  " .. i .. ". " .. migration)
end
print()

-- Apply migrations with error handling
local success_count = 0
local total_count = #production_migrations

for i, migration_name in ipairs(production_migrations) do
    print("📦 Applying migration: " .. migration_name)

    local ok, err = pcall(function()
        migrations.run_migration(migration_name)
    end)

    if ok then
        print("✅ Successfully applied: " .. migration_name)
        success_count = success_count + 1
    else
        print("❌ Failed to apply: " .. migration_name)
        print("Error: " .. tostring(err))
        print()
        print("🛑 Migration failed. Please check the error above and fix before continuing.")
        return false
    end
    print()
end

print("🎉 Production Schema Upgrade Complete!")
print("✅ Applied " .. success_count .. "/" .. total_count .. " migrations successfully")
print()

if success_count == total_count then
    print("🚀 Your database is now production-ready with:")
    print("  ✅ Fixed orderitems variant_uuid issue")
    print("  ✅ Enhanced data validation and constraints")
    print("  ✅ CRM integration fields")
    print("  ✅ Analytics and reporting tables")
    print("  ✅ Performance optimization indexes")
    print("  ✅ Row-level security for multi-tenancy")
    print()
    print("🔧 Next steps:")
    print("  1. Test your application thoroughly")
    print("  2. Update any code that relies on old schema")
    print("  3. Monitor performance with new indexes")
    print("  4. Configure row-level security policies as needed")
else
    print("⚠️  Some migrations failed. Please review and fix errors before proceeding.")
end

return true