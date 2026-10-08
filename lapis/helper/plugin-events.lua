--[[
    Plugin events
    =============

    Core and plugins publish events; plugins react to them from
    projects/<plugin>/events/*.lua (guide: PLUGINS.md):

        -- projects/helpdesk/events/billing.lua
        return {
            ["invoice.updated"] = function(event)
                local status = event.changes and event.changes.status
                if status and status.to == "paid" then ... end
            end,
        }

    Event names are <entity>.<action>. Table changes give created / updated /
    deleted for every entity in CATALOG (core) and in a manifest's
    `publishes` (plugins, prefixed with the plugin code); sdk.emit() adds
    custom ones ("helpdesk.ticket.escalated"). "<entity>.*" subscribes to all
    of an entity's events.

    Business events: an entity's `verbs` name states a row can enter, e.g.
    invoice `paid = { status = "paid" }` fires invoice.paid when an invoice is
    created as paid or updated from any other status to paid (every listed
    column must match; a list means any of those values). They come from the
    same trigger and transaction as invoice.updated, so they are just as
    reliable — subscribe to what happened instead of decoding `changes`.

    How it works
      * Table changes: one generic trigger (opsapi_plugin_event) on each
        source table writes the event plus a delivery row per subscriber in the
        SAME transaction as the change — a transactional outbox, so no event is
        lost or invented by a rollback. It covers every writer (API routes,
        the AI agent, imports, other services on the database). A table only
        gets the trigger while someone subscribes to it, and the trigger
        swallows its own errors: eventing never fails a business write.
      * Delivery: every nginx worker with handlers polls
        plugin_event_deliveries, claiming rows FOR UPDATE SKIP LOCKED (no
        double-claims across workers or pods), runs the handler, retries
        failures with exponential backoff and marks a delivery dead after
        MAX_ATTEMPTS. A claimed row whose worker died is retried after
        LOCK_SECONDS. At-least-once and unordered: handlers must be
        idempotent (event.id is stable across retries).
      * `lapis migrate` syncs sources, subscriptions and triggers
        (helper.project-migrator); done/dead deliveries are purged after
        7/30 days.
      * Audit trail: the reserved subscriber "core.audit" listens to every
        source ("<entity>.*") while OPSAPI_AUDIT_ENABLED isn't "false". For it
        the trigger writes an audit_events row (who, from where, what changed)
        IN THE SAME TRANSACTION as the change, instead of a delivery: nothing
        to dispatch, and a rolled-back write leaves no audit row. Who = the
        session settings helper/request-context.lua puts on every connection.
        Kept OPSAPI_AUDIT_RETENTION_DAYS (default 365).
]]

local cjson = require("cjson")

local PluginEvents = {}

PluginEvents.MAX_ATTEMPTS = 8
PluginEvents.ACTIONS = { "created", "updated", "deleted" } -- every table entity has these
PluginEvents.AUDIT_SUBSCRIBER = "core.audit" -- reserved: written by the trigger, never dispatched

--- The audit trail is on unless OPSAPI_AUDIT_ENABLED=false.
function PluginEvents.auditEnabled()
    return os.getenv("OPSAPI_AUDIT_ENABLED") ~= "false"
end

local function audit_retention_days()
    local n = math.floor(tonumber(os.getenv("OPSAPI_AUDIT_RETENTION_DAYS") or "") or 365)
    return n < 30 and 30 or n
end
PluginEvents.auditRetentionDays = audit_retention_days
local LOCK_SECONDS = 300
local POLL_SECONDS = 2
local BATCH = 20

-- Core entities plugins can subscribe to. Only tables with a tenant: each
-- event carries a namespace_id (`ns_sql` resolves it for tables without the
-- column). `hide` = columns left out of payloads (comma-separated). `module`
-- = the RBAC module that guards the data: a workspace webhook can only
-- subscribe to entities its creator may read. `verbs` = business events
-- (values are the tables' CHECK-constrained statuses).
PluginEvents.CATALOG = {
    { entity = "customer", table = "customers", module = "customers", verbs = { disabled = { state = "disabled" } } },
    {
        entity = "invoice", table = "invoices", module = "invoices",
        verbs = {
            sent = { status = "sent" }, paid = { status = "paid" }, partially_paid = { status = "partially_paid" },
            overdue = { status = "overdue" }, cancelled = { status = { "cancelled", "void" } },
        },
    },
    { entity = "invoice.payment", table = "invoice_payments", module = "invoices" },
    { entity = "crm.account", table = "crm_accounts", module = "crm_accounts" },
    { entity = "crm.contact", table = "crm_contacts", module = "crm_contacts" },
    { entity = "crm.deal", table = "crm_deals", module = "crm_deals", verbs = { won = { status = "won" }, lost = { status = "lost" } } },
    {
        entity = "crm.lead", table = "crm_leads", module = "crm_leads",
        verbs = { qualified = { status = "qualified" }, converted = { status = "converted" }, lost = { status = "lost" } },
    },
    { entity = "crm.activity", table = "crm_activities", module = "crm_activities", verbs = { completed = { status = "completed" } } },
    { entity = "employee", table = "employees", module = "employees", verbs = { deactivated = { is_active = false } } },
    {
        entity = "timesheet", table = "timesheets", module = "timesheets",
        verbs = { submitted = { status = "submitted" }, approved = { status = "approved" }, rejected = { status = "rejected" } },
    },
    {
        entity = "order", table = "orders", module = "orders",
        verbs = {
            confirmed = { status = "confirmed" }, shipped = { status = "shipped" }, delivered = { status = "delivered" },
            cancelled = { status = "cancelled" }, paid = { financial_status = "paid" },
            refunded = { financial_status = "refunded" },
        },
    },
    {
        entity = "kanban.project", table = "kanban_projects", module = "projects",
        verbs = { completed = { status = "completed" }, archived = { status = "archived" } },
    },
    {
        entity = "kanban.task", table = "kanban_tasks", module = "projects", hide = "search_vector", ns_key = "board_id",
        ns_sql = "SELECT p.namespace_id FROM kanban_boards b JOIN kanban_projects p ON p.id = b.project_id WHERE b.id = $1::int",
        verbs = { completed = { status = "completed" }, blocked = { status = "blocked" } },
    },
    {
        entity = "fs.job", table = "fs_jobs", module = "fs_jobs",
        verbs = {
            scheduled = { status = "scheduled" }, started = { status = "in_progress" },
            completed = { status = "completed" }, cancelled = { status = "cancelled" },
        },
    },
    {
        entity = "fs.visit", table = "fs_visits", module = "fs_visits",
        verbs = {
            arrived = { status = "on_site" }, completed = { status = "completed" },
            cancelled = { status = "cancelled" }, no_access = { status = "no_access" },
        },
    },
    {
        entity = "member", table = "namespace_members", module = "users",
        verbs = { joined = { status = "active" }, suspended = { status = "suspended" }, left = { status = "left" } },
    },
}

-- Billing & Entitlements, only where it is deployed (other deployments' webhook
-- lists and audit triggers stay as they were). Entitlements are computed from
-- these rows, so an app's SDK drops its cached answer on subscription.* /
-- billing.grant.* / billing.plan.* instead of a computed "entitlements.changed".
if require("helper.project-config").isFeatureEnabled("billing") then
    for _, source in ipairs({
        {
            entity = "subscription", table = "billing_subscriptions", module = "subscriptions",
            verbs = {
                activated = { status = "active" }, trialing = { status = "trialing" },
                past_due = { status = "past_due" }, canceled = { status = { "canceled", "incomplete_expired" } },
            },
        },
        { entity = "billing.plan", table = "billing_plans", module = "billing" },
        { entity = "billing.grant", table = "billing_grants", module = "subscriptions" },
        {
            entity = "purchase", table = "billing_purchases", module = "subscriptions",
            verbs = { refunded = { status = "refunded" }, revoked = { status = "revoked" } },
        },
        {
            entity = "license", table = "billing_licenses", module = "licenses", hide = "key_hash",
            verbs = {
                suspended = { status = "suspended" }, revoked = { status = "revoked" },
                expired = { status = "expired" },
            },
        },
        {
            entity = "license.activation", table = "billing_license_activations", module = "licenses",
            hide = "fingerprint_hash", ns_key = "license_id",
            ns_sql = "SELECT namespace_id FROM billing_licenses WHERE id = $1::bigint",
        },
    }) do
        PluginEvents.CATALOG[#PluginEvents.CATALOG + 1] = source
    end
end

local EVENT_KEY = "^[a-z][a-z0-9_]*[a-z0-9_.]*%.[a-z0-9_*]+$"
local VERB = "^[a-z][a-z0-9_]*$"
local COLUMN = "^[a-z_][a-z0-9_]*$"

--- Validate a `verbs` table ({ paid = { status = "paid" } }).
-- @return nil when valid, else a message
function PluginEvents.checkVerbs(verbs)
    if verbs == nil then return nil end
    if type(verbs) ~= "table" then return "verbs must be a table like { closed = { status = \"closed\" } }" end
    for verb, cond in pairs(verbs) do
        if type(verb) ~= "string" or not verb:match(VERB) then
            return "verb " .. tostring(verb) .. ": use lowercase letters, digits and _"
        end
        for _, action in ipairs(PluginEvents.ACTIONS) do
            if verb == action then return "verb " .. verb .. " is reserved (every entity has it)" end
        end
        if type(cond) ~= "table" or next(cond) == nil then
            return "verb " .. verb .. " needs a condition like { status = \"" .. verb .. "\" }"
        end
        for column, value in pairs(cond) do
            if type(column) ~= "string" or not column:match(COLUMN) then
                return "verb " .. verb .. ": " .. tostring(column) .. " is not a column name"
            end
            local values = type(value) == "table" and value or { value }
            if #values == 0 then return "verb " .. verb .. ": " .. column .. " needs at least one value" end
            for k, v in pairs(values) do
                local t = type(v)
                if type(k) ~= "number" or (t ~= "string" and t ~= "number" and t ~= "boolean") then
                    return "verb " .. verb .. ": " .. column .. " must be a string, number, boolean or a list of them"
                end
            end
        end
    end
    return nil
end

--- Every event of an entity: created/updated/deleted, then its verbs (sorted).
--- Computed events of core entities: no table change behind them, emitted by
-- core code through emitCore() (e.g. a licence key issued or reissued).
PluginEvents.COMPUTED = { license = { "issued", "reissued" } }

function PluginEvents.entityEvents(entity, verbs)
    local out = {}
    for _, a in ipairs(PluginEvents.ACTIONS) do out[#out + 1] = entity .. "." .. a end
    for _, a in ipairs(PluginEvents.COMPUTED[entity] or {}) do out[#out + 1] = entity .. "." .. a end
    local names = {}
    for verb in pairs(verbs or {}) do names[#names + 1] = verb end
    table.sort(names)
    for _, verb in ipairs(names) do out[#out + 1] = entity .. "." .. verb end
    return out
end

-- Verbs from a database row (jsonb comes back as text or a decoded table).
function PluginEvents.decodeVerbs(v)
    if type(v) == "string" then return cjson.decode(v) end
    return type(v) == "table" and v or {}
end

local function db()
    return require("lapis.db")
end

-- SQL: does <col> belong to plugin <code>? (subscribers are "<code>.<file>")
local function owned_by(col, code)
    return ("left(%s, %d) = %s"):format(col, #code + 1, db().escape_literal(code .. "."))
end

-- ---------------------------------------------------------------------------
-- Subscribers (events/*.lua)
-- ---------------------------------------------------------------------------

--- Load a plugin's events/*.lua files.
-- @return subscribers { [subscriber] = { [event] = fn } }, errors { "file: message" }
-- subscriber = "<plugin code>.<file name>" — the unit of delivery and retry.
function PluginEvents.loadSubscribers(manifest)
    local ProjectLoader = require("helper.project-loader")
    local dir = manifest.path .. "/events"
    local subscribers, errors = {}, {}
    for _, file in ipairs(ProjectLoader.listDir(dir)) do
        local name = file:match("^([%w_%-]+)%.lua$")
        if name then
            local chunk, err = loadfile(dir .. "/" .. file)
            local ok, handlers = chunk ~= nil, err
            if chunk then ok, handlers = pcall(chunk) end
            if ok and type(handlers) ~= "table" then
                ok, handlers = false, "must return a table of { [\"event.name\"] = function(event) ... end }"
            end
            if ok then
                for event, fn in pairs(handlers) do
                    if type(event) ~= "string" or not event:match(EVENT_KEY) then
                        ok, handlers = false, "bad event name " .. tostring(event) .. " (use entity.action, e.g. invoice.updated)"
                        break
                    elseif type(fn) ~= "function" then
                        ok, handlers = false, "handler for " .. event .. " must be a function"
                        break
                    end
                end
            end
            if ok then
                subscribers[manifest.code .. "." .. name] = handlers
            else
                errors[#errors + 1] = "events/" .. file .. ": " .. tostring(handlers)
            end
        end
    end
    return subscribers, errors
end

-- ---------------------------------------------------------------------------
-- Schema + sync (called by helper.project-migrator on `lapis migrate`)
-- ---------------------------------------------------------------------------

function PluginEvents.ensureSchema()
    -- opsapi_plugin_enabled(), used by the trigger below.
    require("helper.plugin-workspaces").ensureSchema()
    local q = db().query
    q([[
        CREATE TABLE IF NOT EXISTS plugin_event_sources (
            entity VARCHAR(150) PRIMARY KEY,
            table_name VARCHAR(100) NOT NULL UNIQUE,
            owner VARCHAR(100) NOT NULL,
            hide TEXT NOT NULL DEFAULT '',
            ns_sql TEXT NOT NULL DEFAULT '',
            ns_key VARCHAR(100) NOT NULL DEFAULT '',
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    q([[
        CREATE TABLE IF NOT EXISTS plugin_event_subscriptions (
            event VARCHAR(200) NOT NULL,
            subscriber VARCHAR(200) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (event, subscriber)
        )
    ]])
    q([[
        CREATE TABLE IF NOT EXISTS plugin_events (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL DEFAULT gen_random_uuid(),
            event VARCHAR(200) NOT NULL,
            entity VARCHAR(150) NOT NULL,
            entity_id TEXT,
            namespace_id BIGINT,
            data JSONB,
            changes JSONB,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    q([[
        CREATE TABLE IF NOT EXISTS plugin_event_deliveries (
            id BIGSERIAL PRIMARY KEY,
            event_id BIGINT NOT NULL REFERENCES plugin_events(id) ON DELETE CASCADE,
            subscriber VARCHAR(200) NOT NULL,
            status VARCHAR(20) NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            last_error TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (event_id, subscriber)
        )
    ]])
    q([[
        CREATE INDEX IF NOT EXISTS idx_plugin_event_deliveries_due
        ON plugin_event_deliveries (next_attempt_at) WHERE status IN ('pending', 'running')
    ]])
    q([[
        CREATE INDEX IF NOT EXISTS idx_plugin_event_deliveries_subscriber
        ON plugin_event_deliveries (subscriber, status)
    ]])
    q("CREATE INDEX IF NOT EXISTS idx_plugin_events_created ON plugin_events (created_at)")
    -- Later additions (idempotent for databases created before them):
    -- sources.module (RBAC guard), subscriptions.namespace_id (NULL = every
    -- namespace, i.e. plugins; set = one workspace's webhook), and the
    -- response of webhook deliveries.
    q("ALTER TABLE plugin_event_sources ADD COLUMN IF NOT EXISTS module VARCHAR(100)")
    q([[
        ALTER TABLE plugin_event_subscriptions
        ADD COLUMN IF NOT EXISTS namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE
    ]])
    q("ALTER TABLE plugin_event_sources ADD COLUMN IF NOT EXISTS verbs JSONB NOT NULL DEFAULT '{}'::jsonb")
    q("ALTER TABLE plugin_event_deliveries ADD COLUMN IF NOT EXISTS response_status INTEGER")
    q("ALTER TABLE plugin_event_deliveries ADD COLUMN IF NOT EXISTS duration_ms INTEGER")

    -- Audit row for one change (also used by emit()). Only when "core.audit"
    -- subscribes to the event and the change belongs to a workspace. Keys that
    -- look like credentials are dropped; the actor comes from the session
    -- settings helper/request-context.lua puts on every connection.
    q("CREATE INDEX IF NOT EXISTS idx_audit_events_ns_time ON audit_events (namespace_id, created_at DESC, id DESC)")
    q("CREATE INDEX IF NOT EXISTS idx_audit_events_created ON audit_events USING BRIN (created_at)")
    q([==[
        CREATE OR REPLACE FUNCTION opsapi_audit(ev text, ent text, ent_id text, ns bigint, old_v jsonb, new_v jsonb)
        RETURNS void LANGUAGE plpgsql AS $fn$
        DECLARE
            secret constant text := '(password|passwd|secret|token|pin_hash|api_key|private_key)';
        BEGIN
            IF ns IS NULL OR NOT EXISTS (SELECT 1 FROM plugin_event_subscriptions
                                         WHERE subscriber = 'core.audit' AND event IN (ev, ent || '.*')) THEN
                RETURN;
            END IF;
            IF old_v IS NOT NULL THEN
                old_v := old_v - ARRAY(SELECT k FROM jsonb_object_keys(old_v) k WHERE k ~* secret);
            END IF;
            IF new_v IS NOT NULL THEN
                new_v := new_v - ARRAY(SELECT k FROM jsonb_object_keys(new_v) k WHERE k ~* secret);
            END IF;
            INSERT INTO audit_events (uuid, namespace_id, event_type, entity_type, entity_id, actor_user_uuid,
                                      actor_ip, old_values, new_values, metadata, created_at)
            VALUES (gen_random_uuid()::text, ns, ev, ent, ent_id,
                    NULLIF(current_setting('opsapi.actor_uuid', true), ''),
                    NULLIF(current_setting('opsapi.actor_ip', true), ''),
                    old_v, new_v,
                    jsonb_strip_nulls(jsonb_build_object(
                        'source', 'db',
                        'via', COALESCE(NULLIF(current_setting('opsapi.actor_via', true), ''), 'system'),
                        'request_id', NULLIF(current_setting('opsapi.request_id', true), ''),
                        'api_key_uuid', NULLIF(current_setting('opsapi.api_key_uuid', true), ''))),
                    now() AT TIME ZONE 'UTC');
        END
        $fn$
    ]==])

    -- Does row r satisfy a verb's condition? Every column must equal its value
    -- (or be one of the values of an array).
    q([==[
        CREATE OR REPLACE FUNCTION opsapi_event_match(r jsonb, cond jsonb) RETURNS boolean
        LANGUAGE sql IMMUTABLE AS $fn$
            SELECT NOT EXISTS (
                SELECT 1 FROM jsonb_each(cond) c(k, v)
                WHERE NOT COALESCE(CASE jsonb_typeof(v)
                    WHEN 'array' THEN EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE x = r -> k)
                    ELSE v = r -> k END, false))
        $fn$
    ]==])

    -- args: entity, hidden columns, namespace SQL, namespace key column, verbs
    q([==[
        CREATE OR REPLACE FUNCTION opsapi_plugin_event() RETURNS trigger LANGUAGE plpgsql AS $fn$
        DECLARE
            entity text := TG_ARGV[0];
            ev text := TG_ARGV[0] || '.' || CASE TG_OP WHEN 'INSERT' THEN 'created'
                                                      WHEN 'UPDATE' THEN 'updated' ELSE 'deleted' END;
            hide text[] := string_to_array(NULLIF(TG_ARGV[1], ''), ',');
            verbs jsonb := COALESCE(NULLIF(TG_ARGV[4], ''), '{}')::jsonb;
            names text[];
            e_name text;
            d jsonb;
            old_d jsonb;
            diff jsonb;
            ns bigint;
            ev_id bigint;
        BEGIN
            -- Never let eventing fail the business write.
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM plugin_event_subscriptions
                               WHERE event IN (ev, entity || '.*')
                                  OR (TG_OP <> 'DELETE' AND left(event, length(entity) + 1) = entity || '.'
                                      AND verbs ? substr(event, length(entity) + 2))) THEN
                    RETURN NULL;
                END IF;
                IF TG_OP = 'DELETE' THEN d := to_jsonb(OLD); ELSE d := to_jsonb(NEW); END IF;
                -- (namespace resolved below; subscribers are re-checked against it)
                IF TG_OP = 'UPDATE' THEN
                    old_d := to_jsonb(OLD);
                    SELECT jsonb_object_agg(n.key, jsonb_build_object('from', o.value, 'to', n.value))
                    INTO diff
                    FROM jsonb_each(d) n JOIN jsonb_each(old_d) o ON o.key = n.key
                    WHERE n.value IS DISTINCT FROM o.value AND n.key <> 'updated_at'
                      AND NOT (n.key = ANY (COALESCE(hide, '{}')));
                    IF diff IS NULL THEN RETURN NULL; END IF; -- only updated_at/hidden columns changed
                END IF;
                -- Business events: the row entered a verb's state (on UPDATE: it
                -- wasn't in that state before).
                names := ARRAY[ev];
                IF TG_OP <> 'DELETE' AND verbs <> '{}'::jsonb THEN
                    SELECT names || COALESCE(array_agg(entity || '.' || v.key ORDER BY v.key), '{}')
                    INTO names
                    FROM jsonb_each(verbs) v
                    WHERE opsapi_event_match(d, v.value)
                      AND (old_d IS NULL OR NOT opsapi_event_match(old_d, v.value));
                END IF;
                IF hide IS NOT NULL THEN d := d - hide; END IF;
                IF COALESCE(TG_ARGV[2], '') <> '' THEN
                    EXECUTE TG_ARGV[2] INTO ns USING d ->> TG_ARGV[3];
                ELSE
                    ns := (d ->> 'namespace_id')::bigint;
                END IF;
                -- Audit trail: same transaction as the change. Updates keep only
                -- the changed fields (before -> after). Business events aren't
                -- audited separately: the update that caused them is.
                PERFORM opsapi_audit(ev, entity, COALESCE(d ->> 'uuid', d ->> 'id'), ns,
                    CASE TG_OP WHEN 'INSERT' THEN NULL
                               WHEN 'UPDATE' THEN (SELECT jsonb_object_agg(k, v -> 'from') FROM jsonb_each(diff) x(k, v))
                               ELSE d END,
                    CASE TG_OP WHEN 'DELETE' THEN NULL
                               WHEN 'UPDATE' THEN (SELECT jsonb_object_agg(k, v -> 'to') FROM jsonb_each(diff) x(k, v))
                               ELSE d END);
                -- One outbox row per event someone wants. Plugins (namespace_id
                -- NULL) hear every tenant where they're on; a webhook only its own.
                FOREACH e_name IN ARRAY names LOOP
                    IF EXISTS (SELECT 1 FROM plugin_event_subscriptions
                               WHERE event IN (e_name, entity || '.*') AND subscriber <> 'core.audit'
                                 AND (namespace_id IS NULL OR namespace_id = ns)
                                 AND (ns IS NULL OR left(subscriber, 8) = 'webhook.'
                                      OR opsapi_plugin_enabled(split_part(subscriber, '.', 1), ns))) THEN
                        INSERT INTO plugin_events (event, entity, entity_id, namespace_id, data, changes)
                        VALUES (e_name, entity, COALESCE(d ->> 'uuid', d ->> 'id'), ns, d, diff)
                        RETURNING id INTO ev_id;
                        INSERT INTO plugin_event_deliveries (event_id, subscriber)
                        SELECT ev_id, subscriber FROM plugin_event_subscriptions
                        WHERE event IN (e_name, entity || '.*') AND subscriber <> 'core.audit'
                          AND (namespace_id IS NULL OR namespace_id = ns)
                          AND (ns IS NULL OR left(subscriber, 8) = 'webhook.'
                               OR opsapi_plugin_enabled(split_part(subscriber, '.', 1), ns));
                    END IF;
                END LOOP;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'opsapi_plugin_event(%): %', ev, SQLERRM;
            END;
            RETURN NULL;
        END
        $fn$
    ]==])

    -- Core sources (catalog changes are picked up here).
    local keep = {}
    for _, s in ipairs(PluginEvents.CATALOG) do
        PluginEvents.upsertSource(s.entity, s.table, "core", s.hide, s.ns_sql, s.ns_key, s.module, s.verbs)
        keep[#keep + 1] = db().escape_literal(s.entity)
    end
    q("DELETE FROM plugin_event_sources WHERE owner = 'core' AND entity NOT IN (" .. table.concat(keep, ", ") .. ")")
end

function PluginEvents.upsertSource(entity, table_name, owner, hide, ns_sql, ns_key, module, verbs)
    local err = PluginEvents.checkVerbs(verbs)
    if err then error(entity .. ": " .. err, 0) end
    db().query([[
        INSERT INTO plugin_event_sources (entity, table_name, owner, hide, ns_sql, ns_key, module, verbs)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?::jsonb)
        ON CONFLICT (entity) DO UPDATE SET table_name = EXCLUDED.table_name, owner = EXCLUDED.owner,
            hide = EXCLUDED.hide, ns_sql = EXCLUDED.ns_sql, ns_key = EXCLUDED.ns_key,
            module = EXCLUDED.module, verbs = EXCLUDED.verbs, updated_at = NOW()
    ]], entity, table_name, owner, hide or "", ns_sql or "", ns_key or "", module or db().NULL,
        next(verbs or {}) and cjson.encode(verbs) or "{}")
end

--- The "core.audit" subscriptions: every source (core and plugin) while the
-- audit trail is on, none when OPSAPI_AUDIT_ENABLED=false. Run syncTriggers
-- after it.
--- Core subscribers that are code, not plugins: Billing & Entitlements
-- emails and jobs (lib/billing-jobs.lua). Synced on every migrate.
local CORE_SUBSCRIPTIONS = {
    { feature = "billing", subscriber = "core.billing",
      events = { "billing.access_link.requested", "billing.licence_key.requested" } },
}
function PluginEvents.syncCore()
    local ProjectConfig = require("helper.project-config")
    for _, c in ipairs(CORE_SUBSCRIPTIONS) do
        if ProjectConfig.isFeatureEnabled(c.feature) then
            for _, e in ipairs(c.events) do
                db().query([[INSERT INTO plugin_event_subscriptions (event, subscriber) VALUES (?, ?)
                    ON CONFLICT DO NOTHING]], e, c.subscriber)
            end
        end
    end
end

function PluginEvents.syncAudit()
    local d = db()
    if PluginEvents.auditEnabled() then
        d.query([[
            INSERT INTO plugin_event_subscriptions (event, subscriber)
            SELECT entity || '.*', 'core.audit' FROM plugin_event_sources
            ON CONFLICT DO NOTHING
        ]])
        d.query([[
            DELETE FROM plugin_event_subscriptions s WHERE s.subscriber = 'core.audit'
              AND NOT EXISTS (SELECT 1 FROM plugin_event_sources src WHERE src.entity || '.*' = s.event)
        ]])
    else
        d.query("DELETE FROM plugin_event_subscriptions WHERE subscriber = 'core.audit'")
    end
end

--- Sync one plugin: the entities it publishes (manifest.publishes) and the
-- events its events/*.lua files subscribe to. Raises on a broken events file
-- so the deploy stops, like a failed migration.
function PluginEvents.syncPlugin(manifest)
    local d = db()
    local prefix = manifest.code .. "."

    local modules = {}
    for _, m in ipairs(manifest.modules) do modules[m.machine_name] = true end
    local entities = {}
    for name, spec in pairs(manifest.publishes) do
        -- By convention (make:resource) a table's RBAC module shares its name.
        PluginEvents.upsertSource(prefix .. name, spec.table, manifest.code, nil, nil, nil,
            modules[spec.table] and spec.table or nil, spec.verbs)
        entities[#entities + 1] = d.escape_literal(prefix .. name)
    end
    d.query("DELETE FROM plugin_event_sources WHERE owner = " .. d.escape_literal(manifest.code)
        .. (#entities > 0 and (" AND entity NOT IN (" .. table.concat(entities, ", ") .. ")") or ""))

    local subscribers, errors = PluginEvents.loadSubscribers(manifest)
    if #errors > 0 then
        error(manifest.code .. ": " .. table.concat(errors, "; "), 0)
    end
    for subscriber, handlers in pairs(subscribers) do
        for event in pairs(handlers) do
            d.query([[
                INSERT INTO plugin_event_subscriptions (event, subscriber) VALUES (?, ?)
                ON CONFLICT DO NOTHING
            ]], event, subscriber)
        end
    end
    -- Handlers that no longer exist: drop their subscriptions, then anything
    -- still queued that no remaining subscription of that subscriber wants.
    for _, sub in ipairs(d.query("SELECT event, subscriber FROM plugin_event_subscriptions WHERE "
        .. owned_by("subscriber", manifest.code))) do
        if not (subscribers[sub.subscriber] and subscribers[sub.subscriber][sub.event]) then
            d.query("DELETE FROM plugin_event_subscriptions WHERE event = ? AND subscriber = ?", sub.event, sub.subscriber)
        end
    end
    d.query([[
        DELETE FROM plugin_event_deliveries d USING plugin_events e
        WHERE d.event_id = e.id AND d.status IN ('pending', 'running') AND ]] .. owned_by("d.subscriber", manifest.code) .. [[
          AND NOT EXISTS (SELECT 1 FROM plugin_event_subscriptions s
                          WHERE s.subscriber = d.subscriber AND s.event IN (e.event, e.entity || '.*'))
    ]])
end

--- Put the trigger on every source table someone subscribes to, and take it
-- off the rest (no cost for tables nobody listens to). Missing tables (a
-- feature not enabled in this deployment) are skipped.
function PluginEvents.syncTriggers()
    local d = db()
    local sources = d.query([[
        SELECT s.*, s.verbs::text AS verbs_text, to_regclass(s.table_name) IS NOT NULL AS present,
               EXISTS (SELECT 1 FROM plugin_event_subscriptions sub
                       WHERE sub.event ~ ('^' || replace(s.entity, '.', '\.')
                                          || '\.(created|updated|deleted|\*)$')
                          OR (left(sub.event, length(s.entity) + 1) = s.entity || '.'
                              AND s.verbs ? substr(sub.event, length(s.entity) + 2))) AS wanted,
               (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
                WHERE t.tgname = 'opsapi_plugin_event' AND t.tgrelid = to_regclass(s.table_name)) AS current
        FROM plugin_event_sources s
    ]])
    for _, s in ipairs(sources) do
        local present, wanted = s.present, s.wanted
        local current = s.current ~= d.NULL and s.current or nil
        local call = "opsapi_plugin_event(" .. table.concat({
            d.escape_literal(s.entity), d.escape_literal(s.hide), d.escape_literal(s.ns_sql), d.escape_literal(s.ns_key),
            d.escape_literal(s.verbs_text),
        }, ", ") .. ")"
        local T = d.escape_identifier(s.table_name)
        if present and wanted then
            if not (current and current:find(call, 1, true)) then
                d.query("DROP TRIGGER IF EXISTS opsapi_plugin_event ON " .. T)
                local ok, err = pcall(d.query, "CREATE TRIGGER opsapi_plugin_event AFTER INSERT OR UPDATE OR DELETE ON "
                    .. T .. " FOR EACH ROW EXECUTE FUNCTION " .. call)
                -- Another request/pod created it between our DROP and CREATE: fine.
                if not ok and not tostring(err):find("already exists", 1, true) then error(err, 0) end
                print("[PluginEvents] listening to " .. s.table_name .. " (" .. s.entity .. ")")
            end
        elseif present and current then
            d.query("DROP TRIGGER IF EXISTS opsapi_plugin_event ON " .. T)
            print("[PluginEvents] stopped listening to " .. s.table_name .. " (no subscribers)")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Custom events
-- ---------------------------------------------------------------------------

local function is_core_entity(entity)
    for _, s in ipairs(PluginEvents.CATALOG) do
        if entity == s.entity or entity:sub(1, #s.entity + 1) == s.entity .. "." then
            return true
        end
    end
    return false
end

-- Checked before emit() calls it, so an unmigrated database can't abort the
-- caller's transaction; re-checked every minute until present.
local _audit_fn, _audit_checked = nil, 0
local function audit_function_ready()
    if _audit_fn then return true end
    local now = ngx and ngx.now() or os.time()
    if now - _audit_checked < 60 then return false end
    _audit_checked = now
    local ok, rows = pcall(db().query,
        "SELECT to_regprocedure('opsapi_audit(text,text,text,bigint,jsonb,jsonb)') IS NOT NULL AS ok")
    _audit_fn = ok and rows[1] and rows[1].ok or nil
    return _audit_fn == true
end

--- Publish a custom event to its subscribers (one statement: the event is
-- only stored when someone listens). Core entity names are reserved.
-- @return number of deliveries queued
local insert_event

function PluginEvents.emit(namespace_id, name, data)
    assert(type(name) == "string" and name:match(EVENT_KEY) and not name:find("*", 1, true),
        "event name must look like <plugin>.<entity>.<action>")
    local entity = name:match("^(.*)%.[^.]+$")
    assert(not is_core_entity(entity), "'" .. name .. "' is a core event; core events come from table changes")
    return insert_event(namespace_id, name, entity, data)
end

--- Publish one of PluginEvents.COMPUTED (core code only).
function PluginEvents.emitCore(namespace_id, name, data)
    local entity, action = name:match("^(.*)%.([^.]+)$")
    local known = false
    for _, a in ipairs(PluginEvents.COMPUTED[entity or ""] or {}) do known = known or a == action end
    assert(known, "'" .. tostring(name) .. "' is not a computed core event")
    return insert_event(namespace_id, name, entity, data)
end

insert_event = function(namespace_id, name, entity, data)
    -- Audit trail (no-op unless "core.audit" subscribes and there is a workspace).
    if namespace_id and audit_function_ready() then
        pcall(db().query, "SELECT opsapi_audit(?, ?, NULL, ?, NULL, ?::jsonb)", name, entity, namespace_id,
            cjson.encode(data or {}))
    end
    local res = db().query([[
        WITH subs AS (
            SELECT subscriber FROM plugin_event_subscriptions
            WHERE event IN (?, ?) AND subscriber <> 'core.audit' AND (namespace_id IS NULL OR namespace_id = ?)
              AND (?::bigint IS NULL OR left(subscriber, 8) = 'webhook.'
                   OR opsapi_plugin_enabled(split_part(subscriber, '.', 1), ?::bigint))
        ), ev AS (
            INSERT INTO plugin_events (event, entity, namespace_id, data)
            SELECT ?, ?, ?, ?::jsonb WHERE EXISTS (SELECT 1 FROM subs)
            RETURNING id
        )
        INSERT INTO plugin_event_deliveries (event_id, subscriber)
        SELECT ev.id, subs.subscriber FROM ev, subs
    ]], name, entity .. ".*", namespace_id or db().NULL, namespace_id or db().NULL, namespace_id or db().NULL,
        name, entity, namespace_id or db().NULL, cjson.encode(data or {}))
    return res.affected_rows or 0
end

-- ---------------------------------------------------------------------------
-- Dispatcher (started per worker from nginx.conf init_worker_by_lua)
-- ---------------------------------------------------------------------------

local _handlers = {}  -- { [subscriber] = { [event] = fn } }
local _manifests = {} -- { [plugin code] = manifest } (event.settings)
local _failures = {}  -- { { code, errors } } events files that failed to load
local _busy = false

--- events/*.lua files that failed to load in this worker (for /ready).
function PluginEvents.failures()
    return _failures
end

local function strip_nulls(t)
    if type(t) ~= "table" then return t end
    for k, v in pairs(t) do
        if v == cjson.null then
            t[k] = nil
        else
            strip_nulls(v)
        end
    end
    return t
end

local function decode(v)
    if type(v) == "string" then v = cjson.decode(v) end
    return strip_nulls(v)
end

-- response_status / duration_ms: set for webhook deliveries.
local function finish(delivery_id, ok, err, response_status, duration_ms)
    local d = db()
    local status, ms = response_status or d.NULL, duration_ms or d.NULL
    if ok then
        d.query([[
            UPDATE plugin_event_deliveries SET status = 'done', last_error = NULL, response_status = ?,
                duration_ms = ?, updated_at = NOW()
            WHERE id = ?
        ]], status, ms, delivery_id)
    else
        d.query([[
            UPDATE plugin_event_deliveries
            SET status = CASE WHEN attempts >= ? THEN 'dead' ELSE 'pending' END,
                next_attempt_at = NOW() + make_interval(secs => LEAST(3600, 15 * power(2, attempts - 1))),
                last_error = ?, response_status = ?, duration_ms = ?, updated_at = NOW()
            WHERE id = ?
        ]], PluginEvents.MAX_ATTEMPTS, tostring(err):sub(1, 2000), status, ms, delivery_id)
    end
end

local function process_batch()
    local d = db()
    local subscribers = {}
    for subscriber in pairs(_handlers) do
        subscribers[#subscribers + 1] = d.escape_literal(subscriber)
    end
    local mine = "left(subscriber, 8) = 'webhook.'"
    if #subscribers > 0 then
        mine = "(" .. mine .. " OR subscriber IN (" .. table.concat(subscribers, ", ") .. "))"
    end
    -- Inline literals only: no "?" placeholders in this statement.
    local claimed = d.query([[
        UPDATE plugin_event_deliveries d
        SET status = 'running', attempts = d.attempts + 1, updated_at = NOW(),
            next_attempt_at = NOW() + interval ']] .. LOCK_SECONDS .. [[ seconds'
        WHERE d.id IN (
            SELECT id FROM plugin_event_deliveries
            WHERE status IN ('pending', 'running') AND next_attempt_at <= NOW()
              AND ]] .. mine .. [[
            ORDER BY id
            LIMIT ]] .. BATCH .. [[
            FOR UPDATE SKIP LOCKED
        )
        RETURNING d.id, d.event_id, d.subscriber, d.attempts
    ]])
    if #claimed == 0 then return 0 end

    local ids = {}
    for i, c in ipairs(claimed) do ids[i] = tonumber(c.event_id) end
    local events = {}
    for _, e in ipairs(d.query("SELECT * FROM plugin_events WHERE id IN (" .. table.concat(ids, ",") .. ")")) do
        events[tonumber(e.id)] = e
    end

    for _, c in ipairs(claimed) do
        local e = events[tonumber(c.event_id)]
        local webhook_uuid = c.subscriber:match("^webhook%.(.+)$")
        if webhook_uuid then
            -- Workspace webhooks: an HTTP POST (lib/outbound-webhooks.lua).
            local ok, err, status, ms = require("lib.outbound-webhooks").deliverEvent(webhook_uuid, e, c)
            finish(c.id, ok, err, status, ms)
            goto next_delivery
        end
        do
        local handlers = _handlers[c.subscriber] or {}
        local handler = e and (handlers[e.event] or handlers[e.entity .. ".*"])
        if not handler then
            -- Subscribed in the database but not in this worker's code (e.g.
            -- mid rolling deploy): hand it back for a worker that has it.
            d.query([[
                UPDATE plugin_event_deliveries SET status = 'pending', attempts = attempts - 1,
                    next_attempt_at = NOW() + interval '30 seconds', updated_at = NOW()
                WHERE id = ?
            ]], c.id)
        else
            local event = {
                id = e.uuid,
                name = e.event,
                entity = e.entity,
                entity_id = e.entity_id ~= d.NULL and e.entity_id or nil,
                namespace_id = e.namespace_id ~= d.NULL and tonumber(e.namespace_id) or nil,
                data = decode(e.data ~= d.NULL and e.data or nil),
                changes = decode(e.changes ~= d.NULL and e.changes or nil),
                occurred_at = e.created_at,
                attempt = tonumber(c.attempts),
            }
            -- event.settings: the workspace's settings for this plugin, read on first use.
            local manifest = _manifests[c.subscriber:match("^([^.]+)")]
            setmetatable(event, { __index = function(t, k)
                if k ~= "settings" then return nil end
                local v = manifest and require("helper.plugin-workspaces").settings(manifest, t.namespace_id) or {}
                rawset(t, "settings", v)
                return v
            end })
            local ok, result, message = pcall(handler, event)
            if ok and result == false then
                ok, result = false, message or "handler returned false"
            end
            if not ok then
                ngx.log(ngx.WARN, "[plugin-events] ", c.subscriber, " ", e.event, " attempt ", c.attempts,
                    " failed: ", tostring(result))
            end
            if PluginEvents.resetTransaction() and ok then
                ok, result = false, "handler left a transaction open; it was rolled back"
            end
            finish(c.id, ok, result)
        end
        end
        ::next_delivery::
    end
    return #claimed
end

--- Roll back a transaction a handler left open (or aborted by an error), so
-- the statements after it - recording the result - can run.
-- @return true when there was one to roll back
function PluginEvents.resetTransaction()
    local d = db()
    local ok, rows = pcall(d.query, "SELECT now() <> statement_timestamp() AS open")
    if ok and not rows[1].open then return false end
    pcall(d.query, "ROLLBACK")
    return true
end

-- Timers don't run lapis' after-dispatch hook, so hand the connection back
-- to the pool ourselves — after rolling back anything a handler left open.
local function release_connection()
    pcall(function()
        local d = db()
        if d.query("SELECT now() <> statement_timestamp() AS open")[1].open then
            d.query("ROLLBACK")
        end
    end)
    pcall(require("lapis.nginx.context").run_after_dispatch)
end

PluginEvents.releaseConnection = release_connection

local function tick(premature)
    if premature or _busy then return end
    _busy = true
    -- Drain while there's work, then wait for the next tick.
    local ok, err = pcall(function()
        for _ = 1, 10 do
            if process_batch() < BATCH then break end
        end
    end)
    release_connection()
    _busy = false
    if not ok then
        ngx.log(ngx.ERR, "[plugin-events] dispatch failed: ", tostring(err))
    end
end

local function purge(premature)
    if premature then return end
    local d = db()
    local ok, err = pcall(function()
        -- One pod at a time (transaction lock: released even if this fails).
        d.query("BEGIN")
        if d.query("SELECT pg_try_advisory_xact_lock(hashtext('opsapi.plugin_events.purge')) AS l")[1].l then
            d.query([[
                DELETE FROM plugin_event_deliveries WHERE id IN (
                    SELECT id FROM plugin_event_deliveries
                    WHERE (status = 'done' AND updated_at < NOW() - interval '7 days')
                       OR (status = 'dead' AND updated_at < NOW() - interval '30 days')
                    LIMIT 10000)
            ]])
            d.query(([[
                DELETE FROM audit_events WHERE id IN (
                    SELECT id FROM audit_events
                    WHERE created_at < (now() AT TIME ZONE 'UTC') - interval '%d days'
                      AND metadata ->> 'source' = 'db'
                    LIMIT 10000)
            ]]):format(audit_retention_days()))
            d.query([[
                DELETE FROM plugin_events WHERE id IN (
                    SELECT e.id FROM plugin_events e
                    WHERE e.created_at < NOW() - interval '1 hour'
                      AND NOT EXISTS (SELECT 1 FROM plugin_event_deliveries d WHERE d.event_id = e.id)
                    LIMIT 10000)
            ]])
        end
        d.query("COMMIT")
    end)
    release_connection()
    if not ok then
        ngx.log(ngx.ERR, "[plugin-events] purge failed: ", tostring(err))
    end
end

--- Load every plugin's events/*.lua and start polling for deliveries
-- (plugin handlers and workspace webhooks).
function PluginEvents.start(projects_root)
    local ProjectLoader = require("helper.project-loader")
    for _, entry in ipairs(ProjectLoader.discover(projects_root)) do
        local manifest = ProjectLoader.loadManifest(entry.manifest_path, entry.path)
        if manifest and manifest.enabled and not ProjectLoader.isReservedCode(manifest.code) then
            _manifests[manifest.code] = manifest
            local subscribers, errors = PluginEvents.loadSubscribers(manifest)
            for subscriber, handlers in pairs(subscribers) do
                _handlers[subscriber] = handlers
            end
            if #errors > 0 then
                table.insert(_failures, { code = manifest.code, errors = errors })
                ngx.log(ngx.ERR, "[plugin-events] ", manifest.code, ": ", table.concat(errors, "; "))
            end
        end
    end
    -- Billing & Entitlements: its emails and jobs run from this outbox.
    if require("helper.project-config").isFeatureEnabled("billing") then
        local ok_jobs, jobs = pcall(require, "lib.billing-jobs")
        if ok_jobs then
            _handlers["core.billing"] = jobs.handlers
            if ngx.worker.id() == 0 then ngx.timer.every(300, jobs.maintain) end
        else
            ngx.log(ngx.ERR, "[plugin-events] billing jobs failed to load: ", tostring(jobs))
        end
    end
    -- Always poll: workspace webhooks are deliveries too, plugins or not.
    ngx.timer.every(POLL_SECONDS, tick)
    if ngx.worker.id() == 0 then
        ngx.timer.every(600, purge)
    end
end

-- ---------------------------------------------------------------------------
-- Admin (GET /api/v2/plugins/:code, POST .../events/retry)
-- ---------------------------------------------------------------------------

local function events_ready()
    return db().query("SELECT to_regclass('plugin_event_deliveries') IS NOT NULL AS ok")[1].ok
end

function PluginEvents.stats(code)
    if not events_ready() then return nil end
    local d = db()
    local where = owned_by("subscriber", code)
    local counts = { pending = 0, running = 0, done = 0, dead = 0 }
    for _, r in ipairs(d.query("SELECT status, COUNT(*)::int AS n FROM plugin_event_deliveries WHERE "
        .. where .. " GROUP BY status")) do
        counts[r.status] = r.n
    end
    return {
        subscriptions = d.query("SELECT event, subscriber FROM plugin_event_subscriptions WHERE "
            .. where .. " ORDER BY event, subscriber"),
        publishes = d.query("SELECT entity, table_name FROM plugin_event_sources WHERE owner = "
            .. d.escape_literal(code) .. " ORDER BY entity"),
        deliveries = counts,
        failures = d.query([[
            SELECT d.id, e.event, d.subscriber, d.status, d.attempts, d.last_error, d.updated_at
            FROM plugin_event_deliveries d JOIN plugin_events e ON e.id = d.event_id
            WHERE d.last_error IS NOT NULL AND ]] .. owned_by("d.subscriber", code) .. [[
            ORDER BY d.updated_at DESC LIMIT 20
        ]]),
    }
end

--- Re-queue a plugin's dead deliveries (after fixing the handler).
function PluginEvents.retryDead(code)
    if not events_ready() then return 0 end
    local d = db()
    local res = d.query([[
        UPDATE plugin_event_deliveries SET status = 'pending', attempts = 0, next_attempt_at = NOW(), updated_at = NOW()
        WHERE status = 'dead' AND ]] .. owned_by("subscriber", code))
    return res.affected_rows or 0
end

return PluginEvents
