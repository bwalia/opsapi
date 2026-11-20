--[[
    Platform AI fallback chain — admin API (core, platform admins only).
    The try-order of the platform's models per AI feature; keys stay in env / Vault.
    See queries/AiChainQueries.lua and lib/agent/llm.lua ("Saved chains").

      GET    /api/v2/admin/ai-chain/config            every scope: saved chain, env order, effective
                                                      order now, and the catalogue of models
      PUT    /api/v2/admin/ai-chain/config/:scope     { hops: [ { name, model?, enabled } ] } → save
      DELETE /api/v2/admin/ai-chain/config/:scope     back to the environment's order
      POST   /api/v2/admin/ai-chain/test              { scope, hops? } → try them in order (tiny prompt)
]]

local Http = require("helper.field-service-http")
local AuthMiddleware = require("middleware.auth")
local AiChainQueries = require("queries.AiChainQueries")

local function admin(handler)
    return AuthMiddleware.requireRole("administrative", handler)
end

local function actor(self)
    local u = self.current_user or {}
    return u.email or (self.user_data and self.user_data.email) or u.uuid or u.sub
end

return function(app)
    app:get("/api/v2/admin/ai-chain/config", admin(function()
        return Http.ok(AiChainQueries.overview())
    end))

    app:put("/api/v2/admin/ai-chain/config/:scope", admin(function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return Http.result(AiChainQueries.save(self.params.scope, body.hops, actor(self)))
    end))

    app:delete("/api/v2/admin/ai-chain/config/:scope", admin(function(self)
        return Http.result(AiChainQueries.reset(self.params.scope))
    end))

    app:post("/api/v2/admin/ai-chain/test", admin(function()
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return Http.result(AiChainQueries.test(body.scope or "default", body.hops))
    end))
end
