--[[
    Project Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local ProjectQueries = require "queries.ProjectQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- GET /api/v2/projects - List projects
    app:get("/api/v2/projects", AuthMiddleware.requireAuth(function(self)
        self.params.timestamp = true
        local projects = ProjectQueries.all(self.params)
        return { json = projects, status = 200 }
    end))

    -- POST /api/v2/projects - Create project
    app:post("/api/v2/projects", AuthMiddleware.requireAuth(function(self)
        local project = ProjectQueries.create(self.params)
        return { json = project, status = 201 }
    end))

    -- GET /api/v2/projects/:id - Get single project
    app:get("/api/v2/projects/:id", AuthMiddleware.requireAuth(function(self)
        local project = ProjectQueries.show(tostring(self.params.id))
        if not project then
            return { json = { error = "Project not found" }, status = 404 }
        end
        return { json = project, status = 200 }
    end))

    -- PUT /api/v2/projects/:id - Update project
    app:put("/api/v2/projects/:id", AuthMiddleware.requireAuth(function(self)
        local project = ProjectQueries.show(tostring(self.params.id))
        if not project then
            return { json = { error = "Project not found" }, status = 404 }
        end
        local updated = ProjectQueries.update(tostring(self.params.id), self.params)
        return { json = updated, status = 200 }
    end))

    -- DELETE /api/v2/projects/:id - Delete project
    app:delete("/api/v2/projects/:id", AuthMiddleware.requireAuth(function(self)
        local project = ProjectQueries.show(tostring(self.params.id))
        if not project then
            return { json = { error = "Project not found" }, status = 404 }
        end
        ProjectQueries.destroy(tostring(self.params.id))
        return { json = { message = "Project deleted successfully" }, status = 200 }
    end))
end
