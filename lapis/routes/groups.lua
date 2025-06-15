local respond_to = require("lapis.application").respond_to
local GroupQueries = require "queries.GroupQueries"
local Global = require "helper.global"

return function(app)
    app:match("groups", "/api/v2/groups", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local groups = GroupQueries.all(self.params)
            return {
                json = groups
            }
        end,
        POST = function(self)
            local groups = GroupQueries.create(self.params)
            return {
                json = groups,
                status = 201
            }
        end
    }))

    app:match("edit_group", "/api/v2/groups/:id", respond_to({
        before = function(self)
            self.group = GroupQueries.show(tostring(self.params.id))
            if not self.group then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "Group not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local group = GroupQueries.show(tostring(self.params.id))
            return {
                json = group,
                status = 200
            }
        end,
        PUT = function(self)
            local group = GroupQueries.update(tostring(self.params.id), self.params)
            return {
                json = group,
                status = 204
            }
        end,
        DELETE = function(self)
            local group = GroupQueries.destroy(tostring(self.params.id))
            return {
                json = group,
                status = 204
            }
        end
    }))

    app:post("/api/v2/groups/:id/members", function(self)
        local group, status = GroupQueries.addMember(self.params.id, self.params.user_id)
        return {
            json = group,
            status = status
        }
    end)

    ----------------- SCIM Group Routes --------------------
    app:match("scim_groups", "/scim/v2/Groups", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local groups = GroupQueries.SCIMall(self.params)
            return {
                json = groups
            }
        end,
        POST = function(self)
            local groups = GroupQueries.create(self.params)
            return {
                json = groups,
                status = 201
            }
        end
    }))

    app:match("edit_scim_group", "/scim/v2/Groups/:id", respond_to({
        before = function(self)
            self.group = GroupQueries.show(tostring(self.params.id))
            if not self.group then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "Group not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local group = GroupQueries.show(tostring(self.params.id))
            return {
                json = group,
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
            local group, status = GroupQueries.SCIMupdate(tostring(self.params.id), body)
            return {
                json = group,
                status = status
            }
        end,
        DELETE = function(self)
            local group = GroupQueries.destroy(tostring(self.params.id))
            return {
                json = group,
                status = 204
            }
        end
    }))
end
