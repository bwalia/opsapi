--[[
    Field Service — customer assets, asset types, service levels, test history
    ==========================================================================

    Simpro's asset model, which is the one DBS survey against:

      Asset type      defines what an engineer is asked to record — the readings
                      and the failure points. Configuration, not schema.
      Asset           the individual machine at a site. Belongs to the SITE, so
                      transferring a site moves its assets with it.
      Service level   a recurring obligation on an asset with its own next-due
                      date (quarterly PPM, annual F-Gas leak check).
      Test history    one row per survey: the readings taken, the failure points
                      found, and the condition rating that came out of it.

    recordTest is the interesting one. It writes the history row, rolls the
    asset's denormalised condition forward, advances the service level's next
    due date, and recomputes the leak-check date from the CO2e — all in one
    transaction, because an engineer who signs off a visit on a flaky 4G
    connection must not leave an asset whose rating and schedule disagree with
    its own history.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable, to_number, to_bool, arr =
    Common.nilify, Common.nullable, Common.to_number, Common.to_bool, Common.arr

local AssetQueries = {}

-- Global warming potential, AR5 100-year values. Used to derive tCO2e, which is
-- what sets the statutory leak-check interval — so it is a lookup with a known
-- provenance rather than a number an engineer types in.
local GWP = {
    R32 = 675, R410A = 2088, R407C = 1774, R404A = 3922, R448A = 1387,
    R449A = 1397, R134A = 1430, R513A = 631, R1234ZE = 7, R1234YF = 4,
    R290 = 3, R600A = 3, R744 = 1, R717 = 0, R452A = 2140, R407F = 1825,
}

local function gwp_for(refrigerant)
    if not refrigerant then return nil end
    return GWP[tostring(refrigerant):upper():gsub("%s", "")]
end

--- UK F-Gas leak-check interval, from tonnes of CO2 equivalent.
--- <5t: none required. 5-50t: 12 months. 50-500t: 6 months. >=500t: 3 months.
--- Halved intervals for systems with a fitted leak-detection system are a
--- site-by-site judgement, so they are not inferred here.
local function leak_check_months(co2e_tonnes, hermetically_sealed)
    if not co2e_tonnes or co2e_tonnes <= 0 then return nil end
    -- A hermetically sealed system gets the exemption up to 10 tonnes.
    local floor = hermetically_sealed and 10 or 5
    if co2e_tonnes < floor then return nil end
    if co2e_tonnes < 50 then return 12 end
    if co2e_tonnes < 500 then return 6 end
    return 3
end

-- ---------------------------------------------------------------------------
-- Shaping
-- ---------------------------------------------------------------------------

local function shape_asset_type(t)
    return {
        uuid = t.uuid, name = t.name, code = t.code, description = t.description,
        discipline = t.discipline, is_fgas = t.is_fgas,
        default_service_months = t.default_service_months,
        readings = arr(Common.decode(t.readings, {})),
        failure_points = arr(Common.decode(t.failure_points, {})),
        consumables = arr(Common.decode(t.consumables, {})),
        is_active = t.is_active,
        simpro_id = t.simpro_id, simpro_sync_state = t.simpro_sync_state,
        created_at = t.created_at, updated_at = t.updated_at,
    }
end

local function shape_asset(a)
    local charge = to_number(a.refrigerant_charge_kg)
    local gwp = to_number(a.refrigerant_gwp)
    return {
        uuid = a.uuid,
        asset_tag = a.asset_tag,
        name = a.name,
        serial_number = a.serial_number,
        product_number = a.product_number,
        manufacturer = a.manufacturer,
        model = a.model,
        location_detail = a.location_detail,
        installed_at = a.installed_at,
        warranty_expires_at = a.warranty_expires_at,
        condition_rating = a.condition_rating,
        condition_notes = a.condition_notes,
        last_surveyed_at = a.last_surveyed_at,
        refrigerant_type = a.refrigerant_type,
        refrigerant_charge_kg = charge,
        refrigerant_gwp = gwp,
        -- Derived rather than stored: two columns that must agree is one column
        -- that can be wrong.
        co2e_tonnes = (charge and gwp) and Common.round2(charge * gwp / 1000) or nil,
        hermetically_sealed = a.hermetically_sealed,
        leak_check_months = a.leak_check_months,
        next_leak_check_at = a.next_leak_check_at,
        status = a.status,
        archived = a.archived,
        display_order = a.display_order,
        notes = a.notes,
        custom_fields = Common.decode(a.custom_fields, {}),
        -- Joined context, present on list/get but not on write.
        site_uuid = a.site_uuid, site_name = a.site_name, site_postcode = a.site_postcode,
        customer_uuid = a.customer_uuid, customer_name = a.customer_name,
        asset_type_uuid = a.asset_type_uuid, asset_type = a.asset_type_name,
        discipline = a.discipline, is_fgas = a.is_fgas,
        contract_uuid = a.contract_uuid, contract_name = a.contract_name,
        parent_uuid = a.parent_uuid,
        next_service_date = a.next_service_date,
        service_level_count = to_number(a.service_level_count),
        open_failures = to_number(a.open_failures),
        simpro_id = a.simpro_id,
        simpro_sync_state = a.simpro_sync_state,
        simpro_synced_at = a.simpro_synced_at,
        created_at = a.created_at, updated_at = a.updated_at,
    }
end

local function shape_service_level(s)
    return {
        uuid = s.uuid, name = s.name, kind = s.kind,
        frequency_months = s.frequency_months,
        last_service_date = s.last_service_date,
        next_service_date = s.next_service_date,
        estimated_hours = to_number(s.estimated_hours),
        is_active = s.is_active, notes = s.notes,
        contract_uuid = s.contract_uuid, contract_name = s.contract_name,
        asset_uuid = s.asset_uuid,
        created_at = s.created_at, updated_at = s.updated_at,
    }
end

local function shape_test(t)
    return {
        uuid = t.uuid, tested_at = t.tested_at, due_date = t.due_date, result = t.result,
        condition_rating = t.condition_rating,
        technician_uuid = t.technician_uuid, technician_name = t.technician_name,
        readings = arr(Common.decode(t.readings, {})),
        failure_points = arr(Common.decode(t.failure_points, {})),
        refrigerant_type = t.refrigerant_type,
        refrigerant_added_kg = to_number(t.refrigerant_added_kg),
        refrigerant_recovered_kg = to_number(t.refrigerant_recovered_kg),
        leak_check_result = t.leak_check_result,
        notes = t.notes, recommendation = t.recommendation,
        job_number = t.job_number, job_uuid = t.job_uuid,
        visit_uuid = t.visit_uuid, service_level = t.service_level_name,
        asset_uuid = t.asset_uuid, asset_tag = t.asset_tag,
        created_at = t.created_at,
    }
end

-- The joins every asset read shares. Kept in one place so list and get can
-- never disagree about what an asset looks like.
local ASSET_SELECT = [[
    SELECT a.*,
           s.uuid::text AS site_uuid, s.name AS site_name, s.postal_code AS site_postcode,
           c.uuid AS customer_uuid,
           COALESCE(NULLIF(c.company_name, ''),
                    NULLIF(TRIM(CONCAT_WS(' ', c.first_name, c.last_name)), '')) AS customer_name,
           at.uuid AS asset_type_uuid, at.name AS asset_type_name,
           at.discipline, at.is_fgas,
           ct.uuid AS contract_uuid, ct.name AS contract_name,
           p.uuid AS parent_uuid,
           sl.next_service_date,
           sl.service_level_count,
           fails.open_failures
    FROM fs_assets a
    LEFT JOIN fs_sites s        ON s.id = a.site_id
    LEFT JOIN customers c       ON c.id = a.customer_id
    LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
    LEFT JOIN fs_contracts ct   ON ct.id = a.contract_id
    LEFT JOIN fs_assets p       ON p.id = a.parent_id
    LEFT JOIN LATERAL (
        SELECT MIN(next_service_date) AS next_service_date, COUNT(*) AS service_level_count
        FROM fs_asset_service_levels
        WHERE asset_id = a.id AND deleted_at IS NULL AND is_active
    ) sl ON TRUE
    LEFT JOIN LATERAL (
        SELECT COUNT(*) AS open_failures
        FROM fs_asset_test_history
        WHERE asset_id = a.id AND deleted_at IS NULL AND result = 'fail'
          AND tested_at > NOW() - INTERVAL '12 months'
    ) fails ON TRUE
]]

-- ---------------------------------------------------------------------------
-- Asset types
-- ---------------------------------------------------------------------------

function AssetQueries.listAssetTypes(namespace_id, params)
    params = params or {}
    local where, values = { "namespace_id = ?", "deleted_at IS NULL" }, { namespace_id }

    if not to_bool(params.include_inactive, false) then
        table.insert(where, "is_active")
    end
    if nilify(params.discipline) then
        table.insert(where, "discipline = ?")
        table.insert(values, params.discipline)
    end
    if nilify(params.search) then
        table.insert(where, "(name ILIKE ? OR code ILIKE ?)")
        table.insert(values, "%" .. params.search .. "%")
        table.insert(values, "%" .. params.search .. "%")
    end

    local sql = "SELECT * FROM fs_asset_types WHERE " .. table.concat(where, " AND ") ..
        " ORDER BY discipline, name"
    local rows = db.query(db.interpolate_query(sql, unpack(values)))

    local out = {}
    for _, r in ipairs(rows) do table.insert(out, shape_asset_type(r)) end
    return { items = arr(out), meta = { total = #out } }
end

function AssetQueries.createAssetType(namespace_id, actor_uuid, body)
    body = body or {}
    if not nilify(body.name) then return nil, "Asset type name is required" end

    local row = db.insert("fs_asset_types", {
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        name = body.name,
        code = nilify(body.code),
        description = nilify(body.description),
        discipline = nilify(body.discipline) or "hvac",
        is_fgas = to_bool(body.is_fgas, false),
        default_service_months = to_number(body.default_service_months),
        readings = cjson.encode(body.readings or {}),
        failure_points = cjson.encode(body.failure_points or {}),
        consumables = cjson.encode(body.consumables or {}),
        is_active = to_bool(body.is_active, true),
        created_by_uuid = actor_uuid,
    }, { returning = "*" })[1]

    return shape_asset_type(row)
end

function AssetQueries.updateAssetType(namespace_id, uuid, body)
    body = body or {}
    local id = Common.resolve_id("fs_asset_types", namespace_id, uuid)
    if not id then return nil, "Asset type not found" end

    local patch = {}
    if body.name ~= nil then patch.name = body.name end
    if body.code ~= nil then patch.code = nullable(body.code) end
    if body.description ~= nil then patch.description = nullable(body.description) end
    if body.discipline ~= nil then patch.discipline = body.discipline end
    if body.is_fgas ~= nil then patch.is_fgas = to_bool(body.is_fgas, false) end
    if body.default_service_months ~= nil then
        patch.default_service_months = to_number(body.default_service_months) or db.NULL
    end
    if body.readings ~= nil then patch.readings = cjson.encode(body.readings) end
    if body.failure_points ~= nil then patch.failure_points = cjson.encode(body.failure_points) end
    if body.consumables ~= nil then patch.consumables = cjson.encode(body.consumables) end
    if body.is_active ~= nil then patch.is_active = to_bool(body.is_active, true) end
    if next(patch) == nil then return nil, "Nothing to update" end

    patch.updated_at = db.raw("NOW()")
    db.update("fs_asset_types", patch, { id = id })
    local row = db.query("SELECT * FROM fs_asset_types WHERE id = ?", id)[1]
    return shape_asset_type(row)
end

-- ---------------------------------------------------------------------------
-- Assets
-- ---------------------------------------------------------------------------

function AssetQueries.listAssets(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where, values = { "a.namespace_id = ?", "a.deleted_at IS NULL" }, { namespace_id }

    if not to_bool(params.include_archived, false) then
        table.insert(where, "a.archived = FALSE")
    end
    if nilify(params.site_uuid) then
        table.insert(where, "s.uuid::text = ?")
        table.insert(values, params.site_uuid)
    end
    if nilify(params.customer_uuid) then
        table.insert(where, "c.uuid = ?")
        table.insert(values, params.customer_uuid)
    end
    if nilify(params.asset_type_uuid) then
        table.insert(where, "at.uuid = ?")
        table.insert(values, params.asset_type_uuid)
    end
    if nilify(params.contract_uuid) then
        table.insert(where, "ct.uuid = ?")
        table.insert(values, params.contract_uuid)
    end
    if nilify(params.status) then
        table.insert(where, "a.status = ?")
        table.insert(values, params.status)
    end
    if nilify(params.discipline) then
        table.insert(where, "at.discipline = ?")
        table.insert(values, params.discipline)
    end
    -- "Show me what needs replacing": condition 5 and 6 are DBS's budget-for-
    -- replacement band.
    if nilify(params.condition_min) then
        table.insert(where, "a.condition_rating >= ?")
        table.insert(values, tonumber(params.condition_min) or 1)
    end
    if to_bool(params.fgas_only, false) then
        table.insert(where, "a.refrigerant_type IS NOT NULL")
    end
    if to_bool(params.service_overdue, false) then
        table.insert(where, "sl.next_service_date < CURRENT_DATE")
    end
    if nilify(params.search) then
        table.insert(where,
            "(a.name ILIKE ? OR a.asset_tag ILIKE ? OR a.serial_number ILIKE ? OR a.model ILIKE ?)")
        local like = "%" .. params.search .. "%"
        for _ = 1, 4 do table.insert(values, like) end
    end

    local clause = table.concat(where, " AND ")

    local total = db.query(db.interpolate_query([[
        SELECT COUNT(*) AS n FROM fs_assets a
        LEFT JOIN fs_sites s        ON s.id = a.site_id
        LEFT JOIN customers c       ON c.id = a.customer_id
        LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
        LEFT JOIN fs_contracts ct   ON ct.id = a.contract_id
        LEFT JOIN LATERAL (
            SELECT MIN(next_service_date) AS next_service_date
            FROM fs_asset_service_levels
            WHERE asset_id = a.id AND deleted_at IS NULL AND is_active
        ) sl ON TRUE
        WHERE ]] .. clause, unpack(values)))[1]

    local list_values = {}
    for _, v in ipairs(values) do table.insert(list_values, v) end
    table.insert(list_values, per_page)
    table.insert(list_values, offset)

    local rows = db.query(db.interpolate_query(
        ASSET_SELECT .. " WHERE " .. clause ..
        " ORDER BY s.name NULLS LAST, a.display_order, a.asset_tag NULLS LAST, a.name" ..
        " LIMIT ? OFFSET ?", unpack(list_values)))

    local out = {}
    for _, r in ipairs(rows) do table.insert(out, shape_asset(r)) end
    return { items = arr(out), meta = Common.meta(total and total.n, page, per_page) }
end

function AssetQueries.getAsset(namespace_id, uuid)
    local rows = db.query(db.interpolate_query(
        ASSET_SELECT .. " WHERE a.namespace_id = ? AND a.uuid = ? AND a.deleted_at IS NULL LIMIT 1",
        namespace_id, uuid))
    if not rows[1] then return nil end

    local asset = shape_asset(rows[1])

    local levels = db.query([[
        SELECT sl.*, a.uuid AS asset_uuid, ct.uuid AS contract_uuid, ct.name AS contract_name
        FROM fs_asset_service_levels sl
        JOIN fs_assets a          ON a.id = sl.asset_id
        LEFT JOIN fs_contracts ct ON ct.id = sl.contract_id
        WHERE sl.namespace_id = ? AND sl.asset_id = ? AND sl.deleted_at IS NULL
        ORDER BY sl.next_service_date NULLS LAST
    ]], namespace_id, rows[1].id)

    asset.service_levels = {}
    for _, l in ipairs(levels) do table.insert(asset.service_levels, shape_service_level(l)) end
    asset.service_levels = arr(asset.service_levels)

    -- The last handful of surveys: enough for the asset card, not the whole
    -- history (that is the asset_history report's job).
    local tests = db.query([[
        SELECT th.*, j.job_number, j.uuid AS job_uuid, v.uuid AS visit_uuid,
               sl.name AS service_level_name, a.uuid AS asset_uuid, a.asset_tag
        FROM fs_asset_test_history th
        JOIN fs_assets a      ON a.id = th.asset_id
        LEFT JOIN fs_jobs j   ON j.id = th.job_id
        LEFT JOIN fs_visits v ON v.id = th.visit_id
        LEFT JOIN fs_asset_service_levels sl ON sl.id = th.service_level_id
        WHERE th.namespace_id = ? AND th.asset_id = ? AND th.deleted_at IS NULL
        ORDER BY th.tested_at DESC
        LIMIT 10
    ]], namespace_id, rows[1].id)

    asset.recent_tests = {}
    for _, t in ipairs(tests) do table.insert(asset.recent_tests, shape_test(t)) end
    asset.recent_tests = arr(asset.recent_tests)

    return asset
end

--- Values shared by create and update. Returns the column patch, or nil + err.
local function asset_columns(namespace_id, body, for_create)
    local patch = {}

    if for_create or body.site_uuid ~= nil then
        local site_id = Common.resolve_id("fs_sites", namespace_id, body.site_uuid)
        if not site_id then return nil, "Site not found" end
        patch.site_id = site_id
        -- Denormalise the owner from the site: Simpro keeps the two in step by
        -- making the site authoritative, and so do we.
        local owner = db.query("SELECT customer_id FROM fs_sites WHERE id = ?", site_id)[1]
        patch.customer_id = (owner and owner.customer_id) or db.NULL
    end

    if body.asset_type_uuid ~= nil then
        patch.asset_type_id = nilify(body.asset_type_uuid)
            and Common.resolve_id("fs_asset_types", namespace_id, body.asset_type_uuid) or db.NULL
        if nilify(body.asset_type_uuid) and not patch.asset_type_id then
            return nil, "Asset type not found"
        end
    end
    if body.contract_uuid ~= nil then
        patch.contract_id = nilify(body.contract_uuid)
            and Common.resolve_id("fs_contracts", namespace_id, body.contract_uuid) or db.NULL
        if nilify(body.contract_uuid) and not patch.contract_id then
            return nil, "Contract not found"
        end
    end
    if body.parent_uuid ~= nil then
        patch.parent_id = nilify(body.parent_uuid)
            and Common.resolve_id("fs_assets", namespace_id, body.parent_uuid) or db.NULL
        if nilify(body.parent_uuid) and not patch.parent_id then
            return nil, "Parent asset not found"
        end
    end

    local plain = {
        "asset_tag", "name", "serial_number", "product_number", "manufacturer",
        "model", "location_detail", "notes", "condition_notes", "refrigerant_type", "status",
    }
    for _, key in ipairs(plain) do
        if body[key] ~= nil then patch[key] = nullable(body[key]) end
    end

    local dates = { "installed_at", "warranty_expires_at", "next_leak_check_at" }
    for _, key in ipairs(dates) do
        if body[key] ~= nil then patch[key] = nullable(body[key]) end
    end

    if body.condition_rating ~= nil then
        local r = to_number(body.condition_rating)
        if r and (r < 1 or r > 6) then
            return nil, "Condition rating must be between 1 (excellent) and 6 (replace)"
        end
        patch.condition_rating = r or db.NULL
    end
    if body.refrigerant_charge_kg ~= nil then
        patch.refrigerant_charge_kg = to_number(body.refrigerant_charge_kg) or db.NULL
    end
    if body.hermetically_sealed ~= nil then
        patch.hermetically_sealed = to_bool(body.hermetically_sealed, false)
    end
    if body.archived ~= nil then patch.archived = to_bool(body.archived, false) end
    if body.display_order ~= nil then patch.display_order = to_number(body.display_order) or 0 end
    if body.custom_fields ~= nil then patch.custom_fields = cjson.encode(body.custom_fields) end

    return patch
end

--- Derive GWP, CO2e and the leak-check interval from whatever refrigerant
--- figures the row will end up with. Mutates `patch`.
local function apply_fgas_derivation(patch, existing)
    local rtype = patch.refrigerant_type
    if rtype == nil or rtype == db.NULL then
        rtype = existing and existing.refrigerant_type
    end
    local charge = patch.refrigerant_charge_kg
    if charge == nil or charge == db.NULL then
        charge = existing and to_number(existing.refrigerant_charge_kg)
    end
    local sealed = patch.hermetically_sealed
    if sealed == nil then sealed = existing and existing.hermetically_sealed end

    local gwp = gwp_for(rtype)
    patch.refrigerant_gwp = gwp or db.NULL

    if gwp and charge then
        local months = leak_check_months(charge * gwp / 1000, sealed)
        patch.leak_check_months = months or db.NULL
        -- Only seed the next date when the caller did not set one and the asset
        -- has none: an engineer's booked date always wins over a computed one.
        if months and patch.next_leak_check_at == nil
            and not (existing and existing.next_leak_check_at) then
            patch.next_leak_check_at = db.raw(
                ("(CURRENT_DATE + INTERVAL '%d months')"):format(months))
        end
    else
        patch.leak_check_months = db.NULL
    end
end

function AssetQueries.createAsset(namespace_id, actor_uuid, body)
    body = body or {}
    if not nilify(body.name) then return nil, "Asset name is required" end
    if not nilify(body.site_uuid) then return nil, "Site is required" end

    local patch, err = asset_columns(namespace_id, body, true)
    if not patch then return nil, err end

    apply_fgas_derivation(patch, nil)

    patch.uuid = Common.uuid()
    patch.namespace_id = namespace_id
    patch.created_by_uuid = actor_uuid
    patch.simpro_sync_state = "pending"

    local row = db.insert("fs_assets", patch, { returning = "*" })[1]

    -- Seed the type's default service level so a new asset is never invisible
    -- to the PPM forecast.
    if row.asset_type_id then
        local t = db.query("SELECT name, default_service_months, is_fgas FROM fs_asset_types WHERE id = ?",
            row.asset_type_id)[1]
        if t and t.default_service_months and tonumber(t.default_service_months) > 0 then
            db.insert("fs_asset_service_levels", {
                uuid = Common.uuid(),
                namespace_id = namespace_id,
                asset_id = row.id,
                contract_id = row.contract_id or db.NULL,
                name = ("%s service"):format(t.name),
                kind = "service",
                frequency_months = tonumber(t.default_service_months),
                next_service_date = db.raw(("(CURRENT_DATE + INTERVAL '%d months')")
                    :format(tonumber(t.default_service_months))),
                created_by_uuid = actor_uuid,
            })
        end
    end

    return AssetQueries.getAsset(namespace_id, row.uuid)
end

function AssetQueries.updateAsset(namespace_id, uuid, body)
    body = body or {}
    local existing = db.query(
        "SELECT * FROM fs_assets WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL LIMIT 1",
        namespace_id, uuid)[1]
    if not existing then return nil, "Asset not found" end

    local patch, err = asset_columns(namespace_id, body, false)
    if not patch then return nil, err end
    if next(patch) == nil then return nil, "Nothing to update" end

    -- An asset cannot be its own ancestor; one level of check catches the
    -- realistic mistake (picking the asset itself in the parent dropdown).
    if patch.parent_id and patch.parent_id == existing.id then
        return nil, "An asset cannot be its own parent"
    end

    if body.refrigerant_type ~= nil or body.refrigerant_charge_kg ~= nil
        or body.hermetically_sealed ~= nil then
        apply_fgas_derivation(patch, existing)
    end

    patch.updated_at = db.raw("NOW()")
    -- Any local edit puts the row back in the push queue.
    patch.simpro_sync_state = "pending"
    db.update("fs_assets", patch, { id = existing.id })

    return AssetQueries.getAsset(namespace_id, uuid)
end

function AssetQueries.deleteAsset(namespace_id, uuid)
    local id = Common.resolve_id("fs_assets", namespace_id, uuid)
    if not id then return nil, "Asset not found" end
    db.update("fs_assets",
        { deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = id })
    return true
end

-- ---------------------------------------------------------------------------
-- Service levels
-- ---------------------------------------------------------------------------

function AssetQueries.createServiceLevel(namespace_id, actor_uuid, asset_uuid, body)
    body = body or {}
    local asset_id = Common.resolve_id("fs_assets", namespace_id, asset_uuid)
    if not asset_id then return nil, "Asset not found" end
    if not nilify(body.name) then return nil, "Service level name is required" end

    local months = to_number(body.frequency_months) or 12
    if months < 1 or months > 120 then
        return nil, "Frequency must be between 1 and 120 months"
    end

    local contract_id = db.NULL
    if nilify(body.contract_uuid) then
        contract_id = Common.resolve_id("fs_contracts", namespace_id, body.contract_uuid)
        if not contract_id then return nil, "Contract not found" end
    end

    local row = db.insert("fs_asset_service_levels", {
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        asset_id = asset_id,
        contract_id = contract_id,
        name = body.name,
        kind = nilify(body.kind) or "service",
        frequency_months = months,
        last_service_date = nullable(body.last_service_date),
        next_service_date = nilify(body.next_service_date)
            or db.raw(("(CURRENT_DATE + INTERVAL '%d months')"):format(months)),
        estimated_hours = to_number(body.estimated_hours) or db.NULL,
        is_active = to_bool(body.is_active, true),
        notes = nullable(body.notes),
        created_by_uuid = actor_uuid,
    }, { returning = "*" })[1]

    return shape_service_level(row)
end

function AssetQueries.updateServiceLevel(namespace_id, uuid, body)
    body = body or {}
    local id = Common.resolve_id("fs_asset_service_levels", namespace_id, uuid)
    if not id then return nil, "Service level not found" end

    local patch = {}
    if body.name ~= nil then patch.name = body.name end
    if body.kind ~= nil then patch.kind = body.kind end
    if body.frequency_months ~= nil then
        local m = to_number(body.frequency_months)
        if not m or m < 1 or m > 120 then
            return nil, "Frequency must be between 1 and 120 months"
        end
        patch.frequency_months = m
    end
    if body.last_service_date ~= nil then patch.last_service_date = nullable(body.last_service_date) end
    if body.next_service_date ~= nil then patch.next_service_date = nullable(body.next_service_date) end
    if body.estimated_hours ~= nil then patch.estimated_hours = to_number(body.estimated_hours) or db.NULL end
    if body.is_active ~= nil then patch.is_active = to_bool(body.is_active, true) end
    if body.notes ~= nil then patch.notes = nullable(body.notes) end
    if body.contract_uuid ~= nil then
        patch.contract_id = nilify(body.contract_uuid)
            and Common.resolve_id("fs_contracts", namespace_id, body.contract_uuid) or db.NULL
    end
    if next(patch) == nil then return nil, "Nothing to update" end

    patch.updated_at = db.raw("NOW()")
    db.update("fs_asset_service_levels", patch, { id = id })
    local row = db.query([[
        SELECT sl.*, a.uuid AS asset_uuid, ct.uuid AS contract_uuid, ct.name AS contract_name
        FROM fs_asset_service_levels sl
        JOIN fs_assets a ON a.id = sl.asset_id
        LEFT JOIN fs_contracts ct ON ct.id = sl.contract_id
        WHERE sl.id = ?
    ]], id)[1]
    return shape_service_level(row)
end

function AssetQueries.deleteServiceLevel(namespace_id, uuid)
    local id = Common.resolve_id("fs_asset_service_levels", namespace_id, uuid)
    if not id then return nil, "Service level not found" end
    db.update("fs_asset_service_levels",
        { deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = id })
    return true
end

-- ---------------------------------------------------------------------------
-- Test history — the survey write path
-- ---------------------------------------------------------------------------

--- Record a survey against an asset.
---
--- One transaction covers the history row, the asset's rolled-forward condition,
--- the service level's next due date and the recomputed leak-check date, so an
--- asset's rating, schedule and history can never be left disagreeing.
function AssetQueries.recordTest(namespace_id, actor_uuid, asset_uuid, body)
    body = body or {}

    return Common.transaction(function()
        local asset = db.query([[
            SELECT a.*, at.is_fgas
            FROM fs_assets a
            LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
            WHERE a.namespace_id = ? AND a.uuid = ? AND a.deleted_at IS NULL
            LIMIT 1
        ]], namespace_id, asset_uuid)[1]
        if not asset then return nil, "Asset not found" end

        local result = nilify(body.result) or "pass"
        local VALID = { pass = true, fail = true, advisory = true, not_tested = true }
        if not VALID[result] then
            return nil, "Result must be one of: pass, fail, advisory, not_tested"
        end

        local rating = to_number(body.condition_rating)
        if rating and (rating < 1 or rating > 6) then
            return nil, "Condition rating must be between 1 (excellent) and 6 (replace)"
        end

        local job_id, visit_id, level_id, due_date = db.NULL, db.NULL, db.NULL, db.NULL
        if nilify(body.job_uuid) then
            job_id = Common.resolve_id("fs_jobs", namespace_id, body.job_uuid)
            if not job_id then return nil, "Job not found" end
        end
        if nilify(body.visit_uuid) then
            visit_id = Common.resolve_id("fs_visits", namespace_id, body.visit_uuid)
            if not visit_id then return nil, "Visit not found" end
        end
        if nilify(body.service_level_uuid) then
            level_id = Common.resolve_id("fs_asset_service_levels", namespace_id, body.service_level_uuid)
            if not level_id then return nil, "Service level not found" end
            -- Capture what was due before this test moves the schedule on.
            local due = db.query("SELECT next_service_date FROM fs_asset_service_levels WHERE id = ?",
                level_id)[1]
            due_date = (due and due.next_service_date) or db.NULL
        end

        local tested_at = nilify(body.tested_at)
        local test = db.insert("fs_asset_test_history", {
            uuid = Common.uuid(),
            namespace_id = namespace_id,
            asset_id = asset.id,
            site_id = asset.site_id or db.NULL,
            job_id = job_id,
            visit_id = visit_id,
            service_level_id = level_id,
            due_date = due_date,
            tested_at = tested_at or db.raw("NOW()"),
            technician_uuid = nilify(body.technician_uuid) or actor_uuid or db.NULL,
            technician_name = nullable(body.technician_name),
            result = result,
            condition_rating = rating or db.NULL,
            readings = cjson.encode(body.readings or {}),
            failure_points = cjson.encode(body.failure_points or {}),
            refrigerant_type = nullable(body.refrigerant_type or asset.refrigerant_type),
            refrigerant_added_kg = to_number(body.refrigerant_added_kg) or db.NULL,
            refrigerant_recovered_kg = to_number(body.refrigerant_recovered_kg) or db.NULL,
            leak_check_result = nullable(body.leak_check_result),
            notes = nullable(body.notes),
            recommendation = nullable(body.recommendation),
            created_by_uuid = actor_uuid,
            -- Simpro's API exposes test history read-only, so a survey recorded
            -- here stays local; its outcome reaches Simpro through the asset's
            -- condition fields, which the asset patch below queues for push.
            simpro_sync_state = "local_only",
        }, { returning = "*" })[1]

        -- Roll the asset's denormalised survey state forward.
        local asset_patch = {
            last_test_id = test.id,
            last_surveyed_at = tested_at or db.raw("NOW()"),
            updated_at = db.raw("NOW()"),
            simpro_sync_state = "pending",
        }
        if rating then
            asset_patch.condition_rating = rating
            if nilify(body.condition_notes) then
                asset_patch.condition_notes = body.condition_notes
            end
        end
        db.update("fs_assets", asset_patch, { id = asset.id })

        -- Advance the schedule this survey was against. Measured from the date
        -- of the visit rather than today, so a test back-dated after the fact
        -- still lands the next due date where the contract says it should.
        if level_id ~= db.NULL then
            local level = db.query(
                "SELECT frequency_months FROM fs_asset_service_levels WHERE id = ?", level_id)[1]
            local months = level and tonumber(level.frequency_months) or 12
            db.query([[
                UPDATE fs_asset_service_levels
                SET last_service_date = ?::date,
                    next_service_date = (?::date + (? || ' months')::interval)::date,
                    updated_at = NOW()
                WHERE id = ?
            ]], tested_at or os.date("!%Y-%m-%d"), tested_at or os.date("!%Y-%m-%d"), months, level_id)
        end

        -- A completed leak check resets the statutory clock.
        if nilify(body.leak_check_result) and asset.leak_check_months then
            db.query([[
                UPDATE fs_assets
                SET next_leak_check_at = (COALESCE(?::date, CURRENT_DATE)
                                          + (? || ' months')::interval)::date,
                    updated_at = NOW()
                WHERE id = ?
            ]], tested_at, asset.leak_check_months, asset.id)
        end

        if job_id ~= db.NULL then
            Common.log_activity(namespace_id, job_id, actor_uuid, "asset_tested",
                ("%s recorded on %s"):format(result, asset.asset_tag or asset.name),
                { asset_uuid = asset_uuid, result = result, condition_rating = rating })
        end

        local row = db.query([[
            SELECT th.*, j.job_number, j.uuid AS job_uuid, v.uuid AS visit_uuid,
                   sl.name AS service_level_name, a.uuid AS asset_uuid, a.asset_tag
            FROM fs_asset_test_history th
            JOIN fs_assets a      ON a.id = th.asset_id
            LEFT JOIN fs_jobs j   ON j.id = th.job_id
            LEFT JOIN fs_visits v ON v.id = th.visit_id
            LEFT JOIN fs_asset_service_levels sl ON sl.id = th.service_level_id
            WHERE th.id = ?
        ]], test.id)[1]
        return shape_test(row)
    end)
end

function AssetQueries.listTests(namespace_id, asset_uuid, params)
    params = params or {}
    local asset_id = Common.resolve_id("fs_assets", namespace_id, asset_uuid)
    if not asset_id then return nil, "Asset not found" end

    local page, per_page, offset = Common.paging(params)
    local rows = db.query([[
        SELECT th.*, j.job_number, j.uuid AS job_uuid, v.uuid AS visit_uuid,
               sl.name AS service_level_name, a.uuid AS asset_uuid, a.asset_tag
        FROM fs_asset_test_history th
        JOIN fs_assets a      ON a.id = th.asset_id
        LEFT JOIN fs_jobs j   ON j.id = th.job_id
        LEFT JOIN fs_visits v ON v.id = th.visit_id
        LEFT JOIN fs_asset_service_levels sl ON sl.id = th.service_level_id
        WHERE th.namespace_id = ? AND th.asset_id = ? AND th.deleted_at IS NULL
        ORDER BY th.tested_at DESC
        LIMIT ? OFFSET ?
    ]], namespace_id, asset_id, per_page, offset)

    local total = db.query([[
        SELECT COUNT(*) AS n FROM fs_asset_test_history
        WHERE namespace_id = ? AND asset_id = ? AND deleted_at IS NULL
    ]], namespace_id, asset_id)[1]

    local out = {}
    for _, r in ipairs(rows) do table.insert(out, shape_test(r)) end
    return { items = arr(out), meta = Common.meta(total and total.n, page, per_page) }
end

-- Exposed for lapis/spec/simpro-assets_spec.lua: the F-Gas interval rules are
-- the part of this module where a quiet mistake has regulatory consequences.
AssetQueries.GWP = GWP
AssetQueries.gwp_for = gwp_for
AssetQueries.leak_check_months = leak_check_months

return AssetQueries
