--[[
    Workspace email (core): the workspace's own SMTP server and its versions of
    the built-in email templates. docs/BILLING_ENTITLEMENTS.md §10.

      GET    /api/v2/namespace/mail-settings                  namespace.read   (never the password)
      PUT    /api/v2/namespace/mail-settings                  namespace.update
      DELETE /api/v2/namespace/mail-settings                  namespace.update (back to the deployment's SMTP)
      POST   /api/v2/namespace/mail-settings/test  { to }     namespace.update
        (the four above act on the default account; kept for older clients)

    Several email accounts, and which one sends which kind of email:
      GET    /api/v2/namespace/mail-accounts                  namespace.read   accounts + routing + platform sender
      POST   /api/v2/namespace/mail-accounts                  namespace.update { name, host, port, security, username,
                                                                password, from_email, from_name?, reply_to?, enabled?,
                                                                is_default? }
      GET    /api/v2/namespace/mail-accounts/:uuid            namespace.read
      PUT    /api/v2/namespace/mail-accounts/:uuid            namespace.update (password omitted = keep, "" = remove)
      DELETE /api/v2/namespace/mail-accounts/:uuid            namespace.update (its emails go back to the default)
      POST   /api/v2/namespace/mail-accounts/:uuid/default    namespace.update
      POST   /api/v2/namespace/mail-accounts/:uuid/test { to }  namespace.update
      GET    /api/v2/namespace/mail-routing                   namespace.read
      PUT    /api/v2/namespace/mail-routing { routes: { leads: "<uuid>", shop_orders: null, default: "<uuid>" } }
                                                              namespace.update (null = use the default account)
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
    app:get("/api/v2/namespace/mail-accounts", Http.guard("namespace", "read", function(self)
        local Mail = require("helper.mail")
        return Http.ok({
            accounts = setmetatable(NamespaceMail.listAccounts(self.namespace.id), require("cjson").array_mt),
            routing = setmetatable(NamespaceMail.routing(self.namespace.id), require("cjson").array_mt),
            platform = Mail.deploymentSender(),
        })
    end))

    app:post("/api/v2/namespace/mail-accounts", with_body("update", function(self, body)
        local row, err = NamespaceMail.saveAccount(self.namespace.id, nil, Http.actor(self), body)
        if not row then return Http.fail(422, err) end
        return Http.ok(row, 201)
    end))

    app:get("/api/v2/namespace/mail-accounts/:uuid", Http.guard("namespace", "read", function(self)
        local row, err = NamespaceMail.getAccount(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, err) end
        return Http.ok(row)
    end))

    app:put("/api/v2/namespace/mail-accounts/:uuid", with_body("update", function(self, body)
        local row, err = NamespaceMail.saveAccount(self.namespace.id, self.params.uuid, Http.actor(self), body)
        if not row then return Http.fail(err == "Email account not found" and 404 or 422, err) end
        return Http.ok(row)
    end))

    app:delete("/api/v2/namespace/mail-accounts/:uuid", Http.guard("namespace", "update", function(self)
        local ok, err = NamespaceMail.deleteAccount(self.namespace.id, self.params.uuid)
        if not ok then return Http.fail(404, err) end
        return Http.ok({ deleted = true })
    end))

    app:post("/api/v2/namespace/mail-accounts/:uuid/default", Http.guard("namespace", "update", function(self)
        local row, err = NamespaceMail.setDefaultAccount(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, err) end
        return Http.ok(row)
    end))

    app:post("/api/v2/namespace/mail-accounts/:uuid/test", with_body("update", function(self, body)
        local ok, err = NamespaceMail.testAccount(self.namespace.id, self.params.uuid, body.to)
        if not ok then return Http.fail(err == "Email account not found" and 404 or 422, err) end
        return Http.ok({ sent = true })
    end))

    app:get("/api/v2/namespace/mail-routing", Http.guard("namespace", "read", function(self)
        return Http.ok(NamespaceMail.routing(self.namespace.id))
    end))

    app:put("/api/v2/namespace/mail-routing", with_body("update", function(self, body)
        local routes, err = NamespaceMail.saveRouting(self.namespace.id, Http.actor(self), body.routes)
        if not routes then return Http.fail(422, err) end
        return Http.ok(routes)
    end))

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
