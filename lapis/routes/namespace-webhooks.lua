--[[
    Workspace webhooks API — namespace members with the `webhooks` permission

      GET    /api/v2/namespace/webhooks/events            events this workspace can subscribe to
      GET    /api/v2/namespace/webhooks                   list (with delivery health)
      POST   /api/v2/namespace/webhooks                   create → { webhook, secret } (secret shown once)
      GET    /api/v2/namespace/webhooks/:id
      PUT    /api/v2/namespace/webhooks/:id               url / description / events / is_active
      DELETE /api/v2/namespace/webhooks/:id
      POST   /api/v2/namespace/webhooks/:id/rotate-secret → { secret }
      POST   /api/v2/namespace/webhooks/:id/test          send a signed webhook.test ping now
      GET    /api/v2/namespace/webhooks/:id/deliveries    delivery log (?status=&page=)
      POST   /api/v2/namespace/webhooks/:id/deliveries/:delivery_id/redeliver

    Storage: queries/NamespaceWebhookQueries.lua. Sending: lib/outbound-webhooks.lua.
]]

local NamespaceMiddleware = require("middleware.namespace")
local sdk = require("helper.plugin-sdk")
local Q = require("queries.NamespaceWebhookQueries")

local function guard(action, fn)
    return NamespaceMiddleware.requirePermission("webhooks", action, fn)
end

-- A webhook may only carry data the caller may read.
local function can_read(self)
    return function(module) return NamespaceMiddleware.hasPermission(self, module, "read") end
end

local NOT_FOUND = sdk.not_found("Webhook")

return function(app)
    app:get("/api/v2/namespace/webhooks/events", guard("read", function(self)
        return sdk.ok(Q.availableEvents(can_read(self)))
    end))

    app:get("/api/v2/namespace/webhooks", guard("read", function(self)
        return sdk.ok(Q.list(self.namespace.id))
    end))

    app:post("/api/v2/namespace/webhooks", guard("create", function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local webhook, secret = Q.create(self.namespace.id, self.current_user.uuid, body, can_read(self))
        if not webhook then return sdk.error(422, secret) end
        return sdk.created({ webhook = webhook, secret = secret })
    end))

    app:get("/api/v2/namespace/webhooks/:id", guard("read", function(self)
        local webhook = Q.find(self.namespace.id, self.params.id)
        if not webhook then return NOT_FOUND end
        return sdk.ok(webhook)
    end))

    app:put("/api/v2/namespace/webhooks/:id", guard("update", function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local webhook, message = Q.update(self.namespace.id, self.params.id, body, can_read(self))
        if message then return sdk.error(422, message) end
        if not webhook then return NOT_FOUND end
        return sdk.ok(webhook)
    end))

    app:delete("/api/v2/namespace/webhooks/:id", guard("delete", function(self)
        if not Q.delete(self.namespace.id, self.params.id) then return NOT_FOUND end
        return sdk.ok()
    end))

    app:post("/api/v2/namespace/webhooks/:id/rotate-secret", guard("update", function(self)
        local secret = Q.rotateSecret(self.namespace.id, self.params.id)
        if not secret then return NOT_FOUND end
        return sdk.ok({ secret = secret })
    end))

    app:post("/api/v2/namespace/webhooks/:id/test", guard("update", function(self)
        if not Q.find(self.namespace.id, self.params.id) then return NOT_FOUND end
        local ok, err, status, ms = require("lib.outbound-webhooks").sendTest(self.params.id)
        return sdk.ok({ delivered = ok, error = err, response_status = status, duration_ms = ms })
    end))

    app:get("/api/v2/namespace/webhooks/:id/deliveries", guard("read", function(self)
        local rows, meta = Q.deliveries(self.namespace.id, self.params.id, self.params)
        if not rows then return NOT_FOUND end
        return sdk.ok(rows, meta)
    end))

    app:post("/api/v2/namespace/webhooks/:id/deliveries/:delivery_id/redeliver", guard("update", function(self)
        if not Q.redeliver(self.namespace.id, self.params.id, self.params.delivery_id) then return NOT_FOUND end
        return sdk.ok()
    end))
end
