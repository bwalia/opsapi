--[[
    Lead pipeline (docs/plans/LEAD_TO_CASH_PIPELINE.md)
    ===================================================

    A lead moves through fixed stages so reports and automation can rely on
    them (workspaces rename the labels, not the stages):

        new -> contacting -> qualified -> meeting -> converted
                  \__________________________________/ -> nurture | lost

    [1] crm_leads: stage columns (status IS the stage), next step, contact
        counters, money estimate, AI summary. Legacy `contacted` -> `contacting`.
    [2] crm_lead_stage_history: one row per stage change (funnel + timings),
        backfilled with each existing lead's current stage.
    [3] crm_lead_analyses: one row per AI analysis run.
    [4] crm_lead_settings: per-workspace pipeline settings (JSON, defaults in
        lib/crm/lead-settings.lua) and the round-robin cursor.
    [5] crm_lead_assignment_rules: "leads like this go to that person/pool".
    [6] crm_activities (CRM only): lead link + call outcome + meeting fields.
    [7] crm_deals (CRM only): the lead a deal came from.
    [8] The `crm_leads` RBAC module: owners and admins manage it (they are the
        lead managers who see every lead); every other role that can open the
        Leads page today (crm_accounts) gets the same actions on crm_leads, so
        turning on the permission checks locks nobody out.
    [9] invoices (invoicing only): the deal an invoice bills.
    [10] crm_partner_profiles (CRM only): companies we pass deals to.
    [11] crm_deal_referrals (CRM only): a deal passed to a partner, through
         to the commission being paid.

    crm_leads is a core table, so [1]-[5] and [8] run in every deployment;
    [6], [7] and [9] skip themselves where their tables don't exist. Every step
    is idempotent.
]]

local db = require("lapis.db")

local STAGES = { "new", "contacting", "qualified", "meeting", "converted", "nurture", "lost" }

local function table_exists(name)
    return db.query("SELECT to_regclass(?) IS NOT NULL AS ok", name)[1].ok
end

local function constraint_exists(name)
    return #db.query("SELECT 1 FROM pg_constraint WHERE conname = ?", name) > 0
end

local function stage_list()
    local quoted = {}
    for i, s in ipairs(STAGES) do quoted[i] = "'" .. s .. "'" end
    return table.concat(quoted, ", ")
end

local function decode_perms(raw)
    if raw == nil or raw == db.NULL or raw == "" then return {} end
    if type(raw) == "table" then return raw end
    local ok, t = pcall(require("cjson").decode, raw)
    return ok and type(t) == "table" and t or {}
end

