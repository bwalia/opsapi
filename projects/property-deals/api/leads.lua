-- Leads with the Property Deals extension (gap map D2). The lead itself stays
-- in crm_leads (created through /api/v2/crm/leads); these routes read it joined
-- with property_deals_lead_details and edit the extension.
--   GET /leads                 list  ?lead_kind=&situation=&status=&vulnerable=true&deadline_before=&q=&sort=deadline|created
--   GET /leads/:uuid           one lead + details
--   PUT /leads/:uuid/details   create or update the extension (only fields sent)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")

local FIELDS = {
    lead_kind = { enum = { "seller", "buyer_investor", "landlord", "agent_referral", "other" } },
    situation = { enum = { "probate", "broken_chain", "divorce", "relocation", "care_fees", "repossession_risk",
                           "tenanted", "unmortgageable", "other" } },
    situation_note = { type = "text" },
    deadline_date = { type = "date" },
    vulnerability_flag = { type = "boolean" },
    vulnerability_note = { type = "text" },
    consent_basis = { enum = { "consent", "contract", "legitimate_interests", "legal_obligation" } },
    consent_given_at = { type = "datetime" },
    consent_channels = { type = "json" },
    privacy_notice_sent_at = { type = "datetime" },
    retention_until = { type = "date" },
    property_uuid = { type = "uuid" },
}

local SELECT = [[
    SELECT l.uuid, l.first_name, l.last_name, l.email, l.phone, l.company_name, l.source, l.channel,
           l.status, l.priority, l.score, l.owner_user_uuid, l.notes, l.converted_at, l.created_at, l.updated_at,
           to_jsonb(d) - 'id' - 'namespace_id' - 'lead_uuid' AS details,
           (SELECT dl.uuid FROM property_deals_deals dl WHERE dl.seller_lead_uuid = l.uuid
            ORDER BY dl.created_at DESC LIMIT 1) AS deal_uuid
    FROM crm_leads l
    LEFT JOIN property_deals_lead_details d ON d.lead_uuid = l.uuid
]]

return function(app)
    app:get("/leads", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local p = self.params
        local where = { "l.namespace_id = " .. db.escape_literal(sdk.namespace_id(self)), "l.deleted_at IS NULL" }
        for _, col in ipairs({ "lead_kind", "situation" }) do
            if p[col] and p[col] ~= "" then where[#where + 1] = "d." .. col .. " = " .. db.escape_literal(p[col]) end
        end
        for _, col in ipairs({ "status", "source", "owner_user_uuid" }) do
            if p[col] and p[col] ~= "" then where[#where + 1] = "l." .. col .. " = " .. db.escape_literal(p[col]) end
        end
        if p.vulnerable == "true" then where[#where + 1] = "d.vulnerability_flag" end
        if p.deadline_before and p.deadline_before:match("^%d%d%d%d%-%d%d%-%d%d$") then
            where[#where + 1] = "d.deadline_date <= " .. db.escape_literal(p.deadline_before)
        end
        if type(p.q) == "string" and p.q ~= "" then
            local like = db.escape_literal("%" .. p.q:gsub("[%%_\\]", "\\%0") .. "%")
            where[#where + 1] = "(l.first_name ILIKE " .. like .. " OR l.last_name ILIKE " .. like
                .. " OR l.email ILIKE " .. like .. " OR l.phone ILIKE " .. like .. ")"
        end
        local order = p.sort == "deadline" and "d.deadline_date ASC NULLS LAST, l.created_at DESC" or "l.created_at DESC"
        local page, per_page, offset = sdk.page(p)
        local w = table.concat(where, " AND ")
        local rows = db.query(SELECT .. " WHERE " .. w .. " ORDER BY " .. order .. " LIMIT " .. per_page .. " OFFSET " .. offset)
        local total = db.query([[SELECT COUNT(*)::int AS n FROM crm_leads l
            LEFT JOIN property_deals_lead_details d ON d.lead_uuid = l.uuid WHERE ]] .. w)[1].n
        return sdk.ok(sdk.array(rows), { page = page, per_page = per_page, total = total,
                                         total_pages = math.ceil(total / per_page) })
    end))

    app:get("/leads/:uuid", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local row = U.one(SELECT .. " WHERE l.namespace_id = ? AND l.uuid = ? AND l.deleted_at IS NULL",
            sdk.namespace_id(self), self.params.uuid)
        if not row then return sdk.not_found("Lead") end
        return sdk.ok(row)
    end))

    app:put("/leads/:uuid/details", sdk.handler({ permission = "property_deals_deals.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local lead = U.one("SELECT uuid FROM crm_leads WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL",
            ns, self.params.uuid)
        if not lead then return sdk.not_found("Lead") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, FIELDS, true)
        if not data then return sdk.error(422, "Validation failed", errors) end

        local existing = U.one("SELECT id FROM property_deals_lead_details WHERE namespace_id = ? AND lead_uuid = ?", ns, lead.uuid)
        if existing then
            if next(data) then
                data.updated_at = db.raw("NOW()")
                db.update("property_deals_lead_details", data, { id = existing.id })
            end
        else
            data.namespace_id, data.lead_uuid = ns, lead.uuid
            db.insert("property_deals_lead_details", data)
        end
        return sdk.ok(U.one(SELECT .. " WHERE l.namespace_id = ? AND l.uuid = ?", ns, lead.uuid))
    end)))
end
