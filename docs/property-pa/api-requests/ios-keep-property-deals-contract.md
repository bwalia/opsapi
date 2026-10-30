# iOS request: keep the shipped app working while the PA is built

**From:** WSL CRM iOS app (`wslcrm-app`), build 1.0.0 (5) on TestFlight.
**Why:** the PA prompt replaces the old back-office prompts, including the iOS one the app's
Property Deals module was built from. The gap map marks Today as "Modify" against
`GET /api/v2/property-deals/today`. Changing that response, or any route below, breaks the
Deals tab on phones already in testers' hands.

## What we ask

1. **Keep `/api/v2/property-deals/*` working, with the same response shapes.** Changes are
   additive (new optional fields), or versioned with notice. The new PA Today is `GET /pa/today`,
   not a change to `/property-deals/today`. Routes the app calls today:
   - `GET /me`, `GET /today`, `GET /due?days=&mine=`, `GET /hot-leads`, `GET /renovations`, `POST /renovations`
   - `GET /tasks/{task_uuid}`, `PUT /tasks/{task_uuid}`, `POST /tasks/{id}/contact-log`, `POST /tasks/{id}/agent-run`
   - `GET /deals`, `GET /deals/{id}/overview`, `POST /chases`
   - `GET /approvals/inbox`, `POST /approvals/{id}/decide` (with `payload_version`)
   - `GET /leads/{uuid}`, `PUT /leads/{uuid}/details`, `GET/POST /leads/{uuid}/replies`, `GET/POST /leads/{uuid}/signals`
   - `POST /properties`, `GET/POST /documents` (multipart photos)
   - `GET/PUT /notification-preferences`
   - Core: `POST /api/v2/crm/leads`, kanban comments and checklist toggles on deal tasks, `/api/v2/purchase-orders/*`, `/api/v2/invoices/*`
2. **Extend tasks, leads and contacts by adding columns only.** No renames or type changes to
   fields the app reads (`task_uuid`, `pd_status`, `due_at`, `urgency_score`, `urgency_why`,
   `deal_uuid`, `first_name`, …). The app treats missing fields as optional, so new ones are safe.
3. **Push stays on the existing path.** Device tokens via `POST/DELETE /api/v2/device-tokens`;
   payload `{ namespace_id, route, uuid, event?, deal_uuid? }`. Keep `task`, `approval`, `deal`,
   `digest`. Add PA routes as new values: `pa_card` (a priority card, e.g. a promised follow-up due),
   `handoff` (decision needed / reply arrived), `pa_brief` (morning brief). Unknown routes are
   ignored by the shipped app, so adding them is safe. Respect `/notification-preferences`
   (add PA categories there) and quiet hours.
4. **PA routes are plain JSON a native client can call** (`/pa/today`, `/pa/why`, `/pa/prepare`,
   `/pa/capture` accepting multipart audio or text, `/pa/capture/:id/confirm`, `/pa/ask`,
   `/pa/handoff`, `/pa/teach`, `/pa/knowledge/:id/approve`), with the same envelope, nulls left
   out, `Idempotency-Key` on creates, and no web-only logic in the routes.
5. **A way to know if the PA is on** for this workspace and person, e.g. `GET /pa/me`
   → `{ enabled, role: agent|manager, permissions, stt: "server"|"on_device" }`. The app shows
   the PA only when it's on and falls back to the Deals screens when it's off or failing.
6. **In the gap map:** list where `property_deals` (urgency engine and `urgency_why`, hot leads,
   approvals, quick capture via `crm/leads` + `leads/{id}/details` + `properties`) overlaps the PA
   priority engine, handoffs and capture, and say which one wins and when the old one retires.
   The app will follow that, with an agreed migration.

## Example: PA push payload

```json
{ "aps": { "alert": { "title": "Call Sarah at 11:00", "body": "You promised a follow-up after her second valuation." } },
  "namespace_id": "ad6740c4-…", "route": "pa_card", "uuid": "card-…", "event": "pa.card.due" }
```

The app's follow-up plan: `wslcrm-app/docs/property-pa/prompt-ios-pa.md`.
