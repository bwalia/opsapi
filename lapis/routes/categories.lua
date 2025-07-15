local respond_to = require("lapis.application").respond_to
local CategoryQueries = require "queries.CategoryQueries"

return function(app)
    app:match("categories", "/api/v2/categories", respond_to({
        GET = function(self)
            return { json = CategoryQueries.all(self.params) }
        end,
        POST = function(self)
            return { json = CategoryQueries.create(self.params), status = 201 }
        end
    }))

    app:match("edit_category", "/api/v2/categories/:id", respond_to({
        before = function(self)
            self.category = CategoryQueries.show(tostring(self.params.id))
            if not self.category then
                self:write({ json = { error = "Category not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.category, status = 200 }
        end,
        PUT = function(self)
            return { json = CategoryQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = CategoryQueries.destroy(self.params.id), status = 204 }
        end
    }))
end
