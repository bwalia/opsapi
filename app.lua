local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to
local UserModel = require "model.UserModel"
local Json = require("cjson")
local app = lapis.Application()


app:get("/", function()
  return "Welcome to Lapis " .. require("lapis.version")
end)

app:match("user", "/user", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local users = UserModel.all(self.params)
    return Json.encode({
      json = users
    })
  end,
  POST = function(self)
    local user = UserModel.create(self.params)
    return { json = user, status = 201 }
  end
}))

app:match("edit_user", "/user/:id", respond_to({
  before = function(self)
    self.user = UserModel.show(tostring(self.params.id))
    if not self.user then
      self:write({ "Not Found", status = 404 })
    end
  end,
  GET = function(self)
    local user = UserModel.show(tostring(self.params.id))
    return {
      json = user,
      status = 200
    }
  end,
  PUT = function(self)
    local user = UserModel.update(tostring(self.params.id), self.params)
    return { json = user, status = 200 }
  end
}))

return app
