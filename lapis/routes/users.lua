local respond_to = require("lapis.application").respond_to
local UserQueries = require "queries.UserQueries"
local RequestParser = require "helper.request_parser"
local Global = require "helper.global"
local cjson = require "cjson"

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Users API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    -- LIST users
    app:get("/api/v2/users", function(self)
        local params = self.params or {}

        local page = tonumber(params.page) or 1
        local perPage = tonumber(params.limit) or tonumber(params.per_page) or 10

        -- Handle offset-based pagination
        local offset = tonumber(params.offset) or 0
        if offset > 0 and page == 1 then
            page = math.floor(offset / perPage) + 1
        end

        local ok, result = pcall(UserQueries.all, {
            page = page,
            perPage = perPage,
            orderBy = params.order_by or 'id',
            orderDir = params.order_dir or 'desc'
        })

        if not ok then
            return error_response(500, "Failed to list users", tostring(result))
        end

        return {
            status = 200,
            json = {
                data = result.data or {},
                total = result.total or 0
            }
        }
    end)

    -- GET single user
    app:get("/api/v2/users/:id", function(self)
        local user_id = self.params.id

        local ok, user = pcall(UserQueries.show, user_id)

        if not ok then
            return error_response(500, "Failed to fetch user", tostring(user))
        end

        if not user then
            return error_response(404, "User not found")
        end

        return {
            status = 200,
            json = user
        }
    end)

    -- CREATE user
    app:post("/api/v2/users", function(self)
        local params, files = RequestParser.parse_request(self)

        local valid, missing = RequestParser.require_params(params, { "email", "password" })
        if not valid then
            return error_response(400, "Missing required fields", table.concat(missing, ", "))
        end

        local user_data = {
            email = params.email,
            password = params.password,
            first_name = params.first_name or params.firstName,
            last_name = params.last_name or params.lastName,
            username = params.username or params.email,
            role = params.role or "buyer"
        }

        ngx.log(ngx.NOTICE, "Creating user: ", params.email)

        local ok, user = pcall(UserQueries.create, user_data)

        if not ok then
            return error_response(500, "Failed to create user", tostring(user))
        end

        return {
            status = 201,
            json = user
        }
    end)

    -- UPDATE user
    app:put("/api/v2/users/:id", function(self)
        local user_id = self.params.id
        local params, files = RequestParser.parse_request(self)

        local update_data = {}
        if params.email then update_data.email = params.email end
        if params.first_name or params.firstName then
            update_data.first_name = params.first_name or params.firstName
        end
        if params.last_name or params.lastName then
            update_data.last_name = params.last_name or params.lastName
        end

        if next(update_data) == nil then
            return error_response(400, "No data provided for update")
        end

        local ok, result = pcall(UserQueries.update, user_id, update_data)

        if not ok then
            return error_response(500, "Failed to update user", tostring(result))
        end

        if not result then
            return error_response(404, "User not found")
        end

        -- Fetch the updated user to return
        local ok2, user = pcall(UserQueries.show, user_id)
        if not ok2 or not user then
            return error_response(500, "User updated but failed to fetch")
        end

        return {
            status = 200,
            json = user
        }
    end)

    -- DELETE user
    app:delete("/api/v2/users/:id", function(self)
        local user_id = self.params.id

        local ok, result = pcall(UserQueries.destroy, user_id)

        if not ok then
            return error_response(500, "Failed to delete user", tostring(result))
        end

        if not result then
            return error_response(404, "User not found")
        end

        return {
            status = 200,
            json = {
                message = "User deleted successfully",
                id = user_id
            }
        }
    end)

    ----------------- SCIM User Routes --------------------
    app:match("scim_users", "/scim/v2/Users", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local users = UserQueries.SCIMall(self.params)
            return {
                json = users,
                status = 200
            }
        end,
        POST = function(self)
            local user = UserQueries.SCIMcreate(self.params)
            return {
                json = user,
                status = 201
            }
        end
    }))

    app:match("edit_scim_user", "/scim/v2/Users/:id", respond_to({
        before = function(self)
            self.user = UserQueries.show(tostring(self.params.id))
            if not self.user then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "User not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local user = UserQueries.show(tostring(self.params.id))
            return {
                json = user,
                status = 200
            }
        end,
        PUT = function(self)
            local content_type = self.req.headers["content-type"]
            local body = self.params
            if content_type == "application/json" then
                ngx.req.read_body()
                body = Global.getPayloads(ngx.req.get_post_args())
            end
            local user, status = UserQueries.SCIMupdate(tostring(self.params.id), body)
            return {
                json = user,
                status = status
            }
        end,
        DELETE = function(self)
            local user = UserQueries.destroy(tostring(self.params.id))
            return {
                json = user,
                status = 204
            }
        end
    }))

    ngx.log(ngx.NOTICE, "Users routes initialized successfully")
end
