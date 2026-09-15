--[[
    Field Service — customer sites

    Reintroduces sites, but the clean way: a site belongs to a CUSTOMER (not the
    old CRM account), so repeat visits to the same place (a hospital ward, a
    building) reuse one saved address instead of re-typing it. Jobs and service
    requests point at a site; the engineer's quote sheet shows it as "Site".

    Feature-gated under FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")

local function index(sql)
    pcall(function() db.query(sql) end)
end

return {
    -- [1] fs_sites (customer-scoped)   (887)
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS fs_sites (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL,
                customer_id BIGINT REFERENCES customers(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                address_line1 TEXT,
                address_line2 TEXT,
                city TEXT,
                county TEXT,
                postal_code TEXT,
                country TEXT,
                contact_name TEXT,
                contact_phone TEXT,
                access_notes TEXT,
                created_by_uuid UUID,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW(),
                deleted_at TIMESTAMPTZ
            )
        ]])
        index([[CREATE INDEX IF NOT EXISTS fs_sites_ns_customer_idx ON fs_sites (namespace_id, customer_id)]])
        index([[CREATE INDEX IF NOT EXISTS fs_sites_uuid_idx ON fs_sites (uuid)]])
    end,

    -- [2] site_id on jobs + service requests   (888)
    [2] = function()
        db.query([[ALTER TABLE fs_jobs ADD COLUMN IF NOT EXISTS site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL]])
        db.query([[ALTER TABLE fs_service_requests ADD COLUMN IF NOT EXISTS site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL]])
        index([[CREATE INDEX IF NOT EXISTS fs_jobs_site_idx ON fs_jobs (site_id)]])
        index([[CREATE INDEX IF NOT EXISTS fs_service_requests_site_idx ON fs_service_requests (site_id)]])
    end,
}
