-- Lead news ("signals") and replies (customer request: personal follow-ups, hot-lead call alerts).
--   GET    /leads/:uuid/signals          recent news, newest first
--   POST   /leads/:uuid/signals          capture a post / page / note { kind, url?, text?, title?, occurred_at? }
--   DELETE /signals/:id
--   GET    /leads/:uuid/replies          replies (email matched by sender, or logged)
--   POST   /leads/:uuid/replies          log a WhatsApp / SMS / call / DM reply { channel, text, received_at? }
--                                        -> scored; a hot one raises a "call now" task + alerts
--   GET    /hot-leads                    hot in the last 7 days ?mine=true
--   GET    /companies-house/officers     ?q=name -> officer ids to link a lead to (the watch then follows them)
--   POST   /signals/run                  run the Companies House watch + new-company search now (managers)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local Signals = require("property_deals.signals")
local Replies = require("property_deals.replies")

local function lead_of(self)
    local id = self.params.uuid
    if type(id) ~= "string" or id == "" or #id > 64 then return nil end
    return U.one("SELECT uuid, first_name FROM crm_leads WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL",
        sdk.namespace_id(self), id)
end

return function(app)
    app:get("/leads/:uuid/signals", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local lead = lead_of(self)
        if not lead then return sdk.not_found("Lead") end
        return sdk.ok(Signals.list(sdk.namespace_id(self), lead.uuid, math.min(tonumber(self.params.limit) or 50, 200)))
    end))

    app:post("/leads/:uuid/signals", sdk.handler({ permission = "property_deals_deals.update" }, U.guard_create(function(self)
        local lead = lead_of(self)
        if not lead then return sdk.not_found("Lead") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            kind = { enum = Signals.MANUAL_KINDS, required = true },
            title = { type = "string", max = 300 }, text = { type = "text" }, url = { type = "url" },
            occurred_at = { type = "datetime" },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        if not data.text and not data.url and not data.title then
            return sdk.error(422, "Validation failed", { text = "paste the post's text, its link, or both" })
        end
        local title = data.title or (data.text and data.text:gsub("%s+", " "):sub(1, 120)) or data.url
        local row = Signals.add(sdk.namespace_id(self), lead.uuid, { kind = data.kind, source = "manual", title = title,
            summary = data.text, url = data.url, occurred_at = data.occurred_at }, sdk.user(self).uuid)
        return sdk.created(row)
    end)))

    app:delete("/signals/:id", sdk.handler({ permission = "property_deals_deals.update" }, function(self)
        if not U.is_uuid(self.params.id) then return sdk.not_found("Signal") end
        local res = db.query("DELETE FROM property_deals_lead_signals WHERE namespace_id = ? AND uuid = ? RETURNING uuid",
            sdk.namespace_id(self), self.params.id)
        if #res == 0 then return sdk.not_found("Signal") end
        return sdk.ok({ deleted = true })
    end))

    app:get("/leads/:uuid/replies", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local lead = lead_of(self)
        if not lead then return sdk.not_found("Lead") end
        return sdk.ok(Replies.list(sdk.namespace_id(self), lead.uuid, math.min(tonumber(self.params.limit) or 50, 200)))
    end))

    app:post("/leads/:uuid/replies", sdk.handler({ permission = "property_deals_deals.update" }, U.guard_create(function(self)
        local lead = lead_of(self)
        if not lead then return sdk.not_found("Lead") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            channel = { enum = { "whatsapp", "sms", "phone", "social", "email", "other" }, required = true },
            text = { type = "text", required = true }, received_at = { type = "datetime" },
            from_name = { type = "string", max = 255 }, subject = { type = "string", max = 300 },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns = sdk.namespace_id(self)
        local row, result = Replies.log(ns, lead.uuid, data, sdk.user(self).uuid)
        local out = U.one([[
            SELECT uuid, lead_uuid, channel, from_name, subject, received_at, body_text, reply_temperature, reply_score,
                   reply_reason, hot_task_uuid, matched_by, logged_by_user_uuid
            FROM property_deals_inbound_messages WHERE id = ?
        ]], row.id)
        out.alerted = result and result.alerted or 0
        out.scored_by = result and result.by
        return sdk.created(out)
    end)))

    app:get("/hot-leads", sdk.handler({ permission = "property_deals_tasks.read" }, function(self)
        local me = self.params.mine == "true" and sdk.user(self).uuid or nil
        return sdk.ok(Replies.hot(sdk.namespace_id(self), me, math.min(tonumber(self.params.limit) or 20, 100)))
    end))

    app:get("/companies-house/officers", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local q = self.params.q
        if type(q) ~= "string" or #q < 3 then return sdk.error(422, "Validation failed", { q = "at least 3 characters" }) end
        local rows, err, status = Signals.officer_search(sdk.namespace_id(self), q:sub(1, 100))
        if not rows then return sdk.error(status or 502, err) end
        return sdk.ok(rows)
    end))

    app:post("/signals/run", sdk.handler({ permission = "property_deals_settings.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local watch = Signals.watch(ns)
        local fresh = Signals.new_companies(ns, sdk.settings(self))
        return sdk.ok({ watch = watch, new_companies = fresh })
    end)))
end
