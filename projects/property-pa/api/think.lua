-- Week 3 "Think": Today (ranked, explainable), Prepare Me, Coach, Teach.
--   GET  /today                         my opportunities ranked by the rules engine ?minutes=30 packs a time budget
--   GET  /today/why/:opportunity_id     why it is where it is: every signal with its weight and source (P07)
--   GET  /prepare/:opportunity_id       Prepare Me: snapshot, price/offer position, decision makers, promises,
--                                       objections, questions for what isn't known, playbook rules, objective (P02)
--   GET  /coach/:opportunity_id         known vs assumed, questions to ask before any figure, the rules (P06)
--   POST /knowledge/teach               { statement, title?, key?, scope?, domain?, triggers?, approve? } a manager
--                                       teaches a rule; approve = true approves it in the same step (scene 6).
--                                       An AI agent may teach (propose) but never approve.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local R = require("property_pa.priority")
local Br = require("property_pa.brief")
local K = require("property_pa.knowledge")

local function slug(s)
    local k = tostring(s or ""):lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return k:sub(1, 60):gsub("_+$", "")
end

return function(app)
    app:get("/today", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local minutes = tonumber(self.params.minutes)
        if self.params.minutes and (not minutes or minutes < 5 or minutes > 600) then
            return sdk.error(422, "Validation failed", { minutes = "5 to 600" })
        end
        return sdk.ok(R.today(sdk.namespace_id(self), sdk.user(self).uuid, minutes))
    end)))

    app:get("/today/why/:opportunity_id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local c = R.why(sdk.namespace_id(self), sdk.user(self).uuid, self.params.opportunity_id)
        if not c then return sdk.not_found("Opportunity on your Today") end
        return sdk.ok({ rank = c.rank, of = c.of, score = c.score, signals = c.signals, weights = R.WEIGHTS,
            action = c.action, objective = c.objective,
            explanation = "Ranked by points from named signals (weights above), highest first. "
                .. "The order is decided by these rules, not by the AI." })
    end)))

    app:get("/prepare/:opportunity_id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local b = Br.prepare(sdk.namespace_id(self), self.params.opportunity_id, sdk.user(self).uuid)
        if not b then return sdk.not_found("Opportunity") end
        return sdk.ok(b)
    end)))

    app:get("/coach/:opportunity_id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local situation = self.params.situation
        if situation and #situation > 2000 then situation = situation:sub(1, 2000) end
        local c = Br.coach(sdk.namespace_id(self), self.params.opportunity_id, sdk.user(self).uuid, situation)
        if not c then return sdk.not_found("Opportunity") end
        return sdk.ok(c)
    end)))

    app:post("/knowledge/teach", sdk.handler({ permission = "property_pa_knowledge.create" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local d, errors = sdk.validate(body, {
            statement = { type = "text", max = 4000, required = true }, title = { type = "string", max = 160 },
            key = { type = "string", max = 80 }, scope = { enum = { "personal", "team", "company" } },
            domain = { type = "string", max = 40 }, rationale = { type = "text", max = 4000 }, approve = { type = "boolean" },
        })
        if not d then return sdk.error(422, "Validation failed", errors) end
        local agent = K.is_agent(ns, me)
        if d.approve and agent then return sdk.error(403, "An AI agent can't approve knowledge; a person must") end
        local manager = sdk.can(self, "property_pa_knowledge", "manage")
        local scope = d.scope or "company"
        if d.approve and scope ~= "personal" and not manager then
            return sdk.error(403, "Only a manager can approve company or team knowledge")
        end
        local title = d.title or (d.statement:gsub("%s+", " "):sub(1, 120))
        local key = d.key or slug(title)
        if key == "" or not key:match("^[a-z0-9_]+$") then return sdk.error(422, "Validation failed", { key = "snake_case" }) end
        local triggers = {}
        for _, t in ipairs(type(body.triggers) == "table" and body.triggers or {}) do
            if type(t) == "string" and t:match("^[a-z0-9_]+$") and #triggers < 20 then triggers[#triggers + 1] = t end
        end
        local p = K.propose(ns, { key = key, scope = scope, domain = d.domain or "general", title = title, rule = d.statement,
            rationale = d.rationale, triggers = triggers }, me, agent)
        local out = p
        if d.approve then out = K.decide(ns, p.knowledge_uuid, p.version, true, me, manager) end
        return { status = 201, json = { success = true, data = out } }
    end)))
end
