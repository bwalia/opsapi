-- Enquiries / blockers and the chase log on a deal:
--   /api/v2/property-deals/enquiries  (list/show/create/update/delete)
--   /api/v2/property-deals/chases     (list/show/create/update; no delete — it is a log)
-- Chases written here are ones a person sent by hand; agent-drafted chases go
-- through an approval first (Phase 5).
local sdk = require("helper.plugin-sdk")

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
            deal_uuid = { type = "uuid", required = true, label = "Deal" },
            enquiry_uuid = { type = "uuid", label = "Enquiry" },
            task_uuid = { type = "uuid", label = "Task" },
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
        filterable = { "deal_uuid", "enquiry_uuid", "status", "channel", "to_party" },
        sortable = { "sent_at", "reply_at", "created_at" },
    })
end
