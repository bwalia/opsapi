--[[
    Workspace webhooks — storage, subscriptions, delivery log
    =========================================================
    A webhook row (namespace_webhooks) is mirrored into
    plugin_event_subscriptions as subscriber "webhook.<uuid>" with its
    namespace_id, so helper.plugin-events only queues events of that
    workspace for it. Sending: lib/outbound-webhooks.lua. Routes:
    routes/namespace-webhooks.lua. Every function takes the caller's
    namespace id and filters by it.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")
local Webhooks = require("lib.outbound-webhooks")
local PluginEvents = require("helper.plugin-events")

local NamespaceWebhookQueries = {}

NamespaceWebhookQueries.MAX_PER_NAMESPACE = 25
local MAX_EVENTS = 100
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function array(t)
    return setmetatable(t or {}, cjson.array_mt)
end

local function subscriber(row)
    return "webhook." .. row.uuid
end

-- Public shape: never the secret.
local function public(row)
    local events = row.events
    if type(events) == "string" then events = cjson.decode(events) end
    local last = row.last_delivery
    if type(last) == "string" then last = cjson.decode(last) end
    return {
        uuid = row.uuid,
        url = row.url,
        description = row.description,
        events = array(events),
        is_active = row.is_active,
        created_at = row.created_at,
        updated_at = row.updated_at,
        last_delivery = last,
        pending_count = row.pending_count,
        dead_count = row.dead_count,
    }
end

-- ---------------------------------------------------------------------------
-- Events a workspace can subscribe to
-- ---------------------------------------------------------------------------

--- Entities whose tables exist here, each marked `allowed` when the caller
-- may read its RBAC module (can_read(module) -> bool).
function NamespaceWebhookQueries.availableEvents(can_read)
    local out = {}
    for _, r in ipairs(db.query([[
        SELECT entity, owner, module FROM plugin_event_sources
        WHERE to_regclass(table_name) IS NOT NULL
        ORDER BY owner <> 'core', entity
    ]])) do
        out[#out + 1] = {
            entity = r.entity,
            owner = r.owner,
            allowed = r.module == nil or can_read(r.module),
            events = array({ r.entity .. ".created", r.entity .. ".updated", r.entity .. ".deleted" }),
        }
    end
    return array(out)
end

-- Validate the requested event list. Returns the clean list or nil, message.
local function check_events(events, can_read)
    if type(events) ~= "table" or #events == 0 then return nil, "choose at least one event" end
    if #events > MAX_EVENTS then return nil, "at most " .. MAX_EVENTS .. " events" end
    local allowed = {}
    for _, a in ipairs(NamespaceWebhookQueries.availableEvents(can_read)) do
        allowed[a.entity] = a.allowed
    end
    local clean, seen = {}, {}
    for _, event in ipairs(events) do
        if type(event) ~= "string" then return nil, "unknown event " .. tostring(event) end
        local entity, action = event:match("^(.+)%.([%a*]+)$")
        if not entity or not (action == "created" or action == "updated" or action == "deleted" or action == "*") then
            return nil, "unknown event " .. tostring(event)
        end
        if allowed[entity] == nil then return nil, "unknown event " .. event end
        if allowed[entity] == false then
            return nil, "you don't have read access to " .. entity .. " data"
        end
        if not seen[event] then
            seen[event] = true
            clean[#clean + 1] = event
        end
    end
    table.sort(clean)
    return clean
end

-- ---------------------------------------------------------------------------
-- Subscriptions
-- ---------------------------------------------------------------------------

-- Mirror a webhook into plugin_event_subscriptions (none while inactive),
-- drop queued deliveries it no longer wants, and (un)install table triggers.
local function sync(row, removing)
    local sub = subscriber(row)
    local events = row.events
    if type(events) == "string" then events = cjson.decode(events) end

    db.query("BEGIN")
    local ok, err = pcall(function()
        db.query("DELETE FROM plugin_event_subscriptions WHERE subscriber = ?", sub)
        if row.is_active and not removing then
            for _, event in ipairs(events) do
                db.query([[
                    INSERT INTO plugin_event_subscriptions (event, subscriber, namespace_id) VALUES (?, ?, ?)
                    ON CONFLICT DO NOTHING
                ]], event, sub, row.namespace_id)
            end
        end
        if removing then
            db.query("DELETE FROM plugin_event_deliveries WHERE subscriber = ?", sub)
        else
            db.query([[
                DELETE FROM plugin_event_deliveries d USING plugin_events e
                WHERE d.event_id = e.id AND d.subscriber = ? AND d.status IN ('pending', 'running')
                  AND NOT EXISTS (SELECT 1 FROM plugin_event_subscriptions s
                                  WHERE s.subscriber = d.subscriber AND s.event IN (e.event, e.entity || '.*'))
            ]], sub)
        end
        PluginEvents.syncTriggers()
    end)
    db.query(ok and "COMMIT" or "ROLLBACK")
    if not ok then error(err, 0) end
end

-- ---------------------------------------------------------------------------
-- CRUD
-- ---------------------------------------------------------------------------

local function find_row(ns, uuid)
    if type(uuid) ~= "string" or not uuid:match(UUID) then return nil end
    return db.query("SELECT * FROM namespace_webhooks WHERE namespace_id = ? AND uuid = ?", ns, uuid)[1]
end

function NamespaceWebhookQueries.list(ns)
    local rows = db.query([[
        SELECT w.*,
            (SELECT row_to_json(x) FROM (
                SELECT d.status, d.response_status, d.updated_at, e.event
                FROM plugin_event_deliveries d JOIN plugin_events e ON e.id = d.event_id
                WHERE d.subscriber = 'webhook.' || w.uuid
                ORDER BY d.id DESC LIMIT 1) x) AS last_delivery,
            (SELECT COUNT(*) FROM plugin_event_deliveries d
             WHERE d.subscriber = 'webhook.' || w.uuid AND d.status IN ('pending', 'running'))::int AS pending_count,
            (SELECT COUNT(*) FROM plugin_event_deliveries d
             WHERE d.subscriber = 'webhook.' || w.uuid AND d.status = 'dead')::int AS dead_count
        FROM namespace_webhooks w
        WHERE w.namespace_id = ?
        ORDER BY w.created_at DESC
    ]], ns)
    local out = {}
    for i, row in ipairs(rows) do out[i] = public(row) end
    return array(out)
end

function NamespaceWebhookQueries.find(ns, uuid)
    local row = find_row(ns, uuid)
    return row and public(row)
end

-- Returns the webhook and its secret (shown once), or nil + message.
function NamespaceWebhookQueries.create(ns, user_uuid, input, can_read)
    local _, why = Webhooks.parseUrl(input.url)
    if why then return nil, "url " .. why end
    local events, eerr = check_events(input.events, can_read)
    if not events then return nil, eerr end
    local count = db.query("SELECT COUNT(*)::int AS n FROM namespace_webhooks WHERE namespace_id = ?", ns)[1].n
    if count >= NamespaceWebhookQueries.MAX_PER_NAMESPACE then
        return nil, "a workspace can have at most " .. NamespaceWebhookQueries.MAX_PER_NAMESPACE .. " webhooks"
    end
    local secret = Webhooks.newSecret()
    local row = db.insert("namespace_webhooks", {
        namespace_id = ns,
        url = input.url,
        description = input.description or db.NULL,
        events = cjson.encode(events),
        encrypted_secret = Global.encryptSecret(secret),
        is_active = input.is_active ~= false,
        created_by_uuid = user_uuid or db.NULL,
    }, { returning = "*" })[1]
    sync(row)
    return public(row), secret
end

-- Partial update of url / description / events / is_active. Returns the
-- webhook, nil (not found) or nil + message.
function NamespaceWebhookQueries.update(ns, uuid, input, can_read)
    local row = find_row(ns, uuid)
    if not row then return nil end
    local changes = {}
    if input.url ~= nil then
        local _, why = Webhooks.parseUrl(input.url)
        if why then return nil, "url " .. why end
        changes.url = input.url
    end
    if input.events ~= nil then
        local events, eerr = check_events(input.events, can_read)
        if not events then return nil, eerr end
        changes.events = cjson.encode(events)
    end
    if input.description ~= nil then
        changes.description = input.description == cjson.null and db.NULL or input.description
    end
    if input.is_active ~= nil then changes.is_active = input.is_active == true end
    if next(changes) == nil then return public(row) end
    changes.updated_at = db.raw("NOW()")
    row = db.update("namespace_webhooks", changes, { id = row.id }, db.raw("*"))[1]
    sync(row)
    return public(row)
end

function NamespaceWebhookQueries.delete(ns, uuid)
    local row = find_row(ns, uuid)
    if not row then return false end
    sync(row, true)
    db.query("DELETE FROM namespace_webhooks WHERE id = ?", row.id)
    return true
end

-- Returns a new secret (shown once), or nil when not found.
function NamespaceWebhookQueries.rotateSecret(ns, uuid)
    local row = find_row(ns, uuid)
    if not row then return nil end
    local secret = Webhooks.newSecret()
    db.update("namespace_webhooks", {
        encrypted_secret = Global.encryptSecret(secret), updated_at = db.raw("NOW()"),
    }, { id = row.id })
    return secret
end

-- ---------------------------------------------------------------------------
-- Delivery log (kept 7 days when delivered, 30 when failed)
-- ---------------------------------------------------------------------------

function NamespaceWebhookQueries.deliveries(ns, uuid, params)
    local row = find_row(ns, uuid)
    if not row then return nil end
    local page = Global.pageParam(params.page)
    local per_page = Global.perPageParam(params.per_page or params.perPage, 20, 100)
    local status = params.status
    local where = "d.subscriber = " .. db.escape_literal(subscriber(row))
    if status == "done" or status == "dead" or status == "pending" or status == "running" then
        where = where .. " AND d.status = " .. db.escape_literal(status)
    end
    local rows = db.query([[
        SELECT d.id, e.uuid AS event_id, e.event, d.status, d.attempts, d.response_status, d.duration_ms,
               d.last_error, d.next_attempt_at, d.created_at, d.updated_at
        FROM plugin_event_deliveries d JOIN plugin_events e ON e.id = d.event_id
        WHERE ]] .. where .. [[
        ORDER BY d.id DESC
        LIMIT ]] .. per_page .. " OFFSET " .. ((page - 1) * per_page))
    local total = db.query("SELECT COUNT(*)::int AS n FROM plugin_event_deliveries d WHERE " .. where)[1].n
    return array(rows), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) }
end

-- Queue one delivery again now. Returns false when not found.
function NamespaceWebhookQueries.redeliver(ns, uuid, delivery_id)
    local row = find_row(ns, uuid)
    local id = tonumber(delivery_id)
    if not row or not id then return false end
    local res = db.query([[
        UPDATE plugin_event_deliveries
        SET status = 'pending', attempts = 0, next_attempt_at = NOW(), last_error = NULL, updated_at = NOW()
        WHERE id = ? AND subscriber = ?
    ]], id, subscriber(row))
    return (res.affected_rows or 0) > 0
end

return NamespaceWebhookQueries
