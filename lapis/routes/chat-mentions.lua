local cjson = require("cjson.safe")
local db = require("lapis.db")
local Global = require "helper.global"

return function(app)
    ----------------- Chat Mentions Routes --------------------

    -- Helper function to get current user from headers
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

    -- GET /api/chat/mentions - Get all mentions for current user
    app:get("/api/chat/mentions", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local limit = tonumber(self.params.limit) or 50
        local offset = tonumber(self.params.offset) or 0
        local unread_only = self.params.unread == "true"

        local sql
        local query_params

        if unread_only then
            sql = [[
                SELECT
                    m.uuid as mention_uuid,
                    m.message_uuid,
                    m.channel_uuid,
                    m.mentioned_by_uuid,
                    m.mention_type,
                    m.is_read,
                    m.created_at,
                    msg.content as message_content,
                    msg.content_type as message_content_type,
                    c.name as channel_name,
                    c.type as channel_type,
                    u.first_name as mentioned_by_first_name,
                    u.last_name as mentioned_by_last_name,
                    u.username as mentioned_by_username,
                    u.email as mentioned_by_email
                FROM chat_mentions m
                INNER JOIN chat_messages msg ON msg.uuid = m.message_uuid
                INNER JOIN chat_channels c ON c.uuid = m.channel_uuid
                INNER JOIN users u ON u.uuid = m.mentioned_by_uuid
                WHERE m.mentioned_user_uuid = ?
                  AND m.is_read = false
                  AND msg.is_deleted = false
                ORDER BY m.created_at DESC
                LIMIT ? OFFSET ?
            ]]
            query_params = { user.uuid, limit, offset }
        else
            sql = [[
                SELECT
                    m.uuid as mention_uuid,
                    m.message_uuid,
                    m.channel_uuid,
                    m.mentioned_by_uuid,
                    m.mention_type,
                    m.is_read,
                    m.created_at,
                    msg.content as message_content,
                    msg.content_type as message_content_type,
                    c.name as channel_name,
                    c.type as channel_type,
                    u.first_name as mentioned_by_first_name,
                    u.last_name as mentioned_by_last_name,
                    u.username as mentioned_by_username,
                    u.email as mentioned_by_email
                FROM chat_mentions m
                INNER JOIN chat_messages msg ON msg.uuid = m.message_uuid
                INNER JOIN chat_channels c ON c.uuid = m.channel_uuid
                INNER JOIN users u ON u.uuid = m.mentioned_by_uuid
                WHERE m.mentioned_user_uuid = ?
                  AND msg.is_deleted = false
                ORDER BY m.created_at DESC
                LIMIT ? OFFSET ?
            ]]
            query_params = { user.uuid, limit, offset }
        end

        local mentions = db.query(sql, table.unpack(query_params))

        -- Get total count
        local count_sql
        if unread_only then
            count_sql = [[
                SELECT COUNT(*) as total
                FROM chat_mentions m
                INNER JOIN chat_messages msg ON msg.uuid = m.message_uuid
                WHERE m.mentioned_user_uuid = ?
                  AND m.is_read = false
                  AND msg.is_deleted = false
            ]]
        else
            count_sql = [[
                SELECT COUNT(*) as total
                FROM chat_mentions m
                INNER JOIN chat_messages msg ON msg.uuid = m.message_uuid
                WHERE m.mentioned_user_uuid = ?
                  AND msg.is_deleted = false
            ]]
        end

        local count_result = db.query(count_sql, user.uuid)
        local total = count_result and count_result[1] and tonumber(count_result[1].total) or 0

        return {
            status = 200,
            json = {
                data = mentions or {},
                total = total,
                limit = limit,
                offset = offset,
                unread_only = unread_only
            }
        }
    end)

    -- GET /api/chat/mentions/unread/count - Get unread mentions count
    app:get("/api/chat/mentions/unread/count", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local sql = [[
            SELECT COUNT(*) as count
            FROM chat_mentions m
            INNER JOIN chat_messages msg ON msg.uuid = m.message_uuid
            WHERE m.mentioned_user_uuid = ?
              AND m.is_read = false
              AND msg.is_deleted = false
        ]]

        local result = db.query(sql, user.uuid)
        local count = result and result[1] and tonumber(result[1].count) or 0

        return {
            status = 200,
            json = {
                unread_count = count
            }
        }
    end)

    -- GET /api/chat/channels/:channel_uuid/mentions - Get mentions in a specific channel
    app:get("/api/chat/channels/:channel_uuid/mentions", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid
        local limit = tonumber(self.params.limit) or 50
        local offset = tonumber(self.params.offset) or 0

        local sql = [[
            SELECT
                m.uuid as mention_uuid,
                m.message_uuid,
                m.channel_uuid,
                m.mentioned_by_uuid,
                m.mention_type,
                m.is_read,
                m.created_at,
                msg.content as message_content,
                msg.content_type as message_content_type,
                u.first_name as mentioned_by_first_name,
                u.last_name as mentioned_by_last_name,
                u.username as mentioned_by_username
            FROM chat_mentions m
            INNER JOIN chat_messages msg ON msg.uuid = m.message_uuid
            INNER JOIN users u ON u.uuid = m.mentioned_by_uuid
            WHERE m.mentioned_user_uuid = ?
              AND m.channel_uuid = ?
              AND msg.is_deleted = false
            ORDER BY m.created_at DESC
            LIMIT ? OFFSET ?
        ]]

        local mentions = db.query(sql, user.uuid, channel_uuid, limit, offset)

        return {
            status = 200,
            json = {
                data = mentions or {},
                channel_uuid = channel_uuid
            }
        }
    end)

    -- POST /api/chat/mentions/:uuid/read - Mark a mention as read
    app:post("/api/chat/mentions/:uuid/read", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local mention_uuid = self.params.uuid

        local sql = [[
            UPDATE chat_mentions
            SET is_read = true
            WHERE uuid = ?
              AND mentioned_user_uuid = ?
            RETURNING uuid
        ]]

        local result = db.query(sql, mention_uuid, user.uuid)

        if not result or #result == 0 then
            return { status = 404, json = { error = "Mention not found or not yours" } }
        end

        return {
            status = 200,
            json = { message = "Mention marked as read" }
        }
    end)

    -- POST /api/chat/mentions/read-all - Mark all mentions as read
    app:post("/api/chat/mentions/read-all", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local sql = [[
            UPDATE chat_mentions
            SET is_read = true
            WHERE mentioned_user_uuid = ?
              AND is_read = false
        ]]

        db.query(sql, user.uuid)

        return {
            status = 200,
            json = { message = "All mentions marked as read" }
        }
    end)

    -- POST /api/chat/channels/:channel_uuid/mentions/read-all - Mark all mentions in a channel as read
    app:post("/api/chat/channels/:channel_uuid/mentions/read-all", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid

        local sql = [[
            UPDATE chat_mentions
            SET is_read = true
            WHERE mentioned_user_uuid = ?
              AND channel_uuid = ?
              AND is_read = false
        ]]

        db.query(sql, user.uuid, channel_uuid)

        return {
            status = 200,
            json = {
                message = "All mentions in channel marked as read",
                channel_uuid = channel_uuid
            }
        }
    end)

    -- GET /api/chat/users/mentionable - Get users that can be mentioned (for autocomplete)
    app:get("/api/chat/users/mentionable", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local channel_uuid = self.params.channel_uuid
        local search = self.params.q or self.params.search or ""
        local limit = tonumber(self.params.limit) or 20

        local sql
        local query_params
        local has_search = search and search ~= ""

        if channel_uuid and channel_uuid ~= "" then
            -- Get users in the specific channel
            if has_search then
                sql = [[
                    SELECT uuid, username, first_name, last_name, email, presence_status
                    FROM (
                        SELECT DISTINCT ON (u.uuid)
                            u.uuid,
                            u.username,
                            u.first_name,
                            u.last_name,
                            u.email,
                            COALESCE(up.status, 'offline') as presence_status,
                            CASE WHEN up.status = 'online' THEN 0
                                 WHEN up.status = 'away' THEN 1
                                 ELSE 2
                            END as presence_order
                        FROM users u
                        INNER JOIN chat_channel_members cm ON cm.user_uuid = u.uuid
                        LEFT JOIN chat_user_presence up ON up.user_uuid = u.uuid
                        WHERE cm.channel_uuid = ?
                          AND cm.left_at IS NULL
                          AND u.uuid != ?
                          AND (
                              LOWER(u.username) LIKE LOWER(?)
                              OR LOWER(u.first_name) LIKE LOWER(?)
                              OR LOWER(u.last_name) LIKE LOWER(?)
                              OR LOWER(u.email) LIKE LOWER(?)
                              OR LOWER(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')) LIKE LOWER(?)
                          )
                        ORDER BY u.uuid
                    ) sub
                    ORDER BY presence_order, first_name, last_name
                    LIMIT ?
                ]]
                local search_pattern = "%" .. search .. "%"
                query_params = { channel_uuid, user.uuid, search_pattern, search_pattern, search_pattern, search_pattern, search_pattern, limit }
            else
                -- No search - get all channel members
                sql = [[
                    SELECT uuid, username, first_name, last_name, email, presence_status
                    FROM (
                        SELECT DISTINCT ON (u.uuid)
                            u.uuid,
                            u.username,
                            u.first_name,
                            u.last_name,
                            u.email,
                            COALESCE(up.status, 'offline') as presence_status,
                            CASE WHEN up.status = 'online' THEN 0
                                 WHEN up.status = 'away' THEN 1
                                 ELSE 2
                            END as presence_order
                        FROM users u
                        INNER JOIN chat_channel_members cm ON cm.user_uuid = u.uuid
                        LEFT JOIN chat_user_presence up ON up.user_uuid = u.uuid
                        WHERE cm.channel_uuid = ?
                          AND cm.left_at IS NULL
                          AND u.uuid != ?
                        ORDER BY u.uuid
                    ) sub
                    ORDER BY presence_order, first_name, last_name
                    LIMIT ?
                ]]
                query_params = { channel_uuid, user.uuid, limit }
            end
        else
            -- Get all users (for DMs or when channel not specified)
            if has_search then
                sql = [[
                    SELECT uuid, username, first_name, last_name, email, presence_status
                    FROM (
                        SELECT DISTINCT ON (u.uuid)
                            u.uuid,
                            u.username,
                            u.first_name,
                            u.last_name,
                            u.email,
                            COALESCE(up.status, 'offline') as presence_status,
                            CASE WHEN up.status = 'online' THEN 0
                                 WHEN up.status = 'away' THEN 1
                                 ELSE 2
                            END as presence_order
                        FROM users u
                        LEFT JOIN chat_user_presence up ON up.user_uuid = u.uuid
                        WHERE u.uuid != ?
                          AND (
                              LOWER(u.username) LIKE LOWER(?)
                              OR LOWER(u.first_name) LIKE LOWER(?)
                              OR LOWER(u.last_name) LIKE LOWER(?)
                              OR LOWER(u.email) LIKE LOWER(?)
                              OR LOWER(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')) LIKE LOWER(?)
                          )
                        ORDER BY u.uuid
                    ) sub
                    ORDER BY presence_order, first_name, last_name
                    LIMIT ?
                ]]
                local search_pattern = "%" .. search .. "%"
                query_params = { user.uuid, search_pattern, search_pattern, search_pattern, search_pattern, search_pattern, limit }
            else
                -- No search - get all users
                sql = [[
                    SELECT uuid, username, first_name, last_name, email, presence_status
                    FROM (
                        SELECT DISTINCT ON (u.uuid)
                            u.uuid,
                            u.username,
                            u.first_name,
                            u.last_name,
                            u.email,
                            COALESCE(up.status, 'offline') as presence_status,
                            CASE WHEN up.status = 'online' THEN 0
                                 WHEN up.status = 'away' THEN 1
                                 ELSE 2
                            END as presence_order
                        FROM users u
                        LEFT JOIN chat_user_presence up ON up.user_uuid = u.uuid
                        WHERE u.uuid != ?
                        ORDER BY u.uuid
                    ) sub
                    ORDER BY presence_order, first_name, last_name
                    LIMIT ?
                ]]
                query_params = { user.uuid, limit }
            end
        end

        local users = db.query(sql, table.unpack(query_params))

        -- Format for mention autocomplete
        local mentionable = {}
        if users then
            for _, u in ipairs(users) do
                table.insert(mentionable, {
                    uuid = u.uuid,
                    username = u.username,
                    display_name = (u.first_name or "") .. " " .. (u.last_name or ""),
                    first_name = u.first_name,
                    last_name = u.last_name,
                    email = u.email,
                    status = u.presence_status
                })
            end
        end

        return {
            status = 200,
            json = {
                data = mentionable,
                special_mentions = {
                    { id = "channel", display = "@channel", description = "Notify all members" },
                    { id = "here", display = "@here", description = "Notify online members" },
                    { id = "everyone", display = "@everyone", description = "Notify all members" }
                }
            }
        }
    end)

    -- GET /api/chat/users/search - Search all users with chat status for DM
    -- Returns whether user is active on chat (member of any channel)
    -- Used for Direct Message user search
    -- Filters by namespace membership (users in the same namespace as the current user)
    app:get("/api/chat/users/search", function(self)
        local user, err = get_current_user()
        if not user then
            return { status = 401, json = { error = err } }
        end

        local search = self.params.q or self.params.search or ""
        local limit = tonumber(self.params.limit) or 20

        -- Validate search query
        if not search or search == "" or #search < 2 then
            return {
                status = 400,
                json = { error = "Search query must be at least 2 characters" }
            }
        end

        local search_pattern = "%" .. search .. "%"

        -- Debug: Log the current user's namespaces
        local debug_ns_sql = [[
            SELECT nm.namespace_id, n.name as namespace_name, n.slug
            FROM namespace_members nm
            INNER JOIN users u ON u.id = nm.user_id
            INNER JOIN namespaces n ON n.id = nm.namespace_id
            WHERE u.uuid = ? AND nm.status = 'active'
        ]]
        local user_namespaces = db.query(debug_ns_sql, user.uuid)
        ngx.log(ngx.NOTICE, "[Chat Search] User ", user.uuid, " namespaces: ", cjson.encode(user_namespaces or {}))

        -- Debug: Count total users matching search (without namespace filter)
        local debug_count_sql = [[
            SELECT COUNT(*) as total FROM users u
            WHERE u.uuid != ?
              AND (
                  LOWER(COALESCE(u.username, '')) LIKE LOWER(?)
                  OR LOWER(COALESCE(u.first_name, '')) LIKE LOWER(?)
                  OR LOWER(COALESCE(u.last_name, '')) LIKE LOWER(?)
                  OR LOWER(COALESCE(u.email, '')) LIKE LOWER(?)
              )
        ]]
        local total_matching = db.query(debug_count_sql, user.uuid, search_pattern, search_pattern, search_pattern, search_pattern)
        ngx.log(ngx.NOTICE, "[Chat Search] Total users matching '", search, "' (without namespace filter): ", total_matching and total_matching[1] and total_matching[1].total or 0)

        -- Debug: Check how many users are in namespace_members at all
        local debug_nm_sql = [[
            SELECT COUNT(DISTINCT nm.user_id) as users_in_namespaces,
                   COUNT(DISTINCT u.id) as total_users
            FROM users u
            LEFT JOIN namespace_members nm ON nm.user_id = u.id AND nm.status = 'active'
            WHERE u.uuid != ?
        ]]
        local nm_stats = db.query(debug_nm_sql, user.uuid)
        if nm_stats and nm_stats[1] then
            ngx.log(ngx.NOTICE, "[Chat Search] Users in namespaces: ", nm_stats[1].users_in_namespaces, ", Total users: ", nm_stats[1].total_users)
        end

        -- Query users in the same namespace(s) as current user, with their chat membership status
        -- This ensures users only see other users from their organization/namespace
        local sql = [[
            SELECT DISTINCT
                u.uuid,
                u.username,
                u.first_name,
                u.last_name,
                u.email,
                COALESCE(up.status, 'offline') as presence_status,
                CASE
                    WHEN EXISTS (
                        SELECT 1 FROM chat_channel_members cm
                        WHERE cm.user_uuid = u.uuid AND cm.left_at IS NULL
                    ) THEN true
                    ELSE false
                END as is_chat_active,
                CASE WHEN up.status = 'online' THEN 0
                     WHEN up.status = 'away' THEN 1
                     ELSE 2
                END as presence_order
            FROM users u
            LEFT JOIN chat_user_presence up ON up.user_uuid = u.uuid
            -- Join to namespace_members to filter by namespace
            INNER JOIN namespace_members nm ON nm.user_id = u.id AND nm.status = 'active'
            WHERE u.uuid != ?
              -- Note: We don't filter by u.active since users may have active=false by default
              -- All users in the same namespace should be searchable for chat
              -- User must be in a namespace that the current user is also in
              AND nm.namespace_id IN (
                  SELECT nm2.namespace_id
                  FROM namespace_members nm2
                  INNER JOIN users u2 ON u2.id = nm2.user_id
                  WHERE u2.uuid = ? AND nm2.status = 'active'
              )
              AND (
                  LOWER(COALESCE(u.username, '')) LIKE LOWER(?)
                  OR LOWER(COALESCE(u.first_name, '')) LIKE LOWER(?)
                  OR LOWER(COALESCE(u.last_name, '')) LIKE LOWER(?)
                  OR LOWER(COALESCE(u.email, '')) LIKE LOWER(?)
                  OR LOWER(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')) LIKE LOWER(?)
              )
            ORDER BY
                is_chat_active DESC,
                presence_order,
                first_name,
                last_name
            LIMIT ?
        ]]

        local users = db.query(sql, user.uuid, user.uuid, search_pattern, search_pattern, search_pattern, search_pattern, search_pattern, limit)

        ngx.log(ngx.NOTICE, "[Chat Search] Search '", search, "' found ", users and #users or 0, " users")

        -- Format response
        local result = {}
        if users then
            for _, u in ipairs(users) do
                local display_name = ""
                if u.first_name and u.last_name then
                    display_name = u.first_name .. " " .. u.last_name
                elseif u.first_name then
                    display_name = u.first_name
                elseif u.last_name then
                    display_name = u.last_name
                elseif u.username then
                    display_name = u.username
                else
                    display_name = u.email
                end

                table.insert(result, {
                    uuid = u.uuid,
                    username = u.username,
                    display_name = display_name,
                    first_name = u.first_name,
                    last_name = u.last_name,
                    email = u.email,
                    status = u.presence_status,
                    is_chat_active = u.is_chat_active
                })
            end
        end

        return {
            status = 200,
            json = {
                data = result,
                total = #result
            }
        }
    end)
end
