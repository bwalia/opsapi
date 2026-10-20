-- Default channel templates (per-namespace seeded lazily via API later).
-- This migration only ensures merge-field registry defaults exist as a global
-- reference table pattern: we insert nothing tenant-specific here.
return function(schema, db)
    -- Placeholder: tenant templates are created via API / studio.
    -- Keep migration for ordering; no-op if tables already exist.
    db.query("SELECT 1")
end
