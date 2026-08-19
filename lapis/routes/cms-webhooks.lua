--[[
    CMS Webhook API Routes
    ======================
    Per-tenant outgoing webhooks: register a URL + events, OPSAPI POSTs a signed
    payload on content changes. Namespace-scoped, RBAC-gated (module "cms").

    Admin (auth + namespace + RBAC module "cms"):
      GET    /api/v2/cms/webhooks
      POST   /api/v2/cms/webhooks         { url, name?, events?, secret?, active? }
      GET    /api/v2/cms/webhooks/:uuid
      PUT    /api/v2/cms/webhooks/:uuid
      DELETE /api/v2/cms/webhooks/:uuid

    Events: post.created | post.updated | post.deleted (comma string or array).
    The response includes `secret` so the operator can configure the receiver;
    it is namespace-scoped and RBAC-gated, so only tenant admins can read it.
]]

local CmsWebhookQueries = require "queries.CmsWebhookQueries"
local CmsHttp = require "helper.cms-http"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local parse_body = CmsHttp.parse_body
local api_response = CmsHttp.api_response
local to_bool = CmsHttp.to_bool

local function public_webhook(w)
    if not w then return nil end
    return {
        uuid = w.uuid,
        name = w.name,
        url = w.url,
        secret = w.secret,
        events = w.events,
        active = w.active,
        last_status = w.last_status,
        last_triggered_at = w.last_triggered_at,
        created_at = w.created_at,
        updated_at = w.updated_at,
    }
end

return function(app)
    app:get("/api/v2/cms/webhooks", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local rows = CmsWebhookQueries.list(self.namespace.id)
            local out = {}
            for _, w in ipairs(rows) do out[#out + 1] = public_webhook(w) end
            return { status = 200, json = { success = true, data = out } }
        end)))

    app:post("/api/v2/cms/webhooks", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "create", function(self)
            local body = parse_body()
            if not body.url or body.url == "" then
                return api_response(400, nil, "url is required")
            end
            if not body.url:match("^https?://") then
                return api_response(400, nil, "url must be http(s)")
            end
            local webhook = CmsWebhookQueries.create(self.namespace.id, {
                name = body.name,
                url = body.url,
                secret = body.secret,
                events = body.events,
                active = body.active == nil and true or to_bool(body.active, true),
            })
            return api_response(201, public_webhook(webhook))
        end)))

    app:get("/api/v2/cms/webhooks/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local w = CmsWebhookQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not w then return api_response(404, nil, "Webhook not found") end
            return api_response(200, public_webhook(w))
        end)))

    app:put("/api/v2/cms/webhooks/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            local body = parse_body()
            if body.url ~= nil and body.url ~= "" and not body.url:match("^https?://") then
                return api_response(400, nil, "url must be http(s)")
            end
            local fields = {}
            for _, k in ipairs({ "name", "url", "secret", "events" }) do
                if body[k] ~= nil then fields[k] = body[k] end
            end
            if body.active ~= nil then fields.active = to_bool(body.active, true) end
            local w = CmsWebhookQueries.update(self.namespace.id, self.params.uuid, fields)
            if not w then return api_response(404, nil, "Webhook not found") end
            return api_response(200, public_webhook(w))
        end)))

    app:delete("/api/v2/cms/webhooks/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "delete", function(self)
            local w = CmsWebhookQueries.softDelete(self.namespace.id, self.params.uuid)
            if not w then return api_response(404, nil, "Webhook not found") end
            return api_response(200, { deleted = true })
        end)))
end
