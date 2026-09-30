-- Tickets opened by an event handler (events/billing.lua) remember which event
-- created them. Events are delivered at least once, so the unique index turns
-- a retried delivery into a harmless 409 instead of a duplicate ticket.
return function(schema, db)
    db.query("ALTER TABLE helpdesk_tickets ADD COLUMN IF NOT EXISTS source_event UUID")
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS idx_helpdesk_tickets_source_event
        ON helpdesk_tickets (namespace_id, source_event) WHERE source_event IS NOT NULL
    ]])
end
