-- Property PA, Week 1 ("Brain"): the data model (PRD §6; gap map §2).
-- New tables only where nothing exists; everything else extends CRM / property_deals tables.
--   pa_opportunities   qualified seller/buyer potential (not a raw lead, not yet a deal)
--   pa_events          valuations, price reductions, promises, appointments, deadlines
--   pa_offers          every offer with its response and who authorised it
--   pa_relationships   one agent <-> one person: strength, last meaningful contact, preferences
--   pa_risks           deal / relationship / compliance / operational risk with evidence
--   pa_knowledge (+ _versions)  rules the PA follows: scope, triggers, versioned, approved
--   pa_decisions       situation + PA recommendation + human decision + rationale
--   pa_outcomes        what finally happened, linked to decisions/actions
--   pa_proposed_updates  capture output, one row per field: confidence, is_inferred, status
--   pa_handoffs        context + exact question + recommendation + reply
--   pa_field_facts     the evidence trail for every AI-written field (fact vs inference, source,
--                      model, prompt version, run, who confirmed) — rule 5 + rule 7 (audit)
-- Extensions: crm_activities becomes the interaction timeline; crm_contacts gains person roles;
-- property_deals_task_details gains the reason and where a next action came from.
return function(schema, db)
    -- Same-workspace guard for references, like property_deals', but it also knows the uuid-typed
    -- pa_* tables (their uuid columns are UUID, core CRM ones are TEXT).
    db.query([[
        CREATE OR REPLACE FUNCTION property_pa_same_namespace() RETURNS trigger AS $fn$
        DECLARE
            row_j jsonb := to_jsonb(NEW);
            ns bigint := (row_j ->> 'namespace_id')::bigint;
            col text; tbl text; ref text; ref_ns bigint; i int;
        BEGIN
            FOR i IN 0 .. (TG_NARGS / 2) - 1 LOOP
                col := TG_ARGV[i * 2];
                tbl := TG_ARGV[i * 2 + 1];
                ref := row_j ->> col;
                CONTINUE WHEN ref IS NULL;
                IF TG_OP = 'UPDATE' AND ref IS NOT DISTINCT FROM (to_jsonb(OLD) ->> col) THEN CONTINUE; END IF;
                ref_ns := NULL;
                IF tbl = 'kanban_tasks' THEN
                    SELECT p.namespace_id INTO ref_ns FROM kanban_tasks t JOIN kanban_boards b ON b.id = t.board_id
                    JOIN kanban_projects p ON p.id = b.project_id WHERE t.uuid = ref;
                ELSIF tbl = 'users' THEN
                    SELECT m.namespace_id INTO ref_ns FROM users u
                    JOIN namespace_members m ON m.user_id = u.id AND m.namespace_id = ns WHERE u.uuid = ref;
                ELSIF tbl LIKE 'pa\_%' OR tbl LIKE 'property\_deals\_%' THEN
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1::uuid', tbl) INTO ref_ns USING ref;
                ELSE
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1', tbl) INTO ref_ns USING ref;
                END IF;
                IF ref_ns IS DISTINCT FROM ns THEN
                    RAISE EXCEPTION 'insert or update on "%" violates foreign key constraint "property_pa_same_namespace" (%)',
                        TG_TABLE_NAME, col USING ERRCODE = 'foreign_key_violation';
                END IF;
            END LOOP;
            RETURN NEW;
        END
        $fn$ LANGUAGE plpgsql
    ]])
    local function same_namespace(tbl, pairs_)
        db.query("DROP TRIGGER IF EXISTS " .. tbl .. "_same_ns ON " .. tbl)
        db.query("CREATE TRIGGER " .. tbl .. "_same_ns BEFORE INSERT OR UPDATE ON " .. tbl
            .. " FOR EACH ROW EXECUTE FUNCTION property_pa_same_namespace('" .. table.concat(pairs_, "', '") .. "')")
    end
    local function base(name, body)
        db.query("CREATE TABLE IF NOT EXISTS " .. name .. [[ (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        ]] .. body .. [[,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )]])
    end

    -- ---------------------------------------------------------------- opportunities
    base("pa_opportunities", [[
        kind VARCHAR(10) NOT NULL DEFAULT 'sell' CHECK (kind IN ('sell', 'buy')),
        person_uuid TEXT REFERENCES crm_contacts(uuid) ON DELETE SET NULL,
        lead_uuid TEXT REFERENCES crm_leads(uuid) ON DELETE SET NULL,
        property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE SET NULL,
        deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE SET NULL,
        owner_user_uuid VARCHAR(255) REFERENCES users(uuid) ON DELETE SET NULL,
        title VARCHAR(255) NOT NULL,
        motivation TEXT,
        expectation_price NUMERIC(14, 2),
        our_position TEXT,
        temperature VARCHAR(10) CHECK (temperature IN ('hot', 'warm', 'cold')),
        decision_makers JSONB NOT NULL DEFAULT '[]',
        primary_concern TEXT,
        status VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'won', 'lost', 'paused')),
        last_meaningful_contact_at TIMESTAMPTZ,
        metadata JSONB NOT NULL DEFAULT '{}'
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_opps_owner ON pa_opportunities (namespace_id, owner_user_uuid, status)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_opps_person ON pa_opportunities (namespace_id, person_uuid)")
    same_namespace("pa_opportunities", { "person_uuid", "crm_contacts", "lead_uuid", "crm_leads",
        "property_uuid", "property_deals_properties", "deal_uuid", "property_deals_deals", "owner_user_uuid", "users" })

    -- ---------------------------------------------------------------- events
    base("pa_events", [[
        kind VARCHAR(30) NOT NULL CHECK (kind IN ('valuation', 'price_reduction', 'promise', 'appointment', 'deadline',
            'listing', 'sstc', 'fall_through', 'other')),
        at TIMESTAMPTZ NOT NULL,
        title VARCHAR(255) NOT NULL,
        details JSONB NOT NULL DEFAULT '{}',
        person_uuid TEXT REFERENCES crm_contacts(uuid) ON DELETE CASCADE,
        property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE CASCADE,
        opportunity_uuid UUID REFERENCES pa_opportunities(uuid) ON DELETE CASCADE,
        deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
        source_interaction_uuid TEXT,
        done BOOLEAN NOT NULL DEFAULT FALSE
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_events_opp ON pa_events (namespace_id, opportunity_uuid, at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_events_due ON pa_events (namespace_id, at) WHERE NOT done")
    same_namespace("pa_events", { "person_uuid", "crm_contacts", "property_uuid", "property_deals_properties",
        "opportunity_uuid", "pa_opportunities", "deal_uuid", "property_deals_deals" })

    -- ---------------------------------------------------------------- offers
    base("pa_offers", [[
        opportunity_uuid UUID REFERENCES pa_opportunities(uuid) ON DELETE CASCADE,
        deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
        amount NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
        currency VARCHAR(3) NOT NULL DEFAULT 'GBP',
        made_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        conditions TEXT,
        response VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (response IN ('pending', 'accepted', 'rejected', 'countered', 'withdrawn')),
        response_note TEXT,
        responded_at TIMESTAMPTZ,
        authority_user_uuid VARCHAR(255) REFERENCES users(uuid) ON DELETE SET NULL,
        CHECK (num_nonnulls(opportunity_uuid, deal_uuid) >= 1)
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_offers_opp ON pa_offers (namespace_id, opportunity_uuid, made_at DESC)")
    same_namespace("pa_offers", { "opportunity_uuid", "pa_opportunities", "deal_uuid", "property_deals_deals",
        "authority_user_uuid", "users" })

    -- ---------------------------------------------------------------- relationships
    base("pa_relationships", [[
        user_uuid VARCHAR(255) NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
        person_uuid TEXT NOT NULL REFERENCES crm_contacts(uuid) ON DELETE CASCADE,
        strength SMALLINT CHECK (strength BETWEEN 0 AND 100),
        last_meaningful_contact_at TIMESTAMPTZ,
        preferences JSONB NOT NULL DEFAULT '{}',
        UNIQUE (namespace_id, user_uuid, person_uuid)
    ]])
    same_namespace("pa_relationships", { "user_uuid", "users", "person_uuid", "crm_contacts" })

    -- ---------------------------------------------------------------- risks
    base("pa_risks", [[
        kind VARCHAR(20) NOT NULL CHECK (kind IN ('deal', 'relationship', 'compliance', 'operational')),
        severity VARCHAR(10) NOT NULL DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high')),
        title VARCHAR(255) NOT NULL,
        evidence JSONB NOT NULL DEFAULT '[]',
        person_uuid TEXT REFERENCES crm_contacts(uuid) ON DELETE CASCADE,
        opportunity_uuid UUID REFERENCES pa_opportunities(uuid) ON DELETE CASCADE,
        deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
        status VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'mitigated', 'closed'))
    ]])
    same_namespace("pa_risks", { "person_uuid", "crm_contacts", "opportunity_uuid", "pa_opportunities",
        "deal_uuid", "property_deals_deals" })

    -- ---------------------------------------------------------------- knowledge (versioned)
    base("pa_knowledge", [[
        key VARCHAR(80) NOT NULL CHECK (key ~ '^[a-z0-9_]+$'),
        domain VARCHAR(40) NOT NULL DEFAULT 'general',
        scope VARCHAR(10) NOT NULL DEFAULT 'company' CHECK (scope IN ('personal', 'team', 'company')),
        owner_user_uuid VARCHAR(255) REFERENCES users(uuid) ON DELETE CASCADE,
        status VARCHAR(10) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'approved', 'retired')),
        current_version INTEGER NOT NULL DEFAULT 0,
        CHECK (scope <> 'personal' OR owner_user_uuid IS NOT NULL)
    ]])
    db.query([[
        CREATE TABLE IF NOT EXISTS pa_knowledge_versions (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            knowledge_uuid UUID NOT NULL REFERENCES pa_knowledge(uuid) ON DELETE CASCADE,
            version INTEGER NOT NULL,
            title VARCHAR(255) NOT NULL,
            rule TEXT NOT NULL,
            rationale TEXT,
            triggers JSONB NOT NULL DEFAULT '[]',
            status VARCHAR(10) NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'approved', 'rejected', 'superseded')),
            proposed_by_user_uuid VARCHAR(255),
            proposed_by_ai BOOLEAN NOT NULL DEFAULT FALSE,
            approved_by_user_uuid VARCHAR(255),
            approved_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (knowledge_uuid, version)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_kv_status ON pa_knowledge_versions (namespace_id, status)")
    -- One rule per key: per workspace for company/team rules, per person for personal ones.
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_knowledge_key_shared ON pa_knowledge (namespace_id, scope, key)
        WHERE scope <> 'personal']])
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_knowledge_key_personal ON pa_knowledge (namespace_id, owner_user_uuid, key)
        WHERE scope = 'personal']])
    same_namespace("pa_knowledge", { "owner_user_uuid", "users" })
    same_namespace("pa_knowledge_versions", { "knowledge_uuid", "pa_knowledge" })

    -- ---------------------------------------------------------------- decisions + outcomes
    base("pa_decisions", [[
        situation TEXT NOT NULL,
        pa_recommendation TEXT,
        human_decision TEXT,
        rationale TEXT,
        decided_by_user_uuid VARCHAR(255) REFERENCES users(uuid) ON DELETE SET NULL,
        decided_at TIMESTAMPTZ,
        opportunity_uuid UUID REFERENCES pa_opportunities(uuid) ON DELETE CASCADE,
        deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
        handoff_uuid UUID
    ]])
    same_namespace("pa_decisions", { "decided_by_user_uuid", "users", "opportunity_uuid", "pa_opportunities",
        "deal_uuid", "property_deals_deals" })
    base("pa_outcomes", [[
        title VARCHAR(255) NOT NULL,
        happened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        details TEXT,
        decision_uuid UUID REFERENCES pa_decisions(uuid) ON DELETE SET NULL,
        opportunity_uuid UUID REFERENCES pa_opportunities(uuid) ON DELETE CASCADE,
        deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE
    ]])
    same_namespace("pa_outcomes", { "decision_uuid", "pa_decisions", "opportunity_uuid", "pa_opportunities",
        "deal_uuid", "property_deals_deals" })

    -- ---------------------------------------------------------------- handoffs
    base("pa_handoffs", [[
        from_user_uuid VARCHAR(255) NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
        to_user_uuid VARCHAR(255) NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
        opportunity_uuid UUID REFERENCES pa_opportunities(uuid) ON DELETE CASCADE,
        deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
        question TEXT NOT NULL,
        context JSONB NOT NULL DEFAULT '{}',
        pa_recommendation TEXT,
        reply TEXT,
        replied_at TIMESTAMPTZ,
        status VARCHAR(10) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'replied', 'closed'))
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_handoffs_to ON pa_handoffs (namespace_id, to_user_uuid, status)")
    same_namespace("pa_handoffs", { "from_user_uuid", "users", "to_user_uuid", "users",
        "opportunity_uuid", "pa_opportunities", "deal_uuid", "property_deals_deals" })

    -- ---------------------------------------------------------------- proposed updates (capture output)
    base("pa_proposed_updates", [[
        capture_uuid UUID,
        target_table VARCHAR(60) NOT NULL,
        target_uuid TEXT,
        field VARCHAR(60) NOT NULL,
        old_value JSONB,
        new_value JSONB,
        confidence NUMERIC(4, 3) CHECK (confidence BETWEEN 0 AND 1),
        is_inferred BOOLEAN NOT NULL DEFAULT FALSE,
        material BOOLEAN NOT NULL DEFAULT FALSE,
        source_interaction_uuid TEXT,
        source_quote TEXT,
        status VARCHAR(10) NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'confirmed', 'corrected', 'rejected')),
        decided_by_user_uuid VARCHAR(255),
        decided_at TIMESTAMPTZ,
        model VARCHAR(160),
        prompt_version VARCHAR(80),
        run_ref VARCHAR(120)
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_pu_status ON pa_proposed_updates (namespace_id, status, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_pu_capture ON pa_proposed_updates (namespace_id, capture_uuid)")

    -- ---------------------------------------------------------------- field facts (evidence + AI change history)
    base("pa_field_facts", [[
        target_table VARCHAR(60) NOT NULL,
        target_uuid TEXT NOT NULL,
        field VARCHAR(60) NOT NULL,
        value JSONB,
        action VARCHAR(10) NOT NULL DEFAULT 'set' CHECK (action IN ('set', 'create', 'correct', 'clear')),
        source VARCHAR(20) NOT NULL CHECK (source IN ('human', 'ai', 'import', 'integration')),
        source_ref TEXT,
        confidence NUMERIC(4, 3),
        is_inferred BOOLEAN NOT NULL DEFAULT FALSE,
        confirmed_by_user_uuid VARCHAR(255),
        confirmed_at TIMESTAMPTZ,
        model VARCHAR(160),
        prompt_version VARCHAR(80),
        run_ref VARCHAR(120),
        superseded_by UUID
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_facts_target ON pa_field_facts (namespace_id, target_table, target_uuid, field, created_at DESC)")

    -- ---------------------------------------------------------------- extensions
    for _, col in ipairs({
        "channel VARCHAR(20)",                 -- call, email, whatsapp, meeting, note, voice
        "direction VARCHAR(10)",               -- inbound, outbound, internal
        "raw_text TEXT", "transcript TEXT", "summary TEXT",
        "audio_document_uuid UUID",
        "lead_uuid TEXT", "property_uuid UUID", "opportunity_uuid UUID",
        "meaningful BOOLEAN NOT NULL DEFAULT TRUE",
        "source VARCHAR(20) NOT NULL DEFAULT 'human'",
    }) do
        db.query("ALTER TABLE crm_activities ADD COLUMN IF NOT EXISTS " .. col)
    end
    db.query([[CREATE INDEX IF NOT EXISTS idx_crm_activities_pa_opp ON crm_activities (namespace_id, opportunity_uuid, activity_date DESC)
        WHERE opportunity_uuid IS NOT NULL]])
    for _, col in ipairs({ "person_roles JSONB NOT NULL DEFAULT '[]'", "preferred_channel VARCHAR(20)" }) do
        db.query("ALTER TABLE crm_contacts ADD COLUMN IF NOT EXISTS " .. col)
    end
    for _, col in ipairs({ "reason TEXT", "created_from_interaction_uuid TEXT", "opportunity_uuid UUID" }) do
        db.query("ALTER TABLE property_deals_task_details ADD COLUMN IF NOT EXISTS " .. col)
    end
end
