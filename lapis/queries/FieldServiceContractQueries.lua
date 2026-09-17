--[[
    Field Service — maintenance contracts

    Simpro's CustomerContract: the agreement an asset's service levels hang off.
    A customer can hold several across one site — DBS's Skanska City of London
    portfolio splits heating from chillers — which is why the PPM forecast groups
    by contract rather than assuming one per site.

    The SLA hours stored here are the source the service desk copies onto a
    request when it is logged, so a contract change never silently rewrites the
    target a past request was measured against.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable, to_number, to_bool, arr =
    Common.nilify, Common.nullable, Common.to_number, Common.to_bool, Common.arr

local ContractQueries = {}

local function shape(c)
    return {
        uuid = c.uuid,
        contract_number = c.contract_number,
        name = c.name,
        description = c.description,
        status = c.status,
        start_date = c.start_date,
        end_date = c.end_date,
        extension_months = c.extension_months,
        annual_value = to_number(c.annual_value),
        currency = c.currency,
        response_hours = c.response_hours,
        resolve_hours = c.resolve_hours,
        quote_turnaround_hours = c.quote_turnaround_hours,
        covers_out_of_hours = c.covers_out_of_hours,
        service_manager_uuid = c.service_manager_uuid,
        coordinator_uuid = c.coordinator_uuid,
        notes = c.notes,
        custom_fields = Common.decode(c.custom_fields, {}),
        customer_uuid = c.customer_uuid,
        customer_name = c.customer_name,
        asset_count = to_number(c.asset_count),
        site_count = to_number(c.site_count),
        -- NULL end_date means open-ended, which is not the same as expired.
        days_to_expiry = to_number(c.days_to_expiry),
        simpro_id = c.simpro_id,
        simpro_sync_state = c.simpro_sync_state,
        created_at = c.created_at,
        updated_at = c.updated_at,
    }
end

local SELECT = [[
    SELECT ct.*,
           c.uuid AS customer_uuid,
           COALESCE(NULLIF(c.company_name, ''),
                    NULLIF(TRIM(CONCAT_WS(' ', c.first_name, c.last_name)), '')) AS customer_name,
           agg.asset_count,
           agg.site_count,
           (ct.end_date - CURRENT_DATE) AS days_to_expiry
    FROM fs_contracts ct
    LEFT JOIN customers c ON c.id = ct.customer_id
    LEFT JOIN LATERAL (
        SELECT COUNT(*) AS asset_count, COUNT(DISTINCT site_id) AS site_count
        FROM fs_assets
        WHERE contract_id = ct.id AND deleted_at IS NULL AND archived = FALSE
    ) agg ON TRUE
]]

function ContractQueries.listContracts(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where, values = { "ct.namespace_id = ?", "ct.deleted_at IS NULL" }, { namespace_id }

    if nilify(params.customer_uuid) then
        table.insert(where, "c.uuid = ?")
        table.insert(values, params.customer_uuid)
    end
    if nilify(params.status) then
        table.insert(where, "ct.status = ?")
        table.insert(values, params.status)
    end
    -- Renewal review: what runs out inside the window.
    if nilify(params.expiring_within_days) then
        table.insert(where,
            "ct.end_date IS NOT NULL AND ct.end_date <= (CURRENT_DATE + (? || ' days')::interval)")
        table.insert(values, tonumber(params.expiring_within_days) or 90)
    end
    if nilify(params.search) then
        table.insert(where, "(ct.name ILIKE ? OR ct.contract_number ILIKE ?)")
        table.insert(values, "%" .. params.search .. "%")
        table.insert(values, "%" .. params.search .. "%")
    end

    local clause = table.concat(where, " AND ")

    local total = db.query(db.interpolate_query([[
        SELECT COUNT(*) AS n FROM fs_contracts ct
        LEFT JOIN customers c ON c.id = ct.customer_id
        WHERE ]] .. clause, unpack(values)))[1]

    local list_values = {}
    for _, v in ipairs(values) do table.insert(list_values, v) end
    table.insert(list_values, per_page)
    table.insert(list_values, offset)

    local rows = db.query(db.interpolate_query(
        SELECT .. " WHERE " .. clause ..
        " ORDER BY ct.status, ct.end_date NULLS LAST, ct.name LIMIT ? OFFSET ?",
        unpack(list_values)))

    local out = {}
    for _, r in ipairs(rows) do table.insert(out, shape(r)) end
    return { items = arr(out), meta = Common.meta(total and total.n, page, per_page) }
end

function ContractQueries.getContract(namespace_id, uuid)
    local rows = db.query(db.interpolate_query(
        SELECT .. " WHERE ct.namespace_id = ? AND ct.uuid = ? AND ct.deleted_at IS NULL LIMIT 1",
        namespace_id, uuid))
    if not rows[1] then return nil end

    local contract = shape(rows[1])

    -- What the contract actually covers, grouped the way a renewal conversation
    -- goes: how many of each kind of plant, and what condition it is in.
    contract.coverage = arr(db.query([[
        SELECT COALESCE(at.name, 'Unclassified') AS asset_type,
               COUNT(*) AS assets,
               ROUND(AVG(a.condition_rating)::numeric, 1) AS avg_condition,
               COUNT(*) FILTER (WHERE a.condition_rating >= 5) AS needs_replacement
        FROM fs_assets a
        LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
        WHERE a.namespace_id = ? AND a.contract_id = ?
          AND a.deleted_at IS NULL AND a.archived = FALSE
        GROUP BY 1 ORDER BY assets DESC
    ]], namespace_id, rows[1].id))

    contract.sites = arr(db.query([[
        SELECT DISTINCT s.uuid::text AS uuid, s.name, s.city, s.postal_code,
               COUNT(a.id) OVER (PARTITION BY s.id) AS assets
        FROM fs_assets a
        JOIN fs_sites s ON s.id = a.site_id
        WHERE a.namespace_id = ? AND a.contract_id = ?
          AND a.deleted_at IS NULL AND a.archived = FALSE
        ORDER BY s.name
    ]], namespace_id, rows[1].id))

    return contract
end

local function columns(namespace_id, body, for_create)
    local patch = {}

    if for_create or body.customer_uuid ~= nil then
        local customer_id = Common.resolve_id("customers", namespace_id, body.customer_uuid)
        if not customer_id then return nil, "Customer not found" end
        patch.customer_id = customer_id
    end

    for _, key in ipairs({ "contract_number", "name", "description", "notes" }) do
        if body[key] ~= nil then patch[key] = nullable(body[key]) end
    end
    for _, key in ipairs({ "start_date", "end_date" }) do
        if body[key] ~= nil then patch[key] = nullable(body[key]) end
    end
    for _, key in ipairs({ "extension_months", "response_hours", "resolve_hours",
                           "quote_turnaround_hours" }) do
        if body[key] ~= nil then patch[key] = to_number(body[key]) or db.NULL end
    end
    if body.annual_value ~= nil then patch.annual_value = to_number(body.annual_value) or db.NULL end
    if body.currency ~= nil then patch.currency = nilify(body.currency) or "GBP" end
    if body.covers_out_of_hours ~= nil then
        patch.covers_out_of_hours = to_bool(body.covers_out_of_hours, false)
    end
    if body.service_manager_uuid ~= nil then
        patch.service_manager_uuid = nullable(body.service_manager_uuid)
    end
    if body.coordinator_uuid ~= nil then patch.coordinator_uuid = nullable(body.coordinator_uuid) end
    if body.custom_fields ~= nil then patch.custom_fields = cjson.encode(body.custom_fields) end
    if body.status ~= nil then
        local VALID = { draft = true, active = true, expired = true, cancelled = true }
        if not VALID[body.status] then
            return nil, "Status must be one of: draft, active, expired, cancelled"
        end
        patch.status = body.status
    end

    -- An end date before the start date is a typo that would quietly poison
    -- every renewal report, so it is caught here rather than in the UI only.
    local starts = patch.start_date
    local ends = patch.end_date
    if starts and ends and starts ~= db.NULL and ends ~= db.NULL
        and tostring(ends) < tostring(starts) then
        return nil, "Contract end date cannot be before its start date"
    end

    return patch
end

function ContractQueries.createContract(namespace_id, actor_uuid, body)
    body = body or {}
    if not nilify(body.name) then return nil, "Contract name is required" end
    if not nilify(body.customer_uuid) then return nil, "Customer is required" end

    local patch, err = columns(namespace_id, body, true)
    if not patch then return nil, err end

    patch.uuid = Common.uuid()
    patch.namespace_id = namespace_id
    patch.created_by_uuid = actor_uuid
    patch.status = patch.status or "active"
    patch.simpro_sync_state = "pending"

    local row = db.insert("fs_contracts", patch, { returning = "*" })[1]
    return ContractQueries.getContract(namespace_id, row.uuid)
end

function ContractQueries.updateContract(namespace_id, uuid, body)
    body = body or {}
    local existing = db.query(
        "SELECT * FROM fs_contracts WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL LIMIT 1",
        namespace_id, uuid)[1]
    if not existing then return nil, "Contract not found" end

    local patch, err = columns(namespace_id, body, false)
    if not patch then return nil, err end
    if next(patch) == nil then return nil, "Nothing to update" end

    -- Re-check the date window against whichever side the caller did not send.
    local starts = patch.start_date ~= nil and patch.start_date or existing.start_date
    local ends = patch.end_date ~= nil and patch.end_date or existing.end_date
    if starts and ends and starts ~= db.NULL and ends ~= db.NULL
        and tostring(ends) < tostring(starts) then
        return nil, "Contract end date cannot be before its start date"
    end

    patch.updated_at = db.raw("NOW()")
    patch.simpro_sync_state = "pending"
    db.update("fs_contracts", patch, { id = existing.id })
    return ContractQueries.getContract(namespace_id, uuid)
end

function ContractQueries.deleteContract(namespace_id, uuid)
    local id = Common.resolve_id("fs_contracts", namespace_id, uuid)
    if not id then return nil, "Contract not found" end
    db.update("fs_contracts",
        { deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = id })
    return true
end

return ContractQueries
