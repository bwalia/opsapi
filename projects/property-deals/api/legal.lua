-- Enquiries / blockers and the chase log on a deal:
--   /api/v2/property-deals/enquiries  (list/show/create/update/delete)
--   /api/v2/property-deals/chases     (list/show/create/update; no delete — it is a log)
-- Chases written here are ones a person sent by hand; agent-drafted chases go
-- through an approval first. A chase needs a deal or a lead (a lead-stage call
-- before there is a deal); when the lead becomes a deal its chases move to it.
--   POST /tasks/:id/contact-log { channel, to_name?, to_address?, outcome?, note?, to_party? }
--        logs a call / WhatsApp / email made from the task (deal or lead).
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")

local PARTIES = { "seller", "buyer", "buyer_solicitor", "seller_solicitor", "lender", "freeholder",
                  "managing_agent", "council", "other" }

return function(app)
    sdk.crud(app, "/enquiries", {
        table = "property_deals_enquiries",
        module = "property_deals_tasks",
        fields = {
            deal_uuid = { type = "uuid", required = true, label = "Deal" },
            title = { type = "string", required = true },
            detail = { type = "text" },
            owner_party = { enum = PARTIES, label = "Waiting on" },
            status = { enum = { "open", "resolved", "withdrawn" } },
            blocking = { type = "boolean" },
            raised_at = { type = "datetime" },
            due_at = { type = "datetime" },
            resolved_at = { type = "datetime" },
            resolution = { type = "text" },
            source = { enum = { "manual", "email", "agent" } },
        },
        searchable = { "title", "detail" },
        filterable = { "deal_uuid", "status", "owner_party", "blocking", "source" },
        sortable = { "raised_at", "due_at", "resolved_at", "created_at" },
    })

    sdk.crud(app, "/chases", {
        table = "property_deals_chases",
        module = "property_deals_tasks",
        only = { "list", "show", "create", "update" },
        fields = {
            deal_uuid = { type = "uuid", label = "Deal" },
            lead_uuid = { type = "uuid", label = "Lead (before there is a deal)" },
            enquiry_uuid = { type = "uuid", label = "Enquiry" },
            task_uuid = { type = "uuid", label = "Task" },
            outcome = { type = "string", max = 40, label = "Outcome (e.g. no_answer, spoke, left_message)" },
            to_party = { enum = PARTIES },
            to_name = { type = "string" },
            to_address = { type = "string" },
            channel = { enum = { "email", "phone", "sms", "whatsapp", "letter", "portal" } },
            subject = { type = "string" },
            body = { type = "text" },
            status = { enum = { "sent", "replied", "failed" } },
            sent_at = { type = "datetime" },
            reply_at = { type = "datetime" },
            reply_summary = { type = "text" },
        },
        searchable = { "subject", "body", "to_name" },
        filterable = { "deal_uuid", "lead_uuid", "enquiry_uuid", "task_uuid", "status", "channel", "to_party" },
        sortable = { "sent_at", "reply_at", "created_at" },
    })

    app:post("/tasks/:id/contact-log", sdk.handler({ permission = "property_deals_tasks.create" }, U.guard(function(self)
        return sdk.idempotent(self, function()
            local body, err = sdk.body(self)
            if not body then return sdk.error(400, err) end
            local data, errors = sdk.validate(body, {
                channel = { required = true, enum = { "phone", "sms", "whatsapp", "email", "letter", "portal" } },
                to_party = { enum = PARTIES }, to_name = { type = "string" }, to_address = { type = "string" },
                outcome = { type = "string", max = 40 }, note = { type = "text" }, subject = { type = "string" },
                sent_at = { type = "datetime" },
            })
            if not data then return sdk.error(422, "Validation failed", errors) end
            local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
            local task = require("property_deals.tasks").get(ns, self.params.id)
            if not task then return sdk.not_found("Task") end
            local deal = task.deal_uuid ~= db.NULL and task.deal_uuid or nil
            local lead = task.lead_uuid ~= db.NULL and task.lead_uuid or nil
            if not deal and not lead then
                return sdk.error(422, "This task has no deal or lead to log the contact against")
            end
            local row = db.insert("property_deals_chases", {
                namespace_id = ns, deal_uuid = deal, lead_uuid = lead, task_uuid = task.task_uuid,
                to_party = data.to_party or (deal and "other" or "seller"), to_name = data.to_name,
                to_address = data.to_address, channel = data.channel, subject = data.subject, body = data.note,
                outcome = data.outcome, status = "sent", sent_at = data.sent_at or db.raw("NOW()"), sent_by_user_uuid = me,
            }, { returning = "*" })[1]
            if deal then
                pcall(require("property_deals.health").recompute_deal, ns, deal, sdk.settings(self))
            end
            return sdk.created(row)
        end)
    end)))
end
