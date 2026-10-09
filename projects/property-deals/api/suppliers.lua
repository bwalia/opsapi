-- Suppliers (every supplier is a CRM company, gap map §2.9) and bookings.
--   GET    /suppliers        list ?kind=&active=&q=&page=
--   GET    /suppliers/:id
--   POST   /suppliers        { account_uuid } to extend an existing company, or { name, email?, phone?, ... } to create one
--   PUT    /suppliers/:id    supplier fields (+ name/email/phone/website on the company)
--   DELETE /suppliers/:id    removes the supplier record (the CRM company stays)
--   /bookings               CRUD (supplier + slot + status + cost)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")

local KINDS = "solicitor, surveyor, epc_assessor, broker, bridging_lender, builder, letting_agent, auction_house, "
    .. "freeholder, managing_agent, council, searches_provider"

local FIELDS = {
    kinds = { type = "json", label = "Kinds (" .. KINDS .. ")" },
    base_lat = { type = "number", min = -90, max = 90 },
    base_lng = { type = "number", min = -180, max = 180 },
    radius_miles = { type = "number", min = 0, max = 500 },
    coverage = { type = "json" },
    accreditations = { type = "json" },
    price_list = { type = "json" },
    booking_method = { enum = { "email", "api", "link", "phone" } },
    booking_config = { type = "json" },
    rating = { type = "number", min = 0, max = 5 },
    active = { type = "boolean" },
    notes = { type = "text" },
}
local ACCOUNT = {
    name = { type = "string" }, email = { type = "email" }, phone = { type = "string", max = 40 },
    website = { type = "string" }, address_line1 = { type = "string" }, city = { type = "string" },
    postal_code = { type = "string", max = 16 },
}

local SELECT = [[
    SELECT s.*, a.name, a.email, a.phone, a.website, a.address_line1, a.city, a.postal_code
    FROM property_deals_suppliers s JOIN crm_accounts a ON a.uuid = s.account_uuid
]]

