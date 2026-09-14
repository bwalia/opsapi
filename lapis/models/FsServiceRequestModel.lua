local Model = require("lapis.db.model").Model
local FsServiceRequests = Model:extend("fs_service_requests", { timestamp = true })
return FsServiceRequests
