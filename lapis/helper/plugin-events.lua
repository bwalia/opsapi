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
]]

local cjson = require("cjson")

local PluginEvents = {}

PluginEvents.MAX_ATTEMPTS = 8
local LOCK_SECONDS = 300
local POLL_SECONDS = 2
local BATCH = 20

-- Core entities plugins can subscribe to. Only tables with a tenant: each
-- event carries a namespace_id (`ns_sql` resolves it for tables without the
-- column). `hide` = columns left out of payloads (comma-separated).
PluginEvents.CATALOG = {
    { entity = "customer", table = "customers" },
    { entity = "invoice", table = "invoices" },
    { entity = "invoice.payment", table = "invoice_payments" },
    { entity = "crm.account", table = "crm_accounts" },
    { entity = "crm.contact", table = "crm_contacts" },
    { entity = "crm.deal", table = "crm_deals" },
    { entity = "crm.lead", table = "crm_leads" },
    { entity = "crm.activity", table = "crm_activities" },
    { entity = "employee", table = "employees" },
    { entity = "timesheet", table = "timesheets" },
    { entity = "order", table = "orders" },
    { entity = "kanban.project", table = "kanban_projects" },
    {
        entity = "kanban.task", table = "kanban_tasks", hide = "search_vector", ns_key = "board_id",
        ns_sql = "SELECT p.namespace_id FROM kanban_boards b JOIN kanban_projects p ON p.id = b.project_id WHERE b.id = $1::int",
    },
    { entity = "fs.job", table = "fs_jobs" },
    { entity = "fs.visit", table = "fs_visits" },
    { entity = "member", table = "namespace_members" },
}

