local lapis = require("lapis")
local app = lapis.Application()
app:enable("etlua")

require("routes.index")(app)
require("routes.auth")(app)
require("routes.users")(app)
require("routes.roles")(app)
require("routes.groups")(app)
require("routes.module")(app)
require("routes.permissions")(app)
require("routes.documents")(app)
require("routes.secrets")(app)
require("routes.tags")(app)
require("routes.templates")(app)
require("routes.projects")(app)
require("routes.enquiries")(app)

return app
