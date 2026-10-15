-- Deal autopilot (property_deals/research.lua):
--  * suppliers say where they came from (a person, a person saving an AI search result, the SRA register), with
--    the register's attribution, so people know which details to confirm before using them;
--  * property_deals_register_offices: the workspace's copy of the SRA register's offices of firms that do
--    residential property work (property_deals/register.lua), refreshed daily, put on the map as deals need it.
return function(schema, db)
    -- The SRA register is a data connector (its key is the workspace's own).
    db.query("ALTER TABLE property_deals_connectors DROP CONSTRAINT IF EXISTS property_deals_connectors_kind_check")
    db.query([[
        ALTER TABLE property_deals_connectors ADD CONSTRAINT property_deals_connectors_kind_check
        CHECK (kind IN ('epc', 'price_paid', 'companies_house', 'postcodes', 'csv', 'propertydata', 'searchland',
            'streetdata', 'homedata', 'ntfy', 'telegram', 'sms_gateway', 'sra'))
    ]])
    db.query("ALTER TABLE property_deals_suppliers ADD COLUMN IF NOT EXISTS source VARCHAR(20) NOT NULL DEFAULT 'manual'")
    db.query("ALTER TABLE property_deals_suppliers ADD COLUMN IF NOT EXISTS source_urls JSONB NOT NULL DEFAULT '[]'")
    db.query("ALTER TABLE property_deals_suppliers ADD COLUMN IF NOT EXISTS register_ref VARCHAR(60)")
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_register_offices (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            register VARCHAR(20) NOT NULL,
            firm_ref VARCHAR(40) NOT NULL,
            firm_name TEXT NOT NULL,
            office_ref VARCHAR(60) NOT NULL,
            address TEXT,
            town VARCHAR(80),
            postcode VARCHAR(12),
            phone VARCHAR(40),
            email VARCHAR(200),
            website VARCHAR(300),
            lat DOUBLE PRECISION,
            lng DOUBLE PRECISION,
            geocoded_at TIMESTAMPTZ,
            fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, register, office_ref)
        )
    ]])
    db.query([[CREATE INDEX IF NOT EXISTS idx_pd_register_offices_geo
        ON property_deals_register_offices (namespace_id, register, lat, lng)]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_agent_runs_deal_agent
            ON property_deals_agent_runs (namespace_id, deal_uuid, agent_key, created_at DESC)
    ]])
end
