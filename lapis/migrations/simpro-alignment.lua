--[[
    Field Service — Simpro alignment
    ================================

    DBS (David Blakey Services Ltd, company 03806201) run their business out of
    Simpro, and OpsAPI is being positioned as the CRM in front of it. Their
    customers, sites, assets, jobs, quotes and invoices already exist in Simpro,
    so the shape of the data here follows Simpro's rather than inventing a
    parallel one. Where a Simpro concept had no home in OpsAPI it gets a table;
    where OpsAPI already had the concept under a different name it gets the
    missing columns plus a Simpro id so the two can be reconciled.

    Simpro's model, and where each piece lands:

      Customers        -> customers            (+ company/type/terms/simpro id)
      Sites            -> fs_sites             (+ zone, geo, simpro id)
      Contacts         -> fs_contacts          NEW
      Employees/Staff  -> employees            (+ staff type, simpro id)
      Licences         -> employee_licences    NEW  (expiry drives a report)
      Contractors      -> fs_contractors       NEW
      Vendors          -> fs_vendors           NEW
      Customer Assets  -> fs_assets            NEW  (dropped in v2, back Simpro-shaped)
      Asset Types      -> fs_asset_types       NEW  (carries the test-reading definitions)
      Service Levels   -> fs_asset_service_levels NEW  (the PPM schedule per asset)
      Test History     -> fs_asset_test_history  NEW  (readings + failure points per visit)
      Customer Contract-> fs_contracts         NEW
      Jobs             -> fs_jobs              (+ kind service|project, stage, order no, PM)
      Job Sections     -> fs_job_sections      NEW
      Job Cost Centers -> fs_job_cost_centres  NEW  (where project money actually sits)
      Quotes           -> fs_quotes            NEW
      Schedules        -> fs_visits            (+ simpro id, schedule ref)
      Invoices         -> invoices             (+ job link, stage, simpro id)

    Two things worth knowing about the asset model, because they drive the
    reports DBS already publish from Simpro:

      * A test reading is a name/value pair defined by the asset TYPE and
        captured per visit, so "condition rating 1-6" and "refrigerant weight"
        are rows in fs_asset_test_history.readings rather than columns. That is
        how Simpro does it, and it means a new survey field is configuration,
        not a migration. The 1-6 rating is denormalised onto fs_assets so the
        asset register can be sorted and filtered without a join.
      * A service level is the recurring obligation (e.g. "Quarterly PPM") with
        a next-due date, which is what the PPM forecast report reads.

    Sync bookkeeping (simpro_id / simpro_synced_at / simpro_sync_state) is added
    by [15] in one pass over every table that has a Simpro counterpart, so the
    connector has one consistent contract to write against.

    Gated on FEATURES.FIELD_SERVICE. One table per migration entry.
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query(
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

-- Index / constraint creation is best-effort: re-running a migration on a build
-- that already has the object must not abort the run.
local function index(sql)
    pcall(function() db.query(sql) end)
end

return {
    -- ========================================
    -- [1] fs_contacts   (894)
    -- ========================================
    -- Simpro hangs contacts off both customers and sites. A site contact is who
    -- the engineer actually rings on the day; a customer contact is who gets the
    -- invoice. Both live here, discriminated by which FK is set.
    [1] = function()
        if table_exists("fs_contacts") then return end

        db.query([[
            CREATE TABLE fs_contacts (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                customer_id BIGINT REFERENCES customers(id) ON DELETE CASCADE,
                site_id BIGINT REFERENCES fs_sites(id) ON DELETE CASCADE,
                given_name TEXT,
                family_name TEXT,
                position TEXT,
                email TEXT,
                phone TEXT,
                mobile TEXT,
                is_primary BOOLEAN NOT NULL DEFAULT FALSE,
                notes TEXT,
                custom_fields JSONB NOT NULL DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP,
                CONSTRAINT fs_contacts_owner_chk CHECK (customer_id IS NOT NULL OR site_id IS NOT NULL)
            )
        ]])

        index([[CREATE INDEX fs_contacts_ns_customer_idx ON fs_contacts (namespace_id, customer_id)]])
        index([[CREATE INDEX fs_contacts_ns_site_idx ON fs_contacts (namespace_id, site_id)]])
    end,

    -- ========================================
    -- [2] fs_contracts   (895)
    -- ========================================
    -- Simpro's "CustomerContract" on an asset. DBS run several per site — the
    -- Skanska City of London portfolio alone splits heating from chillers — so
    -- the PPM report has to be able to group by contract, not just by site.
    [2] = function()
        if table_exists("fs_contracts") then return end

        db.query([[
            CREATE TABLE fs_contracts (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                customer_id BIGINT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
                contract_number TEXT,
                name TEXT NOT NULL,
                description TEXT,
                status TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('draft', 'active', 'expired', 'cancelled')),
                start_date DATE,
                end_date DATE,
                -- Renewal option DBS quote on tenders ("5 years + 2"), in months.
                extension_months INTEGER,
                annual_value NUMERIC(14, 2),
                currency TEXT NOT NULL DEFAULT 'GBP',
                -- Response SLAs, in hours. DBS publish 4h emergency / 24h call-out
                -- / 48h for reports and remedial quotations.
                response_hours INTEGER,
                resolve_hours INTEGER,
                quote_turnaround_hours INTEGER,
                covers_out_of_hours BOOLEAN NOT NULL DEFAULT FALSE,
                service_manager_uuid TEXT,
                coordinator_uuid TEXT,
                notes TEXT,
                custom_fields JSONB NOT NULL DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_contracts_ns_customer_idx ON fs_contracts (namespace_id, customer_id)]])
        index([[CREATE INDEX fs_contracts_ns_status_idx ON fs_contracts (namespace_id, status)]])
        index([[CREATE UNIQUE INDEX fs_contracts_ns_number_uniq
                ON fs_contracts (namespace_id, contract_number)
                WHERE contract_number IS NOT NULL AND deleted_at IS NULL]])
    end,

    -- ========================================
    -- [3] fs_asset_types   (896)
    -- ========================================
    -- The Simpro "Asset Type" carries the survey definition: which readings an
    -- engineer is asked for, and which failure points can be ticked. Storing the
    -- definition as JSONB means DBS can add "compressor amps" to chillers from
    -- the UI without a schema change, which is what Simpro's Asset Builder does.
    --
    -- readings: [{key, label, unit, type: number|text|select|rating, options[], required}]
    -- failure_points: [{key, label}]
    [3] = function()
        if table_exists("fs_asset_types") then return end

        db.query([[
            CREATE TABLE fs_asset_types (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                code TEXT,
                description TEXT,
                -- Broad grouping the reports pivot on: hvac | refrigeration |
                -- heating | electrical | controls | ventilation | other.
                discipline TEXT NOT NULL DEFAULT 'hvac',
                -- Does this type hold fluorinated refrigerant? Drives whether the
                -- F-Gas fields are demanded on a visit and whether it appears on
                -- the F-Gas register.
                is_fgas BOOLEAN NOT NULL DEFAULT FALSE,
                default_service_months INTEGER,
                readings JSONB NOT NULL DEFAULT '[]',
                failure_points JSONB NOT NULL DEFAULT '[]',
                -- Consumables DBS suggest carrying as van/site spares for this
                -- type (filters, belts) — straight off their Simpro survey page.
                consumables JSONB NOT NULL DEFAULT '[]',
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE UNIQUE INDEX fs_asset_types_ns_name_uniq
                ON fs_asset_types (namespace_id, name) WHERE deleted_at IS NULL]])
        index([[CREATE INDEX fs_asset_types_ns_discipline_idx
                ON fs_asset_types (namespace_id, discipline)]])
    end,

    -- ========================================
    -- [4] fs_assets   (897)
    -- ========================================
    -- Recreated after field-service-v2 dropped it. The v2 reasoning still holds
    -- for the *catalogue* — a storeproduct is the model of unit you sell — but
    -- Simpro draws a hard line between that and the individual machine bolted to
    -- a customer's roof, and every report DBS run is built on the latter. So:
    -- product_id keeps the link to the catalogue entry, and this row is the
    -- physical unit.
    --
    -- Assets belong to a SITE (Simpro: "if a site is transferred to another
    -- customer, any assets on the site will also be transferred"), so site_id is
    -- the required FK and customer_id is denormalised for query speed only.
    [4] = function()
        if table_exists("fs_assets") then return end

        db.query([[
            CREATE TABLE fs_assets (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                site_id BIGINT NOT NULL REFERENCES fs_sites(id) ON DELETE CASCADE,
                customer_id BIGINT REFERENCES customers(id) ON DELETE SET NULL,
                asset_type_id BIGINT REFERENCES fs_asset_types(id) ON DELETE SET NULL,
                -- Simpro allows an asset tree (a VRF condenser parenting its
                -- indoor units), which is exactly how DBS survey a VRV system.
                parent_id BIGINT REFERENCES fs_assets(id) ON DELETE SET NULL,
                product_id BIGINT REFERENCES storeproducts(id) ON DELETE SET NULL,
                contract_id BIGINT REFERENCES fs_contracts(id) ON DELETE SET NULL,

                asset_tag TEXT,
                name TEXT NOT NULL,
                serial_number TEXT,
                product_number TEXT,
                manufacturer TEXT,
                model TEXT,
                location_detail TEXT,
                installed_at DATE,
                warranty_expires_at DATE,

                -- Survey outcome, denormalised from the latest test record.
                -- DBS score 1 (excellent) to 6 (budget for replacement).
                condition_rating SMALLINT CHECK (condition_rating BETWEEN 1 AND 6),
                condition_notes TEXT,
                last_surveyed_at TIMESTAMP,
                last_test_id BIGINT,

                -- F-Gas register fields. charge_kg x GWP gives the CO2e that
                -- decides leak-check frequency under the UK F-Gas regulations.
                refrigerant_type TEXT,
                refrigerant_charge_kg NUMERIC(10, 3),
                refrigerant_gwp INTEGER,
                hermetically_sealed BOOLEAN NOT NULL DEFAULT FALSE,
                leak_check_months INTEGER,
                next_leak_check_at DATE,

                status TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive', 'decommissioned')),
                archived BOOLEAN NOT NULL DEFAULT FALSE,
                display_order INTEGER NOT NULL DEFAULT 0,
                notes TEXT,
                custom_fields JSONB NOT NULL DEFAULT '{}',
                metadata JSONB NOT NULL DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_assets_ns_site_idx ON fs_assets (namespace_id, site_id)]])
        index([[CREATE INDEX fs_assets_ns_customer_idx ON fs_assets (namespace_id, customer_id)]])
        index([[CREATE INDEX fs_assets_ns_type_idx ON fs_assets (namespace_id, asset_type_id)]])
        index([[CREATE INDEX fs_assets_ns_contract_idx ON fs_assets (namespace_id, contract_id)]])
        index([[CREATE INDEX fs_assets_ns_condition_idx ON fs_assets (namespace_id, condition_rating)]])
        index([[CREATE INDEX fs_assets_ns_parent_idx ON fs_assets (namespace_id, parent_id)]])
        index([[CREATE INDEX fs_assets_serial_idx ON fs_assets (namespace_id, serial_number)]])
        index([[CREATE UNIQUE INDEX fs_assets_ns_tag_uniq
                ON fs_assets (namespace_id, asset_tag)
                WHERE asset_tag IS NOT NULL AND deleted_at IS NULL]])
    end,

    -- ========================================
    -- [5] fs_asset_service_levels   (898)
    -- ========================================
    -- Simpro's ServiceLevels: the recurring obligation against an asset, each
    -- with its own next ServiceDate. One asset can carry several (a chiller on
    -- both a quarterly PPM and an annual F-Gas leak check), which is why this is
    -- a table and not a pair of columns on fs_assets.
    [5] = function()
        if table_exists("fs_asset_service_levels") then return end

        db.query([[
            CREATE TABLE fs_asset_service_levels (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                asset_id BIGINT NOT NULL REFERENCES fs_assets(id) ON DELETE CASCADE,
                contract_id BIGINT REFERENCES fs_contracts(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                -- service | fgas_leak_check | statutory | inspection
                kind TEXT NOT NULL DEFAULT 'service',
                frequency_months INTEGER NOT NULL DEFAULT 12,
                last_service_date DATE,
                next_service_date DATE,
                estimated_hours NUMERIC(6, 2),
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                notes TEXT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_asl_ns_asset_idx ON fs_asset_service_levels (namespace_id, asset_id)]])
        index([[CREATE INDEX fs_asl_ns_contract_idx ON fs_asset_service_levels (namespace_id, contract_id)]])
        -- The PPM forecast report's driving index: "what is due, soonest first".
        index([[CREATE INDEX fs_asl_ns_due_idx
                ON fs_asset_service_levels (namespace_id, next_service_date)
                WHERE is_active AND deleted_at IS NULL]])
    end,

    -- ========================================
    -- [6] fs_asset_test_history   (899)
    -- ========================================
    -- Simpro's Test History. One row per asset per visit: the readings taken,
    -- any failure points found, and the resulting condition rating. This single
    -- table is what the "asset failure history" and "detailed asset history"
    -- reports on DBS's Simpro page are built from.
    --
    -- readings:       [{key, label, value, unit}]
    -- failure_points: [{key, label, severity}]
    [6] = function()
        if table_exists("fs_asset_test_history") then return end

        db.query([[
            CREATE TABLE fs_asset_test_history (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                asset_id BIGINT NOT NULL REFERENCES fs_assets(id) ON DELETE CASCADE,
                site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,
                job_id BIGINT REFERENCES fs_jobs(id) ON DELETE SET NULL,
                visit_id BIGINT REFERENCES fs_visits(id) ON DELETE SET NULL,
                service_level_id BIGINT REFERENCES fs_asset_service_levels(id) ON DELETE SET NULL,
                tested_at TIMESTAMP NOT NULL DEFAULT NOW(),
                -- The service level's due date at the moment this test was
                -- recorded. The level itself moves on afterwards, so without this
                -- "was it done in the month it was due?" cannot be answered later.
                due_date DATE,
                technician_uuid TEXT,
                technician_name TEXT,
                -- pass | fail | advisory — "fail" is what the failure-history
                -- report counts.
                result TEXT NOT NULL DEFAULT 'pass'
                    CHECK (result IN ('pass', 'fail', 'advisory', 'not_tested')),
                condition_rating SMALLINT CHECK (condition_rating BETWEEN 1 AND 6),
                readings JSONB NOT NULL DEFAULT '[]',
                failure_points JSONB NOT NULL DEFAULT '[]',
                -- Refrigerant moved on this test, mirrored from the visit so the
                -- F-Gas register can be produced per asset without a join back
                -- through jobs.
                refrigerant_type TEXT,
                refrigerant_added_kg NUMERIC(10, 3),
                refrigerant_recovered_kg NUMERIC(10, 3),
                leak_check_result TEXT,
                notes TEXT,
                recommendation TEXT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_ath_ns_asset_date_idx
                ON fs_asset_test_history (namespace_id, asset_id, tested_at DESC)]])
        index([[CREATE INDEX fs_ath_ns_result_idx ON fs_asset_test_history (namespace_id, result)]])
        index([[CREATE INDEX fs_ath_ns_job_idx ON fs_asset_test_history (namespace_id, job_id)]])
        index([[CREATE INDEX fs_ath_ns_visit_idx ON fs_asset_test_history (namespace_id, visit_id)]])
        index([[CREATE INDEX fs_ath_ns_date_idx ON fs_asset_test_history (namespace_id, tested_at DESC)]])
    end,

    -- ========================================
    -- [7] fs_assets.last_test_id FK   (900)
    -- ========================================
    -- Deferred until fs_asset_test_history exists — the two reference each other.
    [7] = function()
        index([[
            ALTER TABLE fs_assets
            ADD CONSTRAINT fs_assets_last_test_fk
            FOREIGN KEY (last_test_id) REFERENCES fs_asset_test_history(id) ON DELETE SET NULL
        ]])
    end,

    -- ========================================
    -- [8] employee_licences   (901)
    -- ========================================
    -- Simpro's Licences. DBS's published Simpro report pack includes an Employee
    -- Licence report with a trigger for upcoming expiry, and their engineers hold
    -- F-Gas and/or Gas Safe plus a minimum Level 2 NVQ — so the register needs an
    -- expiry date it can be sorted on.
    [8] = function()
        if table_exists("employee_licences") then return end

        db.query([[
            CREATE TABLE employee_licences (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                employee_id BIGINT NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
                licence_type TEXT NOT NULL,
                licence_number TEXT,
                issuing_body TEXT,
                issued_on DATE,
                expires_on DATE,
                -- Days before expiry that this should start showing as due.
                reminder_days INTEGER NOT NULL DEFAULT 60,
                notes TEXT,
                attachment_url TEXT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX employee_licences_ns_employee_idx
                ON employee_licences (namespace_id, employee_id)]])
        index([[CREATE INDEX employee_licences_ns_expiry_idx
                ON employee_licences (namespace_id, expires_on)
                WHERE deleted_at IS NULL]])
    end,

    -- ========================================
    -- [9] fs_job_cost_centres   (902)
    -- ========================================
    -- In Simpro the job total is the sum of its cost centres, and a project job
    -- splits across several (Mechanical / Electrical / Controls — which is
    -- exactly how DBS's divisions bill a fit-out). Claimed vs total is what
    -- drives project WIP and application-for-payment reporting.
    [9] = function()
        if table_exists("fs_job_cost_centres") then return end

        db.query([[
            CREATE TABLE fs_job_cost_centres (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_id BIGINT NOT NULL REFERENCES fs_jobs(id) ON DELETE CASCADE,
                section_id BIGINT,
                name TEXT NOT NULL,
                code TEXT,
                -- Which DBS division owns this slice of the job.
                discipline TEXT,
                stage TEXT NOT NULL DEFAULT 'pending'
                    CHECK (stage IN ('pending', 'progress', 'complete', 'archived')),
                estimated_hours NUMERIC(10, 2) NOT NULL DEFAULT 0,
                actual_hours NUMERIC(10, 2) NOT NULL DEFAULT 0,
                estimated_cost NUMERIC(14, 2) NOT NULL DEFAULT 0,
                actual_cost NUMERIC(14, 2) NOT NULL DEFAULT 0,
                total_ex_tax NUMERIC(14, 2) NOT NULL DEFAULT 0,
                total_inc_tax NUMERIC(14, 2) NOT NULL DEFAULT 0,
                claimed_ex_tax NUMERIC(14, 2) NOT NULL DEFAULT 0,
                currency TEXT NOT NULL DEFAULT 'GBP',
                display_order INTEGER NOT NULL DEFAULT 0,
                notes TEXT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_jcc_ns_job_idx ON fs_job_cost_centres (namespace_id, job_id)]])
        index([[CREATE INDEX fs_jcc_ns_stage_idx ON fs_job_cost_centres (namespace_id, stage)]])
    end,

    -- ========================================
    -- [10] fs_job_sections   (903)
    -- ========================================
    -- Simpro groups cost centres into sections on a project job — for DBS a
    -- section is typically a floor or a plantroom.
    [10] = function()
        if table_exists("fs_job_sections") then return end

        db.query([[
            CREATE TABLE fs_job_sections (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_id BIGINT NOT NULL REFERENCES fs_jobs(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                description TEXT,
                display_order INTEGER NOT NULL DEFAULT 0,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_job_sections_ns_job_idx ON fs_job_sections (namespace_id, job_id)]])
        index([[
            ALTER TABLE fs_job_cost_centres
            ADD CONSTRAINT fs_jcc_section_fk
            FOREIGN KEY (section_id) REFERENCES fs_job_sections(id) ON DELETE SET NULL
        ]])
    end,

    -- ========================================
    -- [11] fs_quotes   (904)
    -- ========================================
    -- Simpro treats a quote as a first-class sibling of a job that converts into
    -- one. DBS commit to a 48-hour turnaround on remedial quotations, so the
    -- clock between "raised" and "sent" is a number the service desk is measured
    -- on and needs to be stored, not derived.
    [11] = function()
        if table_exists("fs_quotes") then return end

        db.query([[
            CREATE TABLE fs_quotes (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                quote_number TEXT,
                customer_id BIGINT REFERENCES customers(id) ON DELETE SET NULL,
                site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,
                asset_id BIGINT REFERENCES fs_assets(id) ON DELETE SET NULL,
                service_request_id BIGINT REFERENCES fs_service_requests(id) ON DELETE SET NULL,
                -- Set once the quote is accepted and becomes work.
                job_id BIGINT REFERENCES fs_jobs(id) ON DELETE SET NULL,
                title TEXT NOT NULL,
                description TEXT,
                stage TEXT NOT NULL DEFAULT 'in_progress'
                    CHECK (stage IN ('in_progress', 'complete', 'approved', 'archived')),
                status TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'sent', 'accepted', 'declined', 'expired')),
                salesperson_uuid TEXT,
                date_issued DATE,
                valid_until DATE,
                sent_at TIMESTAMP,
                decided_at TIMESTAMP,
                subtotal NUMERIC(14, 2) NOT NULL DEFAULT 0,
                tax_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
                total_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
                currency TEXT NOT NULL DEFAULT 'GBP',
                customer_order_no TEXT,
                decline_reason TEXT,
                notes TEXT,
                custom_fields JSONB NOT NULL DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_quotes_ns_customer_idx ON fs_quotes (namespace_id, customer_id)]])
        index([[CREATE INDEX fs_quotes_ns_stage_idx ON fs_quotes (namespace_id, stage)]])
        index([[CREATE INDEX fs_quotes_ns_site_idx ON fs_quotes (namespace_id, site_id)]])
        index([[CREATE UNIQUE INDEX fs_quotes_ns_number_uniq
                ON fs_quotes (namespace_id, quote_number)
                WHERE quote_number IS NOT NULL AND deleted_at IS NULL]])
    end,

    -- ========================================
    -- [12] customers -> Simpro customer shape   (905)
    -- ========================================
    -- OpsAPI's customers table is person-shaped (first_name / last_name) because
    -- it came from ecommerce. Simpro customers are a company OR an individual,
    -- and DBS's are almost all companies (BNP Paribas, Skanska, Derwent London).
    -- company_name is added rather than overloading first_name.
    [12] = function()
        db.query([[
            ALTER TABLE customers
                ADD COLUMN IF NOT EXISTS company_name TEXT,
                ADD COLUMN IF NOT EXISTS customer_type TEXT NOT NULL DEFAULT 'company',
                ADD COLUMN IF NOT EXISTS trading_name TEXT,
                ADD COLUMN IF NOT EXISTS customer_group TEXT,
                ADD COLUMN IF NOT EXISTS payment_terms_days INTEGER,
                ADD COLUMN IF NOT EXISTS credit_limit NUMERIC(14, 2),
                ADD COLUMN IF NOT EXISTS requires_order_no BOOLEAN NOT NULL DEFAULT FALSE,
                ADD COLUMN IF NOT EXISTS account_manager_uuid TEXT,
                ADD COLUMN IF NOT EXISTS custom_fields JSONB NOT NULL DEFAULT '{}'
        ]])
        index([[
            ALTER TABLE customers
            ADD CONSTRAINT customers_customer_type_chk
            CHECK (customer_type IN ('company', 'individual'))
        ]])
        index([[CREATE INDEX customers_ns_company_idx ON customers (namespace_id, company_name)]])
    end,

    -- ========================================
    -- [13] fs_sites -> Simpro site shape   (906)
    -- ========================================
    [13] = function()
        db.query([[
            ALTER TABLE fs_sites
                ADD COLUMN IF NOT EXISTS zone TEXT,
                ADD COLUMN IF NOT EXISTS site_type TEXT,
                ADD COLUMN IF NOT EXISTS latitude NUMERIC(10, 7),
                ADD COLUMN IF NOT EXISTS longitude NUMERIC(10, 7),
                ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE,
                ADD COLUMN IF NOT EXISTS custom_fields JSONB NOT NULL DEFAULT '{}'
        ]])
        index([[CREATE INDEX fs_sites_ns_zone_idx ON fs_sites (namespace_id, zone)]])
    end,

    -- ========================================
    -- [14] fs_jobs -> Simpro job shape   (907)
    -- ========================================
    -- Two additions carry most of the weight:
    --   kind   — Simpro's Service vs Project job. DBS run both out of one system
    --            (Service & Maintenance, and the Projects/Mechanical divisions),
    --            and "projects" in the demo are project-kind jobs.
    --   stage  — Simpro's coarse lifecycle (Pending/Progress/Complete/Archived),
    --            which is deliberately separate from the fine-grained `status`
    --            the app already has. Reports group on stage.
    [14] = function()
        db.query([[
            ALTER TABLE fs_jobs
                ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'service',
                ADD COLUMN IF NOT EXISTS stage TEXT NOT NULL DEFAULT 'pending',
                ADD COLUMN IF NOT EXISTS contract_id BIGINT REFERENCES fs_contracts(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS asset_id BIGINT REFERENCES fs_assets(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS quote_id BIGINT REFERENCES fs_quotes(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS order_no TEXT,
                ADD COLUMN IF NOT EXISTS project_manager_uuid TEXT,
                ADD COLUMN IF NOT EXISTS salesperson_uuid TEXT,
                ADD COLUMN IF NOT EXISTS zone TEXT,
                ADD COLUMN IF NOT EXISTS date_issued DATE,
                ADD COLUMN IF NOT EXISTS total_ex_tax NUMERIC(14, 2),
                ADD COLUMN IF NOT EXISTS total_inc_tax NUMERIC(14, 2),
                ADD COLUMN IF NOT EXISTS custom_fields JSONB NOT NULL DEFAULT '{}'
        ]])
        index([[
            ALTER TABLE fs_jobs ADD CONSTRAINT fs_jobs_kind_chk
            CHECK (kind IN ('service', 'project', 'maintenance', 'callout'))
        ]])
        index([[
            ALTER TABLE fs_jobs ADD CONSTRAINT fs_jobs_stage_chk
            CHECK (stage IN ('pending', 'progress', 'complete', 'archived'))
        ]])
        index([[CREATE INDEX fs_jobs_ns_kind_stage_idx ON fs_jobs (namespace_id, kind, stage)]])
        index([[CREATE INDEX fs_jobs_ns_contract_idx ON fs_jobs (namespace_id, contract_id)]])
        index([[CREATE INDEX fs_jobs_ns_asset_idx ON fs_jobs (namespace_id, asset_id)]])

        -- Backfill stage from the status the app already maintains, so existing
        -- rows land somewhere sensible rather than all sitting in 'pending'.
        db.query([[
            UPDATE fs_jobs SET stage = CASE
                WHEN status = 'completed' THEN 'complete'
                WHEN status = 'cancelled' THEN 'archived'
                WHEN status IN ('scheduled', 'in_progress', 'on_hold') THEN 'progress'
                ELSE 'pending' END
            WHERE stage = 'pending'
        ]])
    end,

    -- ========================================
    -- [15] Simpro sync bookkeeping   (908)
    -- ========================================
    -- One shape everywhere, so the connector never has to special-case a table:
    --   simpro_id         the id in DBS's Simpro build (NULL = local only)
    --   simpro_synced_at  when we last agreed with Simpro
    --   simpro_sync_state synced | pending | conflict | error | local_only
    --
    -- `pending` is set by the app on write and cleared by the connector, so a
    -- crash mid-push leaves a row that will be retried rather than lost.
    [15] = function()
        local tables = {
            "customers", "fs_sites", "fs_contacts", "fs_assets", "fs_asset_types",
            "fs_asset_service_levels", "fs_asset_test_history", "fs_contracts",
            "fs_jobs", "fs_job_cost_centres", "fs_quotes", "fs_visits",
            "fs_service_requests", "fs_parts", "invoices", "employees",
            "employee_licences",
        }
        for _, t in ipairs(tables) do
            -- Guarded per table: a build with FIELD_SERVICE off part-way through
            -- its history may legitimately be missing one of these.
            pcall(function()
                db.query(("ALTER TABLE %s " ..
                    "ADD COLUMN IF NOT EXISTS simpro_id TEXT, " ..
                    "ADD COLUMN IF NOT EXISTS simpro_synced_at TIMESTAMP, " ..
                    "ADD COLUMN IF NOT EXISTS simpro_sync_state TEXT NOT NULL DEFAULT 'local_only'")
                    :format(t))
                db.query(("CREATE INDEX IF NOT EXISTS %s_simpro_id_idx ON %s (simpro_id)")
                    :format(t, t))
                db.query(("CREATE INDEX IF NOT EXISTS %s_simpro_state_idx ON %s (simpro_sync_state) " ..
                    "WHERE simpro_sync_state <> 'synced'"):format(t, t))
            end)
        end
    end,

    -- ========================================
    -- [16] simpro_sync_log   (909)
    -- ========================================
    -- Every push and pull, so a demo can show *why* a row is in conflict and an
    -- operator can replay a failed batch.
    [16] = function()
        if table_exists("simpro_sync_log") then return end

        db.query([[
            CREATE TABLE simpro_sync_log (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                direction TEXT NOT NULL CHECK (direction IN ('push', 'pull')),
                entity_type TEXT NOT NULL,
                entity_uuid TEXT,
                simpro_id TEXT,
                operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete', 'read')),
                status TEXT NOT NULL CHECK (status IN ('ok', 'conflict', 'error', 'skipped')),
                http_status INTEGER,
                request_payload JSONB,
                response_payload JSONB,
                error_message TEXT,
                duration_ms INTEGER,
                batch_uuid TEXT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        index([[CREATE INDEX simpro_sync_log_ns_created_idx
                ON simpro_sync_log (namespace_id, created_at DESC)]])
        index([[CREATE INDEX simpro_sync_log_ns_entity_idx
                ON simpro_sync_log (namespace_id, entity_type, entity_uuid)]])
        index([[CREATE INDEX simpro_sync_log_ns_status_idx
                ON simpro_sync_log (namespace_id, status) WHERE status <> 'ok']])
        index([[CREATE INDEX simpro_sync_log_batch_idx ON simpro_sync_log (batch_uuid)]])
    end,

    -- ========================================
    -- [17] simpro_connections   (910)
    -- ========================================
    -- Per-namespace connection to a Simpro build. The OAuth client secret and
    -- refresh token are NOT stored here — they live in the namespace vault and
    -- this row holds only the reference, so a database dump never carries
    -- Simpro credentials.
    [17] = function()
        if table_exists("simpro_connections") then return end

        db.query([[
            CREATE TABLE simpro_connections (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL DEFAULT 'Simpro',
                base_url TEXT NOT NULL,
                company_id TEXT NOT NULL DEFAULT '0',
                -- Vault key holding {client_id, client_secret, refresh_token}.
                credentials_vault_key TEXT,
                mode TEXT NOT NULL DEFAULT 'mock'
                    CHECK (mode IN ('mock', 'sandbox', 'live')),
                -- Guard rail: a live build is read-only until explicitly enabled.
                push_enabled BOOLEAN NOT NULL DEFAULT FALSE,
                pull_enabled BOOLEAN NOT NULL DEFAULT TRUE,
                sync_interval_minutes INTEGER NOT NULL DEFAULT 15,
                last_pull_at TIMESTAMP,
                last_push_at TIMESTAMP,
                last_error TEXT,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                settings JSONB NOT NULL DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE UNIQUE INDEX simpro_connections_ns_uniq
                ON simpro_connections (namespace_id) WHERE deleted_at IS NULL]])
    end,

    -- ========================================
    -- [18] invoices -> Simpro invoice shape   (911)
    -- ========================================
    [18] = function()
        db.query([[
            ALTER TABLE invoices
                ADD COLUMN IF NOT EXISTS job_id BIGINT REFERENCES fs_jobs(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS customer_id BIGINT REFERENCES customers(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS stage TEXT NOT NULL DEFAULT 'pending',
                ADD COLUMN IF NOT EXISTS customer_order_no TEXT
        ]])
        index([[
            ALTER TABLE invoices ADD CONSTRAINT invoices_stage_chk
            CHECK (stage IN ('pending', 'approved', 'archived'))
        ]])
        index([[CREATE INDEX invoices_ns_job_idx ON invoices (namespace_id, job_id)]])
        index([[CREATE INDEX invoices_ns_customer_idx ON invoices (namespace_id, customer_id)]])
    end,

    -- ========================================
    -- [19] employees -> Simpro staff shape   (912)
    -- ========================================
    [19] = function()
        db.query([[
            ALTER TABLE employees
                ADD COLUMN IF NOT EXISTS staff_type TEXT NOT NULL DEFAULT 'employee',
                ADD COLUMN IF NOT EXISTS team TEXT,
                ADD COLUMN IF NOT EXISTS date_started DATE,
                ADD COLUMN IF NOT EXISTS is_apprentice BOOLEAN NOT NULL DEFAULT FALSE,
                ADD COLUMN IF NOT EXISTS bill_rate NUMERIC(10, 2),
                ADD COLUMN IF NOT EXISTS overtime_cost_rate NUMERIC(10, 2),
                ADD COLUMN IF NOT EXISTS custom_fields JSONB NOT NULL DEFAULT '{}'
        ]])
        index([[
            ALTER TABLE employees ADD CONSTRAINT employees_staff_type_chk
            CHECK (staff_type IN ('employee', 'contractor', 'apprentice', 'office'))
        ]])
    end,

    -- ========================================
    -- [20] fs_visits -> Simpro schedule shape   (913)
    -- ========================================
    [20] = function()
        db.query([[
            ALTER TABLE fs_visits
                ADD COLUMN IF NOT EXISTS cost_centre_id BIGINT
                    REFERENCES fs_job_cost_centres(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS asset_id BIGINT REFERENCES fs_assets(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS schedule_reference TEXT,
                ADD COLUMN IF NOT EXISTS is_out_of_hours BOOLEAN NOT NULL DEFAULT FALSE,
                ADD COLUMN IF NOT EXISTS travel_minutes INTEGER
        ]])
        index([[CREATE INDEX fs_visits_ns_asset_idx ON fs_visits (namespace_id, asset_id)]])
    end,
}
