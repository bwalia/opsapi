local Model = require("lapis.db.model").Model

local Users = Model:extend("users", {
    timestamp = true,
    relations = {
        {"roles", has_many = "UserRoleModel", key = "user_id"}
    },
    constraints = {
        username = function(self, value)
          if #value < 3 or #value > 25 then
            return "Username must be between 3 and 25 characters long"
          end
        end,
        email = function(self, value)
          if not value:match("^[%w%.%-%+]+@[%.%w%-]+%.[%w%-]+$") then
            return "Invalid email address"
          end
        end
      }
})

return Users