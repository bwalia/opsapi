--[[
    Tags Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local TagsQueries = require "queries.TagsQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- GET /api/v2/tags - List tags
    app:get("/api/v2/tags", AuthMiddleware.requireAuth(function(self)
        self.params.timestamp = true
        local tags = TagsQueries.all(self.params)
        return { json = tags, status = 200 }
    end))

    -- POST /api/v2/tags - Create tag
    app:post("/api/v2/tags", AuthMiddleware.requireAuth(function(self)
        local tag = TagsQueries.create(self.params)
        return { json = tag, status = 201 }
    end))

    -- GET /api/v2/tags/:id - Get single tag
    app:get("/api/v2/tags/:id", AuthMiddleware.requireAuth(function(self)
        local tag = TagsQueries.show(tostring(self.params.id))
        if not tag then
            return { json = { error = "Tag not found" }, status = 404 }
        end
        return { json = tag, status = 200 }
    end))

    -- PUT /api/v2/tags/:id - Update tag
    app:put("/api/v2/tags/:id", AuthMiddleware.requireAuth(function(self)
        local tag = TagsQueries.show(tostring(self.params.id))
        if not tag then
            return { json = { error = "Tag not found" }, status = 404 }
        end
        local updated = TagsQueries.update(tostring(self.params.id), self.params)
        return { json = updated, status = 200 }
    end))

    -- DELETE /api/v2/tags/:id - Delete tag
    app:delete("/api/v2/tags/:id", AuthMiddleware.requireAuth(function(self)
        local tag = TagsQueries.show(tostring(self.params.id))
        if not tag then
            return { json = { error = "Tag not found" }, status = 404 }
        end
        TagsQueries.destroy(tostring(self.params.id))
        return { json = { message = "Tag deleted successfully" }, status = 200 }
    end))
end