local function get(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one(SELECT .. " WHERE s.namespace_id = ? AND s.uuid = ?", ns, id)
end

local function split(data)
    local account = {}
    for k in pairs(ACCOUNT) do
        if data[k] ~= nil then account[k], data[k] = data[k], nil end
    end
    return data, account
end

return function(app)
    app:get("/suppliers", sdk.handler({ permission = "property_deals_suppliers.read" }, function(self)
        local p, ns = self.params, sdk.namespace_id(self)
        local where = { "s.namespace_id = " .. db.escape_literal(ns) }
        if p.kind and p.kind:match("^[%w_]+$") then
            where[#where + 1] = "s.kinds @> " .. db.escape_literal('["' .. p.kind .. '"]') .. "::jsonb"
        end
        if p.active == "true" or p.active == "false" then where[#where + 1] = "s.active = " .. p.active end
        if type(p.q) == "string" and p.q ~= "" then
            local like = db.escape_literal("%" .. p.q:gsub("[%%_\\]", "\\%0") .. "%")
            where[#where + 1] = "(a.name ILIKE " .. like .. " OR a.city ILIKE " .. like .. ")"
        end
        local order = ({ speed = "s.avg_turnaround_hours ASC NULLS LAST", on_time = "s.on_time_pct DESC NULLS LAST",
                         rating = "s.rating DESC NULLS LAST" })[p.sort] or "a.name"
        local page, per_page, offset = sdk.page(p)
        local w = table.concat(where, " AND ")
        local rows = db.query(SELECT .. " WHERE " .. w .. " ORDER BY " .. order .. " LIMIT " .. per_page .. " OFFSET " .. offset)
        local total = db.query("SELECT COUNT(*)::int AS n FROM property_deals_suppliers s JOIN crm_accounts a ON a.uuid = s.account_uuid WHERE " .. w)[1].n
        return sdk.ok(sdk.array(rows), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) })
    end))

    app:get("/suppliers/:id", sdk.handler({ permission = "property_deals_suppliers.read" }, function(self)
        local row = get(sdk.namespace_id(self), self.params.id)
        if not row then return sdk.not_found("Supplier") end
        return sdk.ok(row)
    end))

    app:post("/suppliers", sdk.handler({ permission = "property_deals_suppliers.create" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local rules = { account_uuid = { type = "uuid" } }
        for k, v in pairs(FIELDS) do rules[k] = v end
        for k, v in pairs(ACCOUNT) do rules[k] = v end
        local data, errors = sdk.validate(body, rules)
        if not data then return sdk.error(422, "Validation failed", errors) end
        if not data.account_uuid and not data.name then
            return sdk.error(422, "Validation failed", { name = "give a company name, or account_uuid of an existing company" })
        end
        local ns, user = sdk.namespace_id(self), sdk.user(self).uuid
        local row = U.tx(function()
            local fields, account = split(data)
            if not fields.account_uuid then
                account.uuid = require("helper.global").generateUUID()
                account.namespace_id, account.owner_user_uuid, account.status = ns, user, "active"
                account.industry = "Property services"
                fields.account_uuid = db.insert("crm_accounts", account, { returning = { "uuid" } })[1].uuid
            end
            fields.namespace_id = ns
            local s = db.insert("property_deals_suppliers", fields, { returning = { "uuid" } })[1]
            return get(ns, s.uuid)
        end)
        return sdk.created(row)
    end)))

    app:put("/suppliers/:id", sdk.handler({ permission = "property_deals_suppliers.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local current = get(ns, self.params.id)
        if not current then return sdk.not_found("Supplier") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local rules = {}
        for k, v in pairs(FIELDS) do rules[k] = v end
        for k, v in pairs(ACCOUNT) do rules[k] = v end
        local data, errors = sdk.validate(body, rules, true)
        if not data then return sdk.error(422, "Validation failed", errors) end
        local row = U.tx(function()
            local fields, account = split(data)
            if next(account) then
                account.updated_at = db.raw("NOW()")
                db.update("crm_accounts", account, { uuid = current.account_uuid, namespace_id = ns })
            end
            if next(fields) then
                fields.updated_at = db.raw("NOW()")
                db.update("property_deals_suppliers", fields, { uuid = current.uuid, namespace_id = ns })
            end
            return get(ns, current.uuid)
        end)
        return sdk.ok(row)
    end)))

    app:delete("/suppliers/:id", sdk.handler({ permission = "property_deals_suppliers.delete" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not get(ns, self.params.id) then return sdk.not_found("Supplier") end
        db.query("DELETE FROM property_deals_suppliers WHERE namespace_id = ? AND uuid = ?", ns, self.params.id)
        return sdk.ok()
    end)))

    sdk.crud(app, "/bookings", {
        table = "property_deals_bookings",
        module = "property_deals_suppliers",
        fields = {
            supplier_uuid = { type = "uuid", required = true, label = "Supplier" },
            deal_uuid = { type = "uuid", label = "Deal" },
            property_uuid = { type = "uuid", label = "Property" },
            task_uuid = { type = "uuid", label = "Task" },
            service = { type = "string", required = true, max = 40, label = "Service (epc, survey, valuation, searches...)" },
            status = { enum = { "requested", "tentative", "confirmed", "done", "cancelled" } },
            slot_start = { type = "datetime" },
            slot_end = { type = "datetime" },
            cost = { type = "number", min = 0 },
            currency = { type = "string", min = 3, max = 3 },
            external_ref = { type = "string", max = 120 },
            confirmed_at = { type = "datetime" },
            done_at = { type = "datetime" },
            notes = { type = "text" },
        },
        filterable = { "supplier_uuid", "deal_uuid", "property_uuid", "task_uuid", "status", "service" },
        sortable = { "slot_start", "requested_at", "created_at" },
    })
end
