-- The workspace's playbook: how this company operates (roles, call scripts, follow-up rules, objection
-- handling, compliance, when a human takes over). The PA (chat assistant on Today) and the follow-up agent
-- read it, so the AI works the company's way. Plain markdown sections a manager edits in Deals settings.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_playbooks (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            key VARCHAR(60) NOT NULL,
            title VARCHAR(160) NOT NULL,
            body TEXT NOT NULL DEFAULT '',
            position INTEGER NOT NULL DEFAULT 0,
            updated_by_user_uuid VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, key),
            CHECK (key ~ '^[a-z0-9_]+$')
        )
    ]])
end
