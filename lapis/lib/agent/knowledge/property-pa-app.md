---
title: Property PA screens
pages: /dashboard/property-pa
api: /api/v2/property-pa
modules: property_pa_records, property_pa_updates, property_pa_knowledge, property_pa_handoffs
suggestions: Who should I call first today? | Why is this opportunity #1? | What changes are waiting for me to confirm?
readonly: true
---
# Property PA
The AI PA for property agents: talk to your PA, the CRM updates underneath. The PA proposes; a person confirms. Nothing is written to a record until someone confirms it, and every change keeps its history (who, when, from which note, which model).

## Pages
- **PA today** (/dashboard/property-pa/today): my opportunities ranked by rules (not AI). Each card: who, property, what to do, why now, aim. "Why #N?" lists every signal and its points. "I have 30 minutes" shows what fits and what waits.
- **PA capture** (/dashboard/property-pa/capture): record a voice note or type what happened. The PA proposes the changes; the confirm sheet marks each row Stated, "<name>'s judgement, unconfirmed" or Proposed, with the words it came from. Change something, then Confirm.
- **My opportunities** and the **opportunity page**: what we know (each fact badged by where it came from), History per field, changes waiting, next actions with reasons, offers, timeline; tabs Prepare me, Coach (questions before any figure; the PA never suggests a higher offer), Ask my PA; Ask my manager.
- **Manager today**: exceptions only: decisions waiting (Agree / Reply / Open deal), unusual negotiations, relationship and deal risks, overdue actions, top opportunities.
- **PA insights** (managers): capture accuracy, grounded vs withheld answers, speed, follow-through, the go-live checklist, email import, GoHighLevel sync (it runs in the background: the result shows on the next pull), AI change history (managers see the whole workspace; others their own opportunities).
- **Consent:** a person can be marked as opted out (or opted out from GoHighLevel's do-not-disturb). The PA then never proposes contacting them, and their Today card says "Don't contact". Only a person can lift an opt-out.
- **PA knowledge**: the rules the PA follows. Teach a rule (managers approve company and team rules; anyone keeps personal ones). Every change is a new version.

## Read-only answers
- My ranked day: `GET /api/v2/property-pa/today`
- Why an opportunity ranks where it does: `GET /api/v2/property-pa/today/why/{opportunity_uuid}`
- Prepare me: `GET /api/v2/property-pa/prepare/{opportunity_uuid}`
- Changes waiting: `GET /api/v2/property-pa/proposed-updates?status=proposed`
