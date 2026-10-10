-- Renovation projects. A renovation IS a kanban project (core): its board's
-- columns are the build stages and its cards are the jobs, so builders and site
-- managers work it on the normal Projects screens. This table only links that
-- project to the deal / property it belongs to (gap map rule: extend, don't copy).
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_renovations (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            kanban_project_uuid VARCHAR(255) NOT NULL UNIQUE REFERENCES kanban_projects(uuid) ON DELETE CASCADE,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE SET NULL,
            property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE SET NULL,
            template_key VARCHAR(80) NOT NULL DEFAULT 'standard',
            created_by_user_uuid VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_renovations_ns ON property_deals_renovations (namespace_id, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_renovations_deal ON property_deals_renovations (deal_uuid) WHERE deal_uuid IS NOT NULL")
    db.query("DROP TRIGGER IF EXISTS property_deals_renovations_same_ns ON property_deals_renovations")
    db.query([[
        CREATE TRIGGER property_deals_renovations_same_ns BEFORE INSERT OR UPDATE ON property_deals_renovations
        FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace('kanban_project_uuid', 'kanban_projects',
            'deal_uuid', 'property_deals_deals', 'property_uuid', 'property_deals_properties')
    ]])
end
