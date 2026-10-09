-- Compliance checks: /api/v2/property-deals/compliance-checks
--   GET /compliance-checks  ?deal_uuid=&status=&check_type=&subject_type=&contact_uuid=&expiring_within_days=
--   GET /compliance-checks/:id, POST, PUT /:id, DELETE /:id
-- Passing or waiving a check records the signed-in person and the time; a
-- client can't supply them (hard rule 6). AI agents (pd_agent role) can't sign off.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")

local FIELDS = {
    check_type = { type = "string", required = true, max = 60, label = "Check (template compliance key)" },
    jurisdiction_pack = { type = "string", max = 40 },
    subject_type = { required = true, enum = { "contact", "account", "deal", "property", "workspace" } },
    contact_uuid = { type = "uuid" },
    account_uuid = { type = "uuid" },
    deal_uuid = { type = "uuid" },
    property_uuid = { type = "uuid" },
    party_role = { type = "string", max = 30 },
    task_uuid = { type = "uuid" },
    status = { enum = { "not_started", "in_progress", "passed", "failed", "waived", "expired" } },
    risk_rating = { enum = { "low", "medium", "high" } },
    evidence_document_uuid = { type = "uuid" },
    expires_at = { type = "datetime" },
    data = { type = "json" },
    notes = { type = "text" },
}

local SIGN_OFF = { passed = true, waived = true }

local function get(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one("SELECT * FROM property_deals_compliance_checks WHERE namespace_id = ? AND uuid = ?", ns, id)
end

local function is_agent(self, ns)
    -- The AI service account holds the pd_agent role; it may prepare checks, never pass them.
    return U.one([[
        SELECT 1 FROM namespace_user_roles ur
        JOIN namespace_roles r ON r.id = ur.namespace_role_id
        JOIN namespace_members m ON m.id = ur.namespace_member_id
        JOIN users u ON u.id = m.user_id
        WHERE m.namespace_id = ? AND u.uuid = ? AND r.role_name = 'pd_agent'
    ]], ns, sdk.user(self).uuid) ~= nil
end

local function sign_off(self, ns, data, previous_status)
    if data.status and SIGN_OFF[data.status] and data.status ~= previous_status then
        if is_agent(self, ns) then
            U.fail(403, "An AI agent can't sign off a compliance check; a person must")
        end
        if data.status == "waived" and not data.notes then
            U.fail(422, "Validation failed", { notes = "say why the check is waived" })
        end
        data.checked_by_user_uuid = sdk.user(self).uuid
        data.checked_at = db.raw("NOW()")
    elseif data.status and not SIGN_OFF[data.status] and previous_status and SIGN_OFF[previous_status] then
        data.checked_by_user_uuid, data.checked_at = db.NULL, db.NULL
    end
end

return function(app)
    sdk.crud(app, "/compliance-checks", {
        table = "property_deals_compliance_checks",
        module = "property_deals_compliance",
        only = { "show", "delete" },
        fields = FIELDS,
    })

    app:get("/compliance-checks", sdk.handler({ permission = "property_deals_compliance.read" }, function(self)
        local p, ns = self.params, sdk.namespace_id(self)
        local where = { "namespace_id = " .. db.escape_literal(ns) }
        for _, col in ipairs({ "status", "check_type", "subject_type", "party_role" }) do
            if p[col] and p[col] ~= "" then where[#where + 1] = col .. " = " .. db.escape_literal(p[col]) end
        end
        for _, col in ipairs({ "deal_uuid", "property_uuid", "contact_uuid", "account_uuid" }) do
            if U.is_uuid(p[col]) then where[#where + 1] = col .. " = " .. db.escape_literal(p[col]) end
        end
        local days = tonumber(p.expiring_within_days)
        if days then
            where[#where + 1] = "status = 'passed' AND expires_at IS NOT NULL AND expires_at <= NOW() + make_interval(days => "
                .. math.floor(days) .. ")"
        end
        local page, per_page, offset = sdk.page(p)
        local w = table.concat(where, " AND ")
        local order = days and "expires_at ASC" or "created_at DESC"
        local rows = db.query("SELECT * FROM property_deals_compliance_checks WHERE " .. w .. " ORDER BY " .. order
            .. ", id DESC LIMIT " .. per_page .. " OFFSET " .. offset)
        local total = db.query("SELECT COUNT(*)::int AS n FROM property_deals_compliance_checks WHERE " .. w)[1].n
        return sdk.ok(sdk.array(rows), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) })
    end))

    app:post("/compliance-checks", sdk.handler({ permission = "property_deals_compliance.create" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, FIELDS)
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns = sdk.namespace_id(self)
        sign_off(self, ns, data, nil)
        data.namespace_id = ns
        local row = db.insert("property_deals_compliance_checks", data, { returning = "*" })[1]
        return sdk.created(row)
    end)))

    app:put("/compliance-checks/:id", sdk.handler({ permission = "property_deals_compliance.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local current = get(ns, self.params.id)
        if not current then return sdk.not_found("Compliance check") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, FIELDS, true)
        if not data then return sdk.error(422, "Validation failed", errors) end
        sign_off(self, ns, data, current.status)
        if next(data) then
            data.updated_at = db.raw("NOW()")
            db.update("property_deals_compliance_checks", data, { namespace_id = ns, uuid = current.uuid })
        end
        return sdk.ok(get(ns, current.uuid))
    end)))
end
