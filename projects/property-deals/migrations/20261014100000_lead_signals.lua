-- Personal follow-ups and hot replies (customer request, step 1).
--   * property_deals_lead_signals  "recent news" about a lead: Companies House events found by the daily
--     watch (a company formed, a new directorship, a filing, a charge) and posts / pages a person captured
--     (we never scrape social networks). Follow-up drafts quote the newest one.
--   * lead details gain what the watch needs (company number, Companies House officer id, social profile
--     links) and the reply state (temperature, score, why, last reply).
--   * connectors gain the staff alert channels (ntfy, Telegram bot, Android SMS Gateway).
--   * inbound messages can belong to a lead (not only a deal), come from other channels (a WhatsApp / SMS /
--     call logged by a person) and carry the reply score and the "call now" task it raised.
return function(schema, db)
    -- Staff alert channels are connectors too (free / open source): ntfy, a Telegram bot, Android SMS Gateway.
    db.query("ALTER TABLE property_deals_connectors DROP CONSTRAINT IF EXISTS property_deals_connectors_kind_check")
    db.query([[
        ALTER TABLE property_deals_connectors ADD CONSTRAINT property_deals_connectors_kind_check
        CHECK (kind IN ('epc', 'price_paid', 'companies_house', 'postcodes', 'csv', 'propertydata', 'searchland',
            'streetdata', 'homedata', 'ntfy', 'telegram', 'sms_gateway'))
    ]])
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_lead_signals (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            lead_uuid TEXT NOT NULL REFERENCES crm_leads(uuid) ON DELETE CASCADE,
            kind VARCHAR(30) NOT NULL CHECK (kind IN ('company_formed', 'officer_appointed', 'company_filing',
                'charge_registered', 'social_post', 'website', 'news', 'note')),
            source VARCHAR(30) NOT NULL DEFAULT 'manual' CHECK (source IN ('companies_house', 'manual', 'share')),
            title VARCHAR(300) NOT NULL,
            summary TEXT,
            url TEXT,
            occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            external_id VARCHAR(255),
            data JSONB NOT NULL DEFAULT '{}',
            used_at TIMESTAMPTZ,
            created_by_user_uuid VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_signals_lead ON property_deals_lead_signals (namespace_id, lead_uuid, occurred_at DESC)")
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS idx_pd_signals_external ON property_deals_lead_signals (namespace_id, external_id)
        WHERE external_id IS NOT NULL
    ]])
    db.query("DROP TRIGGER IF EXISTS property_deals_lead_signals_same_ns ON property_deals_lead_signals")
    db.query([[
        CREATE TRIGGER property_deals_lead_signals_same_ns BEFORE INSERT OR UPDATE ON property_deals_lead_signals
        FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace('lead_uuid', 'crm_leads')
    ]])

    for _, col in ipairs({
        "company_number VARCHAR(10)",
        "ch_officer_id VARCHAR(80)",
        "ch_checked_at TIMESTAMPTZ",
        "social_profiles JSONB NOT NULL DEFAULT '[]'",
        "temperature VARCHAR(10) CHECK (temperature IN ('hot', 'warm', 'cold'))",
        "hot_score INTEGER",
        "hot_reason TEXT",
        "last_reply_at TIMESTAMPTZ",
        "last_signal_at TIMESTAMPTZ",
    }) do
        db.query("ALTER TABLE property_deals_lead_details ADD COLUMN IF NOT EXISTS " .. col)
    end
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_lead_details_ch ON property_deals_lead_details (namespace_id, ch_checked_at NULLS FIRST)
        WHERE company_number IS NOT NULL OR ch_officer_id IS NOT NULL
    ]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_lead_details_hot ON property_deals_lead_details (namespace_id, last_reply_at DESC)
        WHERE temperature = 'hot'
    ]])

    for _, col in ipairs({
        "lead_uuid TEXT REFERENCES crm_leads(uuid) ON DELETE SET NULL",
        "channel VARCHAR(20) NOT NULL DEFAULT 'email'",
        "reply_temperature VARCHAR(10)",
        "reply_score INTEGER",
        "reply_reason TEXT",
        "hot_task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL",
        "logged_by_user_uuid VARCHAR(255)",
    }) do
        db.query("ALTER TABLE property_deals_inbound_messages ADD COLUMN IF NOT EXISTS " .. col)
    end
    db.query([[
        DO $$ BEGIN
            ALTER TABLE property_deals_inbound_messages ADD CONSTRAINT property_deals_inbound_channel
                CHECK (channel IN ('email', 'sms', 'whatsapp', 'phone', 'social', 'other'));
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $$
    ]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_inbound_lead ON property_deals_inbound_messages (namespace_id, lead_uuid, received_at DESC)
        WHERE lead_uuid IS NOT NULL
    ]])
    db.query("DROP TRIGGER IF EXISTS property_deals_inbound_messages_same_ns ON property_deals_inbound_messages")
    db.query([[
        CREATE TRIGGER property_deals_inbound_messages_same_ns BEFORE INSERT OR UPDATE ON property_deals_inbound_messages
        FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace(
            'connector_uuid', 'property_deals_mail_connectors', 'deal_uuid', 'property_deals_deals',
            'chase_uuid', 'property_deals_chases', 'agent_run_uuid', 'property_deals_agent_runs',
            'lead_uuid', 'crm_leads', 'hot_task_uuid', 'kanban_tasks')
    ]])
end
