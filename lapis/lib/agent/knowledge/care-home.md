---
title: Care Home Dashboard
pages: /dashboard/care-home
api: /api/v2/care-plans, /api/v2/dementia
modules: hospital_patients, care_home
tools:
suggestions: Which care plans are overdue for review? | Who is at high wandering risk? | Which dementia reassessments are due?
readonly: true
---
# Care Home Dashboard
A read-only oversight dashboard for dementia care and risk monitoring across every patient in the workspace. It shows care plans that are overdue for review, high wandering-risk residents and dementia reassessments that are due. To change anything, the user opens the patient's page (`/dashboard/patients/{patient_uuid}`) and works there.

## Using the page
- Stat cards: Care Homes, Plans Due Review, High Wandering Risk, Reassessment Due.
- **Care Plans Due for Review**: the first 10 plans, each with title, plan type, priority (urgent shown in red) and review date. "All care plans are up to date ✓" means none are due.
- **High Wandering Risk**: up to 8 residents, shown as "Patient #{id}" with the risk, the assessment date and severity.
- **Reassessment Due**: up to 8 residents, shown as "Patient #{id}" with the assessment type and due date.
- **Active Care Homes**: care-home facilities. Click one to open it, or use **View all** to go to Hospitals. The backend no longer serves the facility list, so this panel normally shows "No care homes registered".

## Rules
- Read only: never create, change or delete anything from this page. For changes, send the user to the patient's page (Care Plans or Alerts tab, or the chat there).
- Health data: answer only what's asked, summarise, and never bulk-export or dump full records.
- These lists show the patient's internal numeric `patient_id`, not a name or uuid. Don't guess identities. Refer to "Patient #id" and ask the user to open the patient for details.
- Module `hospital_patients`: read is required (otherwise 403). Results are limited to patients in the current workspace's hospitals.
- Neither list is paginated and neither takes filters.

## API
- `GET /api/v2/care-plans/due-for-review`: active care plans with `review_date` on or before today, oldest first. Fields: uuid, patient_id, title, plan_type, priority, review_date, status.
- `GET /api/v2/dementia/high-risk-wandering`: completed dementia assessments with `wandering_risk` = high, newest first. Fields: patient_id, assessment_type, assessment_date, severity_level, wandering_risk, fall_risk.
- `GET /api/v2/dementia/due-for-reassessment`: completed assessments whose `next_assessment_date` is on or before today, oldest first. Fields: patient_id, assessment_type, next_assessment_date.
