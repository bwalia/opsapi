---
title: Assets & Contracts
pages: /dashboard/field-service/assets, /dashboard/field-service/contracts
api: /api/v2/field-service/assets, /api/v2/field-service/asset-types, /api/v2/field-service/service-levels, /api/v2/field-service/contracts, /api/v2/field-service/sites
modules: fs_assets, fs_contracts
tools: find_customer
suggestions: Which assets are overdue for service? | Show F-Gas systems in poor condition | Which contracts expire in the next 90 days?
readonly: false
---
# Assets & Contracts
Assets are customer plant at a site (aligned with Simpro), with a condition rating 1 Excellent, 2 Good, 3 Fair, 4 Poor, 5 Plan replacement, 6 Replace, F-Gas refrigerant data, service levels (recurring schedules with a next-due date) and a survey/test history. Contracts are maintenance agreements with a customer: term, annual value and SLA hours. Asset status: active, inactive, decommissioned. Contract status: draft, active, expired, cancelled.

## Using the page
- Assets list: search (tag, description, serial, model), Discipline (HVAC, Heating, Ventilation, Electrical, Controls), Condition ("N or worse"), **F-Gas systems** and **Service overdue** toggles. Columns: Asset, Type, Customer/site, Condition, Refrigerant (kg, tCO₂e), Next service, Simpro. Click a row to open.
- Asset page: Asset details, F-Gas card (GWP, CO₂e, leak-check interval, next leak check), Service levels, **Record a survey** (Condition, Result, Against schedule, Refrigerant added, Leak check, Notes → **Save survey**), Survey history, **Asset history PDF**.
- Contracts list: search by name/number; columns Contract, Customer, Term, Renewal (Expired / days left / Open-ended), Annual value, SLA (respond / fix / quote), Covers, Simpro. The header sums annual value and contracts renewing within 90 days.
- There is no create form on these pages; create/edit through the API below if asked. Local edits are queued to push to Simpro.

## Rules
- Viewing needs fs_assets/fs_contracts read, or fs_jobs/fs_visits read. Recording a survey or editing needs fs_assets update; creating needs create; deleting needs delete.
- Asset create needs name and site_uuid; the customer comes from the site. GWP, CO₂e and the statutory leak-check interval are computed from refrigerant_type + refrigerant_charge_kg. An asset type's default_service_months seeds a service level.
- condition_rating must be 1-6. Survey result: pass, fail, advisory, not_tested (default pass). A survey against a service level advances its next due date by its frequency; a leak_check_result resets the next leak check.
- Service level frequency_months 1-120 (default 12). Contract needs name + customer_uuid; end_date can't be before start_date.
- Resolve customers with find_customer, sites with `GET /api/v2/field-service/sites?customer_uuid=`.

## API
- `GET /api/v2/field-service/assets?site_uuid&customer_uuid&asset_type_uuid&contract_uuid&status&discipline&condition_min=1-6&fgas_only=true&service_overdue=true&include_archived=true&search&page&per_page`
- `GET /api/v2/field-service/assets/{uuid}` — + service levels + recent tests
- `POST /api/v2/field-service/assets {name*, site_uuid*, asset_tag, asset_type_uuid, contract_uuid, parent_uuid, serial_number, product_number, manufacturer, model, location_detail, installed_at, warranty_expires_at, next_leak_check_at: YYYY-MM-DD, condition_rating, condition_notes, refrigerant_type (e.g. R32), refrigerant_charge_kg, hermetically_sealed, status, notes, archived}`
- `PUT /api/v2/field-service/assets/{uuid} {same fields}` / `DELETE /api/v2/field-service/assets/{uuid}`
- `GET /api/v2/field-service/assets/{uuid}/tests?page&per_page`
- `POST /api/v2/field-service/assets/{uuid}/tests {result, condition_rating, condition_notes, service_level_uuid, tested_at: YYYY-MM-DD, job_uuid, visit_uuid, refrigerant_added_kg, refrigerant_recovered_kg, leak_check_result: pass|fail, notes, recommendation}`
- `POST /api/v2/field-service/assets/{uuid}/service-levels {name*, kind (default service), frequency_months, last_service_date, next_service_date, estimated_hours, contract_uuid, is_active, notes}`
- `PUT /api/v2/field-service/service-levels/{uuid} {same fields}` / `DELETE /api/v2/field-service/service-levels/{uuid}`
- `GET /api/v2/field-service/asset-types?discipline&search&include_inactive=true`
- `POST /api/v2/field-service/asset-types {name*, code, description, discipline (default hvac), is_fgas, default_service_months, is_active}` / `PUT /api/v2/field-service/asset-types/{uuid}`
- `GET /api/v2/field-service/contracts?customer_uuid&status&expiring_within_days&search&page&per_page`
- `GET /api/v2/field-service/contracts/{uuid}` — + coverage, sites
- `POST /api/v2/field-service/contracts {name*, customer_uuid*, contract_number, description, notes, start_date, end_date: YYYY-MM-DD, extension_months, response_hours, resolve_hours, quote_turnaround_hours, annual_value, currency, covers_out_of_hours, service_manager_uuid, status (default active)}`
- `PUT /api/v2/field-service/contracts/{uuid} {same fields}` / `DELETE /api/v2/field-service/contracts/{uuid}`
- `GET /api/v2/field-service/sites?customer_uuid&search`
