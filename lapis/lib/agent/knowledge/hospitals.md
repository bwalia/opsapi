---
title: Hospitals
pages: /dashboard/hospitals
api: /api/v2/hospitals
modules: hospital_patients, hospitals
tools:
suggestions: List the wards in this hospital | Add a department to this hospital | Show critical alerts for this hospital
readonly: false
---
# Hospitals
Facilities of type hospital | care_home | clinic (status active | inactive | suspended), each with departments, wards, patients and patient alerts. A hospital's page is `/dashboard/hospitals/{hospital_uuid}`: take the uuid from the page path the user is on. If they're on the list page, ask them to open the hospital first.

## Using the page
- List page "Hospitals & Care Homes": **Add Hospital** opens "Add New Hospital". Fields: Name*, Type, License Number*, Status, Capacity (beds), Phone, Email, Website, Address, City, State, Postal Code, Country, Contact Person, Contact Phone. Each row has an Edit (pencil) and a Delete (bin) icon. Delete also deletes all of the hospital's patients and records. The search box only filters the rows already loaded. Click a row to open the hospital.
- Hospital page: name with type/status badges and an **Edit** button. Cards: Capacity, Active Patients, Active Alerts, Total Patients. Sections: Contact Information (Primary Contact), Location, Capabilities & Services, and **Recent Patients** (click a patient to open their record; **View all** opens the Patients page).
- Departments and wards have no screen yet. Manage them through chat with the API below.

## Rules
- Health data: only read or write what the user asks for. Never bulk-export or dump patient data. Before any change, restate the hospital, the record and the exact change, then wait for a yes.
- This backend has no endpoints to list, view, create, edit or delete hospitals, or for hospital statistics. `GET/POST /api/v2/hospitals`, `/api/v2/hospitals/{uuid}` and `/statistics` all return 404. Never call them. Tell the user that facility records can't be listed or changed from here. This is also why the page can show "Failed to load hospitals".
- Every route below needs module `hospital_patients`: GET needs read, POST needs create, PUT needs update, DELETE needs delete (otherwise 403). A hospital outside the current workspace returns 404 "Not found".
- `{hospital_uuid}`, `{dept_uuid}` and `{ward_uuid}` are uuids. A ward's `department_id` is the department's numeric `id` from the department list, not its uuid.
- Required fields are marked `*`. A missing required field returns a 4xx error. Status and type values are not validated by the server, so use only the listed values.
- JSON fields (specialties, operating_hours, visiting_hours, restrictions) take real arrays or objects.
- Deletes are permanent, and the user must confirm them.
- Alerts are created, acknowledged and resolved per patient on the patient's page (Alerts tab). Here they are read-only.

## API
- `GET /api/v2/hospitals/{hospital_uuid}/departments?page&perPage&orderBy=name|code|created_at&orderDir=asc|desc`: perPage defaults to 20.
- `GET /api/v2/hospitals/{hospital_uuid}/departments/{dept_uuid}`
- `POST /api/v2/hospitals/{hospital_uuid}/departments {name*, code, description, head_of_department, phone, email, floor, capacity: int, specialties: [..], operating_hours: {..}, status: active|inactive|closed}`
- `PUT /api/v2/hospitals/{hospital_uuid}/departments/{dept_uuid} {any of the create fields}`
- `DELETE /api/v2/hospitals/{hospital_uuid}/departments/{dept_uuid}`
- `GET /api/v2/hospitals/{hospital_uuid}/wards?page&perPage&department_id&orderBy=name|code|ward_type|created_at&orderDir`
- `GET /api/v2/hospitals/{hospital_uuid}/wards/{ward_uuid}`
- `POST /api/v2/hospitals/{hospital_uuid}/wards {name*, department_id: int, code, ward_type: general|icu|maternity|dementia|palliative, floor, capacity: int, current_occupancy: int, nurse_station_phone, visiting_hours: {..}, restrictions: [..], status: active|closed|maintenance}`
- `PUT /api/v2/hospitals/{hospital_uuid}/wards/{ward_uuid} {any of the create fields}`
- `DELETE /api/v2/hospitals/{hospital_uuid}/wards/{ward_uuid}`
- `GET /api/v2/hospitals/{hospital_uuid}/alerts/active`: alerts with status active or escalated, most severe first.
- `GET /api/v2/hospitals/{hospital_uuid}/alerts/critical`: active alerts with severity critical or emergency.
