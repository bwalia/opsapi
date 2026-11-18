--[[
    GET /api/v2/sales-orders   every order of the workspace in one list: the shop's and the online stores',
    whatever channel they came through (queries/SalesOrderQueries.lua). Each source needs its own read
    permission (shop.read, orders.read); with neither, 403.
      ?q=&stage=&source=shop|store&channel=online|phone|in_person|email|pos|staff|quote&from=&to=&page=&per_page=
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local cjson = require("cjson")

return function(app)
    app:get("/api/v2/sales-orders", AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
        local Q = require("queries.SalesOrderQueries")
        if #Q.sources_for(self) == 0 then
            return { status = 403, json = { success = false, error = "You don't have access to any orders here" } }
        end
        local ok, rows, meta = pcall(Q.list, self, self.namespace.id, self.params)
        if not ok then
            ngx.log(ngx.ERR, "[sales-orders] ", tostring(rows))
            return { status = 500, json = { success = false, error = "Orders couldn't be loaded. Try again." } }
        end
        if not rows then return { status = meta.status or 400, json = { success = false, error = meta.message } } end
        setmetatable(rows, cjson.array_mt)
        setmetatable(meta.sources, cjson.array_mt)
        return { status = 200, json = { success = true, data = rows, meta = meta } }
    end)))
end
