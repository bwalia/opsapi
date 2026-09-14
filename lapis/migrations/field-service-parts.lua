--[[
    Field Service — Parts catalog + job-item approval migrations
    ============================================================

    Phase 3 of the complaint / job-management extension
    (see FIELD_SERVICE_COMPLAINT_MANAGEMENT_PLAN.md).

    - fs_parts             : the parts / products catalog we fit on jobs.
    - fs_job_items (ALTER) : + part_id (optional link to the catalog) and a
                             manager-approval workflow (approval_status +
                             approved_by/approved_at/rejection_reason). Only
                             approved billable items reach an invoice.
    - Money-path integrity : FK fs_visits.invoice_line_item_id and
                             fs_job_items.invoice_line_item_id to
                             invoice_line_items(id) ON DELETE SET NULL, so voiding
                             an invoice frees that work to be re-billed instead of
                             leaving a dangling pointer (PR #604 review H1).

    Gated on FEATURES.FIELD_SERVICE. One table per CREATE migration.
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

local function constraint_exists(name)
    local r = db.query("SELECT 1 FROM pg_constraint WHERE conname = ?", name)
    return r and r[1] ~= nil
end

local function index(sql)
    pcall(function() db.query(sql) end)
end

return {
    -- ========================================
    -- [1] fs_parts   (875)
    -- ========================================
    [1] = function()
        if table_exists("fs_parts") then return end

        db.query([[
            CREATE TABLE fs_parts (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                sku TEXT,
                name TEXT NOT NULL,
                description TEXT,
                category TEXT,
                unit_cost DECIMAL(12,2),                -- buy price
                unit_price DECIMAL(12,2),               -- default sell price
                tax_rate DECIMAL(5,2) NOT NULL DEFAULT 0,
                stock_quantity DECIMAL(12,2),           -- NULL = not stock-tracked
                reorder_level DECIMAL(12,2),
                is_active BOOLEAN NOT NULL DEFAULT true,
                metadata JSONB DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_parts_ns_active_idx ON fs_parts (namespace_id, is_active)]])
        index([[CREATE INDEX fs_parts_ns_category_idx ON fs_parts (namespace_id, category)]])
        index([[CREATE UNIQUE INDEX fs_parts_ns_sku_idx ON fs_parts (namespace_id, sku)
                WHERE sku IS NOT NULL AND deleted_at IS NULL]])
    end,

    -- ========================================
    -- [2] fs_job_items: catalog link + manager approval   (876)
    -- ========================================
    [2] = function()
        db.query([[
            ALTER TABLE fs_job_items
                ADD COLUMN IF NOT EXISTS part_id BIGINT REFERENCES fs_parts(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS approval_status TEXT NOT NULL DEFAULT 'approved'
                    CHECK (approval_status IN ('pending', 'approved', 'rejected')),
                ADD COLUMN IF NOT EXISTS approved_by_uuid TEXT,
                ADD COLUMN IF NOT EXISTS approved_at TIMESTAMP,
                ADD COLUMN IF NOT EXISTS rejection_reason TEXT
        ]])
        index([[CREATE INDEX IF NOT EXISTS fs_job_items_approval_idx ON fs_job_items (namespace_id, approval_status)]])
    end,

    -- ========================================
    -- [3] Money-path integrity: FK the invoice line pointers   (877)
    -- ========================================
    [3] = function()
        if not constraint_exists("fs_visits_invoice_line_item_fk") then
            db.query([[
                ALTER TABLE fs_visits
                    ADD CONSTRAINT fs_visits_invoice_line_item_fk
                    FOREIGN KEY (invoice_line_item_id) REFERENCES invoice_line_items(id) ON DELETE SET NULL
            ]])
        end
        if not constraint_exists("fs_job_items_invoice_line_item_fk") then
            db.query([[
                ALTER TABLE fs_job_items
                    ADD CONSTRAINT fs_job_items_invoice_line_item_fk
                    FOREIGN KEY (invoice_line_item_id) REFERENCES invoice_line_items(id) ON DELETE SET NULL
            ]])
        end
    end,
}
