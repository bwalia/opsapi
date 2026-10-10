---
title: Property Deals
pages: /dashboard/property-deals
api: /api/v2/property-deals
modules: property_deals_deals, property_deals_tasks, property_deals_approvals, property_deals_properties, property_deals_buyers, property_deals_suppliers, property_deals_compliance, property_deals_reports
suggestions: What's most urgent today? | Why is this deal red? | What's waiting for my approval?
readonly: true
---
# Property Deals
Deals for buying and selling homes, from first lead to completion. Rules (not AI) set deadlines, urgency, deal health and money at risk. AI agents only draft; nothing is sent, booked or signed until a person approves it in Approvals.

## Pages
- **Today** (/dashboard/property-deals/today): "Due this week" first — deal tasks and renovation jobs grouped Overdue / Today / Tomorrow / Later (managers see the whole team, with an Only mine switch; 7/14/30 days) — then my open tasks by urgency score (hover the score for why), red deals, approvals waiting, money at risk. Each task: Do it, Let AI do it, Assign, Snooze (needs a reason), Log contact. Take the tour restarts the guided tour.
- **Renovations** (/dashboard/property-deals/renovations): build projects. Each is a kanban project (open it under Projects) whose columns are the stages — Survey & quotes, Strip-out, Structural, First fix, Plastering, Second fix, Decorating, Snagging & sign-off, Done — with dated job cards. Start one here or from a deal's Renovation tab; pick builders/site managers to add to the board. Builders get the "Builder / site manager" role. Purchase orders for the job are linked from each renovation.
- **Deals** (/dashboard/property-deals/deals): board by stage (dragging checks the stage gate and lists what is missing) or list. New deal creates a property and the first stage's tasks.
- **Deal page** (/dashboard/property-deals/deals/{uuid}): health and reasons, target and forecast dates, money at risk, stage track with Move to / Next; tabs Tasks, Enquiries & blockers, Chase log, Documents, Compliance, Buyers, Timeline.
- **Approvals**: AI drafts and requests with agent, model and cost; Edit, Approve, or Reject with a note (the agent redrafts with it).
- **Deal finder**: map with a pin and radius (5-50 miles), layers, a property card with comparables and the top buyers, saved searches with daily alerts.
- **Buyers**, **Suppliers** (Book nearest), **Compliance** (a named person signs off), **Deal reports** (export CSV/JSON), **Deals settings** (templates, SLA and urgency, AI providers and agents, data connectors, mailboxes, my notifications).

## Read-only answers
- My tasks and the day: `GET /api/v2/property-deals/today`
- What's due soon (deal tasks + renovation jobs): `GET /api/v2/property-deals/due?days=7`
- Renovations and their progress: `GET /api/v2/property-deals/renovations`
- A deal page in one call: `GET /api/v2/property-deals/deals/{uuid}/overview`
- Why a deal is red: `GET /api/v2/property-deals/deals/{uuid}/health`
- What blocks the next stage: `GET /api/v2/property-deals/deals/{uuid}/gate`
- Approvals I can decide: `GET /api/v2/property-deals/approvals/inbox`

## Rules
- Never approve, reject, send or move stages for the user: explain where the button is.
- Compliance checks are passed or waived only by a named person.
