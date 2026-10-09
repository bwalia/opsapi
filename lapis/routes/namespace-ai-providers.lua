--[[
    Workspace AI providers (core, lib/ai-providers.lua). Keys go in, never out:
    responses carry has_secret + secret_hint ("…a1b2").

      GET    /api/v2/namespace/ai-providers              namespace.read
      POST   /api/v2/namespace/ai-providers              namespace.update
             { name, provider_type, base_url?, default_model?, models?, secret?, username?,
               options?, is_local?, enabled?, input_cost_per_mtok?, output_cost_per_mtok? }
      GET    /api/v2/namespace/ai-providers/:id          namespace.read
      PUT    /api/v2/namespace/ai-providers/:id          namespace.update (only fields sent change;
                                                         secret "" clears it)
      DELETE /api/v2/namespace/ai-providers/:id          namespace.update
      POST   /api/v2/namespace/ai-providers/:id/test     namespace.update  one tiny request (or JobShout sign-in)
      GET    /api/v2/namespace/ai-providers/:id/agents   namespace.read    JobShout links: the agents you can map
]]

local Http = require("helper.field-service-http")
local Providers = require("lib.ai-providers")
local db = require("lapis.db")

local function invalid(errors)
    return { status = 422, json = { success = false, error = "Validation failed", details = errors } }
end

local function with_body(action, fn)
    return Http.guard("namespace", action, function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return fn(self, body)
    end)
end

local function found(self)
    return Providers.get(self.namespace.id, self.params.id)
end

return function(app)
    app:get("/api/v2/namespace/ai-providers", Http.guard("namespace", "read", function(self)
        local out = {}
        for _, row in ipairs(Providers.list(self.namespace.id)) do out[#out + 1] = Providers.present(row) end
        return Http.ok(setmetatable(out, require("cjson").array_mt))
    end))

    app:post("/api/v2/namespace/ai-providers", with_body("update", function(self, body)
        local row, errors = Providers.save(self.namespace.id, Http.actor(self), body)
        if not row then return invalid(errors) end
        return Http.ok(Providers.present(row), 201)
    end))

    app:get("/api/v2/namespace/ai-providers/:id", Http.guard("namespace", "read", function(self)
        local row = found(self)
        if not row then return Http.fail(404, "AI provider not found") end
        return Http.ok(Providers.present(row))
    end))

    app:put("/api/v2/namespace/ai-providers/:id", with_body("update", function(self, body)
        local existing = found(self)
        if not existing then return Http.fail(404, "AI provider not found") end
        local row, errors = Providers.save(self.namespace.id, Http.actor(self), body, existing)
        if not row then return invalid(errors) end
        return Http.ok(Providers.present(row))
    end))

    app:delete("/api/v2/namespace/ai-providers/:id", Http.guard("namespace", "update", function(self)
        local row = found(self)
        if not row then return Http.fail(404, "AI provider not found") end
        db.delete("namespace_ai_providers", { id = row.id })
        return Http.ok({ deleted = true })
    end))

    app:post("/api/v2/namespace/ai-providers/:id/test", Http.guard("namespace", "update", function(self)
        local row = found(self)
        if not row then return Http.fail(404, "AI provider not found") end
        local res, err = Providers.test(self.namespace.id, row)
        if not res then return Http.fail(422, err) end
        return Http.ok(res)
    end))

    app:get("/api/v2/namespace/ai-providers/:id/agents", Http.guard("namespace", "read", function(self)
        local row = found(self)
        if not row then return Http.fail(404, "AI provider not found") end
        if row.provider_type ~= "jobshout" then return Http.fail(422, "Only a JobShout link has agents") end
        local agents, err = require("lib.jobshout-client").agents(self.namespace.id, row)
        if not agents then return Http.fail(502, err) end
        local out = {}
        for _, a in ipairs(agents) do
            out[#out + 1] = { id = a.id, name = a.name, description = a.description }
        end
        return Http.ok(setmetatable(out, require("cjson").array_mt))
    end))
end
