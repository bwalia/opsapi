--[[
    Workspace email (core): the workspace's own SMTP server and its versions of
    the built-in email templates. docs/BILLING_ENTITLEMENTS.md §10.

      GET    /api/v2/namespace/mail-settings                  namespace.read   (never the password)
      PUT    /api/v2/namespace/mail-settings                  namespace.update
      DELETE /api/v2/namespace/mail-settings                  namespace.update (back to the deployment's SMTP)
      POST   /api/v2/namespace/mail-settings/test  { to }     namespace.update
      GET    /api/v2/namespace/email-templates                namespace.read
      PUT    /api/v2/namespace/email-templates/:key { subject, html }   namespace.update
      DELETE /api/v2/namespace/email-templates/:key           namespace.update (back to the built-in)
      POST   /api/v2/namespace/email-templates/:key/preview { subject?, html? }   namespace.read
]]

local Http = require("helper.field-service-http")
local NamespaceMail = require("helper.namespace-mail")

local function with_body(action, fn)
    return Http.guard("namespace", action, function(self)
        local body, err = Http.json_body()
        if not body then return Http.fail(400, err) end
        return fn(self, body)
    end)
end

return function(app)
    app:get("/api/v2/namespace/mail-settings", Http.guard("namespace", "read", function(self)
        return Http.ok(NamespaceMail.present(NamespaceMail.settings(self.namespace.id)))
    end))

    app:put("/api/v2/namespace/mail-settings", with_body("update", function(self, body)
        local row, err = NamespaceMail.save(self.namespace.id, Http.actor(self), body)
        if not row then return Http.fail(422, err) end
        return Http.ok(row)
    end))

    app:delete("/api/v2/namespace/mail-settings", Http.guard("namespace", "update", function(self)
        return Http.ok(NamespaceMail.remove(self.namespace.id))
    end))

    app:post("/api/v2/namespace/mail-settings/test", with_body("update", function(self, body)
        local ok, err = NamespaceMail.test(self.namespace.id, body.to)
        if not ok then return Http.fail(422, err) end
        return Http.ok({ sent = true })
    end))

    app:get("/api/v2/namespace/email-templates", Http.guard("namespace", "read", function(self)
        return Http.ok(NamespaceMail.listTemplates(self.namespace.id))
    end))

    app:put("/api/v2/namespace/email-templates/:key", with_body("update", function(self, body)
        return Http.result(NamespaceMail.saveTemplate(self.namespace.id, self.params.key, body, Http.actor(self)))
    end))

    app:delete("/api/v2/namespace/email-templates/:key", Http.guard("namespace", "update", function(self)
        return Http.result(NamespaceMail.resetTemplate(self.namespace.id, self.params.key))
    end))

    app:post("/api/v2/namespace/email-templates/:key/preview", with_body("read", function(self, body)
        local draft = (body.subject or body.html) and { subject = body.subject, html = body.html } or nil
        if draft and not draft.subject then
            draft.subject = NamespaceMail.TEMPLATES[self.params.key] and NamespaceMail.TEMPLATES[self.params.key].subject
        end
        return Http.result(NamespaceMail.preview(self.namespace.id, self.params.key, draft))
    end))
end
