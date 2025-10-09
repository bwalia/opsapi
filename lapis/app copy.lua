local lapis = require("lapis")
local app = lapis.Application()

app:get("/", function()
    return "Hello World"
end)

app:post("/auth/login", function(self)
    return { json = { message = "Login endpoint works" } }
end)

return app

