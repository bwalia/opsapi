--[[
    Template Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local TemplateQueries = require "queries.TemplateQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- GET /api/v2/templates - List templates
    app:get("/api/v2/templates", AuthMiddleware.requireAuth(function(self)
        self.params.timestamp = true
        local templates = TemplateQueries.all(self.params)
        return { json = templates, status = 200 }
    end))

    -- POST /api/v2/templates - Create template
    app:post("/api/v2/templates", AuthMiddleware.requireAuth(function(self)
        local template = TemplateQueries.create(self.params)
        return { json = template, status = 201 }
    end))

    -- GET /api/v2/templates/:id - Get single template
    app:get("/api/v2/templates/:id", AuthMiddleware.requireAuth(function(self)
        local template = TemplateQueries.show(tostring(self.params.id))
        if not template then
            return { json = { error = "Template not found" }, status = 404 }
        end
        return { json = template, status = 200 }
    end))

    -- PUT /api/v2/templates/:id - Update template
    app:put("/api/v2/templates/:id", AuthMiddleware.requireAuth(function(self)
        local template = TemplateQueries.show(tostring(self.params.id))
        if not template then
            return { json = { error = "Template not found" }, status = 404 }
        end
        local updated = TemplateQueries.update(tostring(self.params.id), self.params)
        return { json = updated, status = 200 }
    end))

    -- DELETE /api/v2/templates/:id - Delete template
    app:delete("/api/v2/templates/:id", AuthMiddleware.requireAuth(function(self)
        local template = TemplateQueries.show(tostring(self.params.id))
        if not template then
            return { json = { error = "Template not found" }, status = 404 }
        end
        TemplateQueries.destroy(tostring(self.params.id))
        return { json = { message = "Template deleted successfully" }, status = 200 }
    end))
end
