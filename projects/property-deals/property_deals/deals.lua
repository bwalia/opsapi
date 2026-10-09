-- Deals: every property deal is a crm_deals row (so it shows in CRM) plus a
-- property_deals_deals row with what CRM doesn't hold (gap map D3), and a
-- kanban epic that groups its tasks.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local Store = require("property_deals.templates_store")
local Workspace = require("property_deals.workspace")

local Deals = {}

-- Default template per deal type when the caller doesn't name one.
local DEFAULT_TEMPLATE = {
    buy = "uk_guaranteed_sale", buy_and_assign = "uk_guaranteed_sale", sourcing = "uk_guaranteed_sale",
    sell = "sell_via_estate_agent",
}

local SELECT = [[
    SELECT d.*, cd.name, cd.owner_user_uuid, cd.value, cd.status AS crm_status, cd.pipeline_id,
           c.uuid AS seller_contact_uuid,
           p.address_line1, p.postcode, p.town, p.lat, p.lng, p.epc_rating, p.tenure,
           t.key AS template_key, v.version AS template_version
    FROM property_deals_deals d
    JOIN crm_deals cd ON cd.uuid = d.crm_deal_uuid
    LEFT JOIN crm_contacts c ON c.id = cd.contact_id
    LEFT JOIN property_deals_properties p ON p.uuid = d.property_uuid
    JOIN property_deals_workflow_template_versions v ON v.uuid = d.template_version_uuid
    JOIN property_deals_workflow_templates t ON t.uuid = v.template_uuid
]]

function Deals.get(ns, uuid)
    if not U.is_uuid(uuid) then return nil end
    return U.one(SELECT .. " WHERE d.namespace_id = ? AND d.uuid = ?", ns, uuid)
end

