--[[
    Project Routes (legacy `projects` table)

    SECURITY: platform admins only. These records are global — the table has no
    namespace_id — so a tenant-level check can't scope them: with plain
    requireAuth any signed-in user of any workspace could list, create, change
    or delete every row. (Workspace project boards are the kanban module,
    /api/v2/kanban/*.) GET /api/v2/projects was also shadowed by the plugin
    listing until the plugin platform removed that route.
]]

local ProjectQueries = require "queries.ProjectQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- GET /api/v2/projects - List projects
    app:get("/api/v2/projects", AuthMiddleware.requireRole("administrative", function(self)
        self.params.timestamp = true
        local projects = ProjectQueries.all(self.params)
        return { json = projects, status = 200 }
    end))

    -- POST /api/v2/projects - Create project
    app:post("/api/v2/projects", AuthMiddleware.requireRole("administrative", function(self)
        local project = ProjectQueries.create(self.params)
        return { json = project, status = 201 }
    end))

    -- GET /api/v2/projects/:id - Get single project
    app:get("/api/v2/projects/:id", AuthMiddleware.requireRole("administrative", function(self)
        local project = ProjectQueries.show(tostring(self.params.id))
        if not project then
            return { json = { error = "Project not found" }, status = 404 }
        end
        return { json = project, status = 200 }
    end))

    -- PUT /api/v2/projects/:id - Update project
    app:put("/api/v2/projects/:id", AuthMiddleware.requireRole("administrative", function(self)
        local project = ProjectQueries.show(tostring(self.params.id))
        if not project then
            return { json = { error = "Project not found" }, status = 404 }
        end
        local updated = ProjectQueries.update(tostring(self.params.id), self.params)
        return { json = updated, status = 200 }
    end))

    -- DELETE /api/v2/projects/:id - Delete project
    app:delete("/api/v2/projects/:id", AuthMiddleware.requireRole("administrative", function(self)
        local project = ProjectQueries.show(tostring(self.params.id))
        if not project then
            return { json = { error = "Project not found" }, status = 404 }
        end
        ProjectQueries.destroy(tostring(self.params.id))
        return { json = { message = "Project deleted successfully" }, status = 200 }
    end))
end