local EVENT_KEY = "^[a-z][a-z0-9_]*[a-z0-9_.]*%.[a-z0-9_*]+$"

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

    -- args: entity, hidden columns, namespace SQL, namespace key column
    q([==[
        CREATE OR REPLACE FUNCTION opsapi_plugin_event() RETURNS trigger LANGUAGE plpgsql AS $fn$
        DECLARE
            entity text := TG_ARGV[0];
            ev text := TG_ARGV[0] || '.' || CASE TG_OP WHEN 'INSERT' THEN 'created'
                                                      WHEN 'UPDATE' THEN 'updated' ELSE 'deleted' END;
            hide text[] := string_to_array(NULLIF(TG_ARGV[1], ''), ',');
            d jsonb;
            diff jsonb;
            ns bigint;
            ev_id bigint;
        BEGIN
            -- Never let eventing fail the business write.
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM plugin_event_subscriptions
                               WHERE event IN (ev, entity || '.*')) THEN
                    RETURN NULL;
                END IF;
                IF TG_OP = 'DELETE' THEN d := to_jsonb(OLD); ELSE d := to_jsonb(NEW); END IF;
                IF TG_OP = 'UPDATE' THEN
                    SELECT jsonb_object_agg(n.key, jsonb_build_object('from', o.value, 'to', n.value))
                    INTO diff
                    FROM jsonb_each(d) n JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
                    WHERE n.value IS DISTINCT FROM o.value AND n.key <> 'updated_at'
                      AND NOT (n.key = ANY (COALESCE(hide, '{}')));
                    IF diff IS NULL THEN RETURN NULL; END IF; -- only updated_at/hidden columns changed
                END IF;
                IF hide IS NOT NULL THEN d := d - hide; END IF;
                IF COALESCE(TG_ARGV[2], '') <> '' THEN
                    EXECUTE TG_ARGV[2] INTO ns USING d ->> TG_ARGV[3];
                ELSE
                    ns := (d ->> 'namespace_id')::bigint;
                END IF;
                INSERT INTO plugin_events (event, entity, entity_id, namespace_id, data, changes)
                VALUES (ev, entity, COALESCE(d ->> 'uuid', d ->> 'id'), ns, d, diff)
                RETURNING id INTO ev_id;
                INSERT INTO plugin_event_deliveries (event_id, subscriber)
                SELECT ev_id, subscriber FROM plugin_event_subscriptions WHERE event IN (ev, entity || '.*');
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
        PluginEvents.upsertSource(s.entity, s.table, "core", s.hide, s.ns_sql, s.ns_key)
        keep[#keep + 1] = db().escape_literal(s.entity)
    end
    q("DELETE FROM plugin_event_sources WHERE owner = 'core' AND entity NOT IN (" .. table.concat(keep, ", ") .. ")")
end

function PluginEvents.upsertSource(entity, table_name, owner, hide, ns_sql, ns_key)
    db().query([[
        INSERT INTO plugin_event_sources (entity, table_name, owner, hide, ns_sql, ns_key)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (entity) DO UPDATE SET table_name = EXCLUDED.table_name, owner = EXCLUDED.owner,
            hide = EXCLUDED.hide, ns_sql = EXCLUDED.ns_sql, ns_key = EXCLUDED.ns_key, updated_at = NOW()
    ]], entity, table_name, owner, hide or "", ns_sql or "", ns_key or "")
end

--- Sync one plugin: the entities it publishes (manifest.publishes) and the
-- events its events/*.lua files subscribe to. Raises on a broken events file
-- so the deploy stops, like a failed migration.
function PluginEvents.syncPlugin(manifest)
    local d = db()
    local prefix = manifest.code .. "."

    local entities = {}
    for name, table_name in pairs(manifest.publishes) do
        PluginEvents.upsertSource(prefix .. name, table_name, manifest.code)
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
        SELECT s.*, to_regclass(s.table_name) IS NOT NULL AS present,
               EXISTS (SELECT 1 FROM plugin_event_subscriptions sub
                       WHERE sub.event ~ ('^' || replace(s.entity, '.', '\.')
                                          || '\.(created|updated|deleted|\*)$')) AS wanted,
               (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
                WHERE t.tgname = 'opsapi_plugin_event' AND t.tgrelid = to_regclass(s.table_name)) AS current
        FROM plugin_event_sources s
    ]])
    for _, s in ipairs(sources) do
        local present, wanted = s.present, s.wanted
        local current = s.current ~= d.NULL and s.current or nil
        local call = "opsapi_plugin_event(" .. table.concat({
            d.escape_literal(s.entity), d.escape_literal(s.hide), d.escape_literal(s.ns_sql), d.escape_literal(s.ns_key),
        }, ", ") .. ")"
        local T = d.escape_identifier(s.table_name)
        if present and wanted then
            if not (current and current:find(call, 1, true)) then
                d.query("DROP TRIGGER IF EXISTS opsapi_plugin_event ON " .. T)
                d.query("CREATE TRIGGER opsapi_plugin_event AFTER INSERT OR UPDATE OR DELETE ON " .. T
                    .. " FOR EACH ROW EXECUTE FUNCTION " .. call)
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

--- Publish a custom event to its subscribers (one statement: the event is
-- only stored when someone listens). Core entity names are reserved.
-- @return number of deliveries queued
function PluginEvents.emit(namespace_id, name, data)
    assert(type(name) == "string" and name:match(EVENT_KEY) and not name:find("*", 1, true),
        "event name must look like <plugin>.<entity>.<action>")
    local entity = name:match("^(.*)%.[^.]+$")
    assert(not is_core_entity(entity), "'" .. name .. "' is a core event; core events come from table changes")
    local res = db().query([[
        WITH subs AS (
            SELECT subscriber FROM plugin_event_subscriptions WHERE event IN (?, ?)
        ), ev AS (
            INSERT INTO plugin_events (event, entity, namespace_id, data)
            SELECT ?, ?, ?, ?::jsonb WHERE EXISTS (SELECT 1 FROM subs)
            RETURNING id
        )
        INSERT INTO plugin_event_deliveries (event_id, subscriber)
        SELECT ev.id, subs.subscriber FROM ev, subs
    ]], name, entity .. ".*", name, entity, namespace_id or db().NULL, cjson.encode(data or {}))
    return res.affected_rows or 0
end

-- ---------------------------------------------------------------------------
-- Dispatcher (started per worker from nginx.conf init_worker_by_lua)
-- ---------------------------------------------------------------------------

local _handlers = {}  -- { [subscriber] = { [event] = fn } }
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

local function finish(delivery_id, ok, err)
    local d = db()
    if ok then
        d.query("UPDATE plugin_event_deliveries SET status = 'done', last_error = NULL, updated_at = NOW() WHERE id = ?",
            delivery_id)
    else
        d.query([[
            UPDATE plugin_event_deliveries
            SET status = CASE WHEN attempts >= ? THEN 'dead' ELSE 'pending' END,
                next_attempt_at = NOW() + make_interval(secs => LEAST(3600, 15 * power(2, attempts - 1))),
                last_error = ?, updated_at = NOW()
            WHERE id = ?
        ]], PluginEvents.MAX_ATTEMPTS, tostring(err):sub(1, 2000), delivery_id)
    end
end

local function process_batch()
    local d = db()
    local subscribers = {}
    for subscriber in pairs(_handlers) do
        subscribers[#subscribers + 1] = d.escape_literal(subscriber)
    end
    -- Inline literals only: no "?" placeholders in this statement.
    local claimed = d.query([[
        UPDATE plugin_event_deliveries d
        SET status = 'running', attempts = d.attempts + 1, updated_at = NOW(),
            next_attempt_at = NOW() + interval ']] .. LOCK_SECONDS .. [[ seconds'
        WHERE d.id IN (
            SELECT id FROM plugin_event_deliveries
            WHERE status IN ('pending', 'running') AND next_attempt_at <= NOW()
              AND subscriber IN (]] .. table.concat(subscribers, ", ") .. [[)
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
            local ok, result, message = pcall(handler, event)
            if ok and result == false then
                ok, result = false, message or "handler returned false"
            end
            if not ok then
                ngx.log(ngx.WARN, "[plugin-events] ", c.subscriber, " ", e.event, " attempt ", c.attempts,
                    " failed: ", tostring(result))
            end
            finish(c.id, ok, result)
        end
    end
    return #claimed
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

--- Load every plugin's events/*.lua and, if any handlers exist, start
-- polling. A worker with no handlers does nothing.
function PluginEvents.start(projects_root)
    local ProjectLoader = require("helper.project-loader")
    for _, entry in ipairs(ProjectLoader.discover(projects_root)) do
        local manifest = ProjectLoader.loadManifest(entry.manifest_path, entry.path)
        if manifest and manifest.enabled and not ProjectLoader.isReservedCode(manifest.code) then
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
    if next(_handlers) == nil then return end

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
