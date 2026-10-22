local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local U = require("opsapi_marketing.util")
local E = require("opsapi_marketing.eligibility")
local db = require("lapis.db")

return function(app)
    sdk.crud(app, "/suppressions", {
        table = "mkt_suppressions",
        module = "opsapi_marketing_consent",
        fields = {
            channel = { type = "string", enum = U.CHANNEL_ENUM },
            address = { type = "string", required = true },
            reason = { type = "string", required = true },
            source = { type = "string" },
            notes = { type = "text" },
        },
        searchable = { "address", "reason", "source" },
        filterable = { "channel", "reason" },
        sortable = { "address", "channel", "created_at" },
        ui = {
            label = "Suppressions",
            columns = { "address", "channel", "reason", "source", "created_at" },
            form = { "address", "channel", "reason", "source", "notes" },
        },
    })

    app:post("/consent/opt-in", sdk.handler({ permission = "opsapi_marketing_consent.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        if not U.is_uuid(body.contact_uuid) then return sdk.error(400, "contact_uuid required") end
        local channel = body.channel or "email"
        local ok, err = E.opt_in(ns, body.contact_uuid, channel, {
            list_id = body.list_id,
            source = body.source or "dashboard",
            legal_basis = body.legal_basis or "consent",
            evidence = body.evidence,
            actor_uuid = (sdk.user(self) or {}).uuid,
        })
        if not ok then return sdk.error(400, err) end
        return sdk.ok({ subscribed = true })
    end))

    app:post("/consent/opt-out", sdk.handler({ permission = "opsapi_marketing_consent.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        if not U.is_uuid(body.contact_uuid) then return sdk.error(400, "contact_uuid required") end
        local channel = body.channel or "email"
        local contact = U.one("SELECT email, phone, mobile FROM crm_contacts WHERE namespace_id = ? AND uuid = ?", ns, body.contact_uuid)
        local address = body.address
            or (channel == "email" and contact and contact.email)
            or (channel == "sms" and contact and (contact.phone or contact.mobile))
        E.opt_out(ns, body.contact_uuid, channel, {
            list_id = body.list_id,
            address = address,
            source = body.source or "dashboard",
            reason = body.reason or "unsubscribe",
            evidence = body.evidence,
        })
        return sdk.ok({ unsubscribed = true })
    end))

    app:get("/consent/:contact_uuid", sdk.handler({ permission = "opsapi_marketing_consent.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local cu = self.params.contact_uuid
        local subs = db.query([[
            SELECT uuid, channel, list_id, status, legal_basis, source, changed_at
            FROM mkt_subscriptions WHERE namespace_id = ? AND contact_uuid = ?
            ORDER BY changed_at DESC
        ]], ns, cu)
        local sup = db.query([[
            SELECT uuid, channel, address, reason, source, created_at
            FROM mkt_suppressions WHERE namespace_id = ? AND contact_uuid = ?
        ]], ns, cu)
        return sdk.ok({ subscriptions = sdk.array(subs), suppressions = sdk.array(sup) })
    end))
end
