--[[
    Field Service — configuration queries
    =====================================

    Job types + their phase templates, customer sites, and the lookups the
    dashboard needs to build a job (engineers, CRM accounts/contacts).
    Everything is namespace-scoped.
]]

local db = require("lapis.db")
local FsJobTypeModel = require("models.FsJobTypeModel")
local FsPhaseTemplateModel = require("models.FsPhaseTemplateModel")
local FsSiteModel = require("models.FsSiteModel")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable, to_bool, to_number, arr = Common.nilify, Common.nullable, Common.to_bool, Common.to_number,
    Common.arr

local ConfigQueries = {}

--------------------------------------------------------------------------------
-- Job types
--------------------------------------------------------------------------------

local function shape_template(t)
    return {
        uuid = t.uuid,
        name = t.name,
        description = t.description,
        sort_order = t.sort_order,
        requires_visit = t.requires_visit,
        requires_signoff = t.requires_signoff,
        estimated_hours = t.estimated_hours,
        checklist = arr(Common.template_checklist(t.checklist)),
    }
end

local function list_templates(job_type_id)
    local rows = db.query([[
        SELECT * FROM fs_phase_templates
        WHERE job_type_id = ? AND deleted_at IS NULL
        ORDER BY sort_order ASC, id ASC
    ]], job_type_id)
    local out = {}
    for _, t in ipairs(rows or {}) do table.insert(out, shape_template(t)) end
    return arr(out)
end

