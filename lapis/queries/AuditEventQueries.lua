local AuditEventModel = require("models.AuditEventModel")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local AuditEventQueries = {}

-- Log an audit event
-- @param params table with: namespace_id, event_type, entity_type, entity_id,
--   actor_user_uuid, actor_ip, old_values, new_values, metadata, kafka_topic
-- @return AuditEvent record
function AuditEventQueries.log(params)
    local record = {
        uuid = Global.generateUUID(),
        namespace_id = params.namespace_id or 0,
        event_type = params.event_type,
        entity_type = params.entity_type,
        entity_id = params.entity_id,
        actor_user_uuid = params.actor_user_uuid,
        actor_ip = params.actor_ip,
        kafka_topic = params.kafka_topic,
        created_at = db.raw("NOW()"),
    }

    -- Encode JSONB fields
    if params.old_values then
        record.old_values = db.raw(db.interpolate_query("?::jsonb", cjson.encode(params.old_values)))
    end
    if params.new_values then
        record.new_values = db.raw(db.interpolate_query("?::jsonb", cjson.encode(params.new_values)))
    end
    if params.metadata then
        record.metadata = db.raw(db.interpolate_query("?::jsonb", cjson.encode(params.metadata)))
    end

    return AuditEventModel:create(record, { returning = "*" })
end

-- List audit events with filtering and pagination
-- @param namespace_id number - Namespace to filter by
-- @param params table with optional: event_type, entity_type, entity_id,
--   actor_user_uuid, page, per_page
-- @return table of events, pagination info
function AuditEventQueries.list(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 25

    local conditions = {}
    local values = {}

    -- Always filter by namespace
    table.insert(conditions, "namespace_id = ?")
    table.insert(values, tonumber(namespace_id) or 0)

    -- Optional filters
    if params.event_type and params.event_type ~= "" then
        table.insert(conditions, "event_type = ?")
        table.insert(values, params.event_type)
    end

    if params.entity_type and params.entity_type ~= "" then
        table.insert(conditions, "entity_type = ?")
        table.insert(values, params.entity_type)
    end

    if params.entity_id and params.entity_id ~= "" then
        table.insert(conditions, "entity_id = ?")
        table.insert(values, params.entity_id)
    end

    if params.actor_user_uuid and params.actor_user_uuid ~= "" then
        table.insert(conditions, "actor_user_uuid = ?")
        table.insert(values, params.actor_user_uuid)
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")
    local offset = (page - 1) * per_page

    -- Build count query
    local count_sql = "SELECT COUNT(*) as total FROM audit_events " .. where_clause
    local count_result = db.query(count_sql, unpack(values))
    local total = count_result and count_result[1] and tonumber(count_result[1].total) or 0

    -- Build data query
    local data_sql = "SELECT * FROM audit_events " .. where_clause ..
        " ORDER BY created_at DESC LIMIT " .. per_page .. " OFFSET " .. offset
    local events = db.query(data_sql, unpack(values))

    return {
        data = events or {},
        pagination = {
            page = page,
            per_page = per_page,
            total = total,
            total_pages = math.ceil(total / per_page),
        }
    }
end

-- Get all audit events for a specific entity
-- @param entity_type string - Entity type (e.g., "timesheet", "order")
-- @param entity_id string - Entity ID/UUID
-- @return table of audit events ordered by created_at DESC
function AuditEventQueries.getByEntity(entity_type, entity_id)
    local events = db.query([[
        SELECT * FROM audit_events
        WHERE entity_type = ? AND entity_id = ?
        ORDER BY created_at DESC
    ]], entity_type, entity_id)

    return events or {}
end

return AuditEventQueries
