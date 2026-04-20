-- Tax Support Queries
-- CRUD for tax_support_conversations and tax_support_messages.

local db = require("lapis.db")
local Global = require("helper.global")

local TaxSupportQueries = {}

-- ---------------------------------------------------------------------------
-- Conversations
-- ---------------------------------------------------------------------------

function TaxSupportQueries.createConversation(data)
    data.uuid = data.uuid or Global.generateStaticUUID()
    data.status = data.status or "OPEN"
    data.priority = data.priority or "NORMAL"
    data.created_at = db.raw("NOW()")
    data.updated_at = db.raw("NOW()")
    return db.insert("tax_support_conversations", data)
end

function TaxSupportQueries.getConversationsForUser(user_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 25
    local offset = (page - 1) * per_page

    local where = "user_id = " .. db.escape_literal(user_id)
    if params.status then
        where = where .. " AND status = " .. db.escape_literal(params.status)
    end

    local rows = db.select("* FROM tax_support_conversations WHERE " .. where .. " ORDER BY updated_at DESC LIMIT ? OFFSET ?",
        per_page, offset)
    local count = db.select("COUNT(*) as total FROM tax_support_conversations WHERE " .. where)

    return rows, count and count[1] and count[1].total or 0
end

function TaxSupportQueries.getConversationById(id)
    local rows = db.select("* FROM tax_support_conversations WHERE id = ? LIMIT 1", id)
    return rows and rows[1]
end

function TaxSupportQueries.getConversationByUuid(uuid)
    local rows = db.select("* FROM tax_support_conversations WHERE uuid = ? LIMIT 1", uuid)
    return rows and rows[1]
end

function TaxSupportQueries.updateConversation(uuid, data)
    data.updated_at = db.raw("NOW()")
    db.update("tax_support_conversations", data, { uuid = uuid })
    return TaxSupportQueries.getConversationByUuid(uuid)
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

function TaxSupportQueries.addMessage(data)
    data.uuid = data.uuid or Global.generateStaticUUID()
    data.created_at = db.raw("NOW()")

    local msg = db.insert("tax_support_messages", data)

    -- Update conversation timestamp and unread flags
    local updates = { updated_at = db.raw("NOW()") }
    if data.sender_type == "USER" then
        updates.unread_by_accountant = true
    else
        updates.unread_by_user = true
    end
    db.update("tax_support_conversations", updates, { id = data.conversation_id })

    return msg
end

function TaxSupportQueries.getMessages(conversation_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 50
    local offset = (page - 1) * per_page

    local rows = db.select("* FROM tax_support_messages WHERE conversation_id = ? ORDER BY created_at ASC LIMIT ? OFFSET ?",
        conversation_id, per_page, offset)
    local count = db.select("COUNT(*) as total FROM tax_support_messages WHERE conversation_id = ?", conversation_id)

    return rows, count and count[1] and count[1].total or 0
end

function TaxSupportQueries.getUnreadCount(user_id)
    local rows = db.select(
        "COUNT(*) as count FROM tax_support_conversations WHERE user_id = ? AND unread_by_user = true",
        user_id
    )
    return rows and rows[1] and tonumber(rows[1].count) or 0
end

function TaxSupportQueries.markRead(conversation_id, reader_type)
    if reader_type == "USER" then
        db.update("tax_support_conversations", { unread_by_user = false }, { id = conversation_id })
    else
        db.update("tax_support_conversations", { unread_by_accountant = false }, { id = conversation_id })
    end
end

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

function TaxSupportQueries.getAllConversations(params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 25
    local offset = (page - 1) * per_page

    local where_clauses = { "1=1" }
    if params.status then
        table.insert(where_clauses, "c.status = " .. db.escape_literal(params.status))
    end
    if params.priority then
        table.insert(where_clauses, "c.priority = " .. db.escape_literal(params.priority))
    end
    if params.search and #params.search > 0 then
        local search = db.escape_literal("%" .. params.search .. "%")
        table.insert(where_clauses, "(c.subject ILIKE " .. search .. " OR u.email ILIKE " .. search .. ")")
    end

    local where = table.concat(where_clauses, " AND ")

    local rows = db.query(string.format([[
        SELECT c.*, u.email as user_email, u.first_name, u.last_name
        FROM tax_support_conversations c
        LEFT JOIN users u ON u.id = c.user_id
        WHERE %s
        ORDER BY c.updated_at DESC
        LIMIT %d OFFSET %d
    ]], where, per_page, offset))

    local count = db.query(string.format([[
        SELECT COUNT(*) as total
        FROM tax_support_conversations c
        LEFT JOIN users u ON u.id = c.user_id
        WHERE %s
    ]], where))

    return rows or {}, count and count[1] and count[1].total or 0
end

return TaxSupportQueries
