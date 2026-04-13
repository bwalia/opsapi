local cJson = require("cjson")
local ChatChannelQueries = require "queries.ChatChannelQueries"
local ChatChannelMemberQueries = require "queries.ChatChannelMemberQueries"
local ChatMessageQueries = require "queries.ChatMessageQueries"
local Global = require "helper.global"
local db = require("lapis.db")

return function(app)
    ----------------- Chat Channel Routes --------------------

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

    -- Get namespace_id from header or default to system namespace
    local function get_namespace_id()
        local namespace_id = ngx.var.http_x_namespace_id

        if namespace_id and namespace_id ~= "" then
            return tonumber(namespace_id)
        end

        -- Fallback: Get default "system" namespace
        local result = db.query("SELECT id FROM namespaces WHERE slug = 'system' LIMIT 1")
        if result and #result > 0 then
            return result[1].id
        end

        return nil
    end

    -- GET /api/chat/channels - List user's channels
    app:get("/api/chat/channels", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20
        }

        local result = ChatChannelQueries.getByUser(user.uuid, params)

        return {
            status = 200,
            json = {
                data = result.data,
                total = result.total,
                page = params.page,
                perPage = params.perPage
            }
        }
    end)

    -- GET /api/chat/channels/business - List all business channels
    app:get("/api/chat/channels/business", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        if not user.uuid_business_id then
            return { status = 400, json = { error = "Business ID required" } }
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20
        }

        local result = ChatChannelQueries.getByBusiness(user.uuid_business_id, params)

        return {
            status = 200,
            json = {
                data = result.data,
                total = result.total,
                page = params.page,
                perPage = params.perPage
            }
        }
    end)

    -- POST /api/chat/channels - Create a new channel
    app:post("/api/chat/channels", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local data = parse_json_body()

        if not data.name or data.name == "" then
            return { status = 400, json = { error = "Channel name is required" } }
        end

        -- Validate channel type
        local valid_types = { public = true, private = true, direct = true }
        if data.type and not valid_types[data.type] then
            return { status = 400, json = { error = "Invalid channel type. Must be: public, private, or direct" } }
        end

        -- Get namespace_id (required for foreign key constraint)
        local namespace_id = get_namespace_id()
        if not namespace_id then
            return { status = 400, json = { error = "Namespace context required. Please provide X-Namespace-Id header or ensure system namespace exists." } }
        end

        -- Create channel
        local channel = ChatChannelQueries.create({
            uuid = Global.generateUUID(),
            name = data.name,
            description = data.description,
            type = data.type or "public",
            created_by = user.uuid,
            uuid_business_id = user.uuid_business_id,
            namespace_id = namespace_id,
            linked_task_uuid = data.linked_task_uuid,
            linked_task_id = data.linked_task_id,
            avatar_url = data.avatar_url
        })

        if not channel then
            return { status = 500, json = { error = "Failed to create channel" } }
        end

        -- Add creator as admin
        ChatChannelMemberQueries.addMember(channel.uuid, user.uuid, "admin")

        -- Add initial members if provided
        if data.members and type(data.members) == "table" then
            for _, member_uuid in ipairs(data.members) do
                if member_uuid ~= user.uuid then
                    ChatChannelMemberQueries.addMember(channel.uuid, member_uuid, "member")
                end
            end
        end

        return {
            status = 201,
            json = channel
        }
    end)

    -- GET /api/chat/channels/:uuid - Get channel details
    app:get("/api/chat/channels/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Get channel with details
        local channel = ChatChannelQueries.showWithDetails(channel_uuid, user.uuid)

        if not channel then
            return { status = 404, json = { error = "Channel not found" } }
        end

        -- Check membership for private channels
        if channel.type == "private" and not channel.current_user_role then
            return { status = 403, json = { error = "Access denied" } }
        end

        return {
            status = 200,
            json = channel
        }
    end)

    -- PUT /api/chat/channels/:uuid - Update channel
    app:put("/api/chat/channels/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Check if user is admin
        if not ChatChannelQueries.isAdmin(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can update channels" } }
        end

        local data = parse_json_body()

        local update_params = {}
        if data.name then update_params.name = data.name end
        if data.description then update_params.description = data.description end
        if data.avatar_url then update_params.avatar_url = data.avatar_url end

        if next(update_params) == nil then
            return { status = 400, json = { error = "No fields to update" } }
        end

        local channel = ChatChannelQueries.update(channel_uuid, update_params)

        if not channel then
            return { status = 404, json = { error = "Channel not found" } }
        end

        return {
            status = 200,
            json = channel
        }
    end)

    -- DELETE /api/chat/channels/:uuid - Archive channel
    app:delete("/api/chat/channels/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Check if user is admin
        if not ChatChannelQueries.isAdmin(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can delete channels" } }
        end

        local channel = ChatChannelQueries.archive(channel_uuid)

        if not channel then
            return { status = 404, json = { error = "Channel not found" } }
        end

        return {
            status = 200,
            json = { message = "Channel archived successfully" }
        }
    end)

    -- GET /api/chat/channels/:uuid/members - Get channel members
    app:get("/api/chat/channels/:uuid/members", function(self)
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
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 50
        }

        local result = ChatChannelQueries.getMembers(channel_uuid, params)

        return {
            status = 200,
            json = {
                data = result.data,
                total = result.total,
                page = params.page,
                perPage = params.perPage
            }
        }
    end)

    -- POST /api/chat/channels/:uuid/members - Add members to channel
    app:post("/api/chat/channels/:uuid/members", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Check if user is admin
        if not ChatChannelQueries.isAdmin(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can add members" } }
        end

        local data = parse_json_body()

        if not data.user_uuids or type(data.user_uuids) ~= "table" or #data.user_uuids == 0 then
            return { status = 400, json = { error = "user_uuids array is required" } }
        end

        local role = data.role or "member"
        local result = ChatChannelMemberQueries.addMembers(channel_uuid, data.user_uuids, role, user.uuid)

        -- Create system message for new members
        if #result.added > 0 then
            local names = {}
            for _, member in ipairs(result.added) do
                table.insert(names, member.user_uuid)
            end
            ChatMessageQueries.createSystemMessage(
                channel_uuid,
                "New members joined: " .. table.concat(names, ", ")
            )
        end

        return {
            status = 200,
            json = {
                added = #result.added,
                failed = #result.failed,
                details = result
            }
        }
    end)

    -- DELETE /api/chat/channels/:uuid/members/:user_uuid - Remove member from channel
    app:delete("/api/chat/channels/:uuid/members/:user_uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid
        local member_uuid = self.params.user_uuid

        -- Users can remove themselves, or admins can remove others
        if member_uuid ~= user.uuid and not ChatChannelQueries.isAdmin(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can remove other members" } }
        end

        local result, remove_err = ChatChannelMemberQueries.removeMember(channel_uuid, member_uuid)

        if not result then
            return { status = 404, json = { error = remove_err or "Member not found" } }
        end

        return {
            status = 200,
            json = { message = "Member removed successfully" }
        }
    end)

    -- PUT /api/chat/channels/:uuid/members/:user_uuid/role - Update member role
    app:put("/api/chat/channels/:uuid/members/:user_uuid/role", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid
        local member_uuid = self.params.user_uuid

        -- Check if user is admin
        if not ChatChannelQueries.isAdmin(channel_uuid, user.uuid) then
            return { status = 403, json = { error = "Only admins can change roles" } }
        end

        local data = parse_json_body()

        if not data.role then
            return { status = 400, json = { error = "Role is required" } }
        end

        local valid_roles = { admin = true, moderator = true, member = true }
        if not valid_roles[data.role] then
            return { status = 400, json = { error = "Invalid role. Must be: admin, moderator, or member" } }
        end

        local result, update_err = ChatChannelMemberQueries.updateRole(channel_uuid, member_uuid, data.role)

        if not result then
            return { status = 404, json = { error = update_err or "Member not found" } }
        end

        return {
            status = 200,
            json = result
        }
    end)

    -- PUT /api/chat/channels/:uuid/settings - Update channel settings for current user
    app:put("/api/chat/channels/:uuid/settings", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid
        local data = parse_json_body()

        local settings = {}
        if data.is_muted ~= nil then settings.is_muted = data.is_muted end
        if data.notification_preference then
            local valid_prefs = { all = true, mentions = true, none = true }
            if not valid_prefs[data.notification_preference] then
                return { status = 400, json = { error = "Invalid notification_preference" } }
            end
            settings.notification_preference = data.notification_preference
        end

        local result, update_err = ChatChannelMemberQueries.updateSettings(channel_uuid, user.uuid, settings)

        if not result then
            return { status = 404, json = { error = update_err or "Not a member of this channel" } }
        end

        return {
            status = 200,
            json = result
        }
    end)

    -- POST /api/chat/channels/:uuid/read - Mark channel as read
    app:post("/api/chat/channels/:uuid/read", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Call markAsRead directly (it has its own error handling)
        local result, read_err = ChatChannelMemberQueries.markAsRead(channel_uuid, user.uuid)

        if not result then
            -- Return 200 with warning instead of 404 to not break UI flow
            -- User might not be a member yet but this shouldn't block the channel view
            ngx.log(ngx.WARN, "markAsRead: ", read_err or "Unknown error", ", channel=", channel_uuid, " user=", user.uuid)
            return {
                status = 200,
                json = { message = "Acknowledged", warning = read_err or "Not a member of this channel" }
            }
        end

        -- Handle case where result is a Lapis model object (has last_read_at directly)
        local last_read_at = result.last_read_at
        if type(result) == "table" and not last_read_at then
            -- Try to get from nested structure
            last_read_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        end

        return {
            status = 200,
            json = { message = "Channel marked as read", last_read_at = last_read_at }
        }
    end)

    -- POST /api/chat/channels/:uuid/join - Join a public channel
    app:post("/api/chat/channels/:uuid/join", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        -- Get channel
        local channel = ChatChannelQueries.show(channel_uuid)
        if not channel then
            return { status = 404, json = { error = "Channel not found" } }
        end

        -- Only allow joining public channels
        if channel.type ~= "public" then
            return { status = 403, json = { error = "Cannot join private channels directly" } }
        end

        -- Check if already a member
        if ChatChannelQueries.isMember(channel_uuid, user.uuid) then
            return { status = 400, json = { error = "Already a member of this channel" } }
        end

        local member = ChatChannelMemberQueries.addMember(channel_uuid, user.uuid, "member")

        if not member then
            return { status = 500, json = { error = "Failed to join channel" } }
        end

        return {
            status = 200,
            json = { message = "Joined channel successfully", member = member }
        }
    end)

    -- POST /api/chat/channels/:uuid/leave - Leave a channel
    app:post("/api/chat/channels/:uuid/leave", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.uuid

        local result, leave_err = ChatChannelMemberQueries.removeMember(channel_uuid, user.uuid)

        if not result then
            return { status = 404, json = { error = leave_err or "Not a member of this channel" } }
        end

        return {
            status = 200,
            json = { message = "Left channel successfully" }
        }
    end)

    -- GET /api/chat/channels/search - Search channels
    app:get("/api/chat/channels/search", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        if not user.uuid_business_id then
            return { status = 400, json = { error = "Business ID required" } }
        end

        local search_term = self.params.q or self.params.query
        if not search_term or search_term == "" then
            return { status = 400, json = { error = "Search query is required" } }
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20
        }

        local result = ChatChannelQueries.search(user.uuid_business_id, search_term, params)

        return {
            status = 200,
            json = result
        }
    end)

    -- POST /api/chat/channels/direct - Create or get direct message channel
    app:post("/api/chat/channels/direct", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local data = parse_json_body()

        if not data.user_uuid then
            return { status = 400, json = { error = "user_uuid is required" } }
        end

        if data.user_uuid == user.uuid then
            return { status = 400, json = { error = "Cannot create direct channel with yourself" } }
        end

        -- Check if direct channel already exists
        local existing = ChatChannelQueries.getDirectChannel(user.uuid, data.user_uuid)
        if existing then
            return {
                status = 200,
                json = { channel = existing, created = false }
            }
        end

        -- Get namespace_id (required for foreign key constraint)
        local namespace_id = get_namespace_id()
        if not namespace_id then
            return { status = 400, json = { error = "Namespace context required" } }
        end

        -- Create new direct channel
        local channel = ChatChannelQueries.create({
            uuid = Global.generateUUID(),
            name = "Direct Message",
            type = "direct",
            created_by = user.uuid,
            uuid_business_id = user.uuid_business_id,
            namespace_id = namespace_id
        })

        if not channel then
            return { status = 500, json = { error = "Failed to create channel" } }
        end

        -- Add both users as members
        ChatChannelMemberQueries.addMember(channel.uuid, user.uuid, "member")
        ChatChannelMemberQueries.addMember(channel.uuid, data.user_uuid, "member")

        return {
            status = 201,
            json = { channel = channel, created = true }
        }
    end)

    -- POST /api/chat/channels/defaults - Create default channels for business
    app:post("/api/chat/channels/defaults", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        if not user.uuid_business_id then
            return { status = 400, json = { error = "Business ID required" } }
        end

        -- Get namespace_id (required for foreign key constraint)
        local namespace_id = get_namespace_id()
        if not namespace_id then
            return { status = 400, json = { error = "Namespace context required" } }
        end

        local channels = ChatChannelQueries.createDefaults(user.uuid_business_id, user.uuid, namespace_id)

        -- Add creator to all default channels
        for _, channel in ipairs(channels) do
            ChatChannelMemberQueries.addMember(channel.uuid, user.uuid, "admin")
        end

        return {
            status = 201,
            json = { channels = channels }
        }
    end)
end
