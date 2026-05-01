--[[
    Tax Support Routes

    User support ticket system for client-accountant communication.

    POST /api/v2/support/conversations                  — Create ticket
    GET  /api/v2/support/conversations                  — List user's tickets
    POST /api/v2/support/conversations/:id/messages      — Send message
    GET  /api/v2/support/conversations/:id/messages      — Get messages
    GET  /api/v2/support/unread-count                    — Badge counter
    GET  /api/v2/support/admin/conversations             — Admin: list all
    PUT  /api/v2/support/admin/conversations/:uuid       — Admin: update status
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

local function isAdmin(user)
    if not user then return false end
    local roles = user.roles or ""
    if type(roles) == "string" then
        return roles:match("admin") ~= nil or roles:match("tax_admin") ~= nil or roles:match("accountant") ~= nil
    end
    if type(roles) == "table" then
        for _, r in ipairs(roles) do
            local name = r.role_name or r
            if name == "administrative" or name == "tax_admin" or name == "accountant" then return true end
        end
    end
    local user_uuid = user.uuid or user.id
    local rows = db.query([[
        SELECT r.name FROM roles r
        JOIN user__roles ur ON ur.role_id = r.id
        JOIN users u ON u.id = ur.user_id
        WHERE u.uuid = ? AND r.name IN ('administrative', 'tax_admin', 'accountant')
        LIMIT 1
    ]], user_uuid)
    return rows and #rows > 0
end

return function(app)

    local ok_q, SupportQueries = pcall(require, "queries.TaxSupportQueries")
    if not ok_q then
        ngx.log(ngx.ERR, "TaxSupportQueries not available: ", tostring(SupportQueries))
        return
    end

    -- POST /api/v2/support/conversations — create ticket
    app:post("/api/v2/support/conversations",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            if not self.params.subject then
                return { status = 400, json = { error = "subject is required" } }
            end

            local conversation = SupportQueries.createConversation({
                user_id = user_id,
                subject = self.params.subject,
                statement_id = self.params.statement_id and tonumber(self.params.statement_id) or db.NULL,
            })

            -- Add first message if provided
            if self.params.message and #self.params.message > 0 then
                SupportQueries.addMessage({
                    conversation_id = conversation.id or conversation[1] and conversation[1].id,
                    sender_id = user_id,
                    sender_type = "USER",
                    content = self.params.message,
                })
            end

            return { status = 201, json = { data = conversation, message = "Conversation created" } }
        end)
    )

    -- GET /api/v2/support/conversations — list user's tickets
    app:get("/api/v2/support/conversations",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local rows, total = SupportQueries.getConversationsForUser(user_id, self.params)
            return {
                status = 200,
                json = { data = rows, total = total }
            }
        end)
    )

    -- POST /api/v2/support/conversations/:id/messages
    app:post("/api/v2/support/conversations/:id/messages",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local conversation = SupportQueries.getConversationById(self.params.id)
            if not conversation then
                return { status = 404, json = { error = "Conversation not found" } }
            end

            -- Verify access
            local is_owner = conversation.user_id == user_id
            local is_staff = isAdmin(self.current_user)
            if not is_owner and not is_staff then
                return { status = 403, json = { error = "Access denied" } }
            end

            if not self.params.content or #self.params.content == 0 then
                return { status = 400, json = { error = "content is required" } }
            end

            local sender_type = is_staff and not is_owner and "ACCOUNTANT" or "USER"

            local message = SupportQueries.addMessage({
                conversation_id = tonumber(self.params.id),
                sender_id = user_id,
                sender_type = sender_type,
                content = self.params.content,
            })

            -- Mark as read for sender
            SupportQueries.markRead(tonumber(self.params.id), sender_type)

            return { status = 201, json = { data = message } }
        end)
    )

    -- GET /api/v2/support/conversations/:id/messages
    app:get("/api/v2/support/conversations/:id/messages",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local conversation = SupportQueries.getConversationById(self.params.id)
            if not conversation then
                return { status = 404, json = { error = "Conversation not found" } }
            end

            local is_owner = conversation.user_id == user_id
            local is_staff = isAdmin(self.current_user)
            if not is_owner and not is_staff then
                return { status = 403, json = { error = "Access denied" } }
            end

            local rows, total = SupportQueries.getMessages(self.params.id, self.params)

            -- Mark as read
            SupportQueries.markRead(tonumber(self.params.id), is_staff and "ACCOUNTANT" or "USER")

            return { status = 200, json = { data = rows, total = total } }
        end)
    )

    -- GET /api/v2/support/unread-count
    app:get("/api/v2/support/unread-count",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local count = SupportQueries.getUnreadCount(user_id)
            return { status = 200, json = { unread = count } }
        end)
    )

    -- GET /api/v2/support/admin/conversations
    app:get("/api/v2/support/admin/conversations",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local rows, total = SupportQueries.getAllConversations(self.params)
            return { status = 200, json = { data = rows, total = total } }
        end)
    )

    -- PUT /api/v2/support/admin/conversations/:uuid
    app:put("/api/v2/support/admin/conversations/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local updates = {}
            if self.params.status then updates.status = self.params.status end
            if self.params.priority then updates.priority = self.params.priority end
            if self.params.assigned_to then updates.assigned_to = tonumber(self.params.assigned_to) end

            local updated = SupportQueries.updateConversation(self.params.uuid, updates)
            if not updated then
                return { status = 404, json = { error = "Conversation not found" } }
            end

            return { status = 200, json = { data = updated, message = "Conversation updated" } }
        end)
    )
end
