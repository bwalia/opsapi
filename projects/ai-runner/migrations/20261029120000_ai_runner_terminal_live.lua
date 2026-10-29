-- Who is working right now, and a reversible Suspend (docs/AI_RUNNER_WEB_TERMINAL.md §10, §11). The terminal reports
-- every open tab at least once a minute (seen_at), with when someone last typed in it and whether a browser shows it;
-- a manager can suspend someone's key (signed out within ~30 s, back on Resume). Plus the indexes the work log's list,
-- live view, timeline and sweeps read by.
return function(schema, db)
    db.query("ALTER TABLE ar_terminal_tabs ADD COLUMN IF NOT EXISTS last_input_at TIMESTAMPTZ")
    db.query("ALTER TABLE ar_terminal_tabs ADD COLUMN IF NOT EXISTS seen_at TIMESTAMPTZ")
    db.query("ALTER TABLE ar_terminal_tabs ADD COLUMN IF NOT EXISTS attached BOOLEAN")
    db.query("ALTER TABLE ar_terminal_keys ADD COLUMN IF NOT EXISTS suspended_at TIMESTAMPTZ")
    db.query("ALTER TABLE ar_terminal_keys ADD COLUMN IF NOT EXISTS suspended_by VARCHAR(255)")

    -- A task's terminal sessions find their tab (SESSION_SQL).
    db.query("CREATE INDEX IF NOT EXISTS ar_terminal_tabs_session_idx ON ar_terminal_tabs (session_uuid)")
    -- The work log, newest first (W.list).
    db.query([[CREATE INDEX IF NOT EXISTS ar_terminal_tabs_recent_idx
        ON ar_terminal_tabs (namespace_id, opened_at DESC NULLS LAST, id DESC)]])
    -- Open tabs: the live view and the sweep that closes the ones the terminal stopped reporting.
    db.query([[CREATE INDEX IF NOT EXISTS ar_terminal_tabs_open_idx
        ON ar_terminal_tabs (namespace_id) WHERE closed_at IS NULL]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_terminal_tabs_seen_idx
        ON ar_terminal_tabs (seen_at) WHERE closed_at IS NULL]])
    -- The retention sweep deletes recordings by age.
    db.query("CREATE INDEX IF NOT EXISTS ar_terminal_recordings_created_idx ON ar_terminal_recordings (created_at)")
    -- A tab's timeline filtered by kind (W.events).
    db.query("CREATE INDEX IF NOT EXISTS ar_terminal_events_type_idx ON ar_terminal_events (tab_ref, type, at)")
end
