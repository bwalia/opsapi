--[[
    GET /api/v2/search?q=   the dashboard's ⌘K search across records (lib/global-search.lua)
    → { success, data = { query, groups = [{ key, label, items = [{ title, subtitle?, path }] }], open? } }
    open: a page to go straight to (a whole deal code was typed).

    Signed in, in a workspace; each kind of record only for people with its permission (row rules apply).
    q shorter than 2 characters answers no groups.
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RateLimit = require("middleware.rate-limit")

return function(app)
    app:get("/api/v2/search", RateLimit.wrap({ rate = 300, window = 60, prefix = "global_search" },
        AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local ok, res = pcall(require("lib.global-search").run, self, self.params.q)
            if not ok then
                ngx.log(ngx.ERR, "[search] ", tostring(res))
                return { status = 500, json = { success = false, error = "Search failed. Try again." } }
            end
            local groups = res.groups
            if #groups == 0 then groups = setmetatable({}, require("cjson").array_mt) end
            for _, g in ipairs(groups) do setmetatable(g.items, require("cjson").array_mt) end
            return { status = 200, json = { success = true,
                data = { query = res.query, groups = groups, open = res.open } } }
        end))))
end
