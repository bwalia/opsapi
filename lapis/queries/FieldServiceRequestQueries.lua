--[[
    Field Service — service request (complaint) queries
    ===================================================

    The intake layer: a customer reports a fault on one of our products, a manager
    triages and assigns it, then converts it into one or more jobs. One request →
    many jobs. Every read/write is namespace-scoped; the customer + product are
    resolved from their uuids and re-checked against the tenant.

    Model: customer = `customers`, product (the serviced item) = `storeproducts`,
    the specific unit is a free-text `product_ref`, and the visit address lives on
    the request. Converting reuses JobQueries.createJob and links the job back.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local FsServiceRequestModel = require("models.FsServiceRequestModel")
local Common = require("queries.FieldServiceCommon")
local JobQueries = require("queries.FieldServiceJobQueries")

local nilify, nullable, arr = Common.nilify, Common.nullable, Common.arr

local RequestQueries = {}

local CHANNELS = { phone = true, app = true, email = true, portal = true, web = true, other = true }
local PRIORITIES = { low = true, normal = true, high = true, urgent = true }

-- Manual status moves the manager may make. Booking/converting drives the rest.
local TRANSITIONS = {
    new = { triaged = true, assigned = true, in_progress = true, on_hold = true, rejected = true, duplicate = true },
    triaged = { assigned = true, in_progress = true, on_hold = true, rejected = true, duplicate = true },
    assigned = { in_progress = true, on_hold = true, triaged = true, resolved = true },
    in_progress = { on_hold = true, resolved = true },
    on_hold = { assigned = true, in_progress = true, resolved = true },
    resolved = { closed = true, in_progress = true },  -- reopen
    closed = { in_progress = true },                    -- reopen
    rejected = {},
    duplicate = {},
}

--------------------------------------------------------------------------------
-- Read
--------------------------------------------------------------------------------

-- customers is a person: display name from first/last, fall back to email.
local CUSTOMER_NAME_SQL = [[COALESCE(
    NULLIF(TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '')), ''), c.email)]]

local REQUEST_SELECT = [[
    SELECT r.*,
        c.uuid AS customer_uuid, ]] .. CUSTOMER_NAME_SQL .. [[ AS customer_name,
        c.email AS customer_email, c.phone AS customer_phone,
        p.uuid AS product_uuid, p.name AS product_name, p.sku AS product_sku,
        st.uuid AS site_uuid, st.name AS site_name,
        ]] .. Common.user_name_sql("mgr") .. [[ AS assigned_manager_name,
        (r.sla_response_due_at IS NOT NULL AND r.first_response_at IS NULL AND r.sla_response_due_at < NOW()
            AND r.status NOT IN ('resolved', 'closed', 'rejected', 'duplicate')) AS response_overdue,
        (r.sla_resolve_due_at IS NOT NULL AND r.resolved_at IS NULL AND r.sla_resolve_due_at < NOW()
            AND r.status NOT IN ('resolved', 'closed', 'rejected', 'duplicate')) AS resolve_overdue
    FROM fs_service_requests r
    LEFT JOIN customers c ON c.id = r.customer_id
    LEFT JOIN storeproducts p ON p.id = r.product_id
    LEFT JOIN fs_sites st ON st.id = r.site_id
    LEFT JOIN users mgr ON mgr.uuid = r.assigned_manager_uuid
]]

