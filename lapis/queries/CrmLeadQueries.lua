--[[
    CRM Lead Queries
    ================

    Query helpers for CRM lead capture and management.
    Supports CRUD, conversion to contacts/deals, stats, and public submission.
]]

local CrmLeadModel = require("models.CrmLeadModel")
local CrmContactModel = require("models.CrmContactModel")
local CrmDealModel = require("models.CrmDealModel")
local Global = require("helper.global")
local db = require("lapis.db")

local CrmLeadQueries = {}

--------------------------------------------------------------------------------
-- Lead CRUD
--------------------------------------------------------------------------------

--- Create a new lead
-- @param params table Lead parameters
-- @return table|nil Created lead
function CrmLeadQueries.createLead(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return CrmLeadModel:create(params, { returning = "*" })
end

--- List leads for a namespace with pagination and filters
-- @param namespace_id number Namespace ID
-- @param params table Filter/pagination params
-- @return table Leads list with meta
function CrmLeadQueries.getLeads(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "l.namespace_id = ? AND l.deleted_at IS NULL" }
    local where_values = { namespace_id }

    if params.status and params.status ~= "" then
        table.insert(where_parts, "l.status = ?")
        table.insert(where_values, params.status)
    end

    if params.source and params.source ~= "" then
        table.insert(where_parts, "l.source = ?")
        table.insert(where_values, params.source)
    end

    if params.priority and params.priority ~= "" then
        table.insert(where_parts, "l.priority = ?")
        table.insert(where_values, params.priority)
    end

    if params.owner_user_uuid and params.owner_user_uuid ~= "" then
        table.insert(where_parts, "l.owner_user_uuid = ?")
        table.insert(where_values, params.owner_user_uuid)
    end

    if params.search and params.search ~= "" then
        table.insert(where_parts, "(l.first_name ILIKE ? OR l.last_name ILIKE ? OR l.email ILIKE ? OR l.company_name ILIKE ?)")
        local search_term = "%" .. params.search .. "%"
        table.insert(where_values, search_term)
        table.insert(where_values, search_term)
        table.insert(where_values, search_term)
        table.insert(where_values, search_term)
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Count
    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM crm_leads l WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    -- Data
    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT l.*
        FROM crm_leads l
        WHERE %s
        ORDER BY l.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local leads = db.query(data_sql, unpack(data_values))

    return {
        items = leads,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single lead by UUID
-- @param uuid string Lead UUID
-- @return table|nil Lead
function CrmLeadQueries.getLead(uuid)
    local result = db.query([[
        SELECT l.*,
               cc.uuid as converted_contact_uuid,
               cc.first_name as converted_contact_first_name,
               cc.last_name as converted_contact_last_name,
               cd.uuid as converted_deal_uuid,
               cd.name as converted_deal_name
        FROM crm_leads l
        LEFT JOIN crm_contacts cc ON cc.id = l.converted_contact_id
        LEFT JOIN crm_deals cd ON cd.id = l.converted_deal_id
        WHERE l.uuid = ? AND l.deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--- Update a lead
-- @param uuid string Lead UUID
-- @param params table Update parameters
-- @return table|nil Updated lead
function CrmLeadQueries.updateLead(uuid, params)
    local lead = CrmLeadModel:find({ uuid = uuid })
    if not lead then return nil end

    params.updated_at = db.raw("NOW()")
    return lead:update(params, { returning = "*" })
end

--- Soft-delete a lead
-- @param uuid string Lead UUID
-- @return table|nil Deleted lead
function CrmLeadQueries.deleteLead(uuid)
    local lead = CrmLeadModel:find({ uuid = uuid })
    if not lead then return nil end

    return lead:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Lead Conversion
--------------------------------------------------------------------------------

--- Convert a lead into a CRM contact and optionally a deal
-- @param uuid string Lead UUID
-- @param namespace_id number Namespace ID (for verification)
-- @param owner_user_uuid string User performing conversion
-- @param deal_params table|nil Optional deal parameters
-- @return table|nil { lead, contact, deal }
function CrmLeadQueries.convertLead(uuid, namespace_id, owner_user_uuid, deal_params)
    local lead = CrmLeadModel:find({ uuid = uuid })
    if not lead then return nil, "Lead not found" end
    if tonumber(lead.namespace_id) ~= tonumber(namespace_id) then return nil, "Access denied" end
    if lead.status == "converted" then return nil, "Lead is already converted" end

    -- Start transaction
    db.query("BEGIN")

    local ok, err = pcall(function()
        -- Create CRM contact from lead data
        local contact = CrmContactModel:create({
            uuid = Global.generateUUID(),
            namespace_id = lead.namespace_id,
            first_name = lead.first_name,
            last_name = lead.last_name,
            email = lead.email,
            phone = lead.phone,
            job_title = lead.job_title,
            owner_user_uuid = owner_user_uuid,
            status = "active",
            metadata = lead.metadata or "{}",
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        }, { returning = "*" })

        if not contact then error("Failed to create contact") end

        -- Optionally create a deal
        local deal = nil
        if deal_params and deal_params.name and deal_params.name ~= "" then
            deal = CrmDealModel:create({
                uuid = Global.generateUUID(),
                namespace_id = lead.namespace_id,
                contact_id = contact.id,
                name = deal_params.name,
                value = tonumber(deal_params.value) or 0,
                currency = deal_params.currency or "GBP",
                stage = deal_params.stage or "new",
                pipeline_id = deal_params.pipeline_id and tonumber(deal_params.pipeline_id) or nil,
                owner_user_uuid = owner_user_uuid,
                status = "open",
                metadata = "{}",
                created_at = db.raw("NOW()"),
                updated_at = db.raw("NOW()")
            }, { returning = "*" })
        end

        -- Update lead as converted
        local update_data = {
            status = "converted",
            converted_at = db.raw("NOW()"),
            converted_contact_id = contact.id,
            updated_at = db.raw("NOW()")
        }
        if deal then
            update_data.converted_deal_id = deal.id
        end
        lead:update(update_data, { returning = "*" })

        -- Store results for return
        lead._contact = contact
        lead._deal = deal
    end)

    if not ok then
        db.query("ROLLBACK")
        return nil, err or "Conversion failed"
    end

    db.query("COMMIT")

    return {
        lead = lead,
        contact = lead._contact,
        deal = lead._deal
    }
end

--------------------------------------------------------------------------------
-- Lead Stats
--------------------------------------------------------------------------------

--- Get lead statistics for a namespace
-- @param namespace_id number Namespace ID
-- @return table Lead stats
function CrmLeadQueries.getLeadStats(namespace_id)
    local result = db.query([[
        SELECT
            COUNT(*) as total_leads,
            COUNT(*) FILTER (WHERE status = 'new') as new_leads,
            COUNT(*) FILTER (WHERE status = 'contacted') as contacted_leads,
            COUNT(*) FILTER (WHERE status = 'qualified') as qualified_leads,
            COUNT(*) FILTER (WHERE status = 'converted') as converted_leads,
            COUNT(*) FILTER (WHERE status = 'lost') as lost_leads,
            CASE
                WHEN COUNT(*) FILTER (WHERE status IN ('converted', 'lost')) > 0
                THEN ROUND(
                    COUNT(*) FILTER (WHERE status = 'converted')::numeric /
                    COUNT(*) FILTER (WHERE status IN ('converted', 'lost'))::numeric * 100, 2
                )
                ELSE 0
            END as conversion_rate
        FROM crm_leads
        WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id)

    local stats = result and result[1] or {}

    -- Leads by source
    local by_source = db.query([[
        SELECT source, COUNT(*) as count
        FROM crm_leads
        WHERE namespace_id = ? AND deleted_at IS NULL
        GROUP BY source
        ORDER BY count DESC
    ]], namespace_id)

    stats.leads_by_source = by_source or {}

    return stats
end

--------------------------------------------------------------------------------
-- Public Lead Submission
--------------------------------------------------------------------------------

--- Create a lead from public submission (sanitized, always status=new)
-- @param params table Lead parameters
-- @return table|nil Created lead
function CrmLeadQueries.createLeadFromPublic(params)
    -- Check for duplicate submission (same email in same namespace within 5 minutes)
    if params.email and params.email ~= "" then
        local recent = db.query([[
            SELECT id FROM crm_leads
            WHERE namespace_id = ? AND email = ? AND created_at > NOW() - INTERVAL '5 minutes'
            LIMIT 1
        ]], params.namespace_id, params.email)

        if recent and #recent > 0 then
            return nil, "duplicate"
        end
    end

    -- Enforce public defaults
    params.status = "new"
    params.score = 0
    params.owner_user_uuid = nil

    return CrmLeadQueries.createLead(params)
end

return CrmLeadQueries
