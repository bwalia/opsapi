--[[
    Tax Settings / User Self-Service Routes

    Endpoints for authenticated users to manage their own profile and preferences.
    No admin permissions required — users can only modify their own data.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local bcrypt = require("bcrypt")

-- Helper to get user record by JWT uuid
local function getUserByUuid(uuid)
    local rows = db.query("SELECT * FROM users WHERE uuid = ? LIMIT 1", uuid)
    if rows and #rows > 0 then
        return rows[1]
    end
    return nil
end

return function(app)
    -- =========================================================================
    -- GET /api/v2/tax/settings/profile
    -- Returns the authenticated user's profile for self-service editing
    -- =========================================================================
    app:get("/api/v2/tax/settings/profile", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local uuid = user.uuid or user.id
        local record = getUserByUuid(uuid)
        if not record then
            return { status = 404, json = { error = "User not found" } }
        end

        return {
            status = 200,
            json = {
                uuid = record.uuid,
                email = record.email,
                username = record.username,
                first_name = record.first_name,
                last_name = record.last_name,
                phone_no = record.phone_no,
                address = record.address,
                created_at = record.created_at,
                updated_at = record.updated_at,
            }
        }
    end)

    -- =========================================================================
    -- PUT /api/v2/tax/settings/profile
    -- Update own profile (first_name, last_name, phone_no, address)
    -- =========================================================================
    app:put("/api/v2/tax/settings/profile", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local uuid = user.uuid or user.id
        local record = getUserByUuid(uuid)
        if not record then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Parse JSON body
        local params = self.params
        if ngx.req.get_headers()["content-type"] and
            ngx.req.get_headers()["content-type"]:find("application/json") then
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if body then
                local ok, parsed = pcall(cjson.decode, body)
                if ok and parsed then
                    for k, v in pairs(parsed) do params[k] = v end
                end
            end
        end

        -- Build update fields (only allow safe fields)
        local updates = {}
        if params.first_name ~= nil then
            local v = tostring(params.first_name):match("^%s*(.-)%s*$")
            if #v > 100 then
                return { status = 400, json = { error = "first_name must be 100 characters or less" } }
            end
            updates.first_name = v
        end
        if params.last_name ~= nil then
            local v = tostring(params.last_name):match("^%s*(.-)%s*$")
            if #v > 100 then
                return { status = 400, json = { error = "last_name must be 100 characters or less" } }
            end
            updates.last_name = v
        end
        if params.phone_no ~= nil then
            local v = tostring(params.phone_no):match("^%s*(.-)%s*$")
            if #v > 20 then
                return { status = 400, json = { error = "phone_no must be 20 characters or less" } }
            end
            updates.phone_no = v
        end
        if params.address ~= nil then
            local v = tostring(params.address):match("^%s*(.-)%s*$")
            if #v > 500 then
                return { status = 400, json = { error = "address must be 500 characters or less" } }
            end
            updates.address = v
        end

        if not next(updates) then
            return { status = 400, json = { error = "No fields to update" } }
        end

        -- Build SQL SET clause
        local set_parts = {}
        local set_values = {}
        for field, value in pairs(updates) do
            table.insert(set_parts, field .. " = ?")
            table.insert(set_values, value)
        end
        table.insert(set_parts, "updated_at = NOW()")

        local sql = "UPDATE users SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ?"
        table.insert(set_values, uuid)

        db.query(sql, table.unpack(set_values))

        -- Return updated profile
        local updated = getUserByUuid(uuid)
        if updated ~= nil then
            return {
                status = 200,
                json = {
                    message = "Profile updated",
                    uuid = updated.uuid,
                    email = updated.email,
                    first_name = updated.first_name,
                    last_name = updated.last_name,
                    phone_no = updated.phone_no,
                    address = updated.address,
                    updated_at = updated.updated_at,
                }
            }
        else
            return { status = 200, json = {} }
        end
    end)

    -- =========================================================================
    -- POST /api/v2/tax/settings/change-password
    -- Change own password (requires current password verification)
    -- =========================================================================
    app:post("/api/v2/tax/settings/change-password", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local uuid = user.uuid or user.id
        local record = getUserByUuid(uuid)
        if not record then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Parse JSON body
        local params = self.params
        if ngx.req.get_headers()["content-type"] and
            ngx.req.get_headers()["content-type"]:find("application/json") then
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if body then
                local ok, parsed = pcall(cjson.decode, body)
                if ok and parsed then
                    for k, v in pairs(parsed) do params[k] = v end
                end
            end
        end

        local current_password = params.current_password
        local new_password = params.new_password

        if not current_password or current_password == "" then
            return { status = 400, json = { error = "Current password is required" } }
        end
        if not new_password or #new_password < 8 then
            return { status = 400, json = { error = "New password must be at least 8 characters" } }
        end

        -- Verify current password
        local password_valid = bcrypt.verify(current_password, record.password)
        if not password_valid then
            return { status = 403, json = { error = "Current password is incorrect" } }
        end

        -- Hash new password and update
        local hashed = bcrypt.digest(new_password, 10)
        db.query("UPDATE users SET password = ?, updated_at = NOW() WHERE uuid = ?", hashed, uuid)

        return {
            status = 200,
            json = { message = "Password changed successfully" }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/settings/preferences
    -- Get user's tax-related preferences (stored as JSON in user_settings)
    -- Falls back to defaults if no preferences set
    -- =========================================================================
    app:get("/api/v2/tax/settings/preferences", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local uuid = user.uuid or user.id
        local record = getUserByUuid(uuid)
        if not record then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Check if tax_user_preferences table exists, otherwise return defaults
        local ok, prefs = pcall(function()
            return db.query(
                "SELECT * FROM tax_user_preferences WHERE user_id = ? LIMIT 1",
                record.id
            )
        end)

        local defaults = {
            tax_year = nil, -- auto-detect current
            notification_email = true,
            notification_deadlines = true,
            auto_categorise = true,
            currency = "GBP",
            date_format = "DD/MM/YYYY",
        }

        if ok and prefs and #prefs > 0 then
            local p = prefs[1]
            -- Parse stored JSON preferences
            local stored = {}
            if p.preferences then
                local decode_ok, decoded = pcall(cjson.decode, p.preferences)
                if decode_ok then stored = decoded end
            end
            -- Merge with defaults
            for k, v in pairs(stored) do
                defaults[k] = v
            end
        end

        return { status = 200, json = defaults }
    end)

    -- =========================================================================
    -- PUT /api/v2/tax/settings/preferences
    -- Save user's tax-related preferences
    -- =========================================================================
    app:put("/api/v2/tax/settings/preferences", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local uuid = user.uuid or user.id
        local record = getUserByUuid(uuid)
        if not record then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Parse JSON body
        local params = {}
        if ngx.req.get_headers()["content-type"] and
            ngx.req.get_headers()["content-type"]:find("application/json") then
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if body then
                local ok, parsed = pcall(cjson.decode, body)
                if ok and parsed then params = parsed end
            end
        end

        local prefs_json = cjson.encode(params)

        -- Upsert preferences (try table, fall back gracefully)
        local ok, err = pcall(function()
            -- Try to create the table if it doesn't exist (one-time auto-migration)
            db.query([[
                CREATE TABLE IF NOT EXISTS tax_user_preferences (
                    id SERIAL PRIMARY KEY,
                    user_id INTEGER UNIQUE NOT NULL,
                    preferences TEXT,
                    created_at TIMESTAMP DEFAULT NOW(),
                    updated_at TIMESTAMP DEFAULT NOW()
                )
            ]])

            db.query([[
                INSERT INTO tax_user_preferences (user_id, preferences, updated_at)
                VALUES (?, ?, NOW())
                ON CONFLICT (user_id) DO UPDATE SET preferences = ?, updated_at = NOW()
            ]], record.id, prefs_json, prefs_json)
        end)

        if not ok then
            ngx.log(ngx.ERR, "Failed to save preferences: ", tostring(err))
            return { status = 500, json = { error = "Failed to save preferences" } }
        end

        return { status = 200, json = { message = "Preferences saved", preferences = params } }
    end)

    -- =========================================================================
    -- DELETE /api/v2/tax/settings/account
    -- Request account deletion (soft-delete — sets active=false)
    -- =========================================================================
    app:delete("/api/v2/tax/settings/account", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local uuid = user.uuid or user.id

        -- Parse JSON body for password confirmation
        local params = self.params
        if ngx.req.get_headers()["content-type"] and
            ngx.req.get_headers()["content-type"]:find("application/json") then
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if body then
                local ok, parsed = pcall(cjson.decode, body)
                if ok and parsed then
                    for k, v in pairs(parsed) do params[k] = v end
                end
            end
        end

        if not params.password or params.password == "" then
            return { status = 400, json = { error = "Password confirmation required" } }
        end

        local record = getUserByUuid(uuid)
        if not record then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Verify password
        local password_valid = bcrypt.verify(params.password, record.password)
        if not password_valid then
            return { status = 403, json = { error = "Password is incorrect" } }
        end

        -- Soft delete — deactivate account
        db.query("UPDATE users SET active = false, updated_at = NOW() WHERE uuid = ?", uuid)

        return {
            status = 200,
            json = { message = "Account deactivated. Contact support to permanently delete your data." }
        }
    end)
end