local function shape_request(r)
    return {
        uuid = r.uuid,
        request_number = r.request_number,
        title = r.title,
        description = r.description,
        fault_category = r.fault_category,
        channel = r.channel,
        reported_by = r.reported_by,
        priority = r.priority,
        status = r.status,
        customer_uuid = r.customer_uuid,
        customer_name = r.customer_name,
        customer_email = r.customer_email,
        customer_phone = r.customer_phone,
        product_uuid = r.product_uuid,
        product_name = r.product_name,
        product_sku = r.product_sku,
        product_ref = r.product_ref,
        site_uuid = r.site_uuid,
        site_name = r.site_name,
        service_address = r.service_address,
        service_postcode = r.service_postcode,
        assigned_manager_uuid = r.assigned_manager_uuid,
        assigned_manager_name = r.assigned_manager_uuid and r.assigned_manager_name or nil,
        response_overdue = Common.to_bool(r.response_overdue, false),
        resolve_overdue = Common.to_bool(r.resolve_overdue, false),
        sla_breached = Common.to_bool(r.response_overdue, false) or Common.to_bool(r.resolve_overdue, false),
        sla_response_due_at = r.sla_response_due_at,
        sla_resolve_due_at = r.sla_resolve_due_at,
        first_response_at = r.first_response_at,
        resolved_at = r.resolved_at,
        closed_at = r.closed_at,
        resolution_notes = r.resolution_notes,
        metadata = Common.decode(r.metadata, {}),
        created_at = r.created_at,
        updated_at = r.updated_at,
    }
end

local OPEN_STATUSES = "'new', 'triaged', 'assigned', 'in_progress', 'on_hold'"

