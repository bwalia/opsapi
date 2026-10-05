---
title: Patients
pages: /dashboard/patients
api: /api/v2/patients
modules: hospital_patients, patients
tools:
suggestions: Show this patient's active medications | Add today's daily log for this patient | Acknowledge this patient's open alerts
readonly: false
---
# Patients
Patient records (status active | discharged | transferred | deceased). A patient's page is `/dashboard/patients/{patient_uuid}`: use the uuid from the page path the user is on. On the list page, ask them to open the patient first.

## Using the page
- List page: **Add Patient** opens a form. Required fields are Hospital, Patient ID (internal), First Name, Last Name and Date of Birth. Filter chips: All | active | discharged | transferred. Each row has Edit and Delete icons.
- Patient page: **Edit** button and tabs Overview, Care Plans, Medications, Daily Logs, Family, Access Controls, Alerts. Every tab is view only except two:
  - Access Controls: **Revoke** on each active grant.
  - Alerts: **Ack** and **Resolve** on each active alert.
- Adding or editing plans, medications, logs, family, grants or alerts has no button. Do it in chat.

## Rules
- Health data: only read or write what the user asks for. Never bulk-export, and never loop over many patients.
- Before any write, confirm the patient's identity: name + DOB, or the patient uuid. Restate the change and wait for a yes.
- This backend has no endpoints to list, view, create, edit or delete patients themselves. `/api/v2/patients` and `/api/v2/patients/{uuid}` return 404. Never call them, and don't search by name.
- Module `hospital_patients`: GET needs read, POST needs create (including ack, resolve and revoke), PUT needs update, DELETE needs delete. A patient outside the workspace returns 404.
- Dates are YYYY-MM-DD and times HH:MM. `[..]` and `{..}` take JSON. Use only the listed enum values (the server doesn't check them). Fields marked `*` are required.
- Set automatically: `recorded_by`, `created_by`, `triggered_by`. `care_plan_id` is a plan's numeric `id`.
- An alert goes active → acknowledged → resolved. To end access, prefer revoke (it's audited) over delete.
- Lists take `page` and `perPage` (default 20, max 100). Deletes are permanent and need confirmation.

## API
Use the patient uuid from the page path. Each resource below also has one-record endpoints (PUT takes any of its create fields):
  `GET /api/v2/patients/{patient_uuid}/care-plans/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/care-plans/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/care-plans/{uuid}`
  `GET /api/v2/patients/{patient_uuid}/medications/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/medications/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/medications/{uuid}`
  `GET /api/v2/patients/{patient_uuid}/daily-logs/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/daily-logs/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/daily-logs/{uuid}`
  `GET /api/v2/patients/{patient_uuid}/care-logs/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/care-logs/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/care-logs/{uuid}`
  `GET /api/v2/patients/{patient_uuid}/family-members/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/family-members/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/family-members/{uuid}`
  `GET /api/v2/patients/{patient_uuid}/access-controls/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/access-controls/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/access-controls/{uuid}`
  `GET /api/v2/patients/{patient_uuid}/alerts/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/alerts/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/alerts/{uuid}`
  `GET /api/v2/patients/{patient_uuid}/dementia-assessments/{uuid}` · `PUT /api/v2/patients/{patient_uuid}/dementia-assessments/{uuid}` · `DELETE /api/v2/patients/{patient_uuid}/dementia-assessments/{uuid}`
- Care plans: `GET /api/v2/patients/{patient_uuid}/care-plans?status&plan_type` · `POST /api/v2/patients/{patient_uuid}/care-plans {plan_type*: general|medication|rehabilitation|dementia|palliative|nutrition, title*, start_date*, description, goals: [..], interventions: [..], review_date, end_date, priority: low|normal|high|urgent, status: draft|active|completed|cancelled, notes}`
- Medications: `GET /api/v2/patients/{patient_uuid}/medications?status` · `GET /api/v2/patients/{patient_uuid}/medications/active` · `GET /api/v2/patients/{patient_uuid}/medications/prn` · `POST /api/v2/patients/{patient_uuid}/medications {name*, dosage*, frequency*: once_daily|twice_daily|as_needed|.., start_date*, unit, route: oral|iv|topical|inhaled|injection, schedule_times: ["08:00"], instructions, prescriber, end_date, is_prn, max_daily_doses, status: active|paused|discontinued|completed, discontinued_reason, notes}`
- Daily logs: `GET /api/v2/patients/{patient_uuid}/daily-logs?log_date&shift` · `GET /api/v2/patients/{patient_uuid}/daily-logs/today` · `POST /api/v2/patients/{patient_uuid}/daily-logs {log_date*, shift: morning|afternoon|night, sleep_quality: good|fair|poor|disturbed, sleep_hours, breakfast_intake|lunch_intake|dinner_intake: all|most|half|little|none, fluid_intake_ml, mobility_level: independent|assisted|wheelchair|bedbound, overall_mood: happy|calm|anxious|agitated|confused|distressed, general_wellbeing: excellent|good|fair|poor|declining, pain_level: 0-10, weight, concerns}`
- Care logs: `GET /api/v2/patients/{patient_uuid}/care-logs?log_type&log_date&shift` · `GET /api/v2/patients/{patient_uuid}/care-logs/incidents` · `POST /api/v2/patients/{patient_uuid}/care-logs {log_type*: feeding|medication|personal_care|observation|incident|handover, log_date*, summary*, log_time, shift, medication_name, medication_dose, medication_administered, mood, incident_type: fall|injury|wandering|aggression|medical_emergency, incident_severity: minor|moderate|severe, action_taken, follow_up_required}`
- Family: `GET /api/v2/patients/{patient_uuid}/family-members` · `GET /api/v2/patients/{patient_uuid}/family-members/next-of-kin` · `GET /api/v2/patients/{patient_uuid}/family-members/emergency` · `POST /api/v2/patients/{patient_uuid}/family-members {first_name*, last_name*, relationship*: spouse|daughter|son|sibling|parent|guardian|other, is_next_of_kin, is_emergency_contact, is_power_of_attorney, phone, email, address, notes}`
- Access: `GET /api/v2/patients/{patient_uuid}/access-controls?status&role` · `POST /api/v2/patients/{patient_uuid}/access-controls {granted_to*: email, role*: family_member|caregiver|doctor|specialist|social_worker, access_level: read|read_write|emergency_only, scope: ["medications","care_plans","all"], expires_at, consent_given, notes}` · `POST /api/v2/patients/{patient_uuid}/access-controls/{uuid}/revoke {reason}`
- Alerts: `GET /api/v2/patients/{patient_uuid}/alerts?status&severity&alert_type` · `POST /api/v2/patients/{patient_uuid}/alerts {alert_type*: medication_reminder|emergency|fall|wandering|missed_care|vital_sign|appointment|family_notification, title*, message*, severity: info|warning|critical|emergency, notify_family}` · `POST /api/v2/patients/{patient_uuid}/alerts/{uuid}/acknowledge` · `POST /api/v2/patients/{patient_uuid}/alerts/{uuid}/resolve {resolution_notes}`
- Dementia: `GET /api/v2/patients/{patient_uuid}/dementia-assessments` · `GET /api/v2/patients/{patient_uuid}/dementia-assessments/latest` · `POST /api/v2/patients/{patient_uuid}/dementia-assessments {assessor*, assessment_type*: mmse|moca|adl|behavioural|cognitive|capacity, assessment_date*, score, max_score, severity_level: mild|moderate|severe, wandering_risk|fall_risk: none|low|moderate|high, next_assessment_date, notes}`