local function shape_job_type(row, with_phases)
    local out = {
        uuid = row.uuid,
        name = row.name,
        description = row.description,
        color = row.color,
        default_hourly_rate = row.default_hourly_rate,
        is_active = row.is_active,
        phase_count = tonumber(row.phase_count) or nil,
        job_count = tonumber(row.job_count) or nil,
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
    if with_phases then out.phases = list_templates(row.id) end
    return out
end

function ConfigQueries.listJobTypes(namespace_id, params)
    params = params or {}
    local where = { "jt.namespace_id = ?", "jt.deleted_at IS NULL" }
    local values = { namespace_id }
    if not to_bool(params.include_inactive, false) then
        table.insert(where, "jt.is_active = true")
    end
    local rows = db.query([[
        SELECT jt.*,
            (SELECT COUNT(*) FROM fs_phase_templates pt
             WHERE pt.job_type_id = jt.id AND pt.deleted_at IS NULL) AS phase_count,
            (SELECT COUNT(*) FROM fs_jobs j
             WHERE j.job_type_id = jt.id AND j.deleted_at IS NULL) AS job_count
        FROM fs_job_types jt
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY jt.name ASC
    ]], unpack(values))

    local out = {}
    for _, row in ipairs(rows or {}) do
        table.insert(out, shape_job_type(row, to_bool(params.with_phases, false)))
    end
    return arr(out)
end

local function find_job_type_row(namespace_id, uuid)
    local rows = db.query([[
        SELECT * FROM fs_job_types WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    return rows and rows[1]
end

function ConfigQueries.getJobType(namespace_id, uuid)
    local row = find_job_type_row(namespace_id, uuid)
    if not row then return nil end
    return shape_job_type(row, true)
end

local function template_fields(data)
    return {
        name = data.name and tostring(data.name) or nil,
        description = nilify(data.description),
        requires_visit = to_bool(data.requires_visit, true),
        requires_signoff = to_bool(data.requires_signoff, false),
        estimated_hours = to_number(data.estimated_hours),
        checklist = Common.encode_array(Common.template_checklist(data.checklist)),
    }
end

local function next_template_order(job_type_id)
    local rows = db.query([[
        SELECT COALESCE(MAX(sort_order), 0) + 1 AS n FROM fs_phase_templates
        WHERE job_type_id = ? AND deleted_at IS NULL
    ]], job_type_id)
    return tonumber(rows[1].n) or 1
end

--- Create a job type, optionally with an ordered `phases` array.
function ConfigQueries.createJobType(namespace_id, data)
    if not nilify(data.name) then return nil, "name is required" end

    return Common.transaction(function()
        local jt = FsJobTypeModel:create({
            uuid = Common.uuid(),
            namespace_id = namespace_id,
            name = tostring(data.name),
            description = nilify(data.description),
            color = nilify(data.color),
            default_hourly_rate = to_number(data.default_hourly_rate),
            is_active = to_bool(data.is_active, true),
        })

        for i, phase in ipairs(type(data.phases) == "table" and data.phases or {}) do
            if type(phase) == "string" then phase = { name = phase } end
            if nilify(phase.name) then
                local fields = template_fields(phase)
                fields.uuid = Common.uuid()
                fields.namespace_id = namespace_id
                fields.job_type_id = jt.id
                fields.sort_order = i
                FsPhaseTemplateModel:create(fields)
            end
        end

        return ConfigQueries.getJobType(namespace_id, jt.uuid)
    end)
end

function ConfigQueries.updateJobType(namespace_id, uuid, data)
    local row = find_job_type_row(namespace_id, uuid)
    if not row then return nil, "Job type not found" end

    local update = {}
    if data.name ~= nil then
        if not nilify(data.name) then return nil, "name cannot be empty" end
        update.name = tostring(data.name)
    end
    if data.description ~= nil then update.description = nullable(data.description) end
    if data.color ~= nil then update.color = nullable(data.color) end
    if data.default_hourly_rate ~= nil then
        update.default_hourly_rate = to_number(data.default_hourly_rate) or db.NULL
    end
    if data.is_active ~= nil then update.is_active = to_bool(data.is_active, true) end
    if next(update) == nil then return nil, "No valid fields to update" end

    FsJobTypeModel:find(row.id):update(update)
    return ConfigQueries.getJobType(namespace_id, uuid)
end

function ConfigQueries.deleteJobType(namespace_id, uuid)
    local row = find_job_type_row(namespace_id, uuid)
    if not row then return nil, "Job type not found" end
    -- Existing jobs keep their copied phases; they just lose the type label.
    db.query("UPDATE fs_job_types SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", row.id)
    return true
end

--------------------------------------------------------------------------------
-- Phase templates
--------------------------------------------------------------------------------

function ConfigQueries.addPhaseTemplate(namespace_id, job_type_uuid, data)
    local jt = find_job_type_row(namespace_id, job_type_uuid)
    if not jt then return nil, "Job type not found" end
    if not nilify(data.name) then return nil, "name is required" end

    local fields = template_fields(data)
    fields.uuid = Common.uuid()
    fields.namespace_id = namespace_id
    fields.job_type_id = jt.id
    fields.sort_order = to_number(data.sort_order) or next_template_order(jt.id)
    local t = FsPhaseTemplateModel:create(fields)
    return shape_template(FsPhaseTemplateModel:find(t.id))
end

local function find_template(namespace_id, uuid)
    local rows = db.query([[
        SELECT * FROM fs_phase_templates WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    return rows and rows[1]
end

function ConfigQueries.updatePhaseTemplate(namespace_id, uuid, data)
    local t = find_template(namespace_id, uuid)
    if not t then return nil, "Phase template not found" end

    local update = {}
    if data.name ~= nil then
        if not nilify(data.name) then return nil, "name cannot be empty" end
        update.name = tostring(data.name)
    end
    if data.description ~= nil then update.description = nullable(data.description) end
    if data.requires_visit ~= nil then update.requires_visit = to_bool(data.requires_visit, true) end
    if data.requires_signoff ~= nil then update.requires_signoff = to_bool(data.requires_signoff, false) end
    if data.estimated_hours ~= nil then update.estimated_hours = to_number(data.estimated_hours) or db.NULL end
    if data.checklist ~= nil then
        update.checklist = Common.encode_array(Common.template_checklist(data.checklist))
    end
    if next(update) == nil then return nil, "No valid fields to update" end

    local model = FsPhaseTemplateModel:find(t.id)
    model:update(update)
    return shape_template(FsPhaseTemplateModel:find(t.id))
end

function ConfigQueries.deletePhaseTemplate(namespace_id, uuid)
    local t = find_template(namespace_id, uuid)
    if not t then return nil, "Phase template not found" end
    db.query("UPDATE fs_phase_templates SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", t.id)
    return true
end

--- Reorder a job type's templates to match `uuids` (templates not listed keep
-- their relative order after the listed ones).
function ConfigQueries.reorderPhaseTemplates(namespace_id, job_type_uuid, uuids)
    local jt = find_job_type_row(namespace_id, job_type_uuid)
    if not jt then return nil, "Job type not found" end
    if type(uuids) ~= "table" or #uuids == 0 then return nil, "order must be a non-empty array of uuids" end

    return Common.transaction(function()
        local position = 0
        local seen = {}
        for _, u in ipairs(uuids) do
            position = position + 1
            seen[tostring(u)] = true
            db.query([[
                UPDATE fs_phase_templates SET sort_order = ?, updated_at = NOW()
                WHERE uuid = ? AND job_type_id = ? AND deleted_at IS NULL
            ]], position, tostring(u), jt.id)
        end
        local rest = db.query([[
            SELECT id, uuid FROM fs_phase_templates
            WHERE job_type_id = ? AND deleted_at IS NULL ORDER BY sort_order, id
        ]], jt.id)
        for _, r in ipairs(rest or {}) do
            if not seen[r.uuid] then
                position = position + 1
                db.query("UPDATE fs_phase_templates SET sort_order = ? WHERE id = ?", position, r.id)
            end
        end
        return list_templates(jt.id)
    end)
end

--------------------------------------------------------------------------------
-- Sites
--------------------------------------------------------------------------------

local SITE_SELECT = [[
    SELECT s.*, a.uuid AS account_uuid, a.name AS account_name,
        (SELECT COUNT(*) FROM fs_jobs j WHERE j.site_id = s.id AND j.deleted_at IS NULL) AS job_count
    FROM fs_sites s
    LEFT JOIN crm_accounts a ON a.id = s.account_id
]]

local function shape_site(s)
    return {
        uuid = s.uuid,
        name = s.name,
        account_uuid = s.account_uuid,
        account_name = s.account_name,
        address_line1 = s.address_line1,
        address_line2 = s.address_line2,
        city = s.city,
        county = s.county,
        postal_code = s.postal_code,
        country = s.country,
        latitude = s.latitude,
        longitude = s.longitude,
        contact_name = s.contact_name,
        contact_phone = s.contact_phone,
        contact_email = s.contact_email,
        access_notes = s.access_notes,
        job_count = tonumber(s.job_count) or 0,
        created_at = s.created_at,
        updated_at = s.updated_at,
    }
end

function ConfigQueries.listSites(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "s.namespace_id = ?", "s.deleted_at IS NULL" }
    local values = { namespace_id }

    if nilify(params.account_uuid) then
        table.insert(where, "a.uuid = ?")
        table.insert(values, tostring(params.account_uuid))
    end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        table.insert(where, "(s.name ILIKE ? OR s.address_line1 ILIKE ? OR s.city ILIKE ? OR s.postal_code ILIKE ?)")
        for _ = 1, 4 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")

    local count = db.query([[
        SELECT COUNT(*) AS total FROM fs_sites s LEFT JOIN crm_accounts a ON a.id = s.account_id
        WHERE ]] .. where_sql, unpack(values))

    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query(SITE_SELECT .. " WHERE " .. where_sql .. " ORDER BY s.name ASC LIMIT ? OFFSET ?",
        unpack(page_values))

    local items = {}
    for _, s in ipairs(rows or {}) do table.insert(items, shape_site(s)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

function ConfigQueries.getSite(namespace_id, uuid)
    local rows = db.query(SITE_SELECT .. " WHERE s.uuid = ? AND s.namespace_id = ? AND s.deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id)
    return rows and rows[1] and shape_site(rows[1]) or nil
end

local SITE_FIELDS = {
    "name", "address_line1", "address_line2", "city", "county", "postal_code", "country",
    "contact_name", "contact_phone", "contact_email", "access_notes",
}

function ConfigQueries.createSite(namespace_id, data)
    if not nilify(data.name) then return nil, "name is required" end

    local fields = {
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        latitude = to_number(data.latitude),
        longitude = to_number(data.longitude),
    }
    for _, f in ipairs(SITE_FIELDS) do fields[f] = nilify(data[f]) end

    if nilify(data.account_uuid) then
        fields.account_id = Common.resolve_id("crm_accounts", namespace_id, data.account_uuid)
        if not fields.account_id then return nil, "Account not found" end
    end

    local site = FsSiteModel:create(fields)
    return ConfigQueries.getSite(namespace_id, site.uuid)
end

function ConfigQueries.updateSite(namespace_id, uuid, data)
    local id = Common.resolve_id("fs_sites", namespace_id, uuid)
    if not id then return nil, "Site not found" end

    local update = {}
    for _, f in ipairs(SITE_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if update.name == db.NULL then return nil, "name cannot be empty" end
    if data.latitude ~= nil then update.latitude = to_number(data.latitude) or db.NULL end
    if data.longitude ~= nil then update.longitude = to_number(data.longitude) or db.NULL end
    if data.account_uuid ~= nil then
        if nilify(data.account_uuid) then
            update.account_id = Common.resolve_id("crm_accounts", namespace_id, data.account_uuid)
            if not update.account_id then return nil, "Account not found" end
        else
            update.account_id = db.NULL
        end
    end
    if next(update) == nil then return nil, "No valid fields to update" end

    FsSiteModel:find(id):update(update)
    return ConfigQueries.getSite(namespace_id, uuid)
end

function ConfigQueries.deleteSite(namespace_id, uuid)
    local id = Common.resolve_id("fs_sites", namespace_id, uuid)
    if not id then return nil, "Site not found" end
    local open = db.query([[
        SELECT COUNT(*) AS n FROM fs_jobs
        WHERE site_id = ? AND deleted_at IS NULL AND status NOT IN ('completed', 'cancelled')
    ]], id)
    if tonumber(open[1].n) > 0 then
        return nil, "Site has open jobs — complete or move them first"
    end
    db.query("UPDATE fs_sites SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", id)
    return true
end

--------------------------------------------------------------------------------
-- Lookups
--------------------------------------------------------------------------------

--- Active namespace members, for engineer / service-manager pickers.
function ConfigQueries.listEngineers(namespace_id, params)
    params = params or {}
    local where = { "nm.namespace_id = ?", "nm.status = 'active'" }
    local values = { namespace_id }
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        table.insert(where, "(u.first_name ILIKE ? OR u.last_name ILIKE ? OR u.email ILIKE ?)")
        for _ = 1, 3 do table.insert(values, term) end
    end
    local rows = db.query([[
        SELECT u.uuid, u.email, ]] .. Common.user_name_sql("u") .. [[ AS name,
            (SELECT COUNT(*) FROM fs_visits v
             WHERE v.namespace_id = nm.namespace_id AND v.engineer_user_uuid = u.uuid
               AND v.deleted_at IS NULL AND v.status IN ('scheduled', 'en_route', 'on_site')) AS open_visits
        FROM namespace_members nm
        JOIN users u ON u.id = nm.user_id
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY name ASC
        LIMIT 200
    ]], unpack(values))
    for _, r in ipairs(rows or {}) do r.open_visits = tonumber(r.open_visits) or 0 end
    return arr(rows or {})
end

--- CRM accounts (uuid + display fields) for the customer picker.
function ConfigQueries.lookupAccounts(namespace_id, search)
    local where = "namespace_id = ? AND deleted_at IS NULL"
    local values = { namespace_id }
    if nilify(search) then
        where = where .. " AND (name ILIKE ? OR email ILIKE ?)"
        local term = "%" .. tostring(search) .. "%"
        table.insert(values, term)
        table.insert(values, term)
    end
    local rows = db.query([[
        SELECT uuid, name, email, phone, address_line1, city, postal_code
        FROM crm_accounts WHERE ]] .. where .. [[ ORDER BY name ASC LIMIT 100
    ]], unpack(values))
    return arr(rows or {})
end

--- CRM contacts, optionally filtered to one account (by uuid).
function ConfigQueries.lookupContacts(namespace_id, account_uuid, search)
    local where = { "c.namespace_id = ?", "c.deleted_at IS NULL" }
    local values = { namespace_id }
    if nilify(account_uuid) then
        table.insert(where, "a.uuid = ?")
        table.insert(values, tostring(account_uuid))
    end
    if nilify(search) then
        local term = "%" .. tostring(search) .. "%"
        table.insert(where, "(c.first_name ILIKE ? OR c.last_name ILIKE ? OR c.email ILIKE ?)")
        for _ = 1, 3 do table.insert(values, term) end
    end
    local rows = db.query([[
        SELECT c.uuid, c.first_name, c.last_name, c.email, c.phone,
            a.uuid AS account_uuid, a.name AS account_name
        FROM crm_contacts c
        LEFT JOIN crm_accounts a ON a.id = c.account_id
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY c.first_name ASC, c.last_name ASC LIMIT 100
    ]], unpack(values))
    return arr(rows or {})
end

return ConfigQueries
