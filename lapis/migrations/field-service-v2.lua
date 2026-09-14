--[[
    Field Service v2 — customer + product model
    ============================================

    Reworks the module to the agreed clean model:
    - Customer  = the `customers` table (namespace-scoped, /dashboard/customers)
    - Product   = the `storeproducts` table (namespace-scoped, /dashboard/products)
                  used as the serviced "asset"; the specific unit is an optional
                  free-text reference on the request.
    - Parts     = fs_parts (unchanged)
    - Visit address lives on the request/job (defaults from the customer).

    Service requests and jobs now reference customer_id + product_id (+ a service
    address). The old crm_accounts / fs_assets / fs_sites coupling is removed, and
    the now-redundant fs_assets and fs_sites tables are dropped.

    Gated on FEATURES.FIELD_SERVICE. `customers` / `storeproducts` are created by
    the ecommerce/customer modules, which every field_service preset now enables.
]]

local db = require("lapis.db")

local function index(sql)
    pcall(function() db.query(sql) end)
end

return {
    -- ========================================
    -- [1] fs_service_requests -> customer + product   (882)
    -- ========================================
    [1] = function()
        db.query([[
            ALTER TABLE fs_service_requests
                ADD COLUMN IF NOT EXISTS customer_id BIGINT REFERENCES customers(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS product_id BIGINT REFERENCES storeproducts(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS product_ref TEXT,          -- serial / reference of the specific unit
                ADD COLUMN IF NOT EXISTS service_address TEXT,
                ADD COLUMN IF NOT EXISTS service_postcode TEXT
        ]])
        db.query([[
            ALTER TABLE fs_service_requests
                DROP COLUMN IF EXISTS account_id,
                DROP COLUMN IF EXISTS contact_id,
                DROP COLUMN IF EXISTS site_id,
                DROP COLUMN IF EXISTS asset_id
        ]])
        index([[CREATE INDEX IF NOT EXISTS fs_service_requests_ns_customer_idx
                ON fs_service_requests (namespace_id, customer_id)]])
        index([[CREATE INDEX IF NOT EXISTS fs_service_requests_ns_product_idx
                ON fs_service_requests (namespace_id, product_id)]])
    end,

    -- ========================================
    -- [2] fs_jobs -> customer + product   (883)
    -- ========================================
    [2] = function()
        db.query([[
            ALTER TABLE fs_jobs
                ADD COLUMN IF NOT EXISTS customer_id BIGINT REFERENCES customers(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS product_id BIGINT REFERENCES storeproducts(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS product_ref TEXT,
                ADD COLUMN IF NOT EXISTS service_address TEXT,
                ADD COLUMN IF NOT EXISTS service_postcode TEXT
        ]])
        db.query([[
            ALTER TABLE fs_jobs
                DROP COLUMN IF EXISTS account_id,
                DROP COLUMN IF EXISTS contact_id,
                DROP COLUMN IF EXISTS site_id,
                DROP COLUMN IF EXISTS asset_id
        ]])
        index([[CREATE INDEX IF NOT EXISTS fs_jobs_ns_customer_idx ON fs_jobs (namespace_id, customer_id)]])
        index([[CREATE INDEX IF NOT EXISTS fs_jobs_ns_product_idx ON fs_jobs (namespace_id, product_id)]])
    end,

    -- ========================================
    -- [3] Drop the redundant assets + sites tables and their menu/RBAC   (884)
    -- ========================================
    [3] = function()
        db.query("DROP TABLE IF EXISTS fs_assets CASCADE")
        db.query("DROP TABLE IF EXISTS fs_sites CASCADE")
        -- Remove their sidebar item + RBAC module (permission maps keep the stale
        -- key harmlessly; the module row + menu item are what surface in the UI).
        pcall(function()
            db.query("DELETE FROM namespace_menu_config WHERE menu_item_id IN (SELECT id FROM menu_items WHERE key = 'field_service_assets')")
            db.query("DELETE FROM menu_items WHERE key = 'field_service_assets'")
            db.query("DELETE FROM modules WHERE machine_name IN ('fs_assets', 'fs_sites')")
        end)
    end,
}
