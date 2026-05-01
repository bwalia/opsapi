local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")

return function(app)
    -- Get user's notifications
    app:match("get_notifications", "/api/v2/notifications", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                local limit = tonumber(self.params.limit) or 50
                local offset = tonumber(self.params.offset) or 0
                local unread_only = self.params.unread_only == "true"

                local where_clause = "user_id = " .. user_id
                if unread_only then
                    where_clause = where_clause .. " AND is_read = false"
                end

                local notifications = db.select("* from notifications where " .. where_clause ..
                    " order by created_at desc limit " .. limit .. " offset " .. offset)

                -- Get unread count
                local unread_count = db.query("select count(*) as count from notifications where user_id = ? and is_read = false", user_id)

                return {
                    json = {
                        notifications = notifications or {},
                        unread_count = (unread_count and unread_count[1] and unread_count[1].count) or 0
                    }
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in get_notifications: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))

    -- Mark notification as read
    app:match("mark_notification_read", "/api/v2/notifications/:id/read", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local notification_uuid = self.params.id

                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                -- Verify notification belongs to user
                local notification = db.select("* from notifications where uuid = ? and user_id = ?",
                    notification_uuid, user_id)

                if not notification or #notification == 0 then
                    return { json = { error = "Notification not found" }, status = 404 }
                end

                db.update("notifications", {
                    is_read = true,
                    read_at = db.format_date()
                }, "uuid = ?", notification_uuid)

                return { json = { message = "Notification marked as read" } }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in mark_notification_read: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))

    -- Mark all notifications as read
    app:match("mark_all_read", "/api/v2/notifications/mark-all-read", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                db.update("notifications", {
                    is_read = true,
                    read_at = db.format_date()
                }, "user_id = ? and is_read = false", user_id)

                return { json = { message = "All notifications marked as read" } }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in mark_all_read: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))

    -- Delete notification
    app:match("delete_notification", "/api/v2/notifications/:id", respond_to({
        DELETE = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local notification_uuid = self.params.id

                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                -- Verify notification belongs to user
                local notification = db.select("* from notifications where uuid = ? and user_id = ?",
                    notification_uuid, user_id)

                if not notification or #notification == 0 then
                    return { json = { error = "Notification not found" }, status = 404 }
                end

                db.delete("notifications", "uuid = ?", notification_uuid)

                return { json = { message = "Notification deleted" } }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in delete_notification: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))
end
