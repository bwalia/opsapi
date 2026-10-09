-- Buyer profiles on an existing CRM contact or company:
-- /api/v2/property-deals/buyer-profiles (list/show/create/update/delete).
-- Exactly one of contact_uuid / account_uuid; both must be in this workspace.
local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")

return function(app)
    -- Buyers page list with who each buyer is (api-requests/web-buyer-directory.md).
    -- Registered before sdk.crud so /:id doesn't capture it.
    app:get("/buyer-profiles/directory", sdk.handler({ permission = "property_deals_buyers.read" }, function(self)
        local where, args = { "b.namespace_id = ?" }, { sdk.namespace_id(self) }
        local q = self.params.q
        if type(q) == "string" and q ~= "" then
            where[#where + 1] = "(COALESCE(c.first_name || ' ' || COALESCE(c.last_name, ''), a.name) ILIKE ? OR COALESCE(c.email, a.email) ILIKE ?)"
            args[#args + 1], args[#args + 2] = "%" .. q .. "%", "%" .. q .. "%"
        end
        if type(self.params.pof_status) == "string" and self.params.pof_status ~= "" then
            where[#where + 1] = "b.pof_status = ?"
            args[#args + 1] = self.params.pof_status
        end
        local rows = db.query([[
            SELECT b.*, TRIM(COALESCE(c.first_name || ' ' || COALESCE(c.last_name, ''), a.name)) AS name,
                   COALESCE(NULLIF(c.email, ''), NULLIF(a.email, '')) AS email
            FROM property_deals_buyer_profiles b
            LEFT JOIN crm_contacts c ON c.uuid = b.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = b.account_uuid
            WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY b.updated_at DESC LIMIT 500", unpack(args))
        for _, r in ipairs(rows) do r.id, r.namespace_id = nil, nil end
        return sdk.ok(sdk.array(rows))
    end))

    sdk.crud(app, "/buyer-profiles", {
        table = "property_deals_buyer_profiles",
        module = "property_deals_buyers",
        fields = {
            contact_uuid = { type = "uuid", label = "Contact" },
            account_uuid = { type = "uuid", label = "Company" },
            entity_type = { enum = { "person", "ltd_spv", "overseas_company", "pension_ssas_sipp", "trust_family_office" } },
            capital_band = { type = "string", max = 30 },
            funds_location = { type = "string", max = 120 },
            pof_status = { enum = { "none", "requested", "received", "verified", "expired" }, label = "Proof of funds" },
            pof_expires_on = { type = "date" },
            funding_route = { enum = { "cash", "mortgage", "bridging", "cash_then_refinance" } },
            speed_to_commit_days = { type = "integer", min = 0 },
            strategies = { type = "json", label = "Strategies (btl, brr, flip, hmo, blocks, semi_commercial, commercial, tenanted)" },
            areas = { type = "json", label = "Areas [{type: radius, lat, lng, miles} | {type: polygon, points: [[lat,lng]...]}]" },
            price_min = { type = "number", min = 0 },
            price_max = { type = "number", min = 0 },
            min_discount_pct = { type = "number", min = 0, max = 100 },
            min_yield_pct = { type = "number", min = 0, max = 100 },
            refurb_appetite = { enum = { "none", "light", "medium", "heavy" } },
            top_priority = { type = "string", max = 120 },
            deal_breakers = { type = "json" },
            preferred_channel = { enum = { "email", "phone", "whatsapp", "sms" } },
            timezone = { type = "string", max = 60 },
            holdings = { type = "json" },
            active = { type = "boolean" },
            notes = { type = "text" },
        },
        filterable = { "contact_uuid", "account_uuid", "entity_type", "pof_status", "funding_route", "active" },
        sortable = { "price_max", "pof_expires_on", "created_at", "updated_at" },
        searchable = { "top_priority", "notes" },
        ui = { label = "Buyer profiles", columns = { "entity_type", "pof_status", "funding_route", "price_max", "active" } },
    })
end
