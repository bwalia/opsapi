-- AI Runs security fixes (docs/AI_RUNNER.md §25): who may use a runner (ar_runners.access) and an exact
-- "allow for this run" (rule keys computed by the server, which may be long; rememberable). Idempotent: safe to
-- re-run on a restored database.
return function(schema, db)
    -- §25.1: runners registered before this change stay open to everyone, new ones start with their owner only.
    -- ADD COLUMN fills the rows already there with its default, once: a re-run finds the column and changes nothing
    -- (so it never opens a runner registered later).
    db.query([[ALTER TABLE ar_runners ADD COLUMN IF NOT EXISTS access JSONB NOT NULL DEFAULT '{"mode": "everyone"}']])
    db.query([[ALTER TABLE ar_runners ALTER COLUMN access SET DEFAULT '{"mode": "owner"}']])

    -- §25.2: the rule key is the whole command (or tool + input), not two words.
    db.query("ALTER TABLE ar_run_requests ALTER COLUMN rule_key TYPE TEXT")
    db.query("ALTER TABLE ar_run_requests ADD COLUMN IF NOT EXISTS rememberable BOOLEAN NOT NULL DEFAULT false")
end
