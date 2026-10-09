-- Phase 6: map data, connectors, matching and the deal scout (SPEC §3.6, §3.7).
--   * property_deals_connectors      a workspace's data sources (EPC register, Land Registry Price
--                                    Paid, Companies House, postcode lookup, paid feeds, CSV); keys sealed
--   * property_deals_market_records  what they returned: sold prices, EPC certificates, listings, auction
--                                    lots. Other people's homes (comparables / scouting), so not
--                                    property_deals_properties, which are the workspace's own records
--   * property_deals_saved_searches  a pin + radius (or polygon) + filters the deal scout re-runs daily
--   * property_deals_scout_alerts    new / reduced / stale / cash-only homes it found
--   * buyer_profiles: company_number + the last Companies House check (Ltd/SPV buyers)
return function(schema, db)
    local function same_namespace(tbl, pairs_)
        db.query("DROP TRIGGER IF EXISTS " .. tbl .. "_same_ns ON " .. tbl)
        db.query("CREATE TRIGGER " .. tbl .. "_same_ns BEFORE INSERT OR UPDATE ON " .. tbl
            .. " FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace('" .. table.concat(pairs_, "', '") .. "')")
    end

    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_connectors (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            kind VARCHAR(30) NOT NULL CHECK (kind IN ('epc', 'price_paid', 'companies_house', 'postcodes', 'csv',
                'propertydata', 'searchland', 'streetdata', 'homedata')),
            name VARCHAR(120) NOT NULL,
            config JSONB NOT NULL DEFAULT '{}',
            secret_sealed TEXT,
            enabled BOOLEAN NOT NULL DEFAULT TRUE,
            sync_enabled BOOLEAN NOT NULL DEFAULT FALSE,
            last_run_at TIMESTAMPTZ,
            last_error TEXT,
            records_count INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, name)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_connectors_kind ON property_deals_connectors (namespace_id, kind, enabled)")

    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_market_records (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            connector_uuid UUID REFERENCES property_deals_connectors(uuid) ON DELETE SET NULL,
            source VARCHAR(30) NOT NULL,
            record_type VARCHAR(20) NOT NULL CHECK (record_type IN ('sold_price', 'epc', 'listing', 'auction_lot', 'other')),
            external_id VARCHAR(255) NOT NULL,
            address TEXT,
            postcode VARCHAR(16),
            lat DOUBLE PRECISION CHECK (lat BETWEEN -90 AND 90),
            lng DOUBLE PRECISION CHECK (lng BETWEEN -180 AND 180),
            property_type VARCHAR(40),
            tenure VARCHAR(30),
            bedrooms INTEGER,
            price NUMERIC(14,2),
            previous_price NUMERIC(14,2),
            event_date DATE,
            epc_rating VARCHAR(1),
            status VARCHAR(30),
            cash_only BOOLEAN NOT NULL DEFAULT FALSE,
            url TEXT,
            data JSONB NOT NULL DEFAULT '{}',
            first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, source, external_id)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_market_geo ON property_deals_market_records (namespace_id, record_type, lat, lng)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_market_postcode ON property_deals_market_records (namespace_id, postcode, record_type)")
    same_namespace("property_deals_market_records", { "connector_uuid", "property_deals_connectors" })

    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_saved_searches (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            owner_user_uuid VARCHAR(255) REFERENCES users(uuid) ON DELETE SET NULL,
            name VARCHAR(120) NOT NULL,
            lat DOUBLE PRECISION CHECK (lat BETWEEN -90 AND 90),
            lng DOUBLE PRECISION CHECK (lng BETWEEN -180 AND 180),
            radius_miles NUMERIC(6,1) CHECK (radius_miles BETWEEN 1 AND 100),
            polygon JSONB,
            filters JSONB NOT NULL DEFAULT '{}',
            alerts BOOLEAN NOT NULL DEFAULT TRUE,
            stale_after_days INTEGER NOT NULL DEFAULT 90 CHECK (stale_after_days BETWEEN 7 AND 365),
            last_run_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT property_deals_saved_searches_area CHECK ((lat IS NOT NULL AND lng IS NOT NULL) OR polygon IS NOT NULL)
        )
    ]])
    same_namespace("property_deals_saved_searches", { "owner_user_uuid", "users" })

    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_scout_alerts (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            saved_search_uuid UUID NOT NULL REFERENCES property_deals_saved_searches(uuid) ON DELETE CASCADE,
            market_record_uuid UUID NOT NULL REFERENCES property_deals_market_records(uuid) ON DELETE CASCADE,
            kind VARCHAR(20) NOT NULL CHECK (kind IN ('new', 'reduced', 'stale', 'cash_only')),
            detail TEXT,
            price NUMERIC(14,2),
            previous_price NUMERIC(14,2),
            seen_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    -- One alert per home, kind and price: a second price cut is a new alert, a re-run is not.
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS idx_pd_scout_alert_once ON property_deals_scout_alerts
            (saved_search_uuid, market_record_uuid, kind, COALESCE(price, -1))
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_scout_alerts_ns ON property_deals_scout_alerts (namespace_id, created_at DESC)")
    same_namespace("property_deals_scout_alerts", {
        "saved_search_uuid", "property_deals_saved_searches", "market_record_uuid", "property_deals_market_records",
    })

    db.query("ALTER TABLE property_deals_buyer_profiles ADD COLUMN IF NOT EXISTS company_number VARCHAR(12)")
    db.query("ALTER TABLE property_deals_buyer_profiles ADD COLUMN IF NOT EXISTS company_check JSONB")
    db.query("ALTER TABLE property_deals_buyer_profiles ADD COLUMN IF NOT EXISTS company_checked_at TIMESTAMPTZ")
end
