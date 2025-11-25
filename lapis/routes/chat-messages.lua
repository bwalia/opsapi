local cJson = require("cjson")
local ChatMessageQueries = require "queries.ChatMessageQueries"
local ChatChannelQueries = require "queries.ChatChannelQueries"
local ChatChannelMemberQueries = require "queries.ChatChannelMemberQueries"
local Global = require "helper.global"

return function(app)
    ----------------- Chat Message Routes --------------------

    -- Helper function to parse JSON body
    local function parse_json_body()
        local ok, result = pcall(function()
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cJson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    -- Get current user from headers
    local function get_current_user()
        local user_uuid = ngx.var.http_x_user_id
        local user_business_id = ngx.var.http_x_business_id

        if not user_uuid or user_uuid == "" then
            return nil, "Unauthorized"
        end

        return {
            uuid = user_uuid,
            uuid_business_id = user_business_id
        }
    end

    -- GET /api/chat/channels/:channel_uuid/messages - Get messages for a channel
    app:get("/api/chat/channels/:channel_uuid/messages", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid

        -- Check membership
        if not ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            -- Allow access to public channels
            local channel = ChatChannelQueries.show(channel_uuid)
            if not channel or channel.type ~= "public" then
                return { status = 403, json = { error = "Access denied" } }
            end
        end

        local params = {
            limit = tonumber(self.params.limit) or 50,
            before = self.params.before,
            after = self.params.after
        }

        local messages = ChatMessageQueries.getByChannel(channel_uuid, params)

        return {
            status = 200,
            json = {
                data = messages,
                channel_uuid = channel_uuid
            }
        }
    end)

    -- POST /api/chat/channels/:channel_uuid/messages - Send a message
    app:post("/api/chat/channels/:channel_uuid/messages", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid

        -- Check membership
        if not ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "You must be a member to send messages" } }
        end

        local data = parse_json_body()

        if not data.content or data.content == "" then
            return { status = 400, json = { error = "Message content is required" } }
        end

        -- Validate content type
        local valid_types = { text = true, code = true, markdown = true }
        if data.content_type and not valid_types[data.content_type] then
            return { status = 400, json = { error = "Invalid content_type" } }
        end

        -- Extract mentions from content
        local mentions = ChatMessageQueries.extractMentions(data.content)

        -- Create message
        local message = ChatMessageQueries.create({
            uuid = Global.generateUUID(),
            channel_uuid = channel_uuid,
            user_uuid = user.uuid,
            content = data.content,
            content_type = data.content_type or "text",
            parent_message_uuid = data.parent_message_uuid,
            mentions = #mentions > 0 and mentions or nil,
            attachments = data.attachments,
            metadata = data.metadata
        })

        if not message then
            return { status = 500, json = { error = "Failed to send message" } }
        end

        -- Update channel's last_message_at
        ChatChannelQueries.updateLastMessageAt(channel_uuid)

        -- If this is a reply, update parent's reply count
        if data.parent_message_uuid then
            ChatMessageQueries.updateReplyCount(data.parent_message_uuid)
        end

        -- Get full message with user info
        local full_message = ChatMessageQueries.show(message.uuid)

        return {
            status = 201,
            json = full_message
        }
    end)

    -- GET /api/chat/messages/:uuid - Get single message
    app:get("/api/chat/messages/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.uuid

        local message = ChatMessageQueries.show(message_uuid)

        if not message then
            return { status = 404, json = { error = "Message not found" } }
        end

        -- Check if user has access to the channel
        if not ChatChannelQueries.isMember(message.channel_uuid, user.uuid) then
            local channel = ChatChannelQueries.show(message.channel_uuid)
            if not channel or channel.type ~= "public" then
                return { status = 403, json = { error = "Access denied" } }
            end
        end

        return {
            status = 200,
            json = message
        }
    end)

    -- PUT /api/chat/messages/:uuid - Edit a message
    app:put("/api/chat/messages/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.uuid

        -- Get message to verify ownership
        local message = ChatMessageQueries.show(message_uuid)

        if not message then
            return { status = 404, json = { error = "Message not found" } }
        end

        -- Check ownership
        if message.user_uuid ~= user.uuid then
            return { status = 403, json = { error = "You can only edit your own messages" } }
        end

        -- Check if message is deleted
        if message.is_deleted then
            return { status = 400, json = { error = "Cannot edit deleted message" } }
        end

        local data = parse_json_body()

        if not data.content or data.content == "" then
            return { status = 400, json = { error = "Message content is required" } }
        end

        -- Extract new mentions
        local mentions = ChatMessageQueries.extractMentions(data.content)

        local updated = ChatMessageQueries.update(message_uuid, {
            content = data.content,
            mentions = #mentions > 0 and mentions or nil
        })

        if not updated then
            return { status = 500, json = { error = "Failed to update message" } }
        end

        -- Get full message with user info
        local full_message = ChatMessageQueries.show(message_uuid)

        return {
            status = 200,
            json = full_message
        }
    end)

    -- DELETE /api/chat/messages/:uuid - Delete a message
    app:delete("/api/chat/messages/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.uuid

        -- Get message to verify ownership
        local message = ChatMessageQueries.show(message_uuid)

        if not message then
            return { status = 404, json = { error = "Message not found" } }
        end

        -- Check if user is owner or admin
        local is_owner = message.user_uuid == user.uuid
        local is_admin = ChatChannelQueries.isAdmin(message.channel_uuid, user.uuid)

        if not is_owner and not is_admin then
            return { status = 403, json = { error = "You can only delete your own messages" } }
        end

        -- Soft delete
        local deleted = ChatMessageQueries.softDelete(message_uuid)

        if not deleted then
            return { status = 500, json = { error = "Failed to delete message" } }
        end

        -- If this was a reply, update parent's reply count
        if message.parent_message_uuid then
            ChatMessageQueries.updateReplyCount(message.parent_message_uuid)
        end

        return {
            status = 200,
            json = { message = "Message deleted successfully" }
        }
    end)

    -- GET /api/chat/messages/:uuid/thread - Get thread replies
    app:get("/api/chat/messages/:uuid/thread", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local parent_uuid = self.params.uuid

        -- Get parent message to verify access
        local parent = ChatMessageQueries.show(parent_uuid)

        if not parent then
            return { status = 404, json = { error = "Message not found" } }
        end

        -- Check if user has access to the channel
        if not ChatChannelQueries.isMember(parent.channel_uuid, user.uuid) then
            local channel = ChatChannelQueries.show(parent.channel_uuid)
            if not channel or channel.type ~= "public" then
                return { status = 403, json = { error = "Access denied" } }
            end
        end

        local params = {
            limit = tonumber(self.params.limit) or 50,
            offset = tonumber(self.params.offset) or 0
        }

        local thread = ChatMessageQueries.getThread(parent_uuid, params)

        return {
            status = 200,
            json = thread
        }
    end)

    -- POST /api/chat/messages/:uuid/pin - Pin a message
    app:post("/api/chat/messages/:uuid/pin", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.uuid

        local message = ChatMessageQueries.show(message_uuid)

        if not message then
            return { status = 404, json = { error = "Message not found" } }
        end

        -- Check if user is admin
        if not ChatChannelQueries.isAdmin(message.channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can pin messages" } }
        end

        local pinned = ChatMessageQueries.pin(message_uuid)

        if not pinned then
            return { status = 500, json = { error = "Failed to pin message" } }
        end

        return {
            status = 200,
            json = { message = "Message pinned successfully" }
        }
    end)

    -- DELETE /api/chat/messages/:uuid/pin - Unpin a message
    app:delete("/api/chat/messages/:uuid/pin", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.uuid

        local message = ChatMessageQueries.show(message_uuid)

        if not message then
            return { status = 404, json = { error = "Message not found" } }
        end

        -- Check if user is admin
        if not ChatChannelQueries.isAdmin(message.channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can unpin messages" } }
        end

        local unpinned = ChatMessageQueries.unpin(message_uuid)

        if not unpinned then
            return { status = 500, json = { error = "Failed to unpin message" } }
        end

        return {
            status = 200,
            json = { message = "Message unpinned successfully" }
        }
    end)

    -- GET /api/chat/channels/:channel_uuid/messages/pinned - Get pinned messages
    app:get("/api/chat/channels/:channel_uuid/messages/pinned", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid

        -- Check membership
        if not ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            local channel = ChatChannelQueries.show(channel_uuid)
            if not channel or channel.type ~= "public" then
                return { status = 403, json = { error = "Access denied" } }
            end
        end

        local messages = ChatMessageQueries.getPinned(channel_uuid)

        return {
            status = 200,
            json = {
                data = messages,
                channel_uuid = channel_uuid
            }
        }
    end)

    -- GET /api/chat/channels/:channel_uuid/messages/search - Search messages in channel
    app:get("/api/chat/channels/:channel_uuid/messages/search", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid

        -- Check membership
        if not ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            local channel = ChatChannelQueries.show(channel_uuid)
            if not channel or channel.type ~= "public" then
                return { status = 403, json = { error = "Access denied" } }
            end
        end

        local search_term = self.params.q or self.params.query
        if not search_term or search_term == "" then
            return { status = 400, json = { error = "Search query is required" } }
        end

        local params = {
            limit = tonumber(self.params.limit) or 50,
            offset = tonumber(self.params.offset) or 0
        }

        local messages = ChatMessageQueries.search(channel_uuid, search_term, params)

        return {
            status = 200,
            json = {
                data = messages,
                query = search_term,
                channel_uuid = channel_uuid
            }
        }
    end)

    -- GET /api/chat/channels/:channel_uuid/unread - Get unread count
    app:get("/api/chat/channels/:channel_uuid/unread", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid

        local count = ChatMessageQueries.getUnreadCount(channel_uuid, user.uuid)

        return {
            status = 200,
            json = {
                unread_count = count,
                channel_uuid = channel_uuid
            }
        }
    end)
end
