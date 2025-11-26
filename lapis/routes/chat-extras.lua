local cJson = require("cjson")
local ChatBookmarkQueries = require "queries.ChatBookmarkQueries"
local ChatDraftQueries = require "queries.ChatDraftQueries"
local ChatMentionQueries = require "queries.ChatMentionQueries"
local ChatUserPresenceQueries = require "queries.ChatUserPresenceQueries"
local ChatChannelInviteQueries = require "queries.ChatChannelInviteQueries"
local ChatFileAttachmentQueries = require "queries.ChatFileAttachmentQueries"
local ChatChannelQueries = require "queries.ChatChannelQueries"
local ChatChannelMemberQueries = require "queries.ChatChannelMemberQueries"
local Global = require "helper.global"

return function(app)
    ----------------- Chat Extra Features Routes --------------------

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

    -- ==================== BOOKMARKS ====================

    -- POST /api/chat/bookmarks - Add bookmark
    app:post("/api/chat/bookmarks", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local data = parse_json_body()

        if not data.message_uuid then
            return { status = 400, json = { error = "message_uuid is required" } }
        end

        local bookmark = ChatBookmarkQueries.create(user.uuid, data.message_uuid, data.note)

        if not bookmark then
            return { status = 500, json = { error = "Failed to create bookmark" } }
        end

        return { status = 201, json = bookmark }
    end)

    -- GET /api/chat/bookmarks - Get user's bookmarks
    app:get("/api/chat/bookmarks", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local params = {
            limit = tonumber(self.params.limit) or 50,
            offset = tonumber(self.params.offset) or 0
        }

        local bookmarks = ChatBookmarkQueries.getByUser(user.uuid, params)

        return {
            status = 200,
            json = {
                data = bookmarks,
                count = ChatBookmarkQueries.countByUser(user.uuid)
            }
        }
    end)

    -- DELETE /api/chat/bookmarks/:message_uuid - Remove bookmark
    app:delete("/api/chat/bookmarks/:message_uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local result = ChatBookmarkQueries.remove(user.uuid, self.params.message_uuid)

        if not result then
            return { status = 404, json = { error = "Bookmark not found" } }
        end

        return { status = 200, json = { message = "Bookmark removed" } }
    end)

    -- ==================== DRAFTS ====================

    -- PUT /api/chat/drafts/:channel_uuid - Save draft
    app:put("/api/chat/drafts/:channel_uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local data = parse_json_body()

        if not data.content then
            return { status = 400, json = { error = "content is required" } }
        end

        local draft = ChatDraftQueries.save(
            user.uuid,
            self.params.channel_uuid,
            data.content,
            data.parent_message_uuid
        )

        return { status = 200, json = draft }
    end)

    -- GET /api/chat/drafts/:channel_uuid - Get draft for channel
    app:get("/api/chat/drafts/:channel_uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local draft = ChatDraftQueries.get(user.uuid, self.params.channel_uuid)

        if not draft then
            return { status = 200, json = { content = nil } }
        end

        return { status = 200, json = draft }
    end)

    -- GET /api/chat/drafts - Get all drafts
    app:get("/api/chat/drafts", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local drafts = ChatDraftQueries.getAllByUser(user.uuid)

        return { status = 200, json = { data = drafts } }
    end)

    -- DELETE /api/chat/drafts/:channel_uuid - Delete draft
    app:delete("/api/chat/drafts/:channel_uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        ChatDraftQueries.delete(user.uuid, self.params.channel_uuid)

        return { status = 200, json = { message = "Draft deleted" } }
    end)

    -- ==================== MENTIONS ====================

    -- GET /api/chat/mentions - Get user's mentions
    app:get("/api/chat/mentions", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local params = {
            limit = tonumber(self.params.limit) or 50,
            offset = tonumber(self.params.offset) or 0
        }

        local mentions
        if self.params.unread_only == "true" or self.params.unread_only == "1" then
            mentions = ChatMentionQueries.getUnreadMentions(user.uuid, params)
        else
            mentions = ChatMentionQueries.getAllMentions(user.uuid, params)
        end

        return {
            status = 200,
            json = {
                data = mentions,
                unread_count = ChatMentionQueries.countUnread(user.uuid)
            }
        }
    end)

    -- POST /api/chat/mentions/:uuid/read - Mark mention as read
    app:post("/api/chat/mentions/:uuid/read", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local mention = ChatMentionQueries.markAsRead(self.params.uuid)

        if not mention then
            return { status = 404, json = { error = "Mention not found" } }
        end

        return { status = 200, json = mention }
    end)

    -- POST /api/chat/mentions/read-all - Mark all mentions as read
    app:post("/api/chat/mentions/read-all", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        ChatMentionQueries.markAllAsRead(user.uuid)

        return { status = 200, json = { message = "All mentions marked as read" } }
    end)

    -- ==================== PRESENCE ====================

    -- PUT /api/chat/presence - Update presence
    app:put("/api/chat/presence", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local data = parse_json_body()

        local valid_statuses = { online = true, away = true, dnd = true, offline = true }
        if data.status and not valid_statuses[data.status] then
            return { status = 400, json = { error = "Invalid status. Must be: online, away, dnd, or offline" } }
        end

        local presence = ChatUserPresenceQueries.updatePresence(user.uuid, data.status or "online", {
            status_text = data.status_text,
            status_emoji = data.status_emoji,
            current_channel_uuid = data.current_channel_uuid
        })

        return { status = 200, json = presence }
    end)

    -- GET /api/chat/presence - Get current user's presence
    app:get("/api/chat/presence", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local presence = ChatUserPresenceQueries.getPresence(user.uuid)

        return { status = 200, json = presence or { status = "offline" } }
    end)

    -- GET /api/chat/channels/:uuid/presence - Get online users in channel
    app:get("/api/chat/channels/:uuid/presence", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local online_users = ChatUserPresenceQueries.getOnlineInChannel(self.params.uuid)

        return { status = 200, json = { data = online_users } }
    end)

    -- DELETE /api/chat/presence/custom-status - Clear custom status
    app:delete("/api/chat/presence/custom-status", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        ChatUserPresenceQueries.clearCustomStatus(user.uuid)

        return { status = 200, json = { message = "Custom status cleared" } }
    end)

    -- ==================== INVITATIONS ====================

    -- POST /api/chat/channels/:uuid/invites - Send invitation
    app:post("/api/chat/channels/:uuid/invites", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Check if user is admin
        if not ChatChannelQueries.isAdmin(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can send invitations" } }
        end

        local data = parse_json_body()

        if not data.user_uuid then
            return { status = 400, json = { error = "user_uuid is required" } }
        end

        -- Check if user is already a member
        if ChatChannelQueries.isMember(channel_uuid, data.user_uuid) then
            return { status = 400, json = { error = "User is already a member" } }
        end

        -- Check if there's already a pending invitation
        if ChatChannelInviteQueries.hasPendingInvitation(channel_uuid, data.user_uuid) then
            return { status = 400, json = { error = "User already has a pending invitation" } }
        end

        local invite = ChatChannelInviteQueries.create(
            channel_uuid,
            data.user_uuid,
            user.uuid,
            data.message,
            data.expires_in_hours or 168 -- default 1 week
        )

        return { status = 201, json = invite }
    end)

    -- GET /api/chat/invites - Get pending invitations for current user
    app:get("/api/chat/invites", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local invites = ChatChannelInviteQueries.getPendingForUser(user.uuid)

        return { status = 200, json = { data = invites } }
    end)

    -- POST /api/chat/invites/:uuid/accept - Accept invitation
    app:post("/api/chat/invites/:uuid/accept", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local invite, accept_err = ChatChannelInviteQueries.accept(self.params.uuid)

        if not invite then
            return { status = 400, json = { error = accept_err or "Failed to accept invitation" } }
        end

        -- Add user to channel
        ChatChannelMemberQueries.addMember(invite.channel_uuid, user.uuid, "member")

        return { status = 200, json = { message = "Invitation accepted", invite = invite } }
    end)

    -- POST /api/chat/invites/:uuid/decline - Decline invitation
    app:post("/api/chat/invites/:uuid/decline", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local invite, decline_err = ChatChannelInviteQueries.decline(self.params.uuid)

        if not invite then
            return { status = 400, json = { error = decline_err or "Failed to decline invitation" } }
        end

        return { status = 200, json = { message = "Invitation declined" } }
    end)

    -- ==================== FILE ATTACHMENTS ====================

    -- GET /api/chat/channels/:uuid/files - Get files in channel
    app:get("/api/chat/channels/:uuid/files", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Check membership
        if not ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Access denied" } }
        end

        local params = {
            limit = tonumber(self.params.limit) or 50,
            offset = tonumber(self.params.offset) or 0
        }

        local files = ChatFileAttachmentQueries.getByChannel(channel_uuid, params)
        local storage = ChatFileAttachmentQueries.getChannelStorageUsage(channel_uuid)

        return {
            status = 200,
            json = {
                data = files,
                storage = storage
            }
        }
    end)

    -- GET /api/chat/channels/:uuid/files/images - Get images in channel
    app:get("/api/chat/channels/:uuid/files/images", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        if not ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Access denied" } }
        end

        local params = {
            limit = tonumber(self.params.limit) or 50,
            offset = tonumber(self.params.offset) or 0
        }

        local files = ChatFileAttachmentQueries.getByType(channel_uuid, "image/%", params)

        return { status = 200, json = { data = files } }
    end)

    -- POST /api/chat/files - Create file attachment record (before upload)
    app:post("/api/chat/files", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local data = parse_json_body()

        if not data.channel_uuid then
            return { status = 400, json = { error = "channel_uuid is required" } }
        end

        if not ChatChannelQueries.isMember(data.channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Access denied" } }
        end

        local attachment = ChatFileAttachmentQueries.create({
            uuid = Global.generateUUID(),
            channel_uuid = data.channel_uuid,
            user_uuid = user.uuid,
            file_name = data.file_name,
            file_type = data.file_type,
            file_size = data.file_size,
            file_url = data.file_url,
            thumbnail_url = data.thumbnail_url,
            width = data.width,
            height = data.height,
            duration = data.duration
        })

        return { status = 201, json = attachment }
    end)

    -- DELETE /api/chat/files/:uuid - Delete file attachment
    app:delete("/api/chat/files/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local attachment = ChatFileAttachmentQueries.show(self.params.uuid)

        if not attachment then
            return { status = 404, json = { error = "File not found" } }
        end

        -- Check ownership or admin
        if attachment.user_uuid ~= user.uuid then
            if not ChatChannelQueries.isAdmin(attachment.channel_uuid, user.uuid) then
                return { status = 403, json = { error = "Access denied" } }
            end
        end

        ChatFileAttachmentQueries.softDelete(self.params.uuid)

        return { status = 200, json = { message = "File deleted" } }
    end)
end
