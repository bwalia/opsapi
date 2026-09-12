--[[
    Field Service — job queries
    ===========================

    Jobs, their phases (copied from the job type's templates on creation, then
    editable per job), parts/materials, the activity log, and billing a job
    through the invoicing module.

    Job lifecycle:
        draft -> scheduled -> in_progress -> completed
        (on_hold / cancelled reachable from any open state; completed and
        cancelled can be reopened). Booking a visit moves a draft job to
        scheduled; an engineer checking in (or a phase starting) moves it to
        in_progress. Completing requires every phase completed/skipped and no
        open visits unless forced.
]]

local db = require("lapis.db")
local FsJobModel = require("models.FsJobModel")
local FsJobPhaseModel = require("models.FsJobPhaseModel")
local FsJobItemModel = require("models.FsJobItemModel")
local Common = require("queries.FieldServiceCommon")
local InvoiceGenerator = require("helper.invoice-generator")

local nilify, nullable, to_bool, to_number, arr, round2 =
    Common.nilify, Common.nullable, Common.to_bool, Common.to_number, Common.arr, Common.round2

local JobQueries = {}

JobQueries.STATUSES = { "draft", "scheduled", "in_progress", "on_hold", "completed", "cancelled" }
JobQueries.PRIORITIES = { low = true, normal = true, high = true, urgent = true }

local JOB_TRANSITIONS = {
    draft       = { scheduled = true, in_progress = true, on_hold = true, cancelled = true },
    scheduled   = { draft = true, in_progress = true, on_hold = true, cancelled = true },
    in_progress = { scheduled = true, on_hold = true, completed = true, cancelled = true },
    on_hold     = { scheduled = true, in_progress = true, cancelled = true },
    completed   = { in_progress = true },
    cancelled   = { draft = true },
}

local PHASE_STATUSES = { pending = true, in_progress = true, blocked = true, completed = true, skipped = true }
local ITEM_TYPES = { part = true, material = true, labour = true, expense = true, other = true }
local OPEN_VISIT_STATUSES = "('scheduled', 'en_route', 'on_site')"

--------------------------------------------------------------------------------
-- Row lookups
--------------------------------------------------------------------------------

