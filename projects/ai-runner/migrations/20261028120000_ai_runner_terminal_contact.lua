-- Is a web terminal in touch (docs/AI_RUNNER_WEB_TERMINAL.md §12)? When it last called OpsAPI with the right
-- secret, and when OpsAPI last refused one of its calls and why (wrong secret, clock off): the card's status.
return function(schema, db)
    db.query("ALTER TABLE ar_terminals ADD COLUMN IF NOT EXISTS last_contact_at TIMESTAMPTZ")
    db.query("ALTER TABLE ar_terminals ADD COLUMN IF NOT EXISTS last_refused_at TIMESTAMPTZ")
    db.query("ALTER TABLE ar_terminals ADD COLUMN IF NOT EXISTS last_refused_reason VARCHAR(16)")
end
