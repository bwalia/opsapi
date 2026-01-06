--[[
    Group Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local GroupQueries = require "queries.GroupQueries"
local Global = require "helper.global"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- GET /api/v2/groups - List groups
    app:get("/api/v2/groups", AuthMiddleware.requireAuth(function(self)
        self.params.timestamp = true
        local groups = GroupQueries.all(self.params)
        return { json = groups }
    end))

    -- POST /api/v2/groups - Create group
    app:post("/api/v2/groups", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.create(self.params)
        return { json = group, status = 201 }
    end))

    -- GET /api/v2/groups/:id - Get single group
    app:get("/api/v2/groups/:id", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.show(tostring(self.params.id))
        if not group then
            return { json = { error = "Group not found" }, status = 404 }
        end
        return { json = group, status = 200 }
    end))

    -- PUT /api/v2/groups/:id - Update group
    app:put("/api/v2/groups/:id", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.show(tostring(self.params.id))
        if not group then
            return { json = { error = "Group not found" }, status = 404 }
        end
        local updated = GroupQueries.update(tostring(self.params.id), self.params)
        return { json = updated, status = 200 }
    end))

    -- DELETE /api/v2/groups/:id - Delete group
    app:delete("/api/v2/groups/:id", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.show(tostring(self.params.id))
        if not group then
            return { json = { error = "Group not found" }, status = 404 }
        end
        GroupQueries.destroy(tostring(self.params.id))
        return { json = { message = "Group deleted successfully" }, status = 200 }
    end))

    -- POST /api/v2/groups/:id/members - Add member to group
    app:post("/api/v2/groups/:id/members", AuthMiddleware.requireAuth(function(self)
        local group, status = GroupQueries.addMember(self.params.id, self.params.user_id)
        return { json = group, status = status }
    end))

    ----------------- SCIM Group Routes --------------------
    -- GET /scim/v2/Groups - List groups (SCIM format)
    app:get("/scim/v2/Groups", AuthMiddleware.requireAuth(function(self)
        self.params.timestamp = true
        local groups = GroupQueries.SCIMall(self.params)
        return { json = groups }
    end))

    -- POST /scim/v2/Groups - Create group (SCIM format)
    app:post("/scim/v2/Groups", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.create(self.params)
        return { json = group, status = 201 }
    end))

    -- GET /scim/v2/Groups/:id - Get single group (SCIM format)
    app:get("/scim/v2/Groups/:id", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.show(tostring(self.params.id))
        if not group then
            return { json = { error = "Group not found" }, status = 404 }
        end
        return { json = group, status = 200 }
    end))

    -- PUT /scim/v2/Groups/:id - Update group (SCIM format)
    app:put("/scim/v2/Groups/:id", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.show(tostring(self.params.id))
        if not group then
            return { json = { error = "Group not found" }, status = 404 }
        end
        local content_type = self.req.headers["content-type"]
        local body = self.params
        if content_type == "application/json" then
            ngx.req.read_body()
            body = Global.getPayloads(ngx.req.get_post_args())
        end
        local updated, status = GroupQueries.SCIMupdate(tostring(self.params.id), body)
        return { json = updated, status = status }
    end))

    -- DELETE /scim/v2/Groups/:id - Delete group (SCIM format)
    app:delete("/scim/v2/Groups/:id", AuthMiddleware.requireAuth(function(self)
        local group = GroupQueries.show(tostring(self.params.id))
        if not group then
            return { json = { error = "Group not found" }, status = 404 }
        end
        GroupQueries.destroy(tostring(self.params.id))
        return { json = { message = "Group deleted" }, status = 204 }
    end))
end
