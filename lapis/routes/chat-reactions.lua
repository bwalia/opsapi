local cJson = require("cjson")
local ChatReactionQueries = require "queries.ChatReactionQueries"
local ChatMessageQueries = require "queries.ChatMessageQueries"
local ChatChannelQueries = require "queries.ChatChannelQueries"

return function(app)
    ----------------- Chat Reaction Routes --------------------

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

    -- POST /api/chat/messages/:message_uuid/reactions - Add reaction to message
    app:post("/api/chat/messages/:message_uuid/reactions", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.message_uuid

        -- Get message to verify it exists and get channel
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

        local data = parse_json_body()

        if not data.emoji or data.emoji == "" then
            return { status = 400, json = { error = "Emoji is required" } }
        end

        local reaction, add_err = ChatReactionQueries.addReaction(message_uuid, user.uuid, data.emoji)

        if add_err == "Reaction already exists" then
            return { status = 400, json = { error = add_err } }
        end

        if not reaction then
            return { status = 500, json = { error = "Failed to add reaction" } }
        end

        -- Get all reactions for the message
        local reactions = ChatReactionQueries.getByMessage(message_uuid)

        return {
            status = 201,
            json = {
                reaction = reaction,
                all_reactions = reactions
            }
        }
    end)

    -- DELETE /api/chat/messages/:message_uuid/reactions/:emoji - Remove reaction
    app:delete("/api/chat/messages/:message_uuid/reactions/:emoji", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.message_uuid
        local emoji = ngx.unescape_uri(self.params.emoji)

        -- Get message to verify it exists
        local message = ChatMessageQueries.show(message_uuid)

        if not message then
            return { status = 404, json = { error = "Message not found" } }
        end

        local result, remove_err = ChatReactionQueries.removeReaction(message_uuid, user.uuid, emoji)

        if not result then
            return { status = 404, json = { error = remove_err or "Reaction not found" } }
        end

        -- Get all reactions for the message
        local reactions = ChatReactionQueries.getByMessage(message_uuid)

        return {
            status = 200,
            json = {
                message = "Reaction removed",
                all_reactions = reactions
            }
        }
    end)

    -- POST /api/chat/messages/:message_uuid/reactions/toggle - Toggle reaction
    app:post("/api/chat/messages/:message_uuid/reactions/toggle", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.message_uuid

        -- Get message to verify it exists and get channel
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

        local data = parse_json_body()

        if not data.emoji or data.emoji == "" then
            return { status = 400, json = { error = "Emoji is required" } }
        end

        local reaction, action = ChatReactionQueries.toggleReaction(message_uuid, user.uuid, data.emoji)

        -- Get all reactions for the message
        local reactions = ChatReactionQueries.getByMessage(message_uuid)

        return {
            status = 200,
            json = {
                action = action,
                reaction = reaction,
                all_reactions = reactions
            }
        }
    end)

    -- GET /api/chat/messages/:message_uuid/reactions - Get all reactions for a message
    app:get("/api/chat/messages/:message_uuid/reactions", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.message_uuid

        -- Get message to verify it exists
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

        local reactions = ChatReactionQueries.getByMessage(message_uuid)

        return {
            status = 200,
            json = {
                data = reactions,
                message_uuid = message_uuid
            }
        }
    end)

    -- GET /api/chat/messages/:message_uuid/reactions/:emoji/users - Get users who reacted with specific emoji
    app:get("/api/chat/messages/:message_uuid/reactions/:emoji/users", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local message_uuid = self.params.message_uuid
        local emoji = ngx.unescape_uri(self.params.emoji)

        -- Get message to verify it exists
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

        local users = ChatReactionQueries.getUsersByEmoji(message_uuid, emoji)

        return {
            status = 200,
            json = {
                data = users,
                emoji = emoji,
                message_uuid = message_uuid
            }
        }
    end)

    -- GET /api/chat/channels/:channel_uuid/reactions/popular - Get most used emojis in channel
    app:get("/api/chat/channels/:channel_uuid/reactions/popular", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid

        -- Check if user has access to the channel
        if not ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            local channel = ChatChannelQueries.show(channel_uuid)
            if not channel or channel.type ~= "public" then
                return { status = 403, json = { error = "Access denied" } }
            end
        end

        local limit = tonumber(self.params.limit) or 10
        local emojis = ChatReactionQueries.getMostUsedEmojis(channel_uuid, limit)

        return {
            status = 200,
            json = {
                data = emojis,
                channel_uuid = channel_uuid
            }
        }
    end)
end
