local lapis = require("lapis")
local cJson = require("cjson")
local File = require "helper.file"
local SwaggerUi = require "api-docs.swaggerUi"

return function(app)
    app:match("/", function()
        SwaggerUi.generate()
        return { render = "swagger-ui" }
    end)

    app:match("/swagger/swagger.json", function()
        local swaggerJson = File.readFile("api-docs/swagger.json")
        return { json = cJson.decode(swaggerJson) }
    end)
end
