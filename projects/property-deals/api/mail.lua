-- Email connectors the legal chaser reads (property_deals/mail.lua) and what they fetched.
--   GET    /mail-connectors                list (secrets never returned: has_secret)
--   POST   /mail-connectors                { name, kind: imap|gmail|m365, config, secret, enabled? }
--   GET    /mail-connectors/:id
--   PUT    /mail-connectors/:id            only fields sent change; secret "" clears it
--   DELETE /mail-connectors/:id
--   POST   /mail-connectors/:id/sync       fetch now → { fetched, stored, matched }
--   GET    /inbound-messages               ?deal_uuid=&unmatched=true  newest first
--   POST   /inbound-messages               log an email by hand (pasted / forwarded) { from_address, subject,
--                                          body_text, deal_uuid?, received_at? } — same matching as a connector
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local Mail = require("property_deals.mail")

return function(app)
    app:get("/mail-connectors", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local out = {}
        for _, r in ipairs(db.query("SELECT * FROM property_deals_mail_connectors WHERE namespace_id = ? ORDER BY name",
            sdk.namespace_id(self))) do out[#out + 1] = Mail.present(r) end
        return sdk.ok(sdk.array(out))
    end))

    app:post("/mail-connectors", sdk.handler({ permission = "property_deals_settings.update" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local row, errors = Mail.save(sdk.namespace_id(self), body)
        if not row then return sdk.error(422, "Validation failed", errors) end
        return sdk.created(Mail.present(row))
    end)))

    app:get("/mail-connectors/:id", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local row = Mail.get(sdk.namespace_id(self), self.params.id)
        if not row then return sdk.not_found("Mail connector") end
        return sdk.ok(Mail.present(row))
    end))

    app:put("/mail-connectors/:id", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local existing = Mail.get(ns, self.params.id)
        if not existing then return sdk.not_found("Mail connector") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local row, errors = Mail.save(ns, body, existing)
        if not row then return sdk.error(422, "Validation failed", errors) end
        return sdk.ok(Mail.present(row))
    end)))

    app:delete("/mail-connectors/:id", sdk.handler({ permission = "property_deals_settings.update" }, function(self)
        local row = Mail.get(sdk.namespace_id(self), self.params.id)
        if not row then return sdk.not_found("Mail connector") end
        db.delete("property_deals_mail_connectors", { id = row.id })
        return sdk.ok({ deleted = true })
    end))

    app:post("/mail-connectors/:id/sync", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local row = Mail.get(ns, self.params.id)
        if not row then return sdk.not_found("Mail connector") end
        local res, err = Mail.sync(ns, row)
        if not res then return sdk.error(502, err) end
        return sdk.ok(res)
    end)))

    app:get("/inbound-messages", sdk.handler({ permission = "property_deals_tasks.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local where, args = { "namespace_id = ?" }, { ns }
        if U.is_uuid(self.params.deal_uuid) then where[#where + 1] = "deal_uuid = ?"; args[#args + 1] = self.params.deal_uuid end
        if self.params.unmatched == "true" then where[#where + 1] = "deal_uuid IS NULL" end
        local per_page = math.max(1, math.min(100, tonumber(self.params.per_page) or 25))
        args[#args + 1] = per_page
        local rows = db.query("SELECT uuid, connector_uuid, from_address, from_name, subject, received_at, deal_uuid, matched_by, "
            .. "chase_uuid, agent_run_uuid, processed_at, LEFT(body_text, 2000) AS body_text FROM property_deals_inbound_messages WHERE "
            .. table.concat(where, " AND ") .. " ORDER BY received_at DESC LIMIT ?", unpack(args))
        return sdk.ok(sdk.array(rows))
    end))

    app:post("/inbound-messages", sdk.handler({ permission = "property_deals_tasks.create" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            from_address = { type = "string", required = true }, from_name = { type = "string" },
            subject = { type = "string", max = 500 }, body_text = { type = "text", required = true },
            received_at = { type = "datetime" }, deal_uuid = { type = "uuid" },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns = sdk.namespace_id(self)
        if data.deal_uuid and not U.one("SELECT 1 FROM property_deals_deals WHERE namespace_id = ? AND uuid = ?", ns, data.deal_uuid) then
            return sdk.error(422, "A referenced record does not exist")
        end
        -- A deal chosen by the person wins over automatic matching: tag the subject with its reference.
        local subject = data.subject or ""
        if data.deal_uuid then subject = subject .. " " .. require("property_deals.ai.agents").ref(data.deal_uuid) end
        local row = Mail.ingest(ns, nil, { external_id = "manual:" .. ngx.md5(ngx.now() .. data.from_address .. data.body_text),
            from_address = data.from_address:lower(), from_name = data.from_name, subject = subject,
            received_at = data.received_at, body_text = data.body_text })
        if not row then return sdk.error(409, "Already logged") end
        return sdk.created(U.one("SELECT * FROM property_deals_inbound_messages WHERE id = ?", row.id))
    end)))
end