function RequestQueries.listRequests(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "r.namespace_id = ?", "r.deleted_at IS NULL" }
    local values = { namespace_id }

    local status = nilify(params.status)
    if status == "open" then
        table.insert(where, "r.status IN (" .. OPEN_STATUSES .. ")")
    elseif status then
        table.insert(where, "r.status = ?")
        table.insert(values, tostring(status))
    end
    if nilify(params.priority) and PRIORITIES[tostring(params.priority)] then
        table.insert(where, "r.priority = ?")
        table.insert(values, tostring(params.priority))
    end
    if nilify(params.customer_uuid) then
        table.insert(where, "c.uuid = ?")
        table.insert(values, tostring(params.customer_uuid))
    end
    if nilify(params.product_uuid) then
        table.insert(where, "p.uuid = ?")
        table.insert(values, tostring(params.product_uuid))
    end
    if nilify(params.manager_uuid) then
        table.insert(where, "r.assigned_manager_uuid = ?")
        table.insert(values, tostring(params.manager_uuid))
    end
    if params.sla == "breached" then
        table.insert(where, [[(
            (r.sla_response_due_at IS NOT NULL AND r.first_response_at IS NULL AND r.sla_response_due_at < NOW())
            OR (r.sla_resolve_due_at IS NOT NULL AND r.resolved_at IS NULL AND r.sla_resolve_due_at < NOW())
        ) AND r.status NOT IN ('resolved', 'closed', 'rejected', 'duplicate')]])
    end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        table.insert(where, [[(r.request_number ILIKE ? OR r.title ILIKE ? OR r.description ILIKE ?
            OR c.first_name ILIKE ? OR c.last_name ILIKE ? OR c.email ILIKE ?)]])
        for _ = 1, 6 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")

    local count = db.query([[
        SELECT COUNT(*) AS total FROM fs_service_requests r
        LEFT JOIN customers c ON c.id = r.customer_id
        LEFT JOIN storeproducts p ON p.id = r.product_id
        WHERE ]] .. where_sql, unpack(values))

    -- Urgent first, then newest.
    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query(REQUEST_SELECT .. " WHERE " .. where_sql .. [[
        ORDER BY CASE r.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END,
                 r.created_at DESC
        LIMIT ? OFFSET ?]], unpack(page_values))

    local items = {}
    for _, r in ipairs(rows or {}) do table.insert(items, shape_request(r)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

local function find_request_row(namespace_id, uuid)
    local rows = db.query(REQUEST_SELECT .. [[
        WHERE r.uuid = ? AND r.namespace_id = ? AND r.deleted_at IS NULL LIMIT 1]],
        tostring(uuid), namespace_id)
    return rows and rows[1]
end

-- Jobs spawned from this request + a roll-up of their visits / hours / billing.
local function request_jobs(request_id)
    local rows = db.query([[
        SELECT j.uuid, j.job_number, j.title, j.status, j.priority, j.created_at,
            (SELECT COUNT(*) FROM fs_visits v WHERE v.job_id = j.id AND v.deleted_at IS NULL) AS visit_count,
            i.invoice_number, i.status AS invoice_status
        FROM fs_jobs j
        LEFT JOIN invoices i ON i.id = j.invoice_id
        WHERE j.service_request_id = ? AND j.deleted_at IS NULL
        ORDER BY j.created_at DESC
    ]], request_id)
    local out = {}
    for _, j in ipairs(rows or {}) do
        j.visit_count = tonumber(j.visit_count) or 0
        table.insert(out, j)
    end
    return arr(out)
end

local function request_rollup(request_id)
    local agg = db.query([[
        SELECT
            COUNT(DISTINCT j.id) AS job_count,
            COUNT(DISTINCT j.id) FILTER (WHERE j.status NOT IN ('completed', 'cancelled')) AS open_jobs,
            COUNT(v.id) AS visit_count,
            COALESCE(SUM(v.labour_hours), 0) AS labour_hours
        FROM fs_jobs j
        LEFT JOIN fs_visits v ON v.job_id = j.id AND v.deleted_at IS NULL
        WHERE j.service_request_id = ? AND j.deleted_at IS NULL
    ]], request_id)[1]
    local inv = db.query([[
        SELECT COALESCE(SUM(i.total_amount), 0) AS invoiced
        FROM invoices i
        WHERE i.id IN (SELECT invoice_id FROM fs_jobs
                       WHERE service_request_id = ? AND invoice_id IS NOT NULL AND deleted_at IS NULL)
    ]], request_id)[1]
    return {
        job_count = tonumber(agg.job_count) or 0,
        open_jobs = tonumber(agg.open_jobs) or 0,
        visit_count = tonumber(agg.visit_count) or 0,
        labour_hours = Common.round2(agg.labour_hours),
        invoiced_total = Common.round2(inv.invoiced),
    }
end

function RequestQueries.getRequest(namespace_id, uuid)
    local row = find_request_row(namespace_id, uuid)
    if not row then return nil end
    local req = shape_request(row)
    req.jobs = request_jobs(row.id)
    req.totals = request_rollup(row.id)
    req.allowed_transitions = arr({})
    for status, ok in pairs(TRANSITIONS[row.status] or {}) do
        if ok then table.insert(req.allowed_transitions, status) end
    end
    table.sort(req.allowed_transitions)
    return req
end

--------------------------------------------------------------------------------
-- Write
--------------------------------------------------------------------------------

local function next_request_number(namespace_id)
    local rows = db.query([[
        INSERT INTO fs_request_sequences (namespace_id, prefix, current_number, updated_at)
        VALUES (?, 'SR', 1, NOW())
        ON CONFLICT (namespace_id) DO UPDATE
            SET current_number = fs_request_sequences.current_number + 1, updated_at = NOW()
        RETURNING prefix, current_number
    ]], namespace_id)
    return string.format("%s-%04d", rows[1].prefix or "SR", tonumber(rows[1].current_number))
end

-- Resolve the customer + product uuids a request payload may carry. Only keys
-- present in `data` are returned; an explicit empty value resolves to db.NULL.
local function resolve_refs(namespace_id, data)
    local refs = {}
    local specs = {
        { key = "customer_uuid", tbl = "customers", col = "customer_id", label = "Customer" },
        { key = "product_uuid", tbl = "storeproducts", col = "product_id", label = "Product" },
        { key = "site_uuid", tbl = "fs_sites", col = "site_id", label = "Site" },
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

function RequestQueries.createRequest(namespace_id, actor_uuid, data)
    if not nilify(data.title) then return nil, "title is required" end
    local priority = nilify(data.priority) or "normal"
    if not PRIORITIES[priority] then return nil, "Invalid priority" end
    local channel = nilify(data.channel) or "phone"
    if not CHANNELS[channel] then return nil, "Invalid channel" end
    if nilify(data.assigned_manager_uuid) and not Common.is_member(namespace_id, data.assigned_manager_uuid) then
        return nil, "Assigned manager is not a member of this workspace"
    end

    local refs, ref_err = resolve_refs(namespace_id, data)
    if not refs then return nil, ref_err end
    for k, v in pairs(refs) do if v == db.NULL then refs[k] = nil end end

    local metadata = data.metadata
    if type(metadata) == "table" then metadata = cjson.encode(metadata) end

    return Common.transaction(function()
        local req = FsServiceRequestModel:create({
            uuid = Common.uuid(),
            namespace_id = namespace_id,
            request_number = next_request_number(namespace_id),
            customer_id = refs.customer_id,
            product_id = refs.product_id,
            product_ref = nilify(data.product_ref),
            service_address = nilify(data.service_address),
            service_postcode = nilify(data.service_postcode),
            title = tostring(data.title),
            description = nilify(data.description),
            fault_category = nilify(data.fault_category),
            channel = channel,
            reported_by = nilify(data.reported_by),
            priority = priority,
            status = "new",
            assigned_manager_uuid = nilify(data.assigned_manager_uuid),
            sla_response_due_at = nilify(data.sla_response_due_at),
            sla_resolve_due_at = nilify(data.sla_resolve_due_at),
            metadata = nilify(metadata) or "{}",
            created_by_uuid = actor_uuid,
        })
        return RequestQueries.getRequest(namespace_id, req.uuid)
    end)
end

local TEXT_FIELDS = {
    "title", "description", "fault_category", "reported_by", "resolution_notes",
    "product_ref", "service_address", "service_postcode",
}
local DATE_FIELDS = { "sla_response_due_at", "sla_resolve_due_at" }

function RequestQueries.updateRequest(namespace_id, uuid, data)
    local id = Common.resolve_id("fs_service_requests", namespace_id, uuid)
    if not id then return nil, "Service request not found" end

    local update = {}
    for _, f in ipairs(TEXT_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if update.title == db.NULL then return nil, "title cannot be empty" end
    for _, f in ipairs(DATE_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if data.priority ~= nil then
        if not PRIORITIES[tostring(data.priority)] then return nil, "Invalid priority" end
        update.priority = tostring(data.priority)
    end
    if data.channel ~= nil then
        if not CHANNELS[tostring(data.channel)] then return nil, "Invalid channel" end
        update.channel = tostring(data.channel)
    end
    if type(data.metadata) == "table" then update.metadata = cjson.encode(data.metadata) end

    local refs, ref_err = resolve_refs(namespace_id, data)
    if not refs then return nil, ref_err end
    for col, v in pairs(refs) do update[col] = v end

    if next(update) == nil then return nil, "No valid fields to update" end
    FsServiceRequestModel:find(id):update(update)
    return RequestQueries.getRequest(namespace_id, uuid)
end

--- Stamp the SLA / lifecycle timestamps a status change implies.
local function status_stamps(row, status)
    local set = { status = status }  -- updated_at is handled by the model's timestamp = true
    if not row.first_response_at and status ~= "new" then set.first_response_at = db.raw("NOW()") end
    if status == "resolved" then set.resolved_at = db.raw("NOW()") end
    if status == "closed" then set.closed_at = db.raw("NOW()") end
    -- Reopening clears the terminal stamps.
    if status == "in_progress" then
        set.resolved_at = db.NULL
        set.closed_at = db.NULL
    end
    return set
end

function RequestQueries.setRequestStatus(namespace_id, uuid, status, opts)
    opts = opts or {}
    local row = find_request_row(namespace_id, uuid)
    if not row then return nil, "Service request not found" end
    if status == row.status then return RequestQueries.getRequest(namespace_id, uuid) end
    if not (TRANSITIONS[row.status] and TRANSITIONS[row.status][status]) then
        return nil, "Cannot move a " .. row.status .. " request to " .. status
    end

    local set = status_stamps(row, status)
    if nilify(opts.resolution_notes) then set.resolution_notes = tostring(opts.resolution_notes) end
    FsServiceRequestModel:find(row.id):update(set)
    return RequestQueries.getRequest(namespace_id, uuid)
end

function RequestQueries.assignRequest(namespace_id, uuid, manager_uuid)
    local row = find_request_row(namespace_id, uuid)
    if not row then return nil, "Service request not found" end
    manager_uuid = nilify(manager_uuid)
    if not manager_uuid then return nil, "manager_uuid is required" end
    if not Common.is_member(namespace_id, manager_uuid) then
        return nil, "Manager is not a member of this workspace"
    end

    local set = { assigned_manager_uuid = tostring(manager_uuid) }
    if not row.first_response_at then set.first_response_at = db.raw("NOW()") end
    if row.status == "new" or row.status == "triaged" then set.status = "assigned" end
    FsServiceRequestModel:find(row.id):update(set)
    return RequestQueries.getRequest(namespace_id, uuid)
end

--- Convert a request into a job: create the job (reusing JobQueries.createJob so
--- it gets a JOB number + copied phases), link it back, and advance the request.
function RequestQueries.convertToJob(namespace_id, uuid, actor_uuid, data)
    data = data or {}
    local row = find_request_row(namespace_id, uuid)
    if not row then return nil, "Service request not found" end
    if row.status == "closed" or row.status == "rejected" or row.status == "duplicate" then
        return nil, "A " .. row.status .. " request cannot be converted to a job"
    end

    return Common.transaction(function()
        local job_data = {
            title = nilify(data.title) or row.title,
            description = nilify(data.description) or row.description,
            priority = nilify(data.priority) or row.priority,
            job_type_uuid = nilify(data.job_type_uuid),
            customer_uuid = nilify(data.customer_uuid) or row.customer_uuid,
            product_uuid = nilify(data.product_uuid) or row.product_uuid,
            site_uuid = nilify(data.site_uuid) or row.site_uuid,
            product_ref = row.product_ref,
            service_address = nilify(data.service_address) or row.service_address,
            service_postcode = row.service_postcode,
            service_manager_uuid = nilify(data.service_manager_uuid) or row.assigned_manager_uuid,
            due_date = nilify(data.due_date),
        }
        local job, err = JobQueries.createJob(namespace_id, actor_uuid, job_data)
        if not job then return nil, err end

        -- Link the job back to its request (createJob doesn't know this column).
        db.query([[
            UPDATE fs_jobs SET service_request_id = ?, updated_at = NOW()
            WHERE uuid = ? AND namespace_id = ?
        ]], row.id, job.uuid, namespace_id)

        -- Work has started on the complaint.
        local set = {}
        if not row.first_response_at then set.first_response_at = db.raw("NOW()") end
        if TRANSITIONS[row.status] and TRANSITIONS[row.status].in_progress then set.status = "in_progress" end
        if not row.assigned_manager_uuid and job_data.service_manager_uuid then
            set.assigned_manager_uuid = job_data.service_manager_uuid
        end
        FsServiceRequestModel:find(row.id):update(set)

        return {
            job_uuid = job.uuid,
            job_number = job.job_number,
            request = RequestQueries.getRequest(namespace_id, uuid),
        }
    end)
end

function RequestQueries.deleteRequest(namespace_id, uuid)
    local id = Common.resolve_id("fs_service_requests", namespace_id, uuid)
    if not id then return nil, "Service request not found" end
    -- Jobs already spawned keep their history; they just lose the back-link.
    db.query("UPDATE fs_service_requests SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", id)
    return true
end

return RequestQueries
