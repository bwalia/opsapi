--[[
    Namespace Audit Log Queries

    Audit trail for all RBAC and namespace-level changes.
    Logs role changes, member additions/removals, permission updates, etc.

    Uses existing namespace_audit_logs table (migration 26).
]]

local Global = require "helper.global"
local NamespaceAuditLogs = require "models.NamespaceAuditLogModel"
local db = require("lapis.db")
local cjson = require("cjson")

local NamespaceAuditLogQueries = {}

--- Log an RBAC or namespace action
-- Wrapped in pcall at call sites so audit never breaks primary operations
-- @param data table { namespace_id, user_id, action, entity_type, entity_id?, old_values?, new_values?, ip_address?, user_agent? }
-- @return table The created log entry
function NamespaceAuditLogQueries.log(data)
    -- Encode values to JSON if they're tables
    local old_values = data.old_values
    if type(old_values) == "table" then
        old_values = cjson.encode(old_values)
    end

    local new_values = data.new_values
    if type(new_values) == "table" then
        new_values = cjson.encode(new_values)
    end

    return NamespaceAuditLogs:create({
        uuid = Global.generateUUID(),
        namespace_id = data.namespace_id,
        user_id = data.user_id,
        action = data.action,
        entity_type = data.entity_type,
        entity_id = data.entity_id and tostring(data.entity_id) or nil,
        old_values = old_values,
        new_values = new_values,
        ip_address = data.ip_address,
        user_agent = data.user_agent,
        created_at = Global.getCurrentTimestamp()
    }, { returning = "*" })
end

--- Get audit logs for a namespace (paginated, with filters)
-- @param namespace_id number Namespace ID
-- @param params table { page?, per_page?, entity_type?, action?, user_id?, from_date?, to_date? }
-- @return table { data, total, page, per_page }
function NamespaceAuditLogQueries.getByNamespace(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = math.max(tonumber(params.per_page) or 50, 1)
    local offset = (page - 1) * per_page

    -- Build dynamic WHERE clause
    local conditions = { "namespace_id = ?" }
    local args = { namespace_id }

    if params.entity_type and params.entity_type ~= "" then
        table.insert(conditions, "entity_type = ?")
        table.insert(args, params.entity_type)
    end

    if params.action and params.action ~= "" then
        table.insert(conditions, "action = ?")
        table.insert(args, params.action)
    end

    if params.user_id then
        table.insert(conditions, "user_id = ?")
        table.insert(args, tonumber(params.user_id))
    end

    if params.from_date and params.from_date ~= "" then
        table.insert(conditions, "created_at >= ?")
        table.insert(args, params.from_date)
    end

    if params.to_date and params.to_date ~= "" then
        table.insert(conditions, "created_at <= ?")
        table.insert(args, params.to_date)
    end

    local where_clause = table.concat(conditions, " AND ")

    -- Count query
    local count_query = "SELECT COUNT(*) as total FROM namespace_audit_logs WHERE " .. where_clause
    local count_result = db.query(count_query, table.unpack(args))
    local total = tonumber(count_result and count_result[1] and count_result[1].total) or 0

    -- Data query with user info
    local data_query = [[
        SELECT
            nal.id as internal_id, nal.uuid as id,
            nal.namespace_id, nal.user_id, nal.action,
            nal.entity_type, nal.entity_id,
            nal.old_values, nal.new_values,
            nal.ip_address, nal.user_agent, nal.created_at,
            u.email as user_email,
            u.first_name as user_first_name,
            u.last_name as user_last_name
        FROM namespace_audit_logs nal
        LEFT JOIN users u ON nal.user_id = u.id
        WHERE ]] .. where_clause .. [[
        ORDER BY nal.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    -- Build final args with pagination
    local data_args = {}
    for _, v in ipairs(args) do table.insert(data_args, v) end
    table.insert(data_args, per_page)
    table.insert(data_args, offset)

    local results = db.query(data_query, table.unpack(data_args))

    -- Parse JSON fields
    for _, entry in ipairs(results or {}) do
        if entry.old_values and type(entry.old_values) == "string" then
            local ok, parsed = pcall(cjson.decode, entry.old_values)
            if ok then entry.old_values = parsed end
        end
        if entry.new_values and type(entry.new_values) == "string" then
            local ok, parsed = pcall(cjson.decode, entry.new_values)
            if ok then entry.new_values = parsed end
        end
    end

    return {
        data = results or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Get audit trail for a specific entity
-- @param entity_type string Entity type (e.g., "namespace_role", "namespace_member")
-- @param entity_id string|number Entity ID
-- @param params table { page?, per_page? }
-- @return table { data, total, page, per_page }
function NamespaceAuditLogQueries.getByEntity(entity_type, entity_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = math.max(tonumber(params.per_page) or 50, 1)
    local offset = (page - 1) * per_page

    local count_result = db.query(
        "SELECT COUNT(*) as total FROM namespace_audit_logs WHERE entity_type = ? AND entity_id = ?",
        entity_type, tostring(entity_id)
    )
    local total = tonumber(count_result and count_result[1] and count_result[1].total) or 0

    local results = db.query([[
        SELECT
            nal.id as internal_id, nal.uuid as id,
            nal.namespace_id, nal.user_id, nal.action,
            nal.entity_type, nal.entity_id,
            nal.old_values, nal.new_values,
            nal.ip_address, nal.user_agent, nal.created_at,
            u.email as user_email,
            u.first_name as user_first_name,
            u.last_name as user_last_name
        FROM namespace_audit_logs nal
        LEFT JOIN users u ON nal.user_id = u.id
        WHERE nal.entity_type = ? AND nal.entity_id = ?
        ORDER BY nal.created_at DESC
        LIMIT ? OFFSET ?
    ]], entity_type, tostring(entity_id), per_page, offset)

    return {
        data = results or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

return NamespaceAuditLogQueries
