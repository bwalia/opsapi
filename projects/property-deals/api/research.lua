-- Deal autopilot (property_deals/research.lua): the AI's research on a deal.
--   GET  /deals/:id/research   the latest run: steps, area notes and their web pages, the firms found nearby (with
--                              distance and what was checked on their own website) and the quote requests drafted
--   POST /deals/:id/research   research it again (one run at a time per deal; 409 while one is going)
--   POST /deals/:id/research/firms/:n/save   { run_uuid } a person adds firm n of that run to Suppliers
--   POST /deals/:id/research/firms/:n/quote  { run_uuid } a person asks firm n for a quote (a draft in Approvals)
-- Firms from the web search reach Suppliers or an email only this way: Google's terms don't let grounded results
-- be stored or used automatically (property_deals/research.lua).
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local Research = require("property_deals.research")

return function(app)
    app:get("/deals/:id/research", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local view = Research.view(sdk.namespace_id(self), self.params.id)
        if not view then return sdk.not_found("Deal") end
        return sdk.ok(view)
    end))

    app:post("/deals/:id/research", sdk.handler({ permission = "property_deals_ai.create" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not U.is_uuid(self.params.id) then return sdk.not_found("Deal") end
        local run, err, status = Research.start(ns, self.params.id, sdk.user(self).uuid, "manual")
        if not run then
            if status == 404 then return sdk.not_found("Deal") end
            return sdk.error(status or 409, err)
        end
        return sdk.created({ uuid = run.uuid, status = run.status })
    end)))

    local function firm_action(fn)
        return U.guard(function(self)
            local body, err = sdk.body(self)
            if not body then return sdk.error(400, err) end
            local data, errors = sdk.validate(body, { run_uuid = { type = "uuid", required = true } })
            if not data then return sdk.error(422, "Validation failed", errors) end
            local res, msg, status = fn(sdk.namespace_id(self), self.params.id, data.run_uuid, tonumber(self.params.n),
                sdk.user(self).uuid)
            if not res then
                if status == 404 then return sdk.not_found("Deal") end
                return sdk.error(status or 422, msg)
            end
            return sdk.created(type(res) == "table" and res or { supplier_uuid = res, created = msg == true })
        end)
    end

    app:post("/deals/:id/research/firms/:n/save", sdk.handler({ permission = "property_deals_suppliers.create" },
        firm_action(Research.save_firm)))
    app:post("/deals/:id/research/firms/:n/quote", sdk.handler({ permission = "property_deals_approvals.create" },
        firm_action(Research.quote_firm)))
end