--- List with filters: stage_key, status, health, deal_type, property_uuid, owner_user_uuid, q.
function Deals.list(ns, params)
    local where = { "d.namespace_id = " .. db.escape_literal(ns) }
    for _, col in ipairs({ "stage_key", "status", "health", "deal_type" }) do
        local v = params[col]
        if v and v ~= "" then where[#where + 1] = "d." .. col .. " = " .. db.escape_literal(v) end
    end
    if U.is_uuid(params.property_uuid) then where[#where + 1] = "d.property_uuid = " .. db.escape_literal(params.property_uuid) end
    if params.owner_user_uuid and params.owner_user_uuid ~= "" then
        where[#where + 1] = "cd.owner_user_uuid = " .. db.escape_literal(params.owner_user_uuid)
    end
    if type(params.q) == "string" and params.q ~= "" then
        local like = db.escape_literal("%" .. params.q:gsub("[%%_\\]", "\\%0") .. "%")
        where[#where + 1] = "(cd.name ILIKE " .. like .. " OR p.address_line1 ILIKE " .. like .. " OR p.postcode ILIKE " .. like .. ")"
    end
    local order = ({
        target_completion = "d.target_completion_date ASC NULLS LAST",
        money_at_risk = "d.money_at_risk DESC",
        created = "d.created_at DESC",
        health = "CASE d.health WHEN 'red' THEN 0 WHEN 'amber' THEN 1 ELSE 2 END, d.target_completion_date ASC NULLS LAST",
    })[params.sort or "created"] or "d.created_at DESC"
    local page, per_page, offset = require("helper.plugin-sdk").page(params)
    local w = table.concat(where, " AND ")
    local rows = db.query(SELECT .. " WHERE " .. w .. " ORDER BY " .. order .. ", d.id DESC LIMIT "
        .. per_page .. " OFFSET " .. offset)
    local total = db.query([[
        SELECT COUNT(*)::int AS n FROM property_deals_deals d
        JOIN crm_deals cd ON cd.uuid = d.crm_deal_uuid
        LEFT JOIN property_deals_properties p ON p.uuid = d.property_uuid
        WHERE ]] .. w)[1].n
    return U.array(rows), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) }
end

-- A CRM pipeline per template version, so CRM's deal views show our stages.
local function pipeline_for(ns, tpl, version)
    local name = tpl.name .. " (v" .. version.version .. ")"
    local p = U.one("SELECT id FROM crm_pipelines WHERE namespace_id = ? AND name = ? AND deleted_at IS NULL", ns, name)
    if p then return p.id end
    local stages = {}
    for _, s in ipairs(version.definition.stages) do stages[#stages + 1] = s.key end
    return db.insert("crm_pipelines", {
        uuid = require("helper.global").generateUUID(),
        namespace_id = ns, name = name,
        description = "Property Deals workflow: " .. tpl.key,
        stages = cjson.encode(U.array(stages)),
        is_default = false,
    }, { returning = { "id" } })[1].id
end

-- Convert a lead the same way POST /crm/leads/:uuid/convert does, but inside
-- our transaction. An already converted lead reuses its contact.
local function contact_from_lead(ns, lead, owner_uuid)
    if lead.converted_contact_id then
        return U.one("SELECT * FROM crm_contacts WHERE id = ? AND namespace_id = ?", lead.converted_contact_id, ns)
    end
    local contact = db.insert("crm_contacts", {
        uuid = require("helper.global").generateUUID(),
        namespace_id = ns,
        first_name = lead.first_name, last_name = lead.last_name, email = lead.email, phone = lead.phone,
        job_title = lead.job_title, owner_user_uuid = owner_uuid, status = "active",
        metadata = cjson.encode({ source = "property_deals", lead_uuid = lead.uuid }),
    }, { returning = "*" })[1]
    return contact
end

--- Create a deal. input: { lead_uuid? | contact_uuid?, name?, deal_type?, template? (uuid or key),
-- property_uuid?, offer_amount?, agreed_price?, currency?, finance_route?, target_exchange_date?,
-- target_completion_date?, late_penalty_per_day?, late_penalty_cap_days?, notes?, fees? }
-- @return deal row (Deals.get)
function Deals.create(ns, input, user_uuid, settings)
    Workspace.ensure(ns, user_uuid, settings)
    local deal_type = input.deal_type or "buy"
    local tpl, version = Store.active(ns, input.template or DEFAULT_TEMPLATE[deal_type])
    if not tpl then U.fail(422, "Validation failed", { template = "no active workflow template '" .. tostring(input.template) .. "'" }) end
    local first = version.definition.stages[1]

    return U.tx(function()
        local lead, contact
        if input.lead_uuid then
            lead = U.one("SELECT * FROM crm_leads WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL", input.lead_uuid, ns)
            if not lead then U.fail(422, "Validation failed", { lead_uuid = "not found" }) end
            contact = contact_from_lead(ns, lead, user_uuid)
        elseif input.contact_uuid then
            contact = U.one("SELECT * FROM crm_contacts WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL",
                input.contact_uuid, ns)
            if not contact then U.fail(422, "Validation failed", { contact_uuid = "not found" }) end
        end

        local property
        if input.property_uuid then
            property = U.one("SELECT * FROM property_deals_properties WHERE uuid = ? AND namespace_id = ?", input.property_uuid, ns)
            if not property then U.fail(422, "Validation failed", { property_uuid = "not found" }) end
        end

        local name = input.name
        if not name or name == "" then
            local who = contact and table.concat({ contact.first_name or "", contact.last_name or "" }, " "):match("^%s*(.-)%s*$")
            name = (property and property.address_line1) or (who ~= "" and who) or "New deal"
        end

        local crm_deal = db.insert("crm_deals", {
            uuid = require("helper.global").generateUUID(),
            namespace_id = ns,
            pipeline_id = pipeline_for(ns, tpl, version),
            contact_id = contact and contact.id or nil,
            name = name,
            value = tonumber(input.agreed_price or input.offer_amount) or 0,
            currency = input.currency or (settings and settings.currency) or "GBP",
            stage = first.key,
            expected_close_date = input.target_completion_date,
            owner_user_uuid = user_uuid,
            status = "open",
            metadata = cjson.encode({ source = "property_deals" }),
        }, { returning = "*" })[1]

        if lead and not lead.converted_at then
            db.update("crm_leads", {
                status = "converted", converted_at = db.raw("NOW()"), converted_contact_id = contact.id,
                converted_deal_id = crm_deal.id, updated_at = db.raw("NOW()"),
            }, { id = lead.id })
        end

        local state = Workspace.get(ns)
        local project = U.one("SELECT id FROM kanban_projects WHERE uuid = ?", state.kanban_project_uuid)
        local epic = require("queries.KanbanEpicQueries").create({
            project_id = project.id, namespace_id = ns, name = name, created_by = user_uuid,
            description = "Property deal " .. crm_deal.uuid,
            due_date = input.target_completion_date,
        })

        local deal = db.insert("property_deals_deals", {
            namespace_id = ns,
            crm_deal_uuid = crm_deal.uuid,
            property_uuid = property and property.uuid or nil,
            seller_lead_uuid = lead and lead.uuid or nil,
            deal_type = deal_type,
            template_version_uuid = version.uuid,
            stage_key = first.key,
            currency = crm_deal.currency,
            offer_amount = input.offer_amount,
            agreed_price = input.agreed_price,
            fees = input.fees,
            finance_route = input.finance_route,
            target_exchange_date = input.target_exchange_date,
            target_completion_date = input.target_completion_date,
            late_penalty_per_day = input.late_penalty_per_day,
            late_penalty_cap_days = input.late_penalty_cap_days,
            kanban_epic_uuid = epic and epic.uuid or nil,
            notes = input.notes,
        }, { returning = "*" })[1]

        if contact then
            db.insert("property_deals_deal_parties", {
                namespace_id = ns, deal_uuid = deal.uuid,
                role = deal_type == "sell" and "buyer" or "seller",
                contact_uuid = contact.uuid, is_primary = true,
            })
        end
        if lead then
            db.update("property_deals_lead_details", { property_uuid = deal.property_uuid or db.NULL },
                { namespace_id = ns, lead_uuid = lead.uuid })
            -- Contacts logged on the lead before it was a deal now show on the deal.
            db.query("UPDATE property_deals_chases SET deal_uuid = ?, updated_at = NOW() WHERE namespace_id = ? AND lead_uuid = ? AND deal_uuid IS NULL",
                deal.uuid, ns, lead.uuid)
        end
        -- Workflow engine: the first stage's tasks.
        require("property_deals.engine").enter_stage(ns, deal.uuid, first.key, user_uuid, settings)
        return Deals.get(ns, deal.uuid)
    end)
end

-- Columns a client may change directly. stage_key, health and money_at_risk
-- are owned by the workflow engine (Phase 3): stage moves go through
-- POST /deals/:id/stage so gates are checked.
Deals.UPDATABLE = {
    property_uuid = { type = "uuid" },
    offer_amount = { type = "number", min = 0 },
    agreed_price = { type = "number", min = 0 },
    fees = { type = "json" },
    finance_route = { type = "string", max = 30 },
    target_exchange_date = { type = "date" },
    target_completion_date = { type = "date" },
    late_penalty_per_day = { type = "number", min = 0 },
    late_penalty_cap_days = { type = "integer", min = 0 },
    status = { enum = { "active", "on_hold", "completed", "fell_through" } },
    notes = { type = "text" },
    name = { type = "string" },
}

function Deals.update(ns, uuid, data, actor_uuid)
    local deal = Deals.get(ns, uuid)
    if not deal then return nil end
    return U.tx(function()
        local crm = {}
        if data.name ~= nil then crm.name, data.name = data.name, nil end
        if data.agreed_price ~= nil and data.agreed_price ~= db.NULL then crm.value = data.agreed_price end
        if data.target_completion_date ~= nil then crm.expected_close_date = data.target_completion_date end
        if data.status == "completed" then
            crm.status, crm.won_at, crm.actual_close_date = "won", db.raw("NOW()"), db.raw("CURRENT_DATE")
        elseif data.status == "fell_through" then
            crm.status, crm.lost_at = "lost", db.raw("NOW()")
        end
        if next(crm) then
            crm.updated_at = db.raw("NOW()")
            db.update("crm_deals", crm, { uuid = deal.crm_deal_uuid, namespace_id = ns })
        end
        local retime = data.target_exchange_date ~= nil or data.target_completion_date ~= nil
        if next(data) then
            data.updated_at = db.raw("NOW()")
            db.update("property_deals_deals", data, { uuid = uuid, namespace_id = ns })
        end
        if retime then require("property_deals.engine").retarget(ns, uuid, actor_uuid) end
        return Deals.get(ns, uuid)
    end)
end

return Deals
