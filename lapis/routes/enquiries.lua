--[[
    Enquiry Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local EnquiryQueries = require "queries.EnquiryQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- GET /api/v2/enquiries - List enquiries
    app:get("/api/v2/enquiries", AuthMiddleware.requireAuth(function(self)
        self.params.timestamp = true
        local enquiries = EnquiryQueries.all(self.params)
        return { json = enquiries }
    end))

    -- POST /api/v2/enquiries - Create enquiry
    app:post("/api/v2/enquiries", AuthMiddleware.requireAuth(function(self)
        local enquiry = EnquiryQueries.create(self.params)
        return { json = enquiry, status = 201 }
    end))

    -- GET /api/v2/enquiries/:id - Get single enquiry
    app:get("/api/v2/enquiries/:id", AuthMiddleware.requireAuth(function(self)
        local enquiry = EnquiryQueries.show(tostring(self.params.id))
        if not enquiry then
            return { json = { error = "Enquiry not found" }, status = 404 }
        end
        return { json = enquiry, status = 200 }
    end))

    -- PUT /api/v2/enquiries/:id - Update enquiry
    app:put("/api/v2/enquiries/:id", AuthMiddleware.requireAuth(function(self)
        local enquiry = EnquiryQueries.show(tostring(self.params.id))
        if not enquiry then
            return { json = { error = "Enquiry not found" }, status = 404 }
        end
        local updated = EnquiryQueries.update(tostring(self.params.id), self.params)
        return { json = updated, status = 200 }
    end))

    -- DELETE /api/v2/enquiries/:id - Delete enquiry
    app:delete("/api/v2/enquiries/:id", AuthMiddleware.requireAuth(function(self)
        local enquiry = EnquiryQueries.show(tostring(self.params.id))
        if not enquiry then
            return { json = { error = "Enquiry not found" }, status = 404 }
        end
        EnquiryQueries.destroy(tostring(self.params.id))
        return { json = { message = "Enquiry deleted successfully" }, status = 200 }
    end))
end
