-- Deal work: the kanban task extension, dependencies, enquiries, the chase log,
-- suppliers (on crm_accounts), bookings, compliance checks and documents
-- (gap map §2.6–2.12).
return function(schema, db)
    local function same_namespace(tbl, pairs_)
        db.query("DROP TRIGGER IF EXISTS " .. tbl .. "_same_ns ON " .. tbl)
        db.query("CREATE TRIGGER " .. tbl .. "_same_ns BEFORE INSERT OR UPDATE ON " .. tbl
            .. " FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace('" .. table.concat(pairs_, "', '") .. "')")
    end

    -- Task extension (gap map D4): one row per kanban task the plugin manages.
    -- kanban_tasks.status stays valid for kanban screens; pd_status is exact.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_task_details (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            task_uuid VARCHAR(255) NOT NULL UNIQUE REFERENCES kanban_tasks(uuid) ON DELETE CASCADE,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE SET NULL,
            lead_uuid TEXT REFERENCES crm_leads(uuid) ON DELETE SET NULL,
            template_key VARCHAR(80),
            stage_key VARCHAR(80),
            pd_status VARCHAR(30) NOT NULL DEFAULT 'todo' CHECK (pd_status IN ('todo', 'in_progress',
                'waiting_third_party', 'agent_running', 'awaiting_approval', 'done', 'cancelled')),
            owner_user_uuid VARCHAR(255) REFERENCES users(uuid) ON DELETE SET NULL,
            owner_agent_key VARCHAR(80),
            due_at TIMESTAMPTZ,
            sla_minutes INTEGER CHECK (sla_minutes > 0),
            sla_started_at TIMESTAMPTZ,
            sla_warned_at TIMESTAMPTZ,
            sla_breached_at TIMESTAMPTZ,
            escalation_level INTEGER NOT NULL DEFAULT 0,
            urgency_score NUMERIC(6,2) NOT NULL DEFAULT 0,
            urgency_why JSONB NOT NULL DEFAULT '[]',
            blocking BOOLEAN NOT NULL DEFAULT FALSE,
            compliance BOOLEAN NOT NULL DEFAULT FALSE,
            agent_eligible BOOLEAN NOT NULL DEFAULT FALSE,
            agent_key VARCHAR(80),
            approval_rule VARCHAR(20) NOT NULL DEFAULT 'any_operator'
                CHECK (approval_rule IN ('none', 'any_operator', 'manager', 'two_person')),
            snoozed_until TIMESTAMPTZ,
            snooze_reason TEXT,
            completed_at TIMESTAMPTZ,
            completed_by_user_uuid VARCHAR(255),
            evidence JSONB NOT NULL DEFAULT '{}',
            metadata JSONB NOT NULL DEFAULT '{}',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    -- Today / SLA tick: open tasks by due time; my tasks by urgency.
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_tasks_open_due ON property_deals_task_details (namespace_id, due_at)
        WHERE pd_status NOT IN ('done', 'cancelled')
    ]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_tasks_owner ON property_deals_task_details (namespace_id, owner_user_uuid, urgency_score DESC)
        WHERE pd_status NOT IN ('done', 'cancelled')
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_tasks_deal ON property_deals_task_details (deal_uuid, stage_key)")
    same_namespace("property_deals_task_details", {
        "task_uuid", "kanban_tasks", "deal_uuid", "property_deals_deals", "property_uuid", "property_deals_properties",
        "lead_uuid", "crm_leads", "owner_user_uuid", "users",
    })

    -- kanban has no dependencies: "book survey" waits for "offer accepted".
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_task_dependencies (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            task_uuid VARCHAR(255) NOT NULL REFERENCES property_deals_task_details(task_uuid) ON DELETE CASCADE,
            depends_on_task_uuid VARCHAR(255) NOT NULL REFERENCES property_deals_task_details(task_uuid) ON DELETE CASCADE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (task_uuid, depends_on_task_uuid),
            CHECK (task_uuid <> depends_on_task_uuid)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_task_deps_on ON property_deals_task_dependencies (depends_on_task_uuid)")
    same_namespace("property_deals_task_dependencies",
        { "task_uuid", "kanban_tasks", "depends_on_task_uuid", "kanban_tasks" })

    -- Open legal questions and missing items. (The core `enquiries` table is a
    -- website contact form — unrelated.)
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_enquiries (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            deal_uuid UUID NOT NULL REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            title VARCHAR(255) NOT NULL,
            detail TEXT,
            owner_party VARCHAR(30) NOT NULL DEFAULT 'seller_solicitor' CHECK (owner_party IN ('seller', 'buyer',
                'buyer_solicitor', 'seller_solicitor', 'lender', 'freeholder', 'managing_agent', 'council', 'other')),
            status VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'withdrawn')),
            blocking BOOLEAN NOT NULL DEFAULT TRUE,
            raised_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            due_at TIMESTAMPTZ,
            resolved_at TIMESTAMPTZ,
            resolution TEXT,
            source VARCHAR(20) NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'email', 'agent')),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_enquiries_deal ON property_deals_enquiries (namespace_id, deal_uuid, status)")
    same_namespace("property_deals_enquiries", { "deal_uuid", "property_deals_deals" })

    -- Every chase: who, how, what was asked, when they replied.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_chases (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            deal_uuid UUID NOT NULL REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            enquiry_uuid UUID REFERENCES property_deals_enquiries(uuid) ON DELETE SET NULL,
            task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL,
            to_party VARCHAR(30) NOT NULL DEFAULT 'seller_solicitor',
            to_name VARCHAR(255),
            to_address VARCHAR(255),
            channel VARCHAR(20) NOT NULL DEFAULT 'email'
                CHECK (channel IN ('email', 'phone', 'sms', 'whatsapp', 'letter', 'portal')),
            subject VARCHAR(255),
            body TEXT,
            status VARCHAR(20) NOT NULL DEFAULT 'sent' CHECK (status IN ('draft', 'sent', 'replied', 'failed')),
            sent_at TIMESTAMPTZ,
            sent_by_user_uuid VARCHAR(255),
            approval_uuid UUID,
            reply_at TIMESTAMPTZ,
            reply_summary TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_chases_deal ON property_deals_chases (namespace_id, deal_uuid, sent_at DESC)")
    same_namespace("property_deals_chases", {
        "deal_uuid", "property_deals_deals", "enquiry_uuid", "property_deals_enquiries", "task_uuid", "kanban_tasks",
    })

    -- Supplier extension (gap map §2.9): every supplier is a crm_accounts row.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_suppliers (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            account_uuid TEXT NOT NULL UNIQUE REFERENCES crm_accounts(uuid) ON DELETE CASCADE,
            kinds JSONB NOT NULL DEFAULT '[]',
            base_lat DOUBLE PRECISION CHECK (base_lat BETWEEN -90 AND 90),
            base_lng DOUBLE PRECISION CHECK (base_lng BETWEEN -180 AND 180),
            radius_miles NUMERIC(6,1),
            coverage JSONB NOT NULL DEFAULT '[]',
            accreditations JSONB NOT NULL DEFAULT '[]',
            price_list JSONB NOT NULL DEFAULT '[]',
            booking_method VARCHAR(20) NOT NULL DEFAULT 'email'
                CHECK (booking_method IN ('email', 'api', 'link', 'phone')),
            booking_config JSONB NOT NULL DEFAULT '{}',
            avg_turnaround_hours NUMERIC(10,2),
            on_time_pct NUMERIC(5,2),
            jobs_measured INTEGER NOT NULL DEFAULT 0,
            rating NUMERIC(3,2) CHECK (rating BETWEEN 0 AND 5),
            active BOOLEAN NOT NULL DEFAULT TRUE,
            notes TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_suppliers_ns ON property_deals_suppliers (namespace_id, active)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_suppliers_kinds ON property_deals_suppliers USING GIN (kinds)")
    same_namespace("property_deals_suppliers", { "account_uuid", "crm_accounts" })

    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_bookings (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            supplier_uuid UUID NOT NULL REFERENCES property_deals_suppliers(uuid) ON DELETE RESTRICT,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE SET NULL,
            task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL,
            service VARCHAR(40) NOT NULL,
            status VARCHAR(20) NOT NULL DEFAULT 'requested'
                CHECK (status IN ('requested', 'tentative', 'confirmed', 'done', 'cancelled')),
            slot_start TIMESTAMPTZ,
            slot_end TIMESTAMPTZ,
            cost NUMERIC(12,2),
            currency VARCHAR(3) NOT NULL DEFAULT 'GBP',
            external_ref VARCHAR(120),
            requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            confirmed_at TIMESTAMPTZ,
            done_at TIMESTAMPTZ,
            approval_uuid UUID,
            notes TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CHECK (slot_end IS NULL OR slot_start IS NULL OR slot_end > slot_start)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_bookings_ns ON property_deals_bookings (namespace_id, status, slot_start)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_bookings_supplier ON property_deals_bookings (supplier_uuid, requested_at)")
    same_namespace("property_deals_bookings", {
        "supplier_uuid", "property_deals_suppliers", "deal_uuid", "property_deals_deals",
        "property_uuid", "property_deals_properties", "task_uuid", "kanban_tasks",
    })

    -- Files on a deal / property / check (gap map §2.12). Objects live in MinIO.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_documents (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE CASCADE,
            task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL,
            category VARCHAR(40) NOT NULL DEFAULT 'other',
            filename VARCHAR(255) NOT NULL,
            mime_type VARCHAR(120),
            size_bytes BIGINT,
            sha256 VARCHAR(64),
            bucket VARCHAR(120),
            object_key TEXT NOT NULL,
            source VARCHAR(20) NOT NULL DEFAULT 'upload' CHECK (source IN ('upload', 'agent', 'email', 'connector')),
            uploaded_by_user_uuid VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CHECK (num_nonnulls(deal_uuid, property_uuid) >= 1)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_documents_deal ON property_deals_documents (namespace_id, deal_uuid, category)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_documents_property ON property_deals_documents (namespace_id, property_uuid)")
    same_namespace("property_deals_documents", {
        "deal_uuid", "property_deals_deals", "property_uuid", "property_deals_properties", "task_uuid", "kanban_tasks",
    })

    -- AML, ID, redress, GDPR, conveyancing and letting checks (SPEC §3.4).
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_compliance_checks (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            check_type VARCHAR(60) NOT NULL,
            jurisdiction_pack VARCHAR(40),
            subject_type VARCHAR(20) NOT NULL CHECK (subject_type IN ('contact', 'account', 'deal', 'property', 'workspace')),
            contact_uuid TEXT REFERENCES crm_contacts(uuid) ON DELETE CASCADE,
            account_uuid TEXT REFERENCES crm_accounts(uuid) ON DELETE CASCADE,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            property_uuid UUID REFERENCES property_deals_properties(uuid) ON DELETE CASCADE,
            party_role VARCHAR(30),
            task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL,
            status VARCHAR(20) NOT NULL DEFAULT 'not_started'
                CHECK (status IN ('not_started', 'in_progress', 'passed', 'failed', 'waived', 'expired')),
            risk_rating VARCHAR(10) CHECK (risk_rating IN ('low', 'medium', 'high')),
            evidence_document_uuid UUID REFERENCES property_deals_documents(uuid) ON DELETE SET NULL,
            checked_by_user_uuid VARCHAR(255) REFERENCES users(uuid) ON DELETE SET NULL,
            checked_at TIMESTAMPTZ,
            expires_at TIMESTAMPTZ,
            data JSONB NOT NULL DEFAULT '{}',
            notes TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            -- A pass needs a named human and a time (hard rule 6).
            CHECK (status NOT IN ('passed', 'waived') OR (checked_by_user_uuid IS NOT NULL AND checked_at IS NOT NULL))
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_compliance_deal ON property_deals_compliance_checks (namespace_id, deal_uuid, check_type)")
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_compliance_expiry ON property_deals_compliance_checks (namespace_id, expires_at)
        WHERE expires_at IS NOT NULL AND status = 'passed'
    ]])
    same_namespace("property_deals_compliance_checks", {
        "contact_uuid", "crm_contacts", "account_uuid", "crm_accounts", "deal_uuid", "property_deals_deals",
        "property_uuid", "property_deals_properties", "task_uuid", "kanban_tasks",
        "evidence_document_uuid", "property_deals_documents", "checked_by_user_uuid", "users",
    })
end
