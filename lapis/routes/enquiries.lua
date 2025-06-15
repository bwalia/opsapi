local respond_to = require("lapis.application").respond_to
local EnquiryQueries = require "queries.EnquiryQueries"

return function(app)
    app:match("enquiries", "/api/v2/enquiries", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local roles = EnquiryQueries.all(self.params)
            return {
                json = roles
            }
        end,
        POST = function(self)
            local roles = EnquiryQueries.create(self.params)
            return {
                json = roles,
                status = 201
            }
        end
    }))

    app:match("edit_enquiry", "/api/v2/enquiries/:id", respond_to({
        before = function(self)
            self.role = EnquiryQueries.show(tostring(self.params.id))
            if not self.role then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "Role not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local role = EnquiryQueries.show(tostring(self.params.id))
            return {
                json = role,
                status = 200
            }
        end,
        PUT = function(self)
            local role = EnquiryQueries.update(tostring(self.params.id), self.params)
            return {
                json = role,
                status = 204
            }
        end,
        DELETE = function(self)
            local role = EnquiryQueries.destroy(tostring(self.params.id))
            return {
                json = role,
                status = 204
            }
        end
    }))
end
