--[[
    Enquiry Routes

    SECURITY: JWT auth + namespace. Enquiries hold contact details and carry a
    namespace_id, so every read/write is scoped to the caller's tenant (they
    were previously global: any user could list/edit/delete every tenant's).
]]

local EnquiryQueries = require "queries.EnquiryQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local function tenant(handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(handler))
end

local NOT_FOUND = { json = { error = "Enquiry not found" }, status = 404 }

return function(app)
    -- GET /api/v2/enquiries - List enquiries
    app:get("/api/v2/enquiries", tenant(function(self)
        return { json = EnquiryQueries.all(self.params, self.namespace.id) }
    end))

    -- POST /api/v2/enquiries - Create enquiry
    app:post("/api/v2/enquiries", tenant(function(self)
        local enquiry = EnquiryQueries.create(self.params, self.namespace.id)
        return { json = enquiry, status = 201 }
    end))

    -- GET /api/v2/enquiries/:id - Get single enquiry
    app:get("/api/v2/enquiries/:id", tenant(function(self)
        local enquiry = EnquiryQueries.show(tostring(self.params.id), self.namespace.id)
        if not enquiry then return NOT_FOUND end
        return { json = enquiry, status = 200 }
    end))

    -- PUT /api/v2/enquiries/:id - Update enquiry
    app:put("/api/v2/enquiries/:id", tenant(function(self)
        local updated = EnquiryQueries.update(tostring(self.params.id), self.params, self.namespace.id)
        if not updated then return NOT_FOUND end
        return { json = updated, status = 200 }
    end))

    -- DELETE /api/v2/enquiries/:id - Delete enquiry
    app:delete("/api/v2/enquiries/:id", tenant(function(self)
        if not EnquiryQueries.destroy(tostring(self.params.id), self.namespace.id) then return NOT_FOUND end
        return { json = { message = "Enquiry deleted successfully" }, status = 200 }
    end))
end