function JobQueries.findJobRow(namespace_id, uuid)
    if not nilify(uuid) then return nil end
    local rows = db.query([[
        SELECT * FROM fs_jobs WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    return rows and rows[1]
end

function JobQueries.findJobById(id)
    local rows = db.query("SELECT * FROM fs_jobs WHERE id = ? AND deleted_at IS NULL LIMIT 1", id)
    return rows and rows[1]
end

function JobQueries.findPhaseRow(namespace_id, uuid)
    if not nilify(uuid) then return nil end
    local rows = db.query([[
        SELECT * FROM fs_job_phases WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    return rows and rows[1]
end

function JobQueries.findItemRow(namespace_id, uuid)
    if not nilify(uuid) then return nil end
    local rows = db.query([[
        SELECT * FROM fs_job_items WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    return rows and rows[1]
end

-- Changes to phases/visits are blocked once a job is closed.
function JobQueries.assertJobOpen(job)
    if not job then return nil, "Job not found" end
    if job.status == "completed" or job.status == "cancelled" then
        return nil, "Job is " .. job.status .. " — reopen it to make changes"
    end
    return true
end

--------------------------------------------------------------------------------
-- Shaping
--------------------------------------------------------------------------------

local JOB_SELECT = [[
    SELECT j.*,
        jt.uuid AS job_type_uuid, jt.name AS job_type_name, jt.color AS job_type_color,
        jt.default_hourly_rate AS job_type_hourly_rate,
        a.uuid AS account_uuid, a.name AS account_name, a.email AS account_email, a.phone AS account_phone,
        c.uuid AS contact_uuid, c.first_name AS contact_first_name, c.last_name AS contact_last_name,
        c.email AS contact_email, c.phone AS contact_phone,
        s.uuid AS site_uuid, s.name AS site_name, s.address_line1 AS site_address_line1,
        s.address_line2 AS site_address_line2, s.city AS site_city, s.county AS site_county,
        s.postal_code AS site_postal_code, s.country AS site_country, s.access_notes AS site_access_notes,
        s.contact_name AS site_contact_name, s.contact_phone AS site_contact_phone,
        s.latitude AS site_latitude, s.longitude AS site_longitude,
        ]] .. Common.user_name_sql("mu") .. [[ AS service_manager_name,
        i.uuid AS invoice_uuid, i.invoice_number, i.status AS invoice_status, i.total_amount AS invoice_total,
        (SELECT COUNT(*) FROM fs_job_phases p WHERE p.job_id = j.id AND p.deleted_at IS NULL) AS phase_count,
        (SELECT COUNT(*) FROM fs_job_phases p WHERE p.job_id = j.id AND p.deleted_at IS NULL
            AND p.status IN ('completed', 'skipped')) AS phases_done,
        (SELECT p.name FROM fs_job_phases p WHERE p.job_id = j.id AND p.deleted_at IS NULL
            AND p.status NOT IN ('completed', 'skipped') ORDER BY p.sort_order, p.id LIMIT 1) AS current_phase_name,
        (SELECT COUNT(*) FROM fs_visits v WHERE v.job_id = j.id AND v.deleted_at IS NULL) AS visit_count,
        (SELECT MIN(v.scheduled_start) FROM fs_visits v WHERE v.job_id = j.id AND v.deleted_at IS NULL
            AND v.status IN ('scheduled', 'en_route')) AS next_visit_at
    FROM fs_jobs j
    LEFT JOIN fs_job_types jt ON jt.id = j.job_type_id
    LEFT JOIN crm_accounts a ON a.id = j.account_id
    LEFT JOIN crm_contacts c ON c.id = j.contact_id
    LEFT JOIN fs_sites s ON s.id = j.site_id
    LEFT JOIN users mu ON mu.uuid = j.service_manager_uuid
    LEFT JOIN invoices i ON i.id = j.invoice_id
]]

local JOB_HIDDEN = {
    id = true, namespace_id = true, job_type_id = true, account_id = true, contact_id = true,
    site_id = true, invoice_id = true, deleted_at = true,
}

local function shape_job(row)
    local out = {}
    for k, v in pairs(row) do
        if not JOB_HIDDEN[k] then out[k] = v end
    end
    out.phase_count = tonumber(row.phase_count) or 0
    out.phases_done = tonumber(row.phases_done) or 0
    out.visit_count = tonumber(row.visit_count) or 0
    out.metadata = Common.decode(row.metadata, {})
    if next(out.metadata) == nil then out.metadata = nil end
    local contact = ((row.contact_first_name or "") .. " " .. (row.contact_last_name or "")):match("^%s*(.-)%s*$")
    out.contact_name = contact ~= "" and contact or nil
    out.contact_first_name, out.contact_last_name = nil, nil
    return out
end

local PHASE_SELECT = [[
    SELECT p.*, pt.uuid AS template_uuid,
        ]] .. Common.user_name_sql("cu") .. [[ AS completed_by_name,
        (SELECT COUNT(*) FROM fs_visits v WHERE v.phase_id = p.id AND v.deleted_at IS NULL) AS visit_count,
        (SELECT COALESCE(SUM(v.labour_hours), 0) FROM fs_visits v
            WHERE v.phase_id = p.id AND v.deleted_at IS NULL AND v.status = 'completed') AS logged_hours
    FROM fs_job_phases p
    LEFT JOIN fs_phase_templates pt ON pt.id = p.template_id
    LEFT JOIN users cu ON cu.uuid = p.completed_by_uuid
]]

local function shape_phase(p)
    return {
        uuid = p.uuid,
        template_uuid = p.template_uuid,
        name = p.name,
        description = p.description,
        sort_order = p.sort_order,
        status = p.status,
        requires_visit = p.requires_visit,
        requires_signoff = p.requires_signoff,
        estimated_hours = p.estimated_hours,
        checklist = arr(Common.phase_checklist(p.checklist)),
        started_at = p.started_at,
        completed_at = p.completed_at,
        completed_by_uuid = p.completed_by_uuid,
        completed_by_name = p.completed_by_name,
        signed_off_at = p.signed_off_at,
        signoff_name = p.signoff_name,
        notes = p.notes,
        visit_count = tonumber(p.visit_count) or 0,
        logged_hours = tonumber(p.logged_hours) or 0,
    }
end

local function list_phases(job_id)
    local rows = db.query(PHASE_SELECT .. [[
        WHERE p.job_id = ? AND p.deleted_at IS NULL ORDER BY p.sort_order ASC, p.id ASC
    ]], job_id)
    local out = {}
    for _, p in ipairs(rows or {}) do table.insert(out, shape_phase(p)) end
    return arr(out)
end

function JobQueries.getPhase(namespace_id, uuid)
    local rows = db.query(PHASE_SELECT .. " WHERE p.uuid = ? AND p.namespace_id = ? AND p.deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id)
    return rows and rows[1] and shape_phase(rows[1]) or nil
end

-- Shared with FieldServiceVisitQueries.
JobQueries.VISIT_SELECT = [[
    SELECT v.*,
        j.uuid AS job_uuid, j.job_number, j.title AS job_title, j.status AS job_status,
        j.priority AS job_priority, j.hourly_rate AS job_hourly_rate, j.currency AS job_currency,
        jt.default_hourly_rate AS job_type_hourly_rate,
        p.uuid AS phase_uuid, p.name AS phase_name, p.status AS phase_status,
        ]] .. Common.user_name_sql("eu") .. [[ AS engineer_name, eu.email AS engineer_email,
        a.uuid AS account_uuid, a.name AS account_name,
        s.uuid AS site_uuid, s.name AS site_name, s.address_line1 AS site_address_line1,
        s.address_line2 AS site_address_line2, s.city AS site_city, s.postal_code AS site_postal_code,
        s.latitude AS site_latitude, s.longitude AS site_longitude, s.access_notes AS site_access_notes,
        s.contact_name AS site_contact_name, s.contact_phone AS site_contact_phone
    FROM fs_visits v
    JOIN fs_jobs j ON j.id = v.job_id
    LEFT JOIN fs_job_types jt ON jt.id = j.job_type_id
    LEFT JOIN fs_job_phases p ON p.id = v.phase_id AND p.deleted_at IS NULL
    LEFT JOIN users eu ON eu.uuid = v.engineer_user_uuid
    LEFT JOIN crm_accounts a ON a.id = j.account_id
    LEFT JOIN fs_sites s ON s.id = j.site_id
]]

local VISIT_HIDDEN = {
    id = true, namespace_id = true, job_id = true, phase_id = true, deleted_at = true,
    timesheet_entry_id = true, invoice_line_item_id = true,
    job_hourly_rate = true, job_type_hourly_rate = true,
}

--- Effective labour rate for a visit: visit rate -> job rate -> job type default.
function JobQueries.visitRate(v)
    -- Not ipairs: a NULL (nil) visit rate must fall through to the job's.
    for _, key in ipairs({ "hourly_rate", "job_hourly_rate", "job_type_hourly_rate" }) do
        local n = tonumber(v[key])
        if n and n > 0 then return n end
    end
    return nil
end

function JobQueries.shapeVisit(v)
    local out = {}
    for k, val in pairs(v) do
        if not VISIT_HIDDEN[k] then out[k] = val end
    end
    out.invoiced = v.invoice_line_item_id ~= nil
    out.effective_hourly_rate = JobQueries.visitRate(v)
    return out
end

local function list_job_visits(job_id)
    local rows = db.query(JobQueries.VISIT_SELECT .. [[
        WHERE v.job_id = ? AND v.deleted_at IS NULL ORDER BY v.scheduled_start ASC, v.id ASC
    ]], job_id)
    local out = {}
    for _, v in ipairs(rows or {}) do table.insert(out, JobQueries.shapeVisit(v)) end
    return arr(out)
end

local ITEM_SELECT = [[
    SELECT it.*, v.uuid AS visit_uuid, p.uuid AS phase_uuid, p.name AS phase_name,
        ]] .. Common.user_name_sql("cu") .. [[ AS created_by_name
    FROM fs_job_items it
    LEFT JOIN fs_visits v ON v.id = it.visit_id
    LEFT JOIN fs_job_phases p ON p.id = it.phase_id
    LEFT JOIN users cu ON cu.uuid = it.created_by_uuid
]]

local function shape_item(it)
    local qty, price = tonumber(it.quantity) or 0, tonumber(it.unit_price) or 0
    return {
        uuid = it.uuid,
        item_type = it.item_type,
        description = it.description,
        quantity = qty,
        unit_price = price,
        tax_rate = tonumber(it.tax_rate) or 0,
        line_total = round2(qty * price),
        is_billable = it.is_billable,
        invoiced = it.invoice_line_item_id ~= nil,
        visit_uuid = it.visit_uuid,
        phase_uuid = it.phase_uuid,
        phase_name = it.phase_name,
        created_by_uuid = it.created_by_uuid,
        created_by_name = it.created_by_name,
        created_at = it.created_at,
    }
end

function JobQueries.listItems(job_id)
    local rows = db.query(ITEM_SELECT .. [[
        WHERE it.job_id = ? AND it.deleted_at IS NULL ORDER BY it.created_at ASC, it.id ASC
    ]], job_id)
    local out = {}
    for _, it in ipairs(rows or {}) do table.insert(out, shape_item(it)) end
    return arr(out)
end

function JobQueries.getItem(namespace_id, uuid)
    local rows = db.query(ITEM_SELECT .. " WHERE it.uuid = ? AND it.namespace_id = ? AND it.deleted_at IS NULL",
        tostring(uuid), namespace_id)
    return rows and rows[1] and shape_item(rows[1]) or nil
end

function JobQueries.listActivity(job_id, limit)
    local rows = db.query([[
        SELECT ac.uuid, ac.action, ac.message, ac.metadata, ac.actor_uuid, ac.created_at,
            ]] .. Common.user_name_sql("u") .. [[ AS actor_name
        FROM fs_job_activity ac
        LEFT JOIN users u ON u.uuid = ac.actor_uuid
        WHERE ac.job_id = ?
        ORDER BY ac.created_at DESC, ac.id DESC
        LIMIT ?
    ]], job_id, limit or 50)
    return arr(rows or {})
end

--------------------------------------------------------------------------------
-- Jobs: list / get
--------------------------------------------------------------------------------

local SORTABLE = {
    created_at = "j.created_at", updated_at = "j.updated_at", due_date = "j.due_date",
    job_number = "j.id", title = "j.title", priority = "j.priority", status = "j.status",
}

function JobQueries.listJobs(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "j.namespace_id = ?", "j.deleted_at IS NULL" }
    local values = { namespace_id }

    local function add(cond, value)
        table.insert(where, cond)
        if value ~= nil then table.insert(values, value) end
    end

    local status = nilify(params.status)
    if status == "open" then
        add("j.status NOT IN ('completed', 'cancelled')")
    elseif status and status ~= "all" then
        add("j.status = ?", tostring(status))
    end
    if nilify(params.priority) and params.priority ~= "all" then add("j.priority = ?", tostring(params.priority)) end
    if nilify(params.account_uuid) then add("a.uuid = ?", tostring(params.account_uuid)) end
    if nilify(params.site_uuid) then add("s.uuid = ?", tostring(params.site_uuid)) end
    if nilify(params.job_type_uuid) then add("jt.uuid = ?", tostring(params.job_type_uuid)) end
    if nilify(params.manager_uuid) then add("j.service_manager_uuid = ?", tostring(params.manager_uuid)) end
    if nilify(params.engineer_uuid) then
        add([[EXISTS (SELECT 1 FROM fs_visits ev WHERE ev.job_id = j.id AND ev.deleted_at IS NULL
                AND ev.engineer_user_uuid = ?)]], tostring(params.engineer_uuid))
    end
    if to_bool(params.overdue, false) then
        add("j.due_date < CURRENT_DATE AND j.status NOT IN ('completed', 'cancelled')")
    end
    if to_bool(params.uninvoiced, false) then
        add("j.status = 'completed' AND j.invoice_id IS NULL")
    end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        add("(j.job_number ILIKE ? OR j.title ILIKE ? OR a.name ILIKE ? OR s.postal_code ILIKE ?" ..
            " OR j.customer_reference ILIKE ?)")
        for _ = 1, 5 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")

    local order_col = SORTABLE[params.order_by] or "j.created_at"
    local order_dir = tostring(params.order_dir or ""):lower() == "asc" and "ASC" or "DESC"

    local count = db.query([[
        SELECT COUNT(*) AS total FROM fs_jobs j
        LEFT JOIN fs_job_types jt ON jt.id = j.job_type_id
        LEFT JOIN crm_accounts a ON a.id = j.account_id
        LEFT JOIN fs_sites s ON s.id = j.site_id
        WHERE ]] .. where_sql, unpack(values))

    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query(JOB_SELECT .. " WHERE " .. where_sql ..
        " ORDER BY " .. order_col .. " " .. order_dir .. " NULLS LAST, j.id DESC LIMIT ? OFFSET ?",
        unpack(page_values))

    local items = {}
    for _, row in ipairs(rows or {}) do table.insert(items, shape_job(row)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

local function job_totals(visits, items)
    local t = {
        labour_hours = 0, billable_hours = 0, labour_value = 0, items_value = 0,
        uninvoiced_value = 0, open_visits = 0, missing_rate = false,
    }
    for _, v in ipairs(visits) do
        if v.status == "completed" then
            local hours = tonumber(v.labour_hours) or 0
            t.labour_hours = t.labour_hours + hours
            if v.is_billable then
                t.billable_hours = t.billable_hours + hours
                local rate = v.effective_hourly_rate
                if not rate and hours > 0 then t.missing_rate = true end
                local value = hours * (rate or 0)
                t.labour_value = t.labour_value + value
                if not v.invoiced then t.uninvoiced_value = t.uninvoiced_value + value end
            end
        elseif v.status == "scheduled" or v.status == "en_route" or v.status == "on_site" then
            t.open_visits = t.open_visits + 1
        end
    end
    for _, it in ipairs(items) do
        if it.is_billable then
            t.items_value = t.items_value + it.line_total
            if not it.invoiced then t.uninvoiced_value = t.uninvoiced_value + it.line_total end
        end
    end
    for _, k in ipairs({ "labour_hours", "billable_hours", "labour_value", "items_value", "uninvoiced_value" }) do
        t[k] = round2(t[k])
    end
    return t
end

--- Full job: job fields + phases + visits + items + activity + totals.
function JobQueries.getJob(namespace_id, uuid)
    local rows = db.query(JOB_SELECT .. " WHERE j.uuid = ? AND j.namespace_id = ? AND j.deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id)
    local row = rows and rows[1]
    if not row then return nil end

    local job = shape_job(row)
    job.phases = list_phases(row.id)
    job.visits = list_job_visits(row.id)
    job.items = JobQueries.listItems(row.id)
    job.activity = JobQueries.listActivity(row.id, 50)
    job.totals = job_totals(job.visits, job.items)
    job.allowed_transitions = arr({})
    for status in pairs(JOB_TRANSITIONS[row.status] or {}) do table.insert(job.allowed_transitions, status) end
    table.sort(job.allowed_transitions)
    return job
end

--------------------------------------------------------------------------------
-- Jobs: create / update / status / delete
--------------------------------------------------------------------------------

local function next_job_number(namespace_id)
    local rows = db.query([[
        INSERT INTO fs_job_sequences (namespace_id, prefix, current_number, updated_at)
        VALUES (?, 'JOB', 1, NOW())
        ON CONFLICT (namespace_id) DO UPDATE
            SET current_number = fs_job_sequences.current_number + 1, updated_at = NOW()
        RETURNING prefix, current_number
    ]], namespace_id)
    return string.format("%s-%04d", rows[1].prefix or "JOB", tonumber(rows[1].current_number))
end

--- Resolve the uuid references a job payload may carry. Only keys present in
-- `data` are returned; an explicit empty value resolves to db.NULL (clear).
local function resolve_job_refs(namespace_id, data)
    local refs = {}
    local specs = {
        { key = "account_uuid", tbl = "crm_accounts", col = "account_id", label = "Account" },
        { key = "contact_uuid", tbl = "crm_contacts", col = "contact_id", label = "Contact" },
        { key = "site_uuid", tbl = "fs_sites", col = "site_id", label = "Site" },
        { key = "job_type_uuid", tbl = "fs_job_types", col = "job_type_id", label = "Job type" },
    }
    for _, spec in ipairs(specs) do
        if data[spec.key] ~= nil then
            if nilify(data[spec.key]) then
                local id = Common.resolve_id(spec.tbl, namespace_id, data[spec.key])
                if not id then return nil, spec.label .. " not found" end
                refs[spec.col] = id
            else
                refs[spec.col] = db.NULL
            end
        end
    end
    return refs
end

local function copy_template_phases(namespace_id, job_id, job_type_id)
    local templates = db.query([[
        SELECT * FROM fs_phase_templates
        WHERE job_type_id = ? AND deleted_at IS NULL ORDER BY sort_order ASC, id ASC
    ]], job_type_id)
    for i, t in ipairs(templates or {}) do
        local checklist = {}
        for _, label in ipairs(Common.template_checklist(t.checklist)) do
            table.insert(checklist, { label = label, done = false })
        end
        FsJobPhaseModel:create({
            uuid = Common.uuid(),
            namespace_id = namespace_id,
            job_id = job_id,
            template_id = t.id,
            name = t.name,
            description = t.description,
            sort_order = i,
            status = "pending",
            requires_visit = t.requires_visit,
            requires_signoff = t.requires_signoff,
            estimated_hours = t.estimated_hours,
            checklist = Common.encode_array(checklist),
        })
    end
    return #(templates or {})
end

local function create_phase_row(namespace_id, job_id, data, sort_order)
    return FsJobPhaseModel:create({
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        job_id = job_id,
        name = tostring(data.name),
        description = nilify(data.description),
        sort_order = sort_order,
        status = "pending",
        requires_visit = to_bool(data.requires_visit, true),
        requires_signoff = to_bool(data.requires_signoff, false),
        estimated_hours = to_number(data.estimated_hours),
        checklist = Common.encode_array(Common.phase_checklist(data.checklist)),
    })
end

--- Create a job. Phases come from `data.phases` when given, otherwise they
-- are copied from the job type's templates.
function JobQueries.createJob(namespace_id, actor_uuid, data)
    if not nilify(data.title) then return nil, "title is required" end
    local priority = nilify(data.priority) or "normal"
    if not JobQueries.PRIORITIES[priority] then return nil, "Invalid priority" end
    if nilify(data.service_manager_uuid) and not Common.is_member(namespace_id, data.service_manager_uuid) then
        return nil, "Service manager is not a member of this workspace"
    end

    local refs, ref_err = resolve_job_refs(namespace_id, data)
    if not refs then return nil, ref_err end
    for k, v in pairs(refs) do if v == db.NULL then refs[k] = nil end end

    -- A site belongs to a customer: inherit the account when none was given.
    if refs.site_id and not refs.account_id then
        local s = db.query("SELECT account_id FROM fs_sites WHERE id = ?", refs.site_id)
        refs.account_id = s[1] and s[1].account_id or nil
    end

    local hourly_rate = to_number(data.hourly_rate)
    if not hourly_rate and refs.job_type_id then
        local jt = db.query("SELECT default_hourly_rate FROM fs_job_types WHERE id = ?", refs.job_type_id)
        hourly_rate = jt[1] and tonumber(jt[1].default_hourly_rate) or nil
    end

    local metadata = data.metadata
    if type(metadata) == "table" then metadata = require("cjson").encode(metadata) end

    return Common.transaction(function()
        local job = FsJobModel:create({
            uuid = Common.uuid(),
            namespace_id = namespace_id,
            job_number = next_job_number(namespace_id),
            title = tostring(data.title),
            description = nilify(data.description),
            job_type_id = refs.job_type_id,
            account_id = refs.account_id,
            contact_id = refs.contact_id,
            site_id = refs.site_id,
            status = "draft",
            priority = priority,
            service_manager_uuid = nilify(data.service_manager_uuid) or actor_uuid,
            customer_reference = nilify(data.customer_reference),
            due_date = nilify(data.due_date),
            estimated_hours = to_number(data.estimated_hours),
            hourly_rate = hourly_rate,
            currency = nilify(data.currency) or "GBP",
            notes = nilify(data.notes),
            metadata = nilify(metadata) or "{}",
            created_by_uuid = actor_uuid,
        })

        local phase_count = 0
        if type(data.phases) == "table" and #data.phases > 0 then
            for i, phase in ipairs(data.phases) do
                if type(phase) == "string" then phase = { name = phase } end
                if nilify(phase.name) then
                    create_phase_row(namespace_id, job.id, phase, i)
                    phase_count = phase_count + 1
                end
            end
        elseif refs.job_type_id then
            phase_count = copy_template_phases(namespace_id, job.id, refs.job_type_id)
        end

        Common.log_activity(namespace_id, job.id, actor_uuid, "created",
            "Job " .. job.job_number .. " created with " .. phase_count .. " phase(s)")
        return JobQueries.getJob(namespace_id, job.uuid)
    end)
end

local JOB_TEXT_FIELDS = { "title", "description", "customer_reference", "notes", "currency" }

function JobQueries.updateJob(namespace_id, uuid, data, actor_uuid)
    local job = JobQueries.findJobRow(namespace_id, uuid)
    if not job then return nil, "Job not found" end

    local update = {}
    for _, f in ipairs(JOB_TEXT_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if update.title == db.NULL then return nil, "title cannot be empty" end
    if update.currency == db.NULL then update.currency = "GBP" end
    if data.priority ~= nil then
        if not JobQueries.PRIORITIES[data.priority] then return nil, "Invalid priority" end
        update.priority = data.priority
    end
    if data.due_date ~= nil then update.due_date = nullable(data.due_date) end
    if data.estimated_hours ~= nil then update.estimated_hours = to_number(data.estimated_hours) or db.NULL end
    if data.hourly_rate ~= nil then update.hourly_rate = to_number(data.hourly_rate) or db.NULL end
    if data.service_manager_uuid ~= nil then
        if nilify(data.service_manager_uuid) and not Common.is_member(namespace_id, data.service_manager_uuid) then
            return nil, "Service manager is not a member of this workspace"
        end
        update.service_manager_uuid = nullable(data.service_manager_uuid)
    end
    if data.metadata ~= nil then
        update.metadata = type(data.metadata) == "table" and require("cjson").encode(data.metadata) or data.metadata
    end

    local refs, ref_err = resolve_job_refs(namespace_id, data)
    if not refs then return nil, ref_err end
    for k, v in pairs(refs) do update[k] = v end

    if next(update) == nil then return nil, "No valid fields to update" end

    FsJobModel:find(job.id):update(update)
    Common.log_activity(namespace_id, job.id, actor_uuid, "updated", "Job details updated")
    return JobQueries.getJob(namespace_id, uuid)
end

--- Move a job to `status`, enforcing JOB_TRANSITIONS.
-- @param opts table { reason?, force? }
function JobQueries.setJobStatus(namespace_id, uuid, status, opts, actor_uuid)
    opts = opts or {}
    local job = JobQueries.findJobRow(namespace_id, uuid)
    if not job then return nil, "Job not found" end
    if job.status == status then return JobQueries.getJob(namespace_id, uuid) end
    if not (JOB_TRANSITIONS[job.status] or {})[status] then
        return nil, "Cannot move a " .. job.status .. " job to " .. tostring(status)
    end

    local force = to_bool(opts.force, false)
    if status == "completed" and not force then
        local open = db.query([[
            SELECT
                (SELECT COUNT(*) FROM fs_job_phases WHERE job_id = ? AND deleted_at IS NULL
                    AND status NOT IN ('completed', 'skipped')) AS open_phases,
                (SELECT COUNT(*) FROM fs_visits WHERE job_id = ? AND deleted_at IS NULL
                    AND status IN ]] .. OPEN_VISIT_STATUSES .. [[) AS open_visits
        ]], job.id, job.id)[1]
        local open_phases, open_visits = tonumber(open.open_phases), tonumber(open.open_visits)
        if open_phases > 0 or open_visits > 0 then
            return nil, string.format(
                "Job has %d unfinished phase(s) and %d open visit(s) — finish them or pass force=true",
                open_phases, open_visits)
        end
    end

    return Common.transaction(function()
        local update = { status = status }
        if status == "in_progress" and not job.started_at then update.started_at = db.raw("NOW()") end
        if status == "completed" then update.completed_at = db.raw("NOW()") end
        if job.status == "completed" then update.completed_at = db.NULL end
        if status == "cancelled" then
            update.cancelled_reason = nilify(opts.reason) or db.NULL
            -- Nothing is going to happen on site any more: stand down booked visits.
            db.query([[
                UPDATE fs_visits SET status = 'cancelled', cancelled_reason = 'Job cancelled', updated_at = NOW()
                WHERE job_id = ? AND deleted_at IS NULL AND status IN ('scheduled', 'en_route')
            ]], job.id)
        end
        if job.status == "cancelled" then update.cancelled_reason = db.NULL end

        FsJobModel:find(job.id):update(update)
        local message = "Status " .. job.status .. " → " .. status
        if nilify(opts.reason) then message = message .. ": " .. tostring(opts.reason) end
        Common.log_activity(namespace_id, job.id, actor_uuid, "status_changed", message,
            { from = job.status, to = status, forced = force or nil })
        return JobQueries.getJob(namespace_id, uuid)
    end)
end

--- Automatic transitions driven by visits / phases (no-op when not applicable).
function JobQueries.markJobScheduled(job, actor_uuid)
    if job and job.status == "draft" then
        db.query("UPDATE fs_jobs SET status = 'scheduled', updated_at = NOW() WHERE id = ?", job.id)
        Common.log_activity(job.namespace_id, job.id, actor_uuid, "status_changed",
            "Status draft → scheduled (visit booked)", { from = "draft", to = "scheduled", auto = true })
    end
end

function JobQueries.markJobStarted(job, actor_uuid)
    if job and (job.status == "draft" or job.status == "scheduled" or job.status == "on_hold") then
        db.query([[
            UPDATE fs_jobs SET status = 'in_progress', started_at = COALESCE(started_at, NOW()), updated_at = NOW()
            WHERE id = ?
        ]], job.id)
        Common.log_activity(job.namespace_id, job.id, actor_uuid, "status_changed",
            "Status " .. job.status .. " → in_progress (work started)",
            { from = job.status, to = "in_progress", auto = true })
    end
end

function JobQueries.deleteJob(namespace_id, uuid, actor_uuid)
    local job = JobQueries.findJobRow(namespace_id, uuid)
    if not job then return nil, "Job not found" end
    if job.invoice_id then return nil, "Job has been invoiced and cannot be deleted — cancel it instead" end
    db.query("UPDATE fs_jobs SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", job.id)
    db.query("UPDATE fs_visits SET deleted_at = NOW(), updated_at = NOW() WHERE job_id = ? AND deleted_at IS NULL",
        job.id)
    Common.log_activity(namespace_id, job.id, actor_uuid, "deleted", "Job deleted")
    return true
end

--------------------------------------------------------------------------------
-- Phases
--------------------------------------------------------------------------------

function JobQueries.addPhase(namespace_id, job_uuid, data, actor_uuid)
    local job = JobQueries.findJobRow(namespace_id, job_uuid)
    local ok, err = JobQueries.assertJobOpen(job)
    if not ok then return nil, err end
    if not nilify(data.name) then return nil, "name is required" end

    local order = to_number(data.sort_order)
    if not order then
        local r = db.query([[
            SELECT COALESCE(MAX(sort_order), 0) + 1 AS n FROM fs_job_phases WHERE job_id = ? AND deleted_at IS NULL
        ]], job.id)
        order = tonumber(r[1].n)
    end
    local phase = create_phase_row(namespace_id, job.id, data, order)
    Common.log_activity(namespace_id, job.id, actor_uuid, "phase_added", "Phase '" .. phase.name .. "' added")
    return JobQueries.getPhase(namespace_id, phase.uuid)
end

function JobQueries.updatePhase(namespace_id, uuid, data, actor_uuid)
    local phase = JobQueries.findPhaseRow(namespace_id, uuid)
    if not phase then return nil, "Phase not found" end
    local ok, err = JobQueries.assertJobOpen(JobQueries.findJobById(phase.job_id))
    if not ok then return nil, err end

    local update = {}
    if data.name ~= nil then
        if not nilify(data.name) then return nil, "name cannot be empty" end
        update.name = tostring(data.name)
    end
    if data.description ~= nil then update.description = nullable(data.description) end
    if data.notes ~= nil then update.notes = nullable(data.notes) end
    if data.requires_visit ~= nil then update.requires_visit = to_bool(data.requires_visit, true) end
    if data.requires_signoff ~= nil then update.requires_signoff = to_bool(data.requires_signoff, false) end
    if data.estimated_hours ~= nil then update.estimated_hours = to_number(data.estimated_hours) or db.NULL end
    if data.checklist ~= nil then
        update.checklist = Common.encode_array(Common.phase_checklist(data.checklist))
    end
    if next(update) == nil then return nil, "No valid fields to update" end

    FsJobPhaseModel:find(phase.id):update(update)
    return JobQueries.getPhase(namespace_id, uuid)
end

--- Change a phase's status.
-- completed: every checklist item must be ticked (unless opts.force) and, when
-- the phase requires sign-off, opts.signoff_name must name the signatory.
-- Moving a finished phase back to pending/in_progress/blocked clears the
-- completion and sign-off stamps.
function JobQueries.setPhaseStatus(namespace_id, uuid, status, opts, actor_uuid)
    opts = opts or {}
    if not PHASE_STATUSES[status] then return nil, "Invalid phase status" end
    local phase = JobQueries.findPhaseRow(namespace_id, uuid)
    if not phase then return nil, "Phase not found" end
    local job = JobQueries.findJobById(phase.job_id)
    local ok, err = JobQueries.assertJobOpen(job)
    if not ok then return nil, err end
    if phase.status == status then return JobQueries.getPhase(namespace_id, uuid) end

    local now = db.raw("NOW()")
    local update = { status = status }

    if status == "completed" then
        if not to_bool(opts.force, false) then
            local open_items = 0
            for _, item in ipairs(Common.phase_checklist(phase.checklist)) do
                if not item.done then open_items = open_items + 1 end
            end
            if open_items > 0 then
                return nil, open_items .. " checklist item(s) not ticked — tick them or pass force=true"
            end
        end
        if phase.requires_signoff and not phase.signed_off_at then
            local name = nilify(opts.signoff_name)
            if not name then return nil, "This phase requires customer sign-off — provide signoff_name" end
            update.signed_off_at = now
            update.signed_off_by_uuid = actor_uuid
            update.signoff_name = tostring(name)
        end
        update.completed_at = now
        update.completed_by_uuid = actor_uuid
        if not phase.started_at then update.started_at = now end
    elseif status == "skipped" then
        update.completed_at = now
        update.completed_by_uuid = actor_uuid
    else
        update.completed_at = db.NULL
        update.completed_by_uuid = db.NULL
        update.signed_off_at = db.NULL
        update.signed_off_by_uuid = db.NULL
        update.signoff_name = db.NULL
        if status == "in_progress" and not phase.started_at then update.started_at = now end
    end
    if nilify(opts.notes) then update.notes = tostring(opts.notes) end

    FsJobPhaseModel:find(phase.id):update(update)
    Common.log_activity(namespace_id, job.id, actor_uuid, "phase_status",
        "Phase '" .. phase.name .. "': " .. phase.status .. " → " .. status,
        { phase_uuid = phase.uuid, from = phase.status, to = status })

    if status == "in_progress" or status == "completed" then
        JobQueries.markJobStarted(job, actor_uuid)
    end
    return JobQueries.getPhase(namespace_id, uuid)
end

--- Tick / untick one checklist item (0-based index, as rendered).
function JobQueries.setChecklistItem(namespace_id, uuid, index, done, actor_uuid)
    local phase = JobQueries.findPhaseRow(namespace_id, uuid)
    if not phase then return nil, "Phase not found" end
    local ok, err = JobQueries.assertJobOpen(JobQueries.findJobById(phase.job_id))
    if not ok then return nil, err end

    local checklist = Common.phase_checklist(phase.checklist)
    local i = tonumber(index)
    if not i or i < 0 or i >= #checklist or i % 1 ~= 0 then return nil, "Checklist item not found" end
    local item = checklist[i + 1]
    item.done = to_bool(done, true)
    item.done_at = item.done and ngx.utctime() or nil
    item.done_by = item.done and actor_uuid or nil

    FsJobPhaseModel:find(phase.id):update({ checklist = Common.encode_array(checklist) })
    return JobQueries.getPhase(namespace_id, uuid)
end

function JobQueries.deletePhase(namespace_id, uuid, actor_uuid)
    local phase = JobQueries.findPhaseRow(namespace_id, uuid)
    if not phase then return nil, "Phase not found" end
    local ok, err = JobQueries.assertJobOpen(JobQueries.findJobById(phase.job_id))
    if not ok then return nil, err end
    if phase.status == "completed" then return nil, "Completed phases cannot be removed — reopen it first" end

    -- Phases are job-local: hard delete so visits/items fall back to "no phase".
    db.query("DELETE FROM fs_job_phases WHERE id = ?", phase.id)
    Common.log_activity(namespace_id, phase.job_id, actor_uuid, "phase_removed", "Phase '" .. phase.name .. "' removed")
    return true
end

function JobQueries.reorderPhases(namespace_id, job_uuid, uuids, actor_uuid)
    local job = JobQueries.findJobRow(namespace_id, job_uuid)
    local ok, err = JobQueries.assertJobOpen(job)
    if not ok then return nil, err end
    if type(uuids) ~= "table" or #uuids == 0 then return nil, "order must be a non-empty array of phase uuids" end

    return Common.transaction(function()
        local position, seen = 0, {}
        for _, u in ipairs(uuids) do
            position = position + 1
            seen[tostring(u)] = true
            db.query([[
                UPDATE fs_job_phases SET sort_order = ?, updated_at = NOW()
                WHERE uuid = ? AND job_id = ? AND deleted_at IS NULL
            ]], position, tostring(u), job.id)
        end
        local rest = db.query([[
            SELECT id, uuid FROM fs_job_phases WHERE job_id = ? AND deleted_at IS NULL ORDER BY sort_order, id
        ]], job.id)
        for _, r in ipairs(rest or {}) do
            if not seen[r.uuid] then
                position = position + 1
                db.query("UPDATE fs_job_phases SET sort_order = ? WHERE id = ?", position, r.id)
            end
        end
        Common.log_activity(namespace_id, job.id, actor_uuid, "phases_reordered", "Phases reordered")
        return list_phases(job.id)
    end)
end

--------------------------------------------------------------------------------
-- Items (parts / materials / expenses)
--------------------------------------------------------------------------------

local function validate_item(data, partial)
    local out = {}
    if data.item_type ~= nil or not partial then
        local t = nilify(data.item_type) or "part"
        if not ITEM_TYPES[t] then return nil, "Invalid item_type" end
        out.item_type = t
    end
    if data.description ~= nil or not partial then
        if not nilify(data.description) then return nil, "description is required" end
        out.description = tostring(data.description)
    end
    if data.quantity ~= nil or not partial then
        local q = to_number(data.quantity) or 1
        if q <= 0 then return nil, "quantity must be greater than 0" end
        out.quantity = q
    end
    if data.unit_price ~= nil or not partial then
        local p = to_number(data.unit_price) or 0
        if p < 0 then return nil, "unit_price cannot be negative" end
        out.unit_price = p
    end
    if data.tax_rate ~= nil or not partial then
        local r = to_number(data.tax_rate) or 0
        if r < 0 or r > 100 then return nil, "tax_rate must be between 0 and 100" end
        out.tax_rate = r
    end
    if data.is_billable ~= nil or not partial then out.is_billable = to_bool(data.is_billable, true) end
    return out
end

-- Resolve an optional visit/phase uuid that must belong to `job_id`.
local function resolve_child(tbl, namespace_id, uuid, job_id, label)
    local id = Common.resolve_id(tbl, namespace_id, uuid)
    if not id then return nil, label .. " not found" end
    local r = db.query("SELECT job_id FROM " .. tbl .. " WHERE id = ?", id)
    if not r[1] or r[1].job_id ~= job_id then return nil, label .. " does not belong to this job" end
    return id
end

function JobQueries.addItem(namespace_id, job_uuid, data, actor_uuid)
    local job = JobQueries.findJobRow(namespace_id, job_uuid)
    if not job then return nil, "Job not found" end
    if job.status == "cancelled" then return nil, "Job is cancelled — reopen it to make changes" end

    local fields, err = validate_item(data, false)
    if not fields then return nil, err end
    if nilify(data.visit_uuid) then
        fields.visit_id, err = resolve_child("fs_visits", namespace_id, data.visit_uuid, job.id, "Visit")
        if not fields.visit_id then return nil, err end
    end
    if nilify(data.phase_uuid) then
        fields.phase_id, err = resolve_child("fs_job_phases", namespace_id, data.phase_uuid, job.id, "Phase")
        if not fields.phase_id then return nil, err end
    end
    fields.uuid = Common.uuid()
    fields.namespace_id = namespace_id
    fields.job_id = job.id
    fields.created_by_uuid = actor_uuid

    local item = FsJobItemModel:create(fields)
    Common.log_activity(namespace_id, job.id, actor_uuid, "item_added",
        string.format("%s added: %s × %s", item.item_type, tostring(item.quantity), item.description))
    return JobQueries.getItem(namespace_id, item.uuid)
end

function JobQueries.updateItem(namespace_id, uuid, data, actor_uuid)
    local item = JobQueries.findItemRow(namespace_id, uuid)
    if not item then return nil, "Item not found" end
    if item.invoice_line_item_id then return nil, "Item has been invoiced and cannot be changed" end

    local fields, err = validate_item(data, true)
    if not fields then return nil, err end
    if data.visit_uuid ~= nil then
        if nilify(data.visit_uuid) then
            fields.visit_id, err = resolve_child("fs_visits", namespace_id, data.visit_uuid, item.job_id, "Visit")
            if not fields.visit_id then return nil, err end
        else
            fields.visit_id = db.NULL
        end
    end
    if data.phase_uuid ~= nil then
        if nilify(data.phase_uuid) then
            fields.phase_id, err = resolve_child("fs_job_phases", namespace_id, data.phase_uuid, item.job_id, "Phase")
            if not fields.phase_id then return nil, err end
        else
            fields.phase_id = db.NULL
        end
    end
    if next(fields) == nil then return nil, "No valid fields to update" end

    FsJobItemModel:find(item.id):update(fields)
    Common.log_activity(namespace_id, item.job_id, actor_uuid, "item_updated", "Item updated: " .. item.description)
    return JobQueries.getItem(namespace_id, uuid)
end

function JobQueries.deleteItem(namespace_id, uuid, actor_uuid)
    local item = JobQueries.findItemRow(namespace_id, uuid)
    if not item then return nil, "Item not found" end
    if item.invoice_line_item_id then return nil, "Item has been invoiced and cannot be removed" end
    db.query("UPDATE fs_job_items SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", item.id)
    Common.log_activity(namespace_id, item.job_id, actor_uuid, "item_removed", "Item removed: " .. item.description)
    return true
end

--------------------------------------------------------------------------------
-- Invoicing
--------------------------------------------------------------------------------

--- Everything on the job that is billable and not yet invoiced.
-- Labour: completed, billable visits with hours. A visit whose timesheet entry
-- was already billed through Timesheets -> Invoice is skipped (and vice versa:
-- the line we create carries timesheet_entry_id, so the timesheet route skips
-- it) — the same hours are never invoiced twice.
local function collect_billable(job, opts)
    local fallback_rate = to_number(opts.hourly_rate)
    local labour_tax = to_number(opts.labour_tax_rate) or 0
    local lines, missing_rate = {}, false

    local visits = db.query([[
        SELECT v.id, v.uuid, v.labour_hours, v.hourly_rate, v.timesheet_entry_id,
            COALESCE(v.checked_in_at, v.scheduled_start) AS work_at,
            ]] .. Common.user_name_sql("eu") .. [[ AS engineer_name, p.name AS phase_name,
            j.hourly_rate AS job_hourly_rate, jt.default_hourly_rate AS job_type_hourly_rate
        FROM fs_visits v
        JOIN fs_jobs j ON j.id = v.job_id
        LEFT JOIN fs_job_types jt ON jt.id = j.job_type_id
        LEFT JOIN users eu ON eu.uuid = v.engineer_user_uuid
        LEFT JOIN fs_job_phases p ON p.id = v.phase_id AND p.deleted_at IS NULL
        WHERE v.job_id = ? AND v.deleted_at IS NULL AND v.status = 'completed'
          AND v.is_billable = true AND COALESCE(v.labour_hours, 0) > 0
          AND v.invoice_line_item_id IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM invoice_line_items li
              WHERE v.timesheet_entry_id IS NOT NULL AND li.timesheet_entry_id = v.timesheet_entry_id
          )
        ORDER BY work_at ASC, v.id ASC
    ]], job.id)

    for _, v in ipairs(visits or {}) do
        local rate = JobQueries.visitRate(v) or (fallback_rate and fallback_rate > 0 and fallback_rate) or nil
        if not rate then missing_rate = true end
        local hours = tonumber(v.labour_hours)
        local desc = "Labour"
        if v.phase_name then desc = desc .. " — " .. v.phase_name end
        local detail = {}
        if v.engineer_name then table.insert(detail, v.engineer_name) end
        if v.work_at then table.insert(detail, tostring(v.work_at):sub(1, 10)) end
        if #detail > 0 then desc = desc .. " (" .. table.concat(detail, ", ") .. ")" end
        local calc = InvoiceGenerator.calculateLineTotal(hours, rate or 0, labour_tax, 0)
        table.insert(lines, {
            source = "visit", source_id = v.id, source_uuid = v.uuid,
            timesheet_entry_id = v.timesheet_entry_id,
            description = desc, quantity = hours, unit_price = rate or 0, tax_rate = labour_tax,
            net = round2(calc.subtotal), tax = round2(calc.tax), total = round2(calc.total),
            missing_rate = rate == nil or nil,
        })
    end

    local items = db.query([[
        SELECT id, uuid, item_type, description, quantity, unit_price, tax_rate FROM fs_job_items
        WHERE job_id = ? AND deleted_at IS NULL AND is_billable = true AND invoice_line_item_id IS NULL
        ORDER BY created_at ASC, id ASC
    ]], job.id)
    for _, it in ipairs(items or {}) do
        local calc = InvoiceGenerator.calculateLineTotal(it.quantity, it.unit_price, it.tax_rate, 0)
        table.insert(lines, {
            source = "item", source_id = it.id, source_uuid = it.uuid,
            description = it.description, quantity = tonumber(it.quantity), unit_price = tonumber(it.unit_price),
            tax_rate = tonumber(it.tax_rate) or 0,
            net = round2(calc.subtotal), tax = round2(calc.tax), total = round2(calc.total),
        })
    end

    local totals = { subtotal = 0, tax_amount = 0, total = 0 }
    for _, l in ipairs(lines) do
        totals.subtotal = totals.subtotal + l.net
        totals.tax_amount = totals.tax_amount + l.tax
        totals.total = totals.total + l.total
    end
    for k, v in pairs(totals) do totals[k] = round2(v) end
    return lines, totals, missing_rate
end

local function public_lines(lines)
    local out = {}
    for _, l in ipairs(lines) do
        table.insert(out, {
            source = l.source, source_uuid = l.source_uuid, description = l.description,
            quantity = l.quantity, unit_price = l.unit_price, tax_rate = l.tax_rate,
            net = l.net, tax = l.tax, total = l.total, missing_rate = l.missing_rate,
        })
    end
    return arr(out)
end

function JobQueries.invoicePreview(namespace_id, job_uuid, opts)
    local job = JobQueries.findJobRow(namespace_id, job_uuid)
    if not job then return nil, "Job not found" end
    local lines, totals, missing_rate = collect_billable(job, opts or {})
    return {
        currency = job.currency,
        lines = public_lines(lines),
        subtotal = totals.subtotal,
        tax_amount = totals.tax_amount,
        total = totals.total,
        missing_rate = missing_rate,
        can_invoice = #lines > 0 and not missing_rate and job.status ~= "cancelled" and job.status ~= "draft",
    }
end

local function customer_details(job)
    local rows = db.query([[
        SELECT a.name, a.email, a.address_line1, a.address_line2, a.city, a.state, a.postal_code, a.country,
            s.name AS site_name, s.address_line1 AS s_line1, s.address_line2 AS s_line2, s.city AS s_city,
            s.county AS s_county, s.postal_code AS s_postal_code, s.country AS s_country, s.contact_email
        FROM fs_jobs j
        LEFT JOIN crm_accounts a ON a.id = j.account_id
        LEFT JOIN fs_sites s ON s.id = j.site_id
        WHERE j.id = ?
    ]], job.id)
    local r = rows[1] or {}
    local address
    if r.address_line1 then
        address = { line1 = r.address_line1, line2 = r.address_line2, city = r.city, state = r.state,
            postal_code = r.postal_code, country = r.country }
    elseif r.s_line1 then
        address = { line1 = r.s_line1, line2 = r.s_line2, city = r.s_city, state = r.s_county,
            postal_code = r.s_postal_code, country = r.s_country }
    end
    return {
        name = r.name or r.site_name or "Customer",
        email = r.email or r.contact_email,
        address = address and require("cjson").encode(address) or "{}",
    }
end

--- Bill everything uninvoiced on the job as ONE new draft invoice. Each visit
-- and item is stamped with its invoice line, so re-running only bills new
-- work. The job remembers the latest invoice.
-- @param opts table { hourly_rate?, labour_tax_rate?, due_date?, notes? }
function JobQueries.createInvoice(namespace_id, job_uuid, actor_uuid, opts)
    opts = opts or {}
    local job = JobQueries.findJobRow(namespace_id, job_uuid)
    if not job then return nil, "Job not found" end
    if job.status == "cancelled" or job.status == "draft" then
        return nil, "Only scheduled, in-progress, on-hold or completed jobs can be invoiced"
    end

    local lines, _, missing_rate = collect_billable(job, opts)
    if #lines == 0 then return nil, "Nothing to invoice — no uninvoiced billable labour or items on this job" end
    if missing_rate then
        return nil, "Some labour has no hourly rate — set a rate on the visit, job or job type, or pass hourly_rate"
    end

    local InvoiceQueries = require("queries.InvoiceQueries")
    local customer = customer_details(job)

    return Common.transaction(function()
        local created = InvoiceQueries.create({
            namespace_id = namespace_id,
            customer_name = customer.name,
            customer_email = customer.email,
            customer_address = customer.address,
            account_id = job.account_id,
            owner_user_uuid = actor_uuid,
            due_date = nilify(opts.due_date),
            currency = job.currency,
            notes = nilify(opts.notes) or ("Job " .. job.job_number .. " — " .. job.title ..
                (job.customer_reference and (" (ref " .. job.customer_reference .. ")") or "")),
        })
        local invoice = created and created.data
        if not invoice then return nil, "Failed to create invoice" end

        for i, l in ipairs(lines) do
            local li = InvoiceQueries.addLineItem(invoice.internal_id, {
                description = l.description,
                quantity = l.quantity,
                unit_price = l.unit_price,
                tax_rate = l.tax_rate,
                sort_order = i,
                timesheet_entry_id = l.timesheet_entry_id,
            })
            local tbl = l.source == "visit" and "fs_visits" or "fs_job_items"
            db.query("UPDATE " .. tbl .. " SET invoice_line_item_id = ?, updated_at = NOW() WHERE id = ?",
                li.internal_id, l.source_id)
        end

        db.query("UPDATE fs_jobs SET invoice_id = ?, invoiced_at = NOW(), updated_at = NOW() WHERE id = ?",
            invoice.internal_id, job.id)

        local inv = db.query([[
            SELECT uuid, invoice_number, status, total_amount, currency FROM invoices WHERE id = ?
        ]], invoice.internal_id)[1]
        Common.log_activity(namespace_id, job.id, actor_uuid, "invoiced",
            string.format("Invoice %s created (%d line(s), total %s %.2f)", inv.invoice_number, #lines,
                inv.currency or job.currency, tonumber(inv.total_amount) or 0),
            { invoice_uuid = inv.uuid })
        return {
            invoice_uuid = inv.uuid,
            invoice_number = inv.invoice_number,
            status = inv.status,
            total_amount = tonumber(inv.total_amount) or 0,
            currency = inv.currency,
            line_count = #lines,
        }
    end)
end

--------------------------------------------------------------------------------
-- Dashboard stats
--------------------------------------------------------------------------------

function JobQueries.getStats(namespace_id)
    local r = db.query([[
        SELECT
            COUNT(*) FILTER (WHERE status NOT IN ('completed', 'cancelled')) AS open_jobs,
            COUNT(*) FILTER (WHERE status = 'draft') AS draft_jobs,
            COUNT(*) FILTER (WHERE status = 'scheduled') AS scheduled_jobs,
            COUNT(*) FILTER (WHERE status = 'in_progress') AS in_progress_jobs,
            COUNT(*) FILTER (WHERE status = 'on_hold') AS on_hold_jobs,
            COUNT(*) FILTER (WHERE status = 'completed' AND completed_at >= date_trunc('month', NOW()))
                AS completed_this_month,
            COUNT(*) FILTER (WHERE due_date < CURRENT_DATE AND status NOT IN ('completed', 'cancelled'))
                AS overdue_jobs,
            COUNT(*) FILTER (WHERE status = 'completed' AND invoice_id IS NULL) AS awaiting_invoice
        FROM fs_jobs WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id)[1]
    local v = db.query([[
        SELECT
            COUNT(*) FILTER (WHERE scheduled_start::date = CURRENT_DATE AND status <> 'cancelled') AS visits_today,
            COUNT(*) FILTER (WHERE status = 'on_site') AS engineers_on_site,
            COUNT(*) FILTER (WHERE engineer_user_uuid IS NULL AND status = 'scheduled') AS unassigned_visits,
            COUNT(*) FILTER (WHERE follow_up_required AND status IN ('completed', 'no_access')) AS follow_ups
        FROM fs_visits WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id)[1]
    local out = {}
    for k, val in pairs(r) do out[k] = tonumber(val) or 0 end
    for k, val in pairs(v) do out[k] = tonumber(val) or 0 end
    return out
end

return JobQueries
