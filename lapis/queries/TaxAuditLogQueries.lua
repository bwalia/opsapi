--[[
    Tax Audit Log Queries

    Audit trail for all tax-related changes.
]]

local Global = require "helper.global"
local TaxAuditLogs = require "models.TaxAuditLogModel"
local db = require("lapis.db")

local TaxAuditLogQueries = {}

-- Log an action
function TaxAuditLogQueries.log(data)
    local log_entry = TaxAuditLogs:create({
        uuid = Global.generateUUID(),
        user_id = data.user_id,
        user_email = data.user_email,
        entity_type = data.entity_type,
        entity_id = data.entity_id,
        parent_entity_type = data.parent_entity_type,
        parent_entity_id = data.parent_entity_id,
        action = data.action,
        old_values = data.old_values,
        new_values = data.new_values,
        change_reason = data.change_reason,
        ip_address = data.ip_address
    }, { returning = "*" })

    return log_entry
end

-- Get audit trail for an entity
function TaxAuditLogQueries.getByEntity(entity_type, entity_id, params)
    local page = tonumber(params and params.page) or 1
    local perPage = tonumber(params and params.perPage) or 50

    local paginated = TaxAuditLogs:paginated(
        "WHERE entity_type = ? AND entity_id = ? ORDER BY created_at DESC",
        entity_type, entity_id,
        {
            per_page = perPage,
            fields = 'id as internal_id, uuid as id, user_id, user_email, entity_type, entity_id, parent_entity_type, parent_entity_id, action, old_values, new_values, change_reason, ip_address, created_at'
        }
    )

    return {
        data = paginated:get_page(page),
        total = paginated:total_items(),
        page = page,
        per_page = perPage
    }
end

-- Get audit trail for a statement (including its transactions)
function TaxAuditLogQueries.getByStatement(statement_uuid, params)
    local page = tonumber(params and params.page) or 1
    local perPage = tonumber(params and params.perPage) or 100
    local offset = (page - 1) * perPage

    local results = db.query([[
        SELECT id as internal_id, uuid as id, user_id, user_email, entity_type, entity_id,
               parent_entity_type, parent_entity_id, action, old_values, new_values,
               change_reason, ip_address, created_at
        FROM tax_audit_logs
        WHERE entity_id = ?
           OR parent_entity_id = ?
        ORDER BY created_at DESC
        LIMIT ? OFFSET ?
    ]], statement_uuid, statement_uuid, perPage, offset)

    local count_result = db.query([[
        SELECT COUNT(*) as total FROM tax_audit_logs
        WHERE entity_id = ? OR parent_entity_id = ?
    ]], statement_uuid, statement_uuid)

    return {
        data = results,
        total = count_result[1] and count_result[1].total or 0,
        page = page,
        per_page = perPage
    }
end

-- Get audit logs for a user
function TaxAuditLogQueries.getByUser(user_id, params)
    local page = tonumber(params and params.page) or 1
    local perPage = tonumber(params and params.perPage) or 50

    local paginated = TaxAuditLogs:paginated(
        "WHERE user_id = ? ORDER BY created_at DESC",
        user_id,
        {
            per_page = perPage,
            fields = 'id as internal_id, uuid as id, user_id, user_email, entity_type, entity_id, parent_entity_type, parent_entity_id, action, old_values, new_values, change_reason, ip_address, created_at'
        }
    )

    return {
        data = paginated:get_page(page),
        total = paginated:total_items(),
        page = page,
        per_page = perPage
    }
end

return TaxAuditLogQueries
