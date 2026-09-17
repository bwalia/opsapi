--[[
    Field Service — the Simpro report pack
    ======================================

    DBS publish a sample of the reports they run out of Simpro
    (dbs.uk.com/simpro, "3.0 Sample Simpro Reports.pdf"). This module reproduces
    that pack against the OpsAPI schema so a tenant sitting in front of Simpro
    gets the same numbers from the same shapes.

    The reports, in the order DBS present them:

      asset_failure_history   Failures per asset, filterable by customer, site,
                              asset type and date range.
      engineer_locations      Where every engineer is right now, and on what.
      asset_history           One asset's full maintenance and test history.
      labour_forecast         Booked and committed engineer hours per week.
      admin_efficiency        How long the desk takes to log, quote and invoice.
      response_times          Attendance against the contracted SLA.
      employee_licences       Licences held, and which expire soon.
      ppm_forecast            Programmed maintenance due, by site / type / contract.
      routine_maintenance     Was each PPM done in the month it was due? (SLA tool)
      fgas_register           Refrigerant held and moved — the statutory register.
      powerbi_extract         The flat denormalised feed the Power BI link reads.

    Every report returns the same envelope:

        { key, title, description, generated_at, filters, columns, rows, summary }

    `columns` carries {key, label, type} so a caller can render a table, a CSV
    or a PDF without knowing the report — that single shape is what lets the
    dashboard and the iOS app share one renderer, and what makes "exported in
    CSV/XL and connected to a Power BI Dashboard" true of all of them rather
    than of a hand-built few.

    Numeric `type` hints (money/number/hours) tell the CSV writer not to quote
    and the PDF writer to right-align.
]]

local db = require("lapis.db")
local Common = require("queries.FieldServiceCommon")

local Reports = {}

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Reports are read-only and take operator-supplied filters, so every value goes
-- through db.interpolate_query rather than string concatenation.
local function q(sql, ...)
    return db.query(db.interpolate_query(sql, ...))
end

--- Clamp a caller-supplied row cap. Reports are interactive, and an unbounded
--- LIMIT on a portfolio the size of DBS's Skanska contract will time out a
--- browser long before it times out Postgres.
local function row_limit(params)
    local n = tonumber(params and params.limit) or 500
    if n < 1 then n = 1 end
    if n > 5000 then n = 5000 end
    return n
end

--- Resolve a date window. Reports default to a rolling 12 months because that
--- is the window DBS's contract reviews use.
local function window(params)
    params = params or {}
    local from = params.date_from
    local to = params.date_to
    if not from or from == "" then
        from = os.date("!%Y-%m-%d", os.time() - 365 * 24 * 3600)
    end
    if not to or to == "" then
        to = os.date("!%Y-%m-%d")
    end
    return from, to
end

local function envelope(key, title, description, columns, rows, summary, filters)
    return {
        key = key,
        title = title,
        description = description,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        filters = filters or {},
        columns = columns,
        rows = rows or {},
        row_count = #(rows or {}),
        summary = summary or {},
    }
end

local function col(key, label, type_)
    return { key = key, label = label, type = type_ or "text" }
end

--- Build "AND <expr>" fragments for the optional filters every report shares,
--- so a customer/site/type filter behaves identically across the pack.
--- Returns the SQL fragment and the values to interpolate, in order.
local function common_filters(params, alias)
    params = params or {}
    local a = alias or {}
    local sql, values = "", {}

    if params.customer_uuid and params.customer_uuid ~= "" and a.customer then
        sql = sql .. (" AND %s.uuid = ?"):format(a.customer)
        table.insert(values, params.customer_uuid)
    end
    if params.site_uuid and params.site_uuid ~= "" and a.site then
        sql = sql .. (" AND %s.uuid::text = ?"):format(a.site)
        table.insert(values, params.site_uuid)
    end
    if params.asset_type_uuid and params.asset_type_uuid ~= "" and a.asset_type then
        sql = sql .. (" AND %s.uuid = ?"):format(a.asset_type)
        table.insert(values, params.asset_type_uuid)
    end
    if params.contract_uuid and params.contract_uuid ~= "" and a.contract then
        sql = sql .. (" AND %s.uuid = ?"):format(a.contract)
        table.insert(values, params.contract_uuid)
    end
    return sql, values
end

--- Interpolate a statement whose leading placeholders are fixed and whose
--- trailing ones come from common_filters(), keeping argument order honest.
local function q_with(sql, head_values, filter_values, tail_values)
    local args = {}
    for _, v in ipairs(head_values or {}) do table.insert(args, v) end
    for _, v in ipairs(filter_values or {}) do table.insert(args, v) end
    for _, v in ipairs(tail_values or {}) do table.insert(args, v) end
    return db.query(db.interpolate_query(sql, unpack(args)))
end

-- Customers came from ecommerce as first_name/last_name; Simpro-shaped rows set
-- company_name. Display should prefer the company and fall back cleanly.
local CUSTOMER_NAME = "COALESCE(NULLIF(c.company_name, ''), " ..
    "NULLIF(TRIM(CONCAT_WS(' ', c.first_name, c.last_name)), ''), 'Unknown customer')"

