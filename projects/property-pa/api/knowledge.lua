-- Knowledge the PA follows: versioned, approved, scoped (company / team / personal).
--   GET  /knowledge                        approved rules I may use ?domain=&trigger=&q=&status=all
--   GET  /knowledge/pending                proposed versions waiting for me (managers: company + team)
--   GET  /knowledge/:id                    the rule + every version
--   POST /knowledge                        propose a rule or a new version { key, scope?, domain?, title, rule,
--                                          rationale?, triggers?, proposed_by_ai? }
--   POST /knowledge/:id/versions/:version/approve | reject
--   POST /knowledge/:id/retire
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local K = require("property_pa.knowledge")

local function manager(self) return sdk.can(self, "property_pa_knowledge", "manage") end

return function(app)
    app:get("/knowledge", sdk.handler({ permission = "property_pa_knowledge.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        K.ensure(ns, nil)
        return sdk.ok(K.list(ns, sdk.user(self).uuid, self.params))
    end)))

    app:get("/knowledge/pending", sdk.handler({ permission = "property_pa_knowledge.read" }, U.guard(function(self)
        return sdk.ok(K.pending(sdk.namespace_id(self), sdk.user(self).uuid, manager(self)))
    end)))

    app:get("/knowledge/:id", sdk.handler({ permission = "property_pa_knowledge.read" }, U.guard(function(self)
        local r = K.get(sdk.namespace_id(self), self.params.id, sdk.user(self).uuid)
        if not r then return sdk.not_found("Knowledge") end
        return sdk.ok(r)
    end)))

    app:post("/knowledge", sdk.handler({ permission = "property_pa_knowledge.create" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local d, errors = sdk.validate(body, {
            key = { type = "string", max = 80, required = true }, scope = { enum = { "personal", "team", "company" } },
            domain = { type = "string", max = 40 }, title = { type = "string", required = true },
            rule = { type = "text", max = 4000, required = true }, rationale = { type = "text", max = 4000 },
            proposed_by_ai = { type = "boolean" },
        })
        if not d then return sdk.error(422, "Validation failed", errors) end
        if not d.key:match("^[a-z0-9_]+$") then return sdk.error(422, "Validation failed", { key = "lowercase letters, digits and _" }) end
        if d.domain and not d.domain:match("^[a-z_]+$") then return sdk.error(422, "Validation failed", { domain = "lowercase letters and _" }) end
        local triggers = {}
        if body.triggers ~= nil then
            if type(body.triggers) ~= "table" or #body.triggers > 20 then
                return sdk.error(422, "Validation failed", { triggers = "a list of up to 20 trigger words" })
            end
            for _, t in ipairs(body.triggers) do
                if type(t) ~= "string" or not t:match("^[a-z0-9_]+$") or #t > 40 then
                    return sdk.error(422, "Validation failed", { triggers = "lowercase words with _" })
                end
                triggers[#triggers + 1] = t
            end
        end
        d.triggers = triggers
        local out = K.propose(sdk.namespace_id(self), d, sdk.user(self).uuid, d.proposed_by_ai == true)
        return { status = 201, json = { success = true, data = out } }
    end)))

    for _, action in ipairs({ "approve", "reject" }) do
        app:post("/knowledge/:id/versions/:version/" .. action, sdk.handler({ permission = "property_pa_knowledge.read" },
            U.guard(function(self)
                local v = tonumber(self.params.version)
                if not v or v % 1 ~= 0 or v < 1 then return sdk.not_found("Version") end
                return sdk.ok(K.decide(sdk.namespace_id(self), self.params.id, v, action == "approve",
                    sdk.user(self).uuid, manager(self)))
            end)))
    end

    app:post("/knowledge/:id/retire", sdk.handler({ permission = "property_pa_knowledge.read" }, U.guard(function(self)
        return sdk.ok(K.retire(sdk.namespace_id(self), self.params.id, sdk.user(self).uuid, manager(self)))
    end)))
end
