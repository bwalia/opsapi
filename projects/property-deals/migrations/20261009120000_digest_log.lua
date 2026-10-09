-- One daily digest per person per local day (jobs/daily_digest.lua): the
-- unique key makes the job safe to run on any worker, any number of times.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_digest_log (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            user_uuid VARCHAR(255) NOT NULL,
            local_date DATE NOT NULL,
            payload JSONB NOT NULL,
            empty BOOLEAN NOT NULL DEFAULT FALSE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, user_uuid, local_date)
        )
    ]])
end