-- ---------------------------------------------------------------------------
-- 1. Asset failure history
-- ---------------------------------------------------------------------------
-- "This can be filtered by Customer, Site, Asset type and Date range."
function Reports.assetFailureHistory(namespace_id, params)
    params = params or {}
    local from, to = window(params)
    local fsql, fvals = common_filters(params, {
        customer = "c", site = "s", asset_type = "at", contract = "ct",
    })

    local rows = q_with([[
        SELECT
            a.uuid                              AS asset_uuid,
            a.asset_tag,
            a.name                              AS asset_name,
            COALESCE(at.name, 'Unclassified')   AS asset_type,
            s.name                              AS site_name,
            ]] .. CUSTOMER_NAME .. [[           AS customer_name,
            a.manufacturer,
            a.model,
            a.serial_number,
            a.condition_rating,
            COUNT(*) FILTER (WHERE th.result = 'fail')     AS failures,
            COUNT(*) FILTER (WHERE th.result = 'advisory') AS advisories,
            COUNT(*)                                       AS tests,
            MAX(th.tested_at) FILTER (WHERE th.result = 'fail') AS last_failure_at,
            MAX(th.tested_at)                              AS last_tested_at
        FROM fs_asset_test_history th
        JOIN fs_assets a       ON a.id = th.asset_id AND a.deleted_at IS NULL
        LEFT JOIN fs_sites s   ON s.id = a.site_id
        LEFT JOIN customers c  ON c.id = a.customer_id
        LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
        LEFT JOIN fs_contracts ct   ON ct.id = a.contract_id
        WHERE th.namespace_id = ?
          AND th.deleted_at IS NULL
          AND th.tested_at >= ?::date
          AND th.tested_at < (?::date + INTERVAL '1 day')
          ]] .. fsql .. [[
        GROUP BY a.uuid, a.asset_tag, a.name, at.name, s.name,
                 c.company_name, c.first_name, c.last_name,
                 a.manufacturer, a.model, a.serial_number, a.condition_rating
        HAVING COUNT(*) FILTER (WHERE th.result IN ('fail', 'advisory')) > 0
        ORDER BY failures DESC, advisories DESC, last_failure_at DESC NULLS LAST
        LIMIT ?
    ]], { namespace_id, from, to }, fvals, { row_limit(params) })

    local total_failures, total_tests = 0, 0
    for _, r in ipairs(rows) do
        total_failures = total_failures + (tonumber(r.failures) or 0)
        total_tests = total_tests + (tonumber(r.tests) or 0)
    end

    return envelope("asset_failure_history", "Asset failure history",
        "Assets that failed or raised an advisory in the period, worst first.", {
            col("asset_tag", "Asset"), col("asset_name", "Description"),
            col("asset_type", "Type"), col("site_name", "Site"),
            col("customer_name", "Customer"), col("manufacturer", "Manufacturer"),
            col("model", "Model"), col("serial_number", "Serial"),
            col("condition_rating", "Condition", "number"),
            col("failures", "Failures", "number"), col("advisories", "Advisories", "number"),
            col("tests", "Tests", "number"), col("last_failure_at", "Last failure", "datetime"),
        }, rows, {
            assets_with_failures = #rows,
            total_failures = total_failures,
            total_tests = total_tests,
            failure_rate_pct = total_tests > 0
                and Common.round2(total_failures * 100.0 / total_tests) or 0,
        }, { date_from = from, date_to = to })
end

-- ---------------------------------------------------------------------------
-- 2. Engineer locations
-- ---------------------------------------------------------------------------
-- "Real time interactive Map of current engineer locations. Being interactive we
--  are able to open the job being carried out and see a real time update on its
--  status."
function Reports.engineerLocations(namespace_id, params)
    -- On-site wins over next-booked, so an engineer appears once, showing the
    -- most operationally interesting visit.
    local rows = q([[
        WITH ranked AS (
            SELECT
                v.uuid              AS visit_uuid,
                v.engineer_user_uuid,
                v.status,
                v.scheduled_start,
                v.checked_in_at,
                v.check_in_lat,
                v.check_in_lng,
                v.is_out_of_hours,
                j.uuid              AS job_uuid,
                j.job_number,
                j.title             AS job_title,
                j.priority,
                s.name              AS site_name,
                s.city              AS site_city,
                s.postal_code,
                COALESCE(s.latitude, v.check_in_lat)   AS latitude,
                COALESCE(s.longitude, v.check_in_lng)  AS longitude,
                ]] .. CUSTOMER_NAME .. [[              AS customer_name,
                ROW_NUMBER() OVER (
                    PARTITION BY v.engineer_user_uuid
                    ORDER BY
                        CASE v.status
                            WHEN 'on_site'  THEN 0
                            WHEN 'en_route' THEN 1
                            WHEN 'scheduled'   THEN 2
                            ELSE 3
                        END,
                        v.scheduled_start
                ) AS rn
            FROM fs_visits v
            JOIN fs_jobs j        ON j.id = v.job_id AND j.deleted_at IS NULL
            LEFT JOIN fs_sites s  ON s.id = j.site_id
            LEFT JOIN customers c ON c.id = j.customer_id
            WHERE v.namespace_id = ?
              AND v.deleted_at IS NULL
              AND v.status IN ('scheduled', 'en_route', 'on_site')
              AND v.scheduled_start >= (NOW() - INTERVAL '12 hours')
              AND v.scheduled_start <  (NOW() + INTERVAL '36 hours')
        )
        SELECT r.*,
               TRIM(CONCAT_WS(' ', u.first_name, u.last_name)) AS engineer_name,
               e.employee_code,
               e.phone AS engineer_phone
        FROM ranked r
        LEFT JOIN users u     ON u.uuid = r.engineer_user_uuid
        LEFT JOIN employees e ON e.user_uuid = r.engineer_user_uuid
                             AND e.namespace_id = ?
                             AND e.deleted_at IS NULL
        WHERE r.rn = 1
        ORDER BY
            CASE r.status WHEN 'on_site' THEN 0 WHEN 'en_route' THEN 1 ELSE 2 END,
            r.scheduled_start
        LIMIT ?
    ]], namespace_id, namespace_id, row_limit(params))

    local on_site, travelling, booked = 0, 0, 0
    for _, r in ipairs(rows) do
        if r.status == "on_site" then on_site = on_site + 1
        elseif r.status == "en_route" then travelling = travelling + 1
        else booked = booked + 1 end
    end

    return envelope("engineer_locations", "Engineer locations",
        "Where each engineer is now and the job they are on. Rows carry lat/lng for the map.", {
            col("engineer_name", "Engineer"), col("employee_code", "Code"),
            col("status", "Status"), col("job_number", "Job"),
            col("job_title", "Work"), col("customer_name", "Customer"),
            col("site_name", "Site"), col("postal_code", "Postcode"),
            col("scheduled_start", "Booked", "datetime"),
            col("checked_in_at", "On site since", "datetime"),
            col("latitude", "Lat", "number"), col("longitude", "Lng", "number"),
        }, rows, {
            engineers = #rows, on_site = on_site,
            travelling = travelling, booked = booked,
        })
end

