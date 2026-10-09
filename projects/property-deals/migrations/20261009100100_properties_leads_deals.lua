-- Properties, the lead extension, buyer profiles, workflow templates and deals
-- (gap map §2.1–2.5). Leads, contacts, companies and deals stay in CRM; these
-- tables only add what CRM doesn't have, linked 1:1 by the CRM row's uuid.
return function(schema, db)
    local function same_namespace(tbl, pairs_)
        db.query("DROP TRIGGER IF EXISTS " .. tbl .. "_same_ns ON " .. tbl)
        db.query("CREATE TRIGGER " .. tbl .. "_same_ns BEFORE INSERT OR UPDATE ON " .. tbl
            .. " FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace('" .. table.concat(pairs_, "', '") .. "')")
    end

    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_properties (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            address_line1 VARCHAR(255) NOT NULL,
            address_line2 VARCHAR(255),
            town VARCHAR(120),
            county VARCHAR(120),
            postcode VARCHAR(16),
            country VARCHAR(2) NOT NULL DEFAULT 'GB',
            uprn VARCHAR(20),
            lat DOUBLE PRECISION CHECK (lat BETWEEN -90 AND 90),
            lng DOUBLE PRECISION CHECK (lng BETWEEN -180 AND 180),
            title_number VARCHAR(30),
            tenure VARCHAR(30) CHECK (tenure IN ('freehold', 'leasehold', 'share_of_freehold', 'commonhold', 'unknown')),
            lease_years_left INTEGER,
            ground_rent NUMERIC(12,2),
            service_charge NUMERIC(12,2),
            property_type VARCHAR(40),
            bedrooms INTEGER,
            bathrooms INTEGER,
            floor_area_sqm NUMERIC(10,2),
            epc_rating VARCHAR(1) CHECK (epc_rating IN ('A','B','C','D','E','F','G')),
            epc_certificate_number VARCHAR(40),
            epc_expires_on DATE,
            council_tax_band VARCHAR(2),
            condition VARCHAR(30),
            known_issues JSONB NOT NULL DEFAULT '[]',
            known_issues_note TEXT,
            tenancy JSONB,
            flood_risk VARCHAR(30),
            mining_risk VARCHAR(30),
            est_market_value NUMERIC(14,2),
            est_rent_pcm NUMERIC(12,2),
            refurb_estimate NUMERIC(14,2),
            end_value NUMERIC(14,2),
            notes TEXT,
            metadata JSONB NOT NULL DEFAULT '{}',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_properties_ns ON property_deals_properties (namespace_id, id DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_properties_postcode ON property_deals_properties (namespace_id, postcode)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_properties_uprn ON property_deals_properties (namespace_id, uprn) WHERE uprn IS NOT NULL")
    -- Bounding-box prefilter for map queries; works with or without earthdistance.
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_properties_latlng ON property_deals_properties (namespace_id, lat, lng) WHERE lat IS NOT NULL")

    -- Lead extension (gap map D2): one row per crm_leads row.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_lead_details (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            lead_uuid TEXT NOT NULL UNIQUE REFERENCES crm_leads(uuid) ON DELETE CASCADE,
            lead_kind VARCHAR(30) NOT NULL DEFAULT 'seller',
            situation VARCHAR(30),
            situation_note TEXT,
            deadline_date DATE,
            vulnerability_flag BOOLEAN NOT NULL DEFAULT FALSE,
            vulnerability_note TEXT,
            consent_basis VARCHAR(30),
            consent_given_at TIMESTAMPTZ,
            consent_channels JSONB NOT NULL DEFAULT '[]',
            privacy_notice_sent_at TIMESTAMPTZ,
            retention_until DATE,
            property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE SET NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_lead_details_ns ON property_deals_lead_details (namespace_id, lead_kind, situation)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_lead_details_deadline ON property_deals_lead_details (namespace_id, deadline_date) WHERE deadline_date IS NOT NULL")
    same_namespace("property_deals_lead_details",
        { "lead_uuid", "crm_leads", "property_uuid", "property_deals_properties" })

    -- Buyer profile on an existing contact OR company (gap map §2.3).
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_buyer_profiles (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            contact_uuid TEXT UNIQUE REFERENCES crm_contacts(uuid) ON DELETE CASCADE,
            account_uuid TEXT UNIQUE REFERENCES crm_accounts(uuid) ON DELETE CASCADE,
            entity_type VARCHAR(30) NOT NULL DEFAULT 'person',
            capital_band VARCHAR(30),
            funds_location VARCHAR(120),
            pof_status VARCHAR(20) NOT NULL DEFAULT 'none'
                CHECK (pof_status IN ('none', 'requested', 'received', 'verified', 'expired')),
            pof_expires_on DATE,
            funding_route VARCHAR(30),
            speed_to_commit_days INTEGER,
            strategies JSONB NOT NULL DEFAULT '[]',
            areas JSONB NOT NULL DEFAULT '[]',
            price_min NUMERIC(14,2),
            price_max NUMERIC(14,2),
            min_discount_pct NUMERIC(5,2),
            min_yield_pct NUMERIC(5,2),
            refurb_appetite VARCHAR(20),
            top_priority VARCHAR(120),
            deal_breakers JSONB NOT NULL DEFAULT '[]',
            preferred_channel VARCHAR(20),
            timezone VARCHAR(60),
            holdings JSONB NOT NULL DEFAULT '[]',
            active BOOLEAN NOT NULL DEFAULT TRUE,
            notes TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT property_deals_buyer_profiles_one_owner CHECK (num_nonnulls(contact_uuid, account_uuid) = 1)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_buyers_ns ON property_deals_buyer_profiles (namespace_id, active, id DESC)")
    same_namespace("property_deals_buyer_profiles",
        { "contact_uuid", "crm_contacts", "account_uuid", "crm_accounts" })

    -- Workflow templates: the template row is editable, versions are immutable
    -- JSON snapshots a deal pins to (SPEC §3.1, format: docs/property-deals/template-format.md).
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_workflow_templates (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            key VARCHAR(80) NOT NULL,
            name VARCHAR(255) NOT NULL,
            description TEXT,
            jurisdiction VARCHAR(40),
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            active_version_uuid UUID,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, key)
        )
    ]])
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_workflow_template_versions (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            template_uuid UUID NOT NULL REFERENCES property_deals_workflow_templates(uuid) ON DELETE CASCADE,
            version INTEGER NOT NULL,
            definition JSONB NOT NULL,
            notes TEXT,
            published_by_user_uuid VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (template_uuid, version)
        )
    ]])
    db.query([[
        DO $$ BEGIN
            ALTER TABLE property_deals_workflow_templates ADD CONSTRAINT property_deals_templates_active_version_fk
                FOREIGN KEY (active_version_uuid) REFERENCES property_deals_workflow_template_versions(uuid)
                ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $$
    ]])
    same_namespace("property_deals_workflow_templates",
        { "active_version_uuid", "property_deals_workflow_template_versions" })
    same_namespace("property_deals_workflow_template_versions",
        { "template_uuid", "property_deals_workflow_templates" })
    -- A published version never changes: deals pinned to it must keep behaving the same.
    db.query([[
        CREATE OR REPLACE FUNCTION property_deals_version_immutable() RETURNS trigger AS $fn$
        BEGIN
            IF NEW.definition IS DISTINCT FROM OLD.definition OR NEW.version <> OLD.version
               OR NEW.template_uuid <> OLD.template_uuid THEN
                RAISE EXCEPTION 'property_deals: a published template version cannot be changed; publish a new version';
            END IF;
            RETURN NEW;
        END
        $fn$ LANGUAGE plpgsql
    ]])
    db.query("DROP TRIGGER IF EXISTS property_deals_version_immutable ON property_deals_workflow_template_versions")
    db.query([[
        CREATE TRIGGER property_deals_version_immutable BEFORE UPDATE ON property_deals_workflow_template_versions
        FOR EACH ROW EXECUTE FUNCTION property_deals_version_immutable()
    ]])

    -- Deal extension (gap map D3): every property deal is a crm_deals row.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_deals (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            crm_deal_uuid TEXT NOT NULL UNIQUE REFERENCES crm_deals(uuid) ON DELETE CASCADE,
            property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE SET NULL,
            seller_lead_uuid TEXT REFERENCES crm_leads(uuid) ON DELETE SET NULL,
            deal_type VARCHAR(20) NOT NULL DEFAULT 'buy'
                CHECK (deal_type IN ('buy', 'sell', 'buy_and_assign', 'sourcing')),
            template_version_uuid UUID NOT NULL REFERENCES property_deals_workflow_template_versions(uuid),
            stage_key VARCHAR(80) NOT NULL,
            stage_entered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            status VARCHAR(20) NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'on_hold', 'completed', 'fell_through')),
            currency VARCHAR(3) NOT NULL DEFAULT 'GBP',
            offer_amount NUMERIC(14,2),
            agreed_price NUMERIC(14,2),
            fees JSONB NOT NULL DEFAULT '{}',
            finance_route VARCHAR(30),
            target_exchange_date DATE,
            target_completion_date DATE,
            actual_exchange_at TIMESTAMPTZ,
            actual_completion_at TIMESTAMPTZ,
            late_penalty_per_day NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (late_penalty_per_day >= 0),
            late_penalty_cap_days INTEGER CHECK (late_penalty_cap_days >= 0),
            health VARCHAR(10) NOT NULL DEFAULT 'green' CHECK (health IN ('green', 'amber', 'red')),
            health_reasons JSONB NOT NULL DEFAULT '[]',
            predicted_completion_date DATE,
            money_at_risk NUMERIC(14,2) NOT NULL DEFAULT 0,
            kanban_epic_uuid VARCHAR(255) REFERENCES kanban_epics(uuid) ON DELETE SET NULL,
            notes TEXT,
            metadata JSONB NOT NULL DEFAULT '{}',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_deals_ns ON property_deals_deals (namespace_id, status, stage_key)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_deals_health ON property_deals_deals (namespace_id, health) WHERE status = 'active'")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_deals_property ON property_deals_deals (property_uuid)")
    same_namespace("property_deals_deals", {
        "crm_deal_uuid", "crm_deals", "property_uuid", "property_deals_properties",
        "seller_lead_uuid", "crm_leads", "template_version_uuid", "property_deals_workflow_template_versions",
        "kanban_epic_uuid", "kanban_epics",
    })

    -- Everyone on a deal: buyers, sellers, solicitors, lenders... (gap map §2.4)
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_deal_parties (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            deal_uuid UUID NOT NULL REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            role VARCHAR(30) NOT NULL CHECK (role IN ('buyer', 'seller', 'buyer_solicitor', 'seller_solicitor',
                'lender', 'broker', 'surveyor', 'estate_agent', 'freeholder', 'managing_agent', 'other')),
            contact_uuid TEXT REFERENCES crm_contacts(uuid) ON DELETE CASCADE,
            account_uuid TEXT REFERENCES crm_accounts(uuid) ON DELETE CASCADE,
            is_primary BOOLEAN NOT NULL DEFAULT FALSE,
            notes TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT property_deals_deal_parties_someone CHECK (num_nonnulls(contact_uuid, account_uuid) >= 1)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_deal_parties_deal ON property_deals_deal_parties (namespace_id, deal_uuid, role)")
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS idx_pd_deal_parties_unique ON property_deals_deal_parties
            (deal_uuid, role, COALESCE(contact_uuid, ''), COALESCE(account_uuid, ''))
    ]])
    same_namespace("property_deals_deal_parties", {
        "deal_uuid", "property_deals_deals", "contact_uuid", "crm_contacts", "account_uuid", "crm_accounts",
    })
end
