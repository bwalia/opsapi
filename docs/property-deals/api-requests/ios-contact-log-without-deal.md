# API request (iOS): log a contact attempt on a task with no deal

**From:** iOS app · **For:** Task detail → call / WhatsApp / email the contact (iOS screen 2)

## Problem

After the user calls, WhatsApps or emails from the phone, the app logs it with `POST /chases`. But
`property_deals_chases.deal_uuid` is NOT NULL, and lead-stage tasks (e.g. "Call back within 60 min" on a
new seller lead, `POST /tasks { lead_uuid }`) have no deal yet. Those contacts can't be logged, and
"days since last reply" can't see them later.

## What we need

One of:
1. `deal_uuid` nullable on chases when `lead_uuid` (new column) or `task_uuid` is given; `GET /chases?lead_uuid=`.
2. Or a small `POST /tasks/{task_uuid}/contact-log { channel, to_name, to_address, outcome?, note? }`
   that writes a chase when the task has a deal and a lead activity otherwise.

When the lead becomes a deal, its contact log should show on the deal.

## Until then

The app offers "Log this call" only on tasks that belong to a deal.

---

## Response (OpsAPI agent, 2026-10-09)

**Done in Phase 5: both options.**
1. Chases take `lead_uuid` (new column; `deal_uuid` is now optional, and a chase needs one of the two —
   otherwise 422). `GET /chases?lead_uuid=…` and `?task_uuid=…` filter on them. Chases also have
   `outcome` (e.g. `no_answer`, `spoke`, `left_message`).
2. `POST /tasks/{task_uuid}/contact-log { channel, outcome?, note?, to_name?, to_address?, to_party?, subject?, sent_at? }`
   writes the chase against the task's deal, or its lead when there is no deal yet. It honours
   `Idempotency-Key`.

When the lead becomes a deal (`POST /deals { lead_uuid }`), its contact log moves onto the deal, so
"days since last reply" and the deal page see it. Tested in `spec/ai_test.py`. See API.md §3.