-- ---------------------------------------------------------------------------
-- 3. Detailed asset history
-- ---------------------------------------------------------------------------
-- "By looking at an individual asset we can see all historical maintenance
--  visits as a snapshot."
function Reports.assetHistory(namespace_id, params)
    params = params or {}
    if not params.asset_uuid or params.asset_uuid == "" then
        return nil, "asset_uuid is required for the asset history report"
    end

    local asset = q([[
        SELECT a.*, s.name AS site_name, s.address_line1, s.city, s.postal_code,
               at.name AS asset_type, at.is_fgas,
               ct.name AS contract_name, ct.contract_number,
               ]] .. CUSTOMER_NAME .. [[ AS customer_name
        FROM fs_assets a
        LEFT JOIN fs_sites s        ON s.id = a.site_id
        LEFT JOIN customers c       ON c.id = a.customer_id
        LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
        LEFT JOIN fs_contracts ct   ON ct.id = a.contract_id
        WHERE a.namespace_id = ? AND a.uuid = ? AND a.deleted_at IS NULL
        LIMIT 1
    ]], namespace_id, params.asset_uuid)[1]

    if not asset then return nil, "Asset not found" end

    local rows = q([[
        SELECT
            th.uuid,
            th.tested_at,
            th.result,
            th.condition_rating,
            th.technician_name,
            th.readings,
            th.failure_points,
            th.refrigerant_type,
            th.refrigerant_added_kg,
            th.refrigerant_recovered_kg,
            th.leak_check_result,
            th.notes,
            th.recommendation,
            j.job_number,
            j.title       AS job_title,
            j.kind        AS job_kind,
            sl.name       AS service_level,
            v.labour_hours
        FROM fs_asset_test_history th
        LEFT JOIN fs_jobs j   ON j.id = th.job_id
        LEFT JOIN fs_visits v ON v.id = th.visit_id
        LEFT JOIN fs_asset_service_levels sl ON sl.id = th.service_level_id
        WHERE th.namespace_id = ? AND th.asset_id = ? AND th.deleted_at IS NULL
        ORDER BY th.tested_at DESC
        LIMIT ?
    ]], namespace_id, asset.id, row_limit(params))

    local service_levels = q([[
        SELECT name, kind, frequency_months, last_service_date, next_service_date, is_active
        FROM fs_asset_service_levels
        WHERE namespace_id = ? AND asset_id = ? AND deleted_at IS NULL
        ORDER BY next_service_date NULLS LAST
    ]], namespace_id, asset.id)

    local failures = 0
    for _, r in ipairs(rows) do
        if r.result == "fail" then failures = failures + 1 end
    end

    local env = envelope("asset_history", "Asset history",
        "Every recorded visit against one asset, newest first.", {
            col("tested_at", "Date", "datetime"), col("job_number", "Job"),
            col("job_title", "Work"), col("service_level", "Service level"),
            col("technician_name", "Engineer"), col("result", "Result"),
            col("condition_rating", "Condition", "number"),
            col("labour_hours", "Hours", "hours"),
            col("refrigerant_type", "Refrigerant"),
            col("refrigerant_added_kg", "Added kg", "number"),
            col("refrigerant_recovered_kg", "Recovered kg", "number"),
            col("leak_check_result", "Leak check"),
            col("recommendation", "Recommendation"),
        }, rows, {
            visits = #rows,
            failures = failures,
            condition_rating = asset.condition_rating,
            last_surveyed_at = asset.last_surveyed_at,
        }, { asset_uuid = params.asset_uuid })

    -- The asset card and its schedule ride alongside the rows: the printed
    -- version of this report leads with them.
    env.asset = {
        uuid = asset.uuid, asset_tag = asset.asset_tag, name = asset.name,
        asset_type = asset.asset_type, manufacturer = asset.manufacturer,
        model = asset.model, serial_number = asset.serial_number,
        product_number = asset.product_number, installed_at = asset.installed_at,
        location_detail = asset.location_detail, condition_rating = asset.condition_rating,
        condition_notes = asset.condition_notes,
        refrigerant_type = asset.refrigerant_type,
        refrigerant_charge_kg = asset.refrigerant_charge_kg,
        site_name = asset.site_name, customer_name = asset.customer_name,
        postal_code = asset.postal_code,
        contract_name = asset.contract_name, contract_number = asset.contract_number,
    }
    env.service_levels = service_levels
    return env
end

-- ---------------------------------------------------------------------------
-- 4. Labour forecast
-- ---------------------------------------------------------------------------
function Reports.labourForecast(namespace_id, params)
    params = params or {}
    local weeks = math.min(math.max(tonumber(params.weeks) or 8, 1), 52)

    local rows = q([[
        SELECT
            TO_CHAR(DATE_TRUNC('week', v.scheduled_start), 'YYYY-MM-DD') AS week_starting,
            COUNT(*)                                             AS visits,
            COUNT(DISTINCT v.engineer_user_uuid)                 AS engineers,
            ROUND(SUM(COALESCE(
                EXTRACT(EPOCH FROM (v.scheduled_end - v.scheduled_start)) / 3600.0,
                2))::numeric, 2)                                 AS booked_hours,
            ROUND(SUM(CASE WHEN v.is_out_of_hours THEN COALESCE(
                EXTRACT(EPOCH FROM (v.scheduled_end - v.scheduled_start)) / 3600.0,
                2) ELSE 0 END)::numeric, 2)                      AS out_of_hours,
            COUNT(*) FILTER (WHERE j.kind = 'project')           AS project_visits,
            COUNT(*) FILTER (WHERE j.kind IN ('service', 'callout')) AS service_visits,
            COUNT(*) FILTER (WHERE j.kind = 'maintenance')      AS ppm_visits
        FROM fs_visits v
        JOIN fs_jobs j ON j.id = v.job_id AND j.deleted_at IS NULL
        WHERE v.namespace_id = ?
          AND v.deleted_at IS NULL
          AND v.status NOT IN ('cancelled', 'no_access')
          AND v.scheduled_start >= DATE_TRUNC('week', NOW())
          AND v.scheduled_start <  DATE_TRUNC('week', NOW()) + (? || ' weeks')::interval
        GROUP BY 1
        ORDER BY 1
    ]], namespace_id, weeks)

    -- Capacity to compare the booked hours against: active engineers x 37.5h.
    local cap = q([[
        SELECT COUNT(*) AS engineers
        FROM employees
        WHERE namespace_id = ? AND is_engineer AND is_active AND deleted_at IS NULL
    ]], namespace_id)[1]
    local engineers = tonumber(cap and cap.engineers) or 0
    local weekly_capacity = engineers * 37.5

    local booked = 0
    for _, r in ipairs(rows) do
        r.capacity_hours = weekly_capacity
        r.utilisation_pct = weekly_capacity > 0
            and Common.round2((tonumber(r.booked_hours) or 0) * 100.0 / weekly_capacity) or 0
        booked = booked + (tonumber(r.booked_hours) or 0)
    end

    return envelope("labour_forecast", "Labour forecast",
        "Booked engineer hours per week against available capacity.", {
            col("week_starting", "Week starting", "date"),
            col("visits", "Visits", "number"),
            col("engineers", "Engineers", "number"),
            col("booked_hours", "Booked hours", "hours"),
            col("capacity_hours", "Capacity", "hours"),
            col("utilisation_pct", "Utilisation %", "number"),
            col("out_of_hours", "Out of hours", "hours"),
            col("ppm_visits", "PPM", "number"),
            col("service_visits", "Service", "number"),
            col("project_visits", "Project", "number"),
        }, rows, {
            weeks = weeks,
            engineers = engineers,
            weekly_capacity_hours = weekly_capacity,
            total_booked_hours = Common.round2(booked),
        })
