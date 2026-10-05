---
title: Field Service Reports
pages: /dashboard/field-service/reports
api: /api/v2/field-service/reports, /api/v2/field-service/assets, /api/v2/field-service/asset-types, /api/v2/field-service/contracts, /api/v2/field-service/sites
modules: fs_reports
tools: find_customer
suggestions: Run the F-Gas register for this year | Show the PPM forecast for the next 6 months | Which employee licences expire within 60 days?
readonly: true
---
# Field Service Reports
The Simpro report pack: portfolio-wide asset, compliance, operations and performance reports. Each report returns columns, rows and a summary. Read-only.

## Using the page
- Pick a report from the left list (grouped Assets, Compliance, Operations, Performance, Data), set its filters (From / To, Months ahead, Weeks ahead, Expiring within (days), Contract, Asset), then **Run**. **CSV** exports the same rows for Excel / Power BI; **PDF** downloads a branded PDF. Point the user to CSV / PDF for downloads — don't fetch format=csv yourself.

## Rules
- Needs fs_reports read (managers / service desk); engineers usually don't have it.
- Date range defaults to the last 12 months (date_from / date_to YYYY-MM-DD). limit defaults to 500 rows, max 5000. Unknown filters are ignored; an unknown key returns 404.
- asset_history requires asset_uuid (find it with `GET /api/v2/field-service/assets?search=`). months 1-36 (default 6), weeks 1-52 (default 8), expiring_within_days 1-730 (default 90).
- Summarise results briefly (row count, key totals); don't dump every row.

## Reports (key — filters)
- asset_failure_history — date range, customer, site, asset type
- asset_history — asset_uuid (required)
- ppm_forecast — months, customer, site, asset type, contract
- routine_maintenance — date range
- fgas_register — date range, customer, site, asset type
- employee_licences — expiring_within_days
- engineer_locations — none
- labour_forecast — weeks
- response_times — date range, customer, site, contract
- admin_efficiency — date range
- powerbi_extract — date range

## API
- `GET /api/v2/field-service/reports` — catalogue (key, title, group, filters)
- `GET /api/v2/field-service/reports/{key}?date_from&date_to&customer_uuid&site_uuid&asset_uuid&asset_type_uuid&contract_uuid&months&weeks&expiring_within_days&limit`
- Lookups: `GET /api/v2/field-service/assets?search`, `GET /api/v2/field-service/asset-types`, `GET /api/v2/field-service/contracts?search`, `GET /api/v2/field-service/sites?customer_uuid&search`; customers via find_customer
