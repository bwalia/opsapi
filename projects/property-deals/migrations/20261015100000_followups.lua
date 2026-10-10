-- Personal follow-ups (step 2): a lead who asked us to stop is never drafted to again.
-- opted_out_at is set when a reply opts out (rules) and checked again before anything is sent.
return function(schema, db)
    db.query("ALTER TABLE property_deals_lead_details ADD COLUMN IF NOT EXISTS opted_out_at TIMESTAMPTZ")
    db.query("ALTER TABLE property_deals_lead_details ADD COLUMN IF NOT EXISTS last_followup_at TIMESTAMPTZ")
end