return {
    [1] = function()
        db.query([[
            ALTER TABLE crm_leads
                ADD COLUMN IF NOT EXISTS stage_changed_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS assigned_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS next_action_type TEXT,
                ADD COLUMN IF NOT EXISTS next_action_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS next_action_note TEXT,
                ADD COLUMN IF NOT EXISTS next_action_warned_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS next_action_escalated_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS first_contacted_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS last_contacted_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS contact_attempts INTEGER NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS estimated_value NUMERIC(15,2),
                ADD COLUMN IF NOT EXISTS currency VARCHAR(3),
                ADD COLUMN IF NOT EXISTS expected_close_date DATE,
                ADD COLUMN IF NOT EXISTS nurture_until DATE,
                ADD COLUMN IF NOT EXISTS lost_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS qualification JSONB NOT NULL DEFAULT '{}'::jsonb,
                ADD COLUMN IF NOT EXISTS ai_status TEXT,
                ADD COLUMN IF NOT EXISTS ai_score INTEGER,
                ADD COLUMN IF NOT EXISTS ai_summary TEXT,
                ADD COLUMN IF NOT EXISTS ai_analysed_at TIMESTAMPTZ
        ]])
        -- metadata is an object; an empty [] (older writers' cjson) becomes {} so `||` merges work.
        db.query("UPDATE crm_leads SET metadata = '{}'::jsonb WHERE metadata IS NULL OR metadata = '[]'::jsonb")
        -- Legacy vocabulary, then anything a client invented falls back to `new`.
        db.query("UPDATE crm_leads SET status = 'contacting' WHERE status = 'contacted'")
        db.query("UPDATE crm_leads SET status = 'new' WHERE status IS NULL OR status NOT IN (" .. stage_list() .. ")")
        db.query("UPDATE crm_leads SET stage_changed_at = COALESCE(converted_at, updated_at, created_at) WHERE stage_changed_at IS NULL")
        db.query("UPDATE crm_leads SET assigned_at = created_at WHERE assigned_at IS NULL AND owner_user_uuid IS NOT NULL")
        db.query("ALTER TABLE crm_leads ALTER COLUMN stage_changed_at SET DEFAULT NOW()")
        if not constraint_exists("crm_leads_status_stage_check") then
            db.query("ALTER TABLE crm_leads ADD CONSTRAINT crm_leads_status_stage_check CHECK (status IN ("
                .. stage_list() .. ")) NOT VALID")
            db.query("ALTER TABLE crm_leads VALIDATE CONSTRAINT crm_leads_status_stage_check")
        end
        if not constraint_exists("crm_leads_ai_score_range") then
            db.query("ALTER TABLE crm_leads ADD CONSTRAINT crm_leads_ai_score_range CHECK (ai_score IS NULL OR ai_score BETWEEN 0 AND 100)")
        end
        db.query([[CREATE INDEX IF NOT EXISTS crm_leads_ns_stage_open_idx ON crm_leads (namespace_id, status, stage_changed_at DESC)
            WHERE deleted_at IS NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS crm_leads_ns_owner_idx ON crm_leads (namespace_id, owner_user_uuid)
            WHERE deleted_at IS NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS crm_leads_next_action_idx ON crm_leads (next_action_at)
            WHERE deleted_at IS NULL AND next_action_at IS NOT NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS crm_leads_nurture_idx ON crm_leads (nurture_until)
            WHERE deleted_at IS NULL AND status = 'nurture']])
        db.query([[CREATE INDEX IF NOT EXISTS crm_leads_ns_phone_idx ON crm_leads (namespace_id, phone)
            WHERE deleted_at IS NULL AND phone IS NOT NULL]])
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS crm_lead_stage_history (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                lead_id BIGINT NOT NULL REFERENCES crm_leads(id) ON DELETE CASCADE,
                from_status TEXT,
                to_status TEXT NOT NULL,
                changed_by_uuid TEXT,
                reason TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS crm_lead_stage_history_lead_idx ON crm_lead_stage_history (lead_id, created_at)")
        db.query([[CREATE INDEX IF NOT EXISTS crm_lead_stage_history_ns_idx
            ON crm_lead_stage_history (namespace_id, to_status, created_at)]])
        -- Every lead entered `new` when it was created; converted/other leads also
        -- entered their current stage. Only seed leads that have no history yet.
        db.query([[
            INSERT INTO crm_lead_stage_history (namespace_id, lead_id, from_status, to_status, reason, created_at)
            SELECT l.namespace_id, l.id, NULL, 'new', 'backfill', l.created_at
            FROM crm_leads l
            WHERE NOT EXISTS (SELECT 1 FROM crm_lead_stage_history h WHERE h.lead_id = l.id)
        ]])
        db.query([[
            INSERT INTO crm_lead_stage_history (namespace_id, lead_id, from_status, to_status, reason, created_at)
            SELECT l.namespace_id, l.id, 'new', l.status, 'backfill', COALESCE(l.stage_changed_at, l.updated_at, l.created_at)
            FROM crm_leads l
            WHERE l.status <> 'new'
              AND NOT EXISTS (SELECT 1 FROM crm_lead_stage_history h WHERE h.lead_id = l.id AND h.to_status = l.status)
        ]])
    end,

    [3] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS crm_lead_analyses (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                lead_id BIGINT NOT NULL REFERENCES crm_leads(id) ON DELETE CASCADE,
                status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'running', 'done', 'failed', 'skipped')),
                trigger TEXT NOT NULL DEFAULT 'created',
                input_hash TEXT,
                result JSONB,
                error TEXT,
                provider_name TEXT,
                model TEXT,
                cost_usd NUMERIC(12,6),
                latency_ms INTEGER,
                requested_by_uuid TEXT,
                started_at TIMESTAMPTZ,
                finished_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS crm_lead_analyses_lead_idx ON crm_lead_analyses (lead_id, created_at DESC)")
        db.query([[CREATE INDEX IF NOT EXISTS crm_lead_analyses_ns_day_idx ON crm_lead_analyses (namespace_id, created_at)
            WHERE status = 'done']])
        -- At most one queued/running analysis per lead: a burst of triggers coalesces.
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS crm_lead_analyses_one_open ON crm_lead_analyses (lead_id)
            WHERE status IN ('pending', 'running')]])
    end,

    [4] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS crm_lead_settings (
                namespace_id BIGINT PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
                settings JSONB NOT NULL DEFAULT '{}'::jsonb,
                rr_last_user_uuid TEXT,
                updated_by_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
    end,

    [5] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS crm_lead_assignment_rules (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                conditions JSONB NOT NULL DEFAULT '{}'::jsonb,
                assignee_user_uuid TEXT,
                pool JSONB NOT NULL DEFAULT '[]'::jsonb,
                rr_last_user_uuid TEXT,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                created_by_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CONSTRAINT crm_lead_assignment_rules_target CHECK (
                    assignee_user_uuid IS NOT NULL OR jsonb_array_length(pool) > 0)
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS crm_lead_assignment_rules_ns_idx
            ON crm_lead_assignment_rules (namespace_id, position) WHERE enabled]])
    end,

    [6] = function()
        if not table_exists("crm_activities") then return end
        db.query([[
            ALTER TABLE crm_activities
                ADD COLUMN IF NOT EXISTS lead_id BIGINT REFERENCES crm_leads(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS outcome TEXT,
                ADD COLUMN IF NOT EXISTS ends_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS location TEXT,
                ADD COLUMN IF NOT EXISTS meeting_url TEXT,
                ADD COLUMN IF NOT EXISTS attendees JSONB NOT NULL DEFAULT '[]'::jsonb,
                ADD COLUMN IF NOT EXISTS ics_uid TEXT,
                ADD COLUMN IF NOT EXISTS ics_sequence INTEGER NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS reminders_sent JSONB NOT NULL DEFAULT '{}'::jsonb,
                ADD COLUMN IF NOT EXISTS outcome_prompted_at TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS crm_activities_lead_idx ON crm_activities (lead_id, activity_date)
            WHERE lead_id IS NOT NULL AND deleted_at IS NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS crm_activities_planned_due_idx ON crm_activities (activity_date)
            WHERE status = 'planned' AND deleted_at IS NULL]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS crm_activities_ics_uid_idx ON crm_activities (ics_uid)
            WHERE ics_uid IS NOT NULL]])
    end,

    [7] = function()
        if not table_exists("crm_deals") then return end
        db.query("ALTER TABLE crm_deals ADD COLUMN IF NOT EXISTS lead_id BIGINT REFERENCES crm_leads(id) ON DELETE SET NULL")
        db.query("CREATE INDEX IF NOT EXISTS crm_deals_lead_idx ON crm_deals (lead_id) WHERE lead_id IS NOT NULL")
        -- Deals closed from the CRM page (closed_won / closed_lost) were never marked won/lost.
        db.query([[UPDATE crm_deals SET status = 'won', won_at = COALESCE(won_at, updated_at),
            actual_close_date = COALESCE(actual_close_date, updated_at::date)
            WHERE stage IN ('closed_won', 'won') AND status = 'open']])
        db.query([[UPDATE crm_deals SET status = 'lost', lost_at = COALESCE(lost_at, updated_at),
            actual_close_date = COALESCE(actual_close_date, updated_at::date)
            WHERE stage IN ('closed_lost', 'lost') AND status = 'open']])
        -- Deals converted before this migration: link them back to their lead.
        db.query([[
            UPDATE crm_deals d SET lead_id = l.id
            FROM crm_leads l
            WHERE l.converted_deal_id = d.id AND d.lead_id IS NULL
        ]])
    end,

    [8] = function()
        local cjson = require("cjson")
        if #db.query("SELECT 1 FROM modules WHERE machine_name = 'crm_leads'") == 0 then
            local MigrationUtils = require("helper.migration-utils")
            local ts = MigrationUtils.getCurrentTimestamp()
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(), machine_name = "crm_leads", name = "CRM Leads",
                description = "Lead pipeline: capture, follow-up, meetings, conversion", priority = 45,
                created_at = ts, updated_at = ts,
            })
        end
        local ALL = { "create", "read", "update", "delete", "manage" }
        for _, role in ipairs(db.query("SELECT id, role_name, permissions FROM namespace_roles")) do
            local perms = decode_perms(role.permissions)
            if perms.crm_leads == nil then
                local name = tostring(role.role_name or ""):lower()
                local grant
                if name == "owner" or name == "namespace owner" or name == "admin" or name == "namespace admin" then
                    grant = ALL
                elseif type(perms.crm_accounts) == "table" and #perms.crm_accounts > 0 then
                    grant = perms.crm_accounts
                end
                if grant then
                    perms.crm_leads = grant
                    db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
                end
            end
        end
    end,

    [9] = function()
        if not table_exists("invoices") or not table_exists("crm_deals") then return end
        db.query("ALTER TABLE invoices ADD COLUMN IF NOT EXISTS deal_id BIGINT REFERENCES crm_deals(id) ON DELETE SET NULL")
        db.query("CREATE INDEX IF NOT EXISTS invoices_deal_idx ON invoices (deal_id) WHERE deal_id IS NOT NULL")
    end,

    -- [10] Partners: companies (crm_accounts) we pass deals to for fulfilment,
    -- with what they supply and our commission terms.
    [10] = function()
        if not table_exists("crm_accounts") then return end
        db.query([[
            CREATE TABLE IF NOT EXISTS crm_partner_profiles (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                account_id BIGINT NOT NULL UNIQUE REFERENCES crm_accounts(id) ON DELETE CASCADE,
                categories JSONB NOT NULL DEFAULT '[]'::jsonb,
                offering TEXT,
                regions JSONB NOT NULL DEFAULT '[]'::jsonb,
                referral_email TEXT,
                referral_contact_name TEXT,
                commission_type TEXT NOT NULL DEFAULT 'percent' CHECK (commission_type IN ('percent', 'fixed')),
                commission_value NUMERIC(15,4) NOT NULL DEFAULT 0 CHECK (commission_value >= 0),
                currency VARCHAR(3),
                terms TEXT,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                created_by_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CONSTRAINT crm_partner_profiles_percent CHECK (commission_type <> 'percent' OR commission_value <= 100)
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS crm_partner_profiles_ns_idx ON crm_partner_profiles (namespace_id) WHERE active")
    end,

    -- [11] Referrals: a deal (or a lead not yet converted) passed to a partner,
    -- from the introduction to the commission being paid.
    [11] = function()
        if not table_exists("crm_accounts") or not table_exists("crm_deals") then return end
        db.query([[
            CREATE TABLE IF NOT EXISTS crm_deal_referrals (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                deal_id BIGINT REFERENCES crm_deals(id) ON DELETE CASCADE,
                lead_id BIGINT REFERENCES crm_leads(id) ON DELETE SET NULL,
                partner_account_id BIGINT NOT NULL REFERENCES crm_accounts(id) ON DELETE RESTRICT,
                status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'sent', 'accepted', 'declined', 'won',
                    'lost', 'commission_invoiced', 'commission_paid', 'cancelled')),
                deal_value NUMERIC(15,2),
                currency VARCHAR(3),
                commission_type TEXT NOT NULL DEFAULT 'percent' CHECK (commission_type IN ('percent', 'fixed')),
                commission_value NUMERIC(15,4) NOT NULL DEFAULT 0 CHECK (commission_value >= 0),
                commission_amount NUMERIC(15,2),
                message TEXT,
                consent_confirmed_at TIMESTAMPTZ,
                consent_by_uuid TEXT,
                partner_reference TEXT,
                partner_notes TEXT,
                response_token_hash TEXT,
                response_token_expires_at TIMESTAMPTZ,
                ai_reason TEXT,
                share_contact BOOLEAN NOT NULL DEFAULT FALSE,
                sent_at TIMESTAMPTZ,
                responded_at TIMESTAMPTZ,
                won_at TIMESTAMPTZ,
                closed_at TIMESTAMPTZ,
                invoice_id BIGINT,
                created_by_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CONSTRAINT crm_deal_referrals_subject CHECK (deal_id IS NOT NULL OR lead_id IS NOT NULL)
            )
        ]])
        db.query("ALTER TABLE crm_deal_referrals ADD COLUMN IF NOT EXISTS share_contact BOOLEAN NOT NULL DEFAULT FALSE")
        if table_exists("invoices") and not constraint_exists("crm_deal_referrals_invoice_fk") then
            db.query([[ALTER TABLE crm_deal_referrals ADD CONSTRAINT crm_deal_referrals_invoice_fk
                FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE SET NULL]])
        end
        db.query("CREATE INDEX IF NOT EXISTS crm_deal_referrals_deal_idx ON crm_deal_referrals (deal_id) WHERE deal_id IS NOT NULL")
        db.query("CREATE INDEX IF NOT EXISTS crm_deal_referrals_lead_idx ON crm_deal_referrals (lead_id) WHERE lead_id IS NOT NULL")
        db.query("CREATE INDEX IF NOT EXISTS crm_deal_referrals_ns_status_idx ON crm_deal_referrals (namespace_id, status)")
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS crm_deal_referrals_token_idx ON crm_deal_referrals (response_token_hash)
            WHERE response_token_hash IS NOT NULL]])
        -- One live referral per deal (or lead) and partner.
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS crm_deal_referrals_one_live ON crm_deal_referrals
            (COALESCE(deal_id, 0), COALESCE(lead_id, 0), partner_account_id)
            WHERE status NOT IN ('declined', 'lost', 'cancelled')]])
    end,
}