end

-- ---------------------------------------------------------------------------
-- 5. Administration efficiency
-- ---------------------------------------------------------------------------
-- How long the desk takes at each hand-off. DBS commit to a 48-hour turnaround
-- on reports and remedial quotations, so that is the bar these columns are read
-- against.
function Reports.adminEfficiency(namespace_id, params)
    params = params or {}
    local from, to = window(params)

    local rows = q([[
        SELECT
            TO_CHAR(DATE_TRUNC('month', r.created_at), 'YYYY-MM')  AS month,
            COUNT(*)                                               AS requests,
            ROUND(AVG(EXTRACT(EPOCH FROM (r.first_response_at - r.created_at))
                      / 3600.0)::numeric, 1)                       AS avg_first_response_h,
            ROUND(AVG(EXTRACT(EPOCH FROM (r.resolved_at - r.created_at))
                      / 3600.0)::numeric, 1)                       AS avg_resolve_h,
            COUNT(*) FILTER (WHERE r.first_response_at IS NULL
                             AND r.status NOT IN ('closed', 'cancelled')) AS unacknowledged,
            ROUND(AVG(EXTRACT(EPOCH FROM (q.sent_at - q.created_at))
                      / 3600.0)::numeric, 1)                       AS avg_quote_turnaround_h,
            COUNT(q.id)                                            AS quotes_sent,
            COUNT(q.id) FILTER (
                WHERE q.sent_at IS NOT NULL
                  AND q.sent_at - q.created_at <= INTERVAL '48 hours')  AS quotes_within_48h
        FROM fs_service_requests r
        LEFT JOIN fs_quotes q ON q.service_request_id = r.id AND q.deleted_at IS NULL
        WHERE r.namespace_id = ?
          AND r.deleted_at IS NULL
          AND r.created_at >= ?::date
          AND r.created_at <  (?::date + INTERVAL '1 day')
        GROUP BY 1
        ORDER BY 1 DESC
    ]], namespace_id, from, to)

    -- Invoicing lag is a separate grain (jobs, not requests), so it is measured
    -- on its own and merged onto the month rows.
    local billing = q([[
        SELECT
            TO_CHAR(DATE_TRUNC('month', j.completed_at), 'YYYY-MM') AS month,
            COUNT(*) FILTER (WHERE j.invoiced_at IS NOT NULL)       AS jobs_invoiced,
            ROUND(AVG(EXTRACT(EPOCH FROM (j.invoiced_at - j.completed_at))
                      / 86400.0)::numeric, 1)                       AS avg_days_to_invoice,
            COUNT(*) FILTER (WHERE j.completed_at IS NOT NULL
                             AND j.invoiced_at IS NULL)             AS awaiting_invoice
        FROM fs_jobs j
        WHERE j.namespace_id = ?
          AND j.deleted_at IS NULL
          AND j.completed_at >= ?::date
          AND j.completed_at <  (?::date + INTERVAL '1 day')
        GROUP BY 1
    ]], namespace_id, from, to)

    local by_month = {}
    for _, b in ipairs(billing) do by_month[b.month] = b end
    for _, r in ipairs(rows) do
        local b = by_month[r.month]
        r.jobs_invoiced = b and b.jobs_invoiced or 0
        r.avg_days_to_invoice = b and b.avg_days_to_invoice or nil
        r.awaiting_invoice = b and b.awaiting_invoice or 0
        local sent = tonumber(r.quotes_sent) or 0
        r.quote_sla_pct = sent > 0
            and Common.round2((tonumber(r.quotes_within_48h) or 0) * 100.0 / sent) or nil
    end

    return envelope("admin_efficiency", "Administration efficiency",
        "Desk turnaround by month: acknowledgement, quotation and invoicing.", {
            col("month", "Month"), col("requests", "Requests", "number"),
            col("avg_first_response_h", "Avg ack (h)", "number"),
            col("avg_resolve_h", "Avg resolve (h)", "number"),
            col("unacknowledged", "Unacknowledged", "number"),
            col("quotes_sent", "Quotes sent", "number"),
            col("avg_quote_turnaround_h", "Avg quote (h)", "number"),
            col("quote_sla_pct", "Quotes in 48h %", "number"),
            col("jobs_invoiced", "Jobs invoiced", "number"),
            col("avg_days_to_invoice", "Avg days to invoice", "number"),
            col("awaiting_invoice", "Awaiting invoice", "number"),
        }, rows, { months = #rows }, { date_from = from, date_to = to })
end

-- ---------------------------------------------------------------------------
-- 6. Response times
-- ---------------------------------------------------------------------------
-- Attendance against the SLA carried on the request (set from the contract).
function Reports.responseTimes(namespace_id, params)
    params = params or {}
    local from, to = window(params)
    local fsql, fvals = common_filters(params, { customer = "c", site = "s", contract = "ct" })

    local rows = q_with([[
        SELECT
            r.request_number,
            r.title,
            r.priority,
            r.fault_category,
            ]] .. CUSTOMER_NAME .. [[   AS customer_name,
            s.name                      AS site_name,
            ct.name                     AS contract_name,
            r.created_at                AS logged_at,
            r.sla_response_due_at,
            first_visit.attended_at,
            r.resolved_at,
            ROUND(EXTRACT(EPOCH FROM (first_visit.attended_at - r.created_at))
                  / 3600.0, 1)          AS response_hours,
            ROUND(EXTRACT(EPOCH FROM (r.resolved_at - r.created_at))
                  / 3600.0, 1)          AS resolve_hours,
            CASE
                WHEN first_visit.attended_at IS NULL THEN 'not attended'
                WHEN r.sla_response_due_at IS NULL   THEN 'no sla'
                WHEN first_visit.attended_at <= r.sla_response_due_at THEN 'met'
                ELSE 'breached'
            END                         AS sla_result
        FROM fs_service_requests r
        LEFT JOIN customers c   ON c.id = r.customer_id
        LEFT JOIN fs_sites s    ON s.id = r.site_id
        LEFT JOIN fs_jobs j     ON j.service_request_id = r.id AND j.deleted_at IS NULL
        LEFT JOIN fs_contracts ct ON ct.id = j.contract_id
        LEFT JOIN LATERAL (
            SELECT MIN(COALESCE(v.checked_in_at, v.scheduled_start)) AS attended_at
            FROM fs_visits v
            WHERE v.job_id = j.id AND v.deleted_at IS NULL AND v.status <> 'cancelled'
        ) first_visit ON TRUE
        WHERE r.namespace_id = ?
          AND r.deleted_at IS NULL
          AND r.created_at >= ?::date
          AND r.created_at <  (?::date + INTERVAL '1 day')
          ]] .. fsql .. [[
        ORDER BY r.created_at DESC
        LIMIT ?
    ]], { namespace_id, from, to }, fvals, { row_limit(params) })

    local met, breached, unattended = 0, 0, 0
    for _, r in ipairs(rows) do
        if r.sla_result == "met" then met = met + 1
        elseif r.sla_result == "breached" then breached = breached + 1
        elseif r.sla_result == "not attended" then unattended = unattended + 1 end
    end
    local measured = met + breached

    return envelope("response_times", "Response times",
        "Attendance against the contracted response SLA.", {
            col("request_number", "Request"), col("title", "Fault"),
            col("customer_name", "Customer"), col("site_name", "Site"),
            col("contract_name", "Contract"), col("priority", "Priority"),
            col("logged_at", "Logged", "datetime"),
            col("sla_response_due_at", "Due by", "datetime"),
            col("attended_at", "Attended", "datetime"),
            col("response_hours", "Response (h)", "number"),
            col("resolve_hours", "Resolve (h)", "number"),
            col("sla_result", "SLA"),
        }, rows, {
            requests = #rows, met = met, breached = breached, not_attended = unattended,
            sla_pct = measured > 0 and Common.round2(met * 100.0 / measured) or nil,
        }, { date_from = from, date_to = to })
end

-- ---------------------------------------------------------------------------
-- 7. Employee licences
-- ---------------------------------------------------------------------------
-- "This enables us to track license types per employee and have a trigger for
--  when they are due to expire."
function Reports.employeeLicences(namespace_id, params)
    params = params or {}
    local horizon = math.min(math.max(tonumber(params.expiring_within_days) or 90, 1), 730)

    local rows = q([[
        SELECT
            TRIM(CONCAT_WS(' ', u.first_name, u.last_name)) AS employee_name,
            e.employee_code,
            e.job_title,
            e.team,
            e.is_engineer,
            e.is_apprentice,
            l.licence_type,
            l.licence_number,
            l.issuing_body,
            l.issued_on,
            l.expires_on,
            (l.expires_on - CURRENT_DATE)  AS days_remaining,
            CASE
                WHEN l.expires_on IS NULL                       THEN 'no expiry'
                WHEN l.expires_on < CURRENT_DATE                THEN 'expired'
                WHEN l.expires_on <= CURRENT_DATE + (? || ' days')::interval THEN 'expiring'
                ELSE 'valid'
            END                             AS state
        FROM employee_licences l
        JOIN employees e  ON e.id = l.employee_id AND e.deleted_at IS NULL
        LEFT JOIN users u ON u.uuid = e.user_uuid
        WHERE l.namespace_id = ? AND l.deleted_at IS NULL
        ORDER BY
            CASE
                WHEN l.expires_on IS NULL        THEN 2
                WHEN l.expires_on < CURRENT_DATE THEN 0
                ELSE 1
            END,
            l.expires_on NULLS LAST
        LIMIT ?
    ]], horizon, namespace_id, row_limit(params))

    local expired, expiring = 0, 0
    for _, r in ipairs(rows) do
        if r.state == "expired" then expired = expired + 1
        elseif r.state == "expiring" then expiring = expiring + 1 end
    end

    return envelope("employee_licences", "Employee licences",
        ("Licences held, flagged when expired or due within %d days."):format(horizon), {
            col("employee_name", "Employee"), col("employee_code", "Code"),
            col("job_title", "Role"), col("team", "Team"),
            col("licence_type", "Licence"), col("licence_number", "Number"),
            col("issuing_body", "Issued by"), col("issued_on", "Issued", "date"),
            col("expires_on", "Expires", "date"),
            col("days_remaining", "Days left", "number"), col("state", "State"),
        }, rows, {
            licences = #rows, expired = expired, expiring = expiring,
            horizon_days = horizon,
        }, { expiring_within_days = horizon })
end

-- ---------------------------------------------------------------------------
-- 8. PPM forecast
-- ---------------------------------------------------------------------------
-- "This enables us to see the future PPM requirements by site and by asset type.
--  We can also show it linked to a specific contract where a client's site may
--  have multiple contracts across it."
function Reports.ppmForecast(namespace_id, params)
    params = params or {}
    local months = math.min(math.max(tonumber(params.months) or 6, 1), 36)
    local fsql, fvals = common_filters(params, {
        customer = "c", site = "s", asset_type = "at", contract = "ct",
    })

    local rows = q_with([[
        SELECT
            TO_CHAR(DATE_TRUNC('month', sl.next_service_date), 'YYYY-MM') AS due_month,
            sl.next_service_date,
            sl.name                             AS service_level,
            sl.kind,
            sl.frequency_months,
            sl.estimated_hours,
            a.uuid                              AS asset_uuid,
            a.asset_tag,
            a.name                              AS asset_name,
            COALESCE(at.name, 'Unclassified')   AS asset_type,
            s.name                              AS site_name,
            s.postal_code,
            ]] .. CUSTOMER_NAME .. [[           AS customer_name,
            COALESCE(ct.name, 'No contract')    AS contract_name,
            ct.contract_number,
            sl.last_service_date,
            CASE WHEN sl.next_service_date < CURRENT_DATE THEN TRUE ELSE FALSE END AS overdue
        FROM fs_asset_service_levels sl
        JOIN fs_assets a       ON a.id = sl.asset_id AND a.deleted_at IS NULL
                              AND a.archived = FALSE AND a.status = 'active'
        LEFT JOIN fs_sites s   ON s.id = a.site_id
        LEFT JOIN customers c  ON c.id = a.customer_id
        LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
        LEFT JOIN fs_contracts ct   ON ct.id = COALESCE(sl.contract_id, a.contract_id)
        WHERE sl.namespace_id = ?
          AND sl.deleted_at IS NULL
          AND sl.is_active
          AND sl.next_service_date IS NOT NULL
          AND sl.next_service_date < (CURRENT_DATE + (? || ' months')::interval)
          ]] .. fsql .. [[
        ORDER BY sl.next_service_date, s.name, a.asset_tag
        LIMIT ?
    ]], { namespace_id, months }, fvals, { row_limit(params) })

    local overdue, hours = 0, 0
    local by_month = {}
    for _, r in ipairs(rows) do
        if r.overdue then overdue = overdue + 1 end
        hours = hours + (tonumber(r.estimated_hours) or 0)
        by_month[r.due_month] = (by_month[r.due_month] or 0) + 1
    end

    return envelope("ppm_forecast", "Programmed maintenance forecast",
        ("Planned maintenance falling due in the next %d months, by site, asset type and contract.")
            :format(months), {
            col("due_month", "Due month"), col("next_service_date", "Due", "date"),
            col("customer_name", "Customer"), col("site_name", "Site"),
            col("contract_name", "Contract"), col("asset_tag", "Asset"),
            col("asset_name", "Description"), col("asset_type", "Type"),
            col("service_level", "Service level"),
            col("frequency_months", "Every (months)", "number"),
            col("last_service_date", "Last done", "date"),
            col("estimated_hours", "Est. hours", "hours"),
            col("overdue", "Overdue"),
        }, rows, {
            due = #rows, overdue = overdue,
            estimated_hours = Common.round2(hours),
            months = months, by_month = by_month,
        }, { months = months })
end

-- ---------------------------------------------------------------------------
-- 9. Routine maintenance performance
-- ---------------------------------------------------------------------------
-- "This enables us to report on how many maintenances were carried out in the
--  month they were due. It will be able to be used as an SLA reporting tool."
function Reports.routineMaintenance(namespace_id, params)
    params = params or {}
    local from, to = window(params)

    local rows = q([[
        WITH done AS (
            SELECT
                th.id,
                th.tested_at,
                th.due_date          AS was_due,
                sl.name              AS service_level,
                a.asset_tag,
                s.name               AS site_name,
                ct.name              AS contract_name,
                ]] .. CUSTOMER_NAME .. [[ AS customer_name
            FROM fs_asset_test_history th
            JOIN fs_assets a  ON a.id = th.asset_id AND a.deleted_at IS NULL
            JOIN fs_asset_service_levels sl ON sl.id = th.service_level_id
            LEFT JOIN fs_sites s  ON s.id = a.site_id
            LEFT JOIN customers c ON c.id = a.customer_id
            LEFT JOIN fs_contracts ct ON ct.id = COALESCE(sl.contract_id, a.contract_id)
            WHERE th.namespace_id = ?
              AND th.deleted_at IS NULL
              AND th.service_level_id IS NOT NULL
              AND th.tested_at >= ?::date
              AND th.tested_at <  (?::date + INTERVAL '1 day')
        )
        SELECT
            TO_CHAR(DATE_TRUNC('month', tested_at), 'YYYY-MM')  AS month,
            COUNT(*)                                            AS completed,
            COUNT(*) FILTER (
                WHERE was_due IS NOT NULL
                  AND DATE_TRUNC('month', tested_at) = DATE_TRUNC('month', was_due)
            )                                                   AS on_time,
            COUNT(*) FILTER (
                WHERE was_due IS NOT NULL
                  AND DATE_TRUNC('month', tested_at) > DATE_TRUNC('month', was_due)
            )                                                   AS late,
            COUNT(*) FILTER (
                WHERE was_due IS NOT NULL
                  AND DATE_TRUNC('month', tested_at) < DATE_TRUNC('month', was_due)
            )                                                   AS early,
            COUNT(DISTINCT site_name)                           AS sites
        FROM done
        GROUP BY 1
        ORDER BY 1 DESC
    ]], namespace_id, from, to)

    local completed, on_time = 0, 0
    for _, r in ipairs(rows) do
        local c, o = tonumber(r.completed) or 0, tonumber(r.on_time) or 0
        completed = completed + c
        on_time = on_time + o
        r.on_time_pct = c > 0 and Common.round2(o * 100.0 / c) or 0
    end

    return envelope("routine_maintenance", "Routine maintenance performance",
        "Planned maintenance completed in the month it fell due — the contract SLA measure.", {
            col("month", "Month"), col("completed", "Completed", "number"),
            col("on_time", "In due month", "number"),
            col("late", "Late", "number"), col("early", "Early", "number"),
            col("on_time_pct", "On time %", "number"),
            col("sites", "Sites", "number"),
        }, rows, {
            completed = completed, on_time = on_time,
            on_time_pct = completed > 0 and Common.round2(on_time * 100.0 / completed) or 0,
        }, { date_from = from, date_to = to })
end

-- ---------------------------------------------------------------------------
-- 10. F-Gas register
-- ---------------------------------------------------------------------------
-- The statutory record: what refrigerant sits in each system, what moved, and
-- when the next leak check falls due. CO2e (charge x GWP, in tonnes) is what
-- sets the leak-check interval under the UK F-Gas regulations.
function Reports.fgasRegister(namespace_id, params)
    params = params or {}
    local from, to = window(params)
    local fsql, fvals = common_filters(params, { customer = "c", site = "s", asset_type = "at" })

    local rows = q_with([[
        SELECT
            a.uuid                              AS asset_uuid,
            a.asset_tag,
            a.name                              AS asset_name,
            COALESCE(at.name, 'Unclassified')   AS asset_type,
            s.name                              AS site_name,
            s.postal_code,
            ]] .. CUSTOMER_NAME .. [[           AS customer_name,
            a.manufacturer,
            a.model,
            a.serial_number,
            a.refrigerant_type,
            a.refrigerant_charge_kg,
            a.refrigerant_gwp,
            ROUND((COALESCE(a.refrigerant_charge_kg, 0)
                   * COALESCE(a.refrigerant_gwp, 0) / 1000.0)::numeric, 2) AS co2e_tonnes,
            a.hermetically_sealed,
            a.leak_check_months,
            a.next_leak_check_at,
            CASE WHEN a.next_leak_check_at < CURRENT_DATE THEN TRUE ELSE FALSE END AS check_overdue,
            COALESCE(mv.added_kg, 0)      AS added_kg,
            COALESCE(mv.recovered_kg, 0)  AS recovered_kg,
            mv.last_leak_check_at,
            mv.last_leak_check_result
        FROM fs_assets a
        LEFT JOIN fs_sites s   ON s.id = a.site_id
        LEFT JOIN customers c  ON c.id = a.customer_id
        LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
        LEFT JOIN LATERAL (
            SELECT
                SUM(COALESCE(th.refrigerant_added_kg, 0))     AS added_kg,
                SUM(COALESCE(th.refrigerant_recovered_kg, 0)) AS recovered_kg,
                MAX(th.tested_at) FILTER (WHERE th.leak_check_result IS NOT NULL)
                                                              AS last_leak_check_at,
                (ARRAY_AGG(th.leak_check_result ORDER BY th.tested_at DESC)
                    FILTER (WHERE th.leak_check_result IS NOT NULL))[1]
                                                              AS last_leak_check_result
            FROM fs_asset_test_history th
            WHERE th.asset_id = a.id
              AND th.deleted_at IS NULL
              AND th.tested_at >= ?::date
              AND th.tested_at <  (?::date + INTERVAL '1 day')
        ) mv ON TRUE
        WHERE a.namespace_id = ?
          AND a.deleted_at IS NULL
          AND a.archived = FALSE
          AND a.refrigerant_type IS NOT NULL
          ]] .. fsql .. [[
        ORDER BY co2e_tonnes DESC, s.name, a.asset_tag
        LIMIT ?
    ]], { from, to, namespace_id }, fvals, { row_limit(params) })

    local charge, added, recovered, overdue, co2e = 0, 0, 0, 0, 0
    for _, r in ipairs(rows) do
        charge = charge + (tonumber(r.refrigerant_charge_kg) or 0)
        added = added + (tonumber(r.added_kg) or 0)
        recovered = recovered + (tonumber(r.recovered_kg) or 0)
        co2e = co2e + (tonumber(r.co2e_tonnes) or 0)
        if r.check_overdue then overdue = overdue + 1 end
    end

    return envelope("fgas_register", "F-Gas register",
        "Refrigerant held and moved per system, with leak-check status. " ..
        "CO2e drives the statutory check interval.", {
            col("asset_tag", "Asset"), col("asset_name", "Description"),
            col("asset_type", "Type"), col("customer_name", "Customer"),
            col("site_name", "Site"), col("manufacturer", "Manufacturer"),
            col("model", "Model"), col("serial_number", "Serial"),
            col("refrigerant_type", "Refrigerant"),
            col("refrigerant_charge_kg", "Charge kg", "number"),
            col("refrigerant_gwp", "GWP", "number"),
            col("co2e_tonnes", "tCO2e", "number"),
            col("added_kg", "Added kg", "number"),
            col("recovered_kg", "Recovered kg", "number"),
            col("last_leak_check_at", "Last check", "datetime"),
            col("last_leak_check_result", "Result"),
            col("next_leak_check_at", "Next check", "date"),
            col("check_overdue", "Overdue"),
        }, rows, {
            systems = #rows,
            total_charge_kg = Common.round2(charge),
            total_added_kg = Common.round2(added),
            total_recovered_kg = Common.round2(recovered),
            total_co2e_tonnes = Common.round2(co2e),
            checks_overdue = overdue,
        }, { date_from = from, date_to = to })
end

-- ---------------------------------------------------------------------------
-- 11. Power BI extract
-- ---------------------------------------------------------------------------
-- "We have a live connection between Simpro and Microsoft PowerBi which allows
--  us to build bespoke dashboards." One wide, flat, already-joined row per
--  visit is what a BI tool wants — it can pivot everything else itself.
function Reports.powerbiExtract(namespace_id, params)
    params = params or {}
    local from, to = window(params)

    local rows = q([[
        SELECT
            v.uuid                          AS visit_uuid,
            v.scheduled_start,
            v.checked_in_at,
            v.checked_out_at,
            v.status                        AS visit_status,
            v.labour_hours,
            v.is_billable,
            v.is_out_of_hours,
            -- Visits rarely carry their own rate; fall back to the job's, then the
            -- job type's default, which is what the invoice would have used.
            COALESCE(v.hourly_rate, j.hourly_rate, jt.default_hourly_rate) AS hourly_rate,
            ROUND((COALESCE(v.labour_hours, 0)
                   * COALESCE(v.hourly_rate, j.hourly_rate, jt.default_hourly_rate, 0))::numeric, 2)
                                            AS labour_value,
            j.job_number,
            j.title                         AS job_title,
            j.kind                          AS job_kind,
            j.stage                         AS job_stage,
            j.status                        AS job_status,
            j.priority,
            jt.name                         AS job_type,
            ]] .. CUSTOMER_NAME .. [[       AS customer_name,
            c.customer_group,
            s.name                          AS site_name,
            s.city                          AS site_city,
            s.postal_code,
            s.zone,
            ct.name                         AS contract_name,
            ct.contract_number,
            a.asset_tag,
            at.name                         AS asset_type,
            at.discipline,
            TRIM(CONCAT_WS(' ', u.first_name, u.last_name)) AS engineer_name,
            e.team,
            th.result                       AS test_result,
            th.condition_rating,
            th.refrigerant_added_kg,
            th.refrigerant_recovered_kg
        FROM fs_visits v
        JOIN fs_jobs j           ON j.id = v.job_id AND j.deleted_at IS NULL
        LEFT JOIN fs_job_types jt ON jt.id = j.job_type_id
        LEFT JOIN customers c    ON c.id = j.customer_id
        LEFT JOIN fs_sites s     ON s.id = j.site_id
        LEFT JOIN fs_contracts ct ON ct.id = j.contract_id
        LEFT JOIN fs_assets a    ON a.id = COALESCE(v.asset_id, j.asset_id)
        LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
        LEFT JOIN users u        ON u.uuid = v.engineer_user_uuid
        LEFT JOIN employees e    ON e.user_uuid = v.engineer_user_uuid
                                AND e.namespace_id = v.namespace_id
                                AND e.deleted_at IS NULL
        LEFT JOIN fs_asset_test_history th ON th.visit_id = v.id AND th.deleted_at IS NULL
        WHERE v.namespace_id = ?
          AND v.deleted_at IS NULL
          AND v.scheduled_start >= ?::date
          AND v.scheduled_start <  (?::date + INTERVAL '1 day')
        ORDER BY v.scheduled_start DESC
        LIMIT ?
    ]], namespace_id, from, to, row_limit(params))

    local hours, value = 0, 0
    for _, r in ipairs(rows) do
        hours = hours + (tonumber(r.labour_hours) or 0)
        value = value + (tonumber(r.labour_value) or 0)
    end

    return envelope("powerbi_extract", "Power BI extract",
        "One flat row per visit with customer, site, contract, asset and engineer " ..
        "already joined — the feed the BI dashboards read.", {
            col("scheduled_start", "Booked", "datetime"), col("job_number", "Job"),
            col("job_title", "Work"), col("job_kind", "Kind"),
            col("job_type", "Job type"), col("job_stage", "Stage"),
            col("priority", "Priority"), col("customer_name", "Customer"),
            col("customer_group", "Customer group"), col("site_name", "Site"),
            col("site_city", "Town"), col("postal_code", "Postcode"), col("zone", "Zone"),
            col("contract_name", "Contract"), col("contract_number", "Contract no"),
            col("asset_tag", "Asset"), col("asset_type", "Asset type"),
            col("discipline", "Discipline"), col("engineer_name", "Engineer"),
            col("team", "Team"), col("visit_status", "Visit status"),
            col("labour_hours", "Hours", "hours"),
            col("hourly_rate", "Rate", "money"),
            col("labour_value", "Labour value", "money"),
            col("is_out_of_hours", "Out of hours"), col("test_result", "Test result"),
            col("condition_rating", "Condition", "number"),
            col("refrigerant_added_kg", "Refrigerant added kg", "number"),
            col("refrigerant_recovered_kg", "Refrigerant recovered kg", "number"),
        }, rows, {
            visits = #rows,
            total_hours = Common.round2(hours),
            total_labour_value = Common.round2(value),
        }, { date_from = from, date_to = to })
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

-- Keyed so a route can dispatch by name and the dashboard can list the pack
-- without hard-coding it. `filters` tells the UI which controls to show.
Reports.catalogue = {
    { key = "asset_failure_history", title = "Asset failure history",
      group = "Assets", fn = Reports.assetFailureHistory,
      filters = { "date_range", "customer", "site", "asset_type" } },
    { key = "asset_history", title = "Asset history",
      group = "Assets", fn = Reports.assetHistory,
      filters = { "asset" } },
    { key = "ppm_forecast", title = "Programmed maintenance forecast",
      group = "Assets", fn = Reports.ppmForecast,
      filters = { "months", "customer", "site", "asset_type", "contract" } },
    { key = "routine_maintenance", title = "Routine maintenance performance",
      group = "Assets", fn = Reports.routineMaintenance,
      filters = { "date_range" } },
    { key = "fgas_register", title = "F-Gas register",
      group = "Compliance", fn = Reports.fgasRegister,
      filters = { "date_range", "customer", "site", "asset_type" } },
    { key = "employee_licences", title = "Employee licences",
      group = "Compliance", fn = Reports.employeeLicences,
      filters = { "expiring_within_days" } },
    { key = "engineer_locations", title = "Engineer locations",
      group = "Operations", fn = Reports.engineerLocations,
      filters = {} },
    { key = "labour_forecast", title = "Labour forecast",
      group = "Operations", fn = Reports.labourForecast,
      filters = { "weeks" } },
    { key = "response_times", title = "Response times",
      group = "Performance", fn = Reports.responseTimes,
      filters = { "date_range", "customer", "site", "contract" } },
    { key = "admin_efficiency", title = "Administration efficiency",
      group = "Performance", fn = Reports.adminEfficiency,
      filters = { "date_range" } },
    { key = "powerbi_extract", title = "Power BI extract",
      group = "Data", fn = Reports.powerbiExtract,
      filters = { "date_range" } },
}

function Reports.list()
    local out = {}
    for _, r in ipairs(Reports.catalogue) do
        table.insert(out, {
            key = r.key, title = r.title, group = r.group, filters = r.filters,
        })
    end
    return out
end

--- Run one report by key. Returns (envelope) or (nil, err).
function Reports.run(namespace_id, key, params)
    for _, r in ipairs(Reports.catalogue) do
        if r.key == key then return r.fn(namespace_id, params) end
    end
    return nil, "Unknown report: " .. tostring(key)
end

return Reports
