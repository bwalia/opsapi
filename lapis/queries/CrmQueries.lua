--[[
    CRM Queries
    ===========

    Query helpers for the CRM system: pipelines, accounts, contacts, deals,
    and activities.
]]

local CrmPipelineModel = require("models.CrmPipelineModel")
local CrmAccountModel = require("models.CrmAccountModel")
local CrmContactModel = require("models.CrmContactModel")
local CrmDealModel = require("models.CrmDealModel")
local CrmActivityModel = require("models.CrmActivityModel")
local Global = require("helper.global")
local db = require("lapis.db")

local CrmQueries = {}

--------------------------------------------------------------------------------
-- Pipeline CRUD
--------------------------------------------------------------------------------

--- Create a new pipeline
-- @param params table Pipeline parameters
-- @return table|nil Created pipeline
function CrmQueries.createPipeline(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return CrmPipelineModel:create(params, { returning = "*" })
end

--- List pipelines for a namespace with pagination
-- @param namespace_id number Namespace ID
-- @param params table Pagination params (page, per_page)
-- @return table Pipelines list with meta
function CrmQueries.getPipelines(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20

    local offset = (page - 1) * per_page

    local count_result = db.query([[
        SELECT COUNT(*) as total FROM crm_pipelines
        WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id)
    local total = tonumber(count_result[1].total) or 0

    local pipelines = db.query([[
        SELECT * FROM crm_pipelines
        WHERE namespace_id = ? AND deleted_at IS NULL
        ORDER BY is_default DESC, created_at ASC
        LIMIT ? OFFSET ?
    ]], namespace_id, per_page, offset)

    return {
        items = pipelines,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single pipeline by UUID
-- @param uuid string Pipeline UUID
-- @return table|nil Pipeline
function CrmQueries.getPipeline(uuid)
    local result = db.query([[
        SELECT * FROM crm_pipelines
        WHERE uuid = ? AND deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--- Update a pipeline
-- @param uuid string Pipeline UUID
-- @param params table Update parameters
-- @return table|nil Updated pipeline
function CrmQueries.updatePipeline(uuid, params)
    local pipeline = CrmPipelineModel:find({ uuid = uuid })
    if not pipeline then return nil end

    params.updated_at = db.raw("NOW()")
    return pipeline:update(params, { returning = "*" })
end

--- Soft-delete a pipeline
-- @param uuid string Pipeline UUID
-- @return table|nil Deleted pipeline
function CrmQueries.deletePipeline(uuid)
    local pipeline = CrmPipelineModel:find({ uuid = uuid })
    if not pipeline then return nil end

    return pipeline:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Account CRUD
--------------------------------------------------------------------------------

--- Create a new account
-- @param params table Account parameters
-- @return table|nil Created account
function CrmQueries.createAccount(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return CrmAccountModel:create(params, { returning = "*" })
end

--- List accounts for a namespace with pagination and filters
-- @param namespace_id number Namespace ID
-- @param params table Filter/pagination params
-- @return table Accounts list with meta
function CrmQueries.getAccounts(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "namespace_id = ? AND deleted_at IS NULL" }
    local where_values = { namespace_id }

    if params.status and params.status ~= "" then
        table.insert(where_parts, "status = ?")
        table.insert(where_values, params.status)
    end

    if params.owner_user_uuid and params.owner_user_uuid ~= "" then
        table.insert(where_parts, "owner_user_uuid = ?")
        table.insert(where_values, params.owner_user_uuid)
    end

    if params.search and params.search ~= "" then
        table.insert(where_parts, "(name ILIKE ? OR email ILIKE ?)")
        local search_term = "%" .. params.search .. "%"
        table.insert(where_values, search_term)
        table.insert(where_values, search_term)
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Count
    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM crm_accounts WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    -- Data
    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT * FROM crm_accounts
        WHERE %s
        ORDER BY created_at DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local accounts = db.query(data_sql, unpack(data_values))

    return {
        items = accounts,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single account by UUID with aggregated stats
-- @param uuid string Account UUID
-- @return table|nil Account with stats
function CrmQueries.getAccount(uuid)
    local result = db.query([[
        SELECT a.*,
               (SELECT COUNT(*) FROM crm_contacts WHERE account_id = a.id AND deleted_at IS NULL) as contact_count,
               (SELECT COUNT(*) FROM crm_deals WHERE account_id = a.id AND deleted_at IS NULL) as deal_count,
               (SELECT COALESCE(SUM(value), 0) FROM crm_deals WHERE account_id = a.id AND deleted_at IS NULL) as total_deal_value
        FROM crm_accounts a
        WHERE a.uuid = ? AND a.deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--- Update an account
-- @param uuid string Account UUID
-- @param params table Update parameters
-- @return table|nil Updated account
function CrmQueries.updateAccount(uuid, params)
    local account = CrmAccountModel:find({ uuid = uuid })
    if not account then return nil end

    params.updated_at = db.raw("NOW()")
    return account:update(params, { returning = "*" })
end

--- Soft-delete an account
-- @param uuid string Account UUID
-- @return table|nil Deleted account
function CrmQueries.deleteAccount(uuid)
    local account = CrmAccountModel:find({ uuid = uuid })
    if not account then return nil end

    return account:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Contact CRUD
--------------------------------------------------------------------------------

--- Create a new contact
-- @param params table Contact parameters
-- @return table|nil Created contact
function CrmQueries.createContact(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return CrmContactModel:create(params, { returning = "*" })
end

--- List contacts for a namespace with pagination and filters
-- @param namespace_id number Namespace ID
-- @param params table Filter/pagination params
-- @return table Contacts list with meta
function CrmQueries.getContacts(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "c.namespace_id = ? AND c.deleted_at IS NULL" }
    local where_values = { namespace_id }

    if params.account_id and params.account_id ~= "" then
        table.insert(where_parts, "c.account_id = ?")
        table.insert(where_values, tonumber(params.account_id))
    end

    if params.status and params.status ~= "" then
        table.insert(where_parts, "c.status = ?")
        table.insert(where_values, params.status)
    end

    if params.search and params.search ~= "" then
        table.insert(where_parts, "(c.first_name ILIKE ? OR c.last_name ILIKE ? OR c.email ILIKE ?)")
        local search_term = "%" .. params.search .. "%"
        table.insert(where_values, search_term)
        table.insert(where_values, search_term)
        table.insert(where_values, search_term)
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Count
    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM crm_contacts c WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    -- Data with account name join
    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT c.*, a.name as account_name
        FROM crm_contacts c
        LEFT JOIN crm_accounts a ON a.id = c.account_id
        WHERE %s
        ORDER BY c.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local contacts = db.query(data_sql, unpack(data_values))

    return {
        items = contacts,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single contact by UUID with account name
-- @param uuid string Contact UUID
-- @return table|nil Contact
function CrmQueries.getContact(uuid)
    local result = db.query([[
        SELECT c.*, a.name as account_name
        FROM crm_contacts c
        LEFT JOIN crm_accounts a ON a.id = c.account_id
        WHERE c.uuid = ? AND c.deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--- Update a contact
-- @param uuid string Contact UUID
-- @param params table Update parameters
-- @return table|nil Updated contact
function CrmQueries.updateContact(uuid, params)
    local contact = CrmContactModel:find({ uuid = uuid })
    if not contact then return nil end

    params.updated_at = db.raw("NOW()")
    return contact:update(params, { returning = "*" })
end

--- Soft-delete a contact
-- @param uuid string Contact UUID
-- @return table|nil Deleted contact
function CrmQueries.deleteContact(uuid)
    local contact = CrmContactModel:find({ uuid = uuid })
    if not contact then return nil end

    return contact:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Deal CRUD
--------------------------------------------------------------------------------

--- Create a new deal
-- @param params table Deal parameters
-- @return table|nil Created deal
function CrmQueries.createDeal(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return CrmDealModel:create(params, { returning = "*" })
end

--- List deals for a namespace with pagination and filters
-- @param namespace_id number Namespace ID
-- @param params table Filter/pagination params
-- @return table Deals list with meta
function CrmQueries.getDeals(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "d.namespace_id = ? AND d.deleted_at IS NULL" }
    local where_values = { namespace_id }

    if params.pipeline_id and params.pipeline_id ~= "" then
        table.insert(where_parts, "d.pipeline_id = ?")
        table.insert(where_values, tonumber(params.pipeline_id))
    end

    if params.stage and params.stage ~= "" then
        table.insert(where_parts, "d.stage = ?")
        table.insert(where_values, params.stage)
    end

    if params.status and params.status ~= "" then
        table.insert(where_parts, "d.status = ?")
        table.insert(where_values, params.status)
    end

    if params.owner_user_uuid and params.owner_user_uuid ~= "" then
        table.insert(where_parts, "d.owner_user_uuid = ?")
        table.insert(where_values, params.owner_user_uuid)
    end

    if params.account_id and params.account_id ~= "" then
        table.insert(where_parts, "d.account_id = ?")
        table.insert(where_values, tonumber(params.account_id))
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Count
    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM crm_deals d WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    -- Data with joins
    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT d.*,
               a.name as account_name,
               ct.first_name as contact_first_name,
               ct.last_name as contact_last_name,
               p.name as pipeline_name
        FROM crm_deals d
        LEFT JOIN crm_accounts a ON a.id = d.account_id
        LEFT JOIN crm_contacts ct ON ct.id = d.contact_id
        LEFT JOIN crm_pipelines p ON p.id = d.pipeline_id
        WHERE %s
        ORDER BY d.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local deals = db.query(data_sql, unpack(data_values))

    return {
        items = deals,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single deal by UUID with account/contact/pipeline joins
-- @param uuid string Deal UUID
-- @return table|nil Deal
function CrmQueries.getDeal(uuid)
    local result = db.query([[
        SELECT d.*,
               a.name as account_name,
               ct.first_name as contact_first_name,
               ct.last_name as contact_last_name,
               ct.email as contact_email,
               p.name as pipeline_name,
               p.stages as pipeline_stages
        FROM crm_deals d
        LEFT JOIN crm_accounts a ON a.id = d.account_id
        LEFT JOIN crm_contacts ct ON ct.id = d.contact_id
        LEFT JOIN crm_pipelines p ON p.id = d.pipeline_id
        WHERE d.uuid = ? AND d.deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--- Update a deal (detects stage changes for won/lost)
-- @param uuid string Deal UUID
-- @param params table Update parameters
-- @return table|nil Updated deal
function CrmQueries.updateDeal(uuid, params)
    local deal = CrmDealModel:find({ uuid = uuid })
    if not deal then return nil end

    -- Detect stage transitions
    if params.stage and params.stage ~= deal.stage then
        if params.stage == "won" then
            params.won_at = db.raw("NOW()")
            params.actual_close_date = db.raw("CURRENT_DATE")
            params.status = "won"
        elseif params.stage == "lost" then
            params.lost_at = db.raw("NOW()")
            params.actual_close_date = db.raw("CURRENT_DATE")
            params.status = "lost"
        end
    end

    params.updated_at = db.raw("NOW()")
    return deal:update(params, { returning = "*" })
end

--- Soft-delete a deal
-- @param uuid string Deal UUID
-- @return table|nil Deleted deal
function CrmQueries.deleteDeal(uuid)
    local deal = CrmDealModel:find({ uuid = uuid })
    if not deal then return nil end

    return deal:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Get deals grouped by stage for a pipeline (kanban view)
-- @param namespace_id number Namespace ID
-- @param pipeline_id number Pipeline ID
-- @return table Deals grouped by stage
function CrmQueries.getDealsByPipeline(namespace_id, pipeline_id)
    local deals = db.query([[
        SELECT d.*,
               a.name as account_name,
               ct.first_name as contact_first_name,
               ct.last_name as contact_last_name
        FROM crm_deals d
        LEFT JOIN crm_accounts a ON a.id = d.account_id
        LEFT JOIN crm_contacts ct ON ct.id = d.contact_id
        WHERE d.namespace_id = ? AND d.pipeline_id = ? AND d.deleted_at IS NULL
        ORDER BY d.stage, d.created_at ASC
    ]], namespace_id, pipeline_id)

    -- Group by stage
    local stages = {}
    for _, deal in ipairs(deals or {}) do
        if not stages[deal.stage] then
            stages[deal.stage] = {}
        end
        table.insert(stages[deal.stage], deal)
    end

    return stages
end

--- Get dashboard statistics for a namespace
-- @param namespace_id number Namespace ID
-- @return table Dashboard stats
function CrmQueries.getDashboardStats(namespace_id)
    local result = db.query([[
        SELECT
            COUNT(*) as total_deals,
            COALESCE(SUM(value), 0) as total_value,
            COUNT(*) FILTER (WHERE status = 'open') as open_deals,
            COUNT(*) FILTER (WHERE status = 'won') as won_deals,
            COUNT(*) FILTER (WHERE status = 'lost') as lost_deals,
            COALESCE(SUM(value) FILTER (WHERE status = 'won'), 0) as won_value,
            CASE
                WHEN COUNT(*) FILTER (WHERE status IN ('won', 'lost')) > 0
                THEN ROUND(
                    COUNT(*) FILTER (WHERE status = 'won')::numeric /
                    COUNT(*) FILTER (WHERE status IN ('won', 'lost'))::numeric * 100, 2
                )
                ELSE 0
            END as win_rate
        FROM crm_deals
        WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id)

    local stats = result and result[1] or {}

    -- Deals by stage
    local by_stage = db.query([[
        SELECT stage, COUNT(*) as count, COALESCE(SUM(value), 0) as total_value
        FROM crm_deals
        WHERE namespace_id = ? AND deleted_at IS NULL AND status = 'open'
        GROUP BY stage
        ORDER BY count DESC
    ]], namespace_id)

    stats.deals_by_stage = by_stage or {}

    return stats
end

--------------------------------------------------------------------------------
-- Activity CRUD
--------------------------------------------------------------------------------

--- Create a new activity
-- @param params table Activity parameters
-- @return table|nil Created activity
function CrmQueries.createActivity(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return CrmActivityModel:create(params, { returning = "*" })
end

--- List activities for a namespace with pagination and filters
-- @param namespace_id number Namespace ID
-- @param params table Filter/pagination params
-- @return table Activities list with meta
function CrmQueries.getActivities(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "act.namespace_id = ? AND act.deleted_at IS NULL" }
    local where_values = { namespace_id }

    if params.activity_type and params.activity_type ~= "" then
        table.insert(where_parts, "act.activity_type = ?")
        table.insert(where_values, params.activity_type)
    end

    if params.account_id and params.account_id ~= "" then
        table.insert(where_parts, "act.account_id = ?")
        table.insert(where_values, tonumber(params.account_id))
    end

    if params.contact_id and params.contact_id ~= "" then
        table.insert(where_parts, "act.contact_id = ?")
        table.insert(where_values, tonumber(params.contact_id))
    end

    if params.deal_id and params.deal_id ~= "" then
        table.insert(where_parts, "act.deal_id = ?")
        table.insert(where_values, tonumber(params.deal_id))
    end

    if params.status and params.status ~= "" then
        table.insert(where_parts, "act.status = ?")
        table.insert(where_values, params.status)
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Count
    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM crm_activities act WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    -- Data
    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT act.*,
               a.name as account_name,
               ct.first_name as contact_first_name,
               ct.last_name as contact_last_name,
               d.name as deal_name
        FROM crm_activities act
        LEFT JOIN crm_accounts a ON a.id = act.account_id
        LEFT JOIN crm_contacts ct ON ct.id = act.contact_id
        LEFT JOIN crm_deals d ON d.id = act.deal_id
        WHERE %s
        ORDER BY act.activity_date DESC, act.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local activities = db.query(data_sql, unpack(data_values))

    return {
        items = activities,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single activity by UUID
-- @param uuid string Activity UUID
-- @return table|nil Activity
function CrmQueries.getActivity(uuid)
    local result = db.query([[
        SELECT act.*,
               a.name as account_name,
               ct.first_name as contact_first_name,
               ct.last_name as contact_last_name,
               d.name as deal_name
        FROM crm_activities act
        LEFT JOIN crm_accounts a ON a.id = act.account_id
        LEFT JOIN crm_contacts ct ON ct.id = act.contact_id
        LEFT JOIN crm_deals d ON d.id = act.deal_id
        WHERE act.uuid = ? AND act.deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--- Update an activity
-- @param uuid string Activity UUID
-- @param params table Update parameters
-- @return table|nil Updated activity
function CrmQueries.updateActivity(uuid, params)
    local activity = CrmActivityModel:find({ uuid = uuid })
    if not activity then return nil end

    params.updated_at = db.raw("NOW()")
    return activity:update(params, { returning = "*" })
end

--- Soft-delete an activity
-- @param uuid string Activity UUID
-- @return table|nil Deleted activity
function CrmQueries.deleteActivity(uuid)
    local activity = CrmActivityModel:find({ uuid = uuid })
    if not activity then return nil end

    return activity:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Mark an activity as completed
-- @param uuid string Activity UUID
-- @return table|nil Completed activity
function CrmQueries.completeActivity(uuid)
    local activity = CrmActivityModel:find({ uuid = uuid })
    if not activity then return nil end

    return activity:update({
        completed_at = db.raw("NOW()"),
        status = "completed",
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

return CrmQueries
