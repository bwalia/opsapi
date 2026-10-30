# iOS request: PA endpoints a native client can use

**From:** WSL CRM iOS app. Plan: `wslcrm-app/docs/property-pa/IOS_PLAN.md`.
**Why:** the app will show the PA (Today, Prepare me, voice capture, confirm, Ask PA, handoffs,
Manager Today, Teach PA) using the same endpoints as the web. These are the shapes the app is being
built against (as a clearly marked mock). Adjust names to repo conventions; tell us what changes.

Conventions as elsewhere: `{success, data, meta?}`, nulls left out, ISO 8601 times (please, not
`2026-10-09 15:31:19+00`), `Idempotency-Key` on creates, `X-Namespace-Id`.

## 1. Gate — `GET /pa/me`
```json
{ "enabled": true, "role": "agent", "user_uuid": "…", "display_name": "Sophie",
  "permissions": { "capture": ["create"], "ask": ["create"], "handoff": ["create"], "knowledge": ["create"], "manager_view": [] },
  "stt": "server", "max_audio_seconds": 300, "timezone": "Europe/London" }
```
404 `PLUGIN_DISABLED` (or `enabled: false`) hides the PA; the app falls back to the Deals screens.

## 2. Today — `GET /pa/today?mode=full|minutes:30&role=manager`
```json
{ "generated_at": "2026-10-13T07:30:00Z", "mode": "full",
  "brief": { "text": "Three things matter today…", "sources": [ { "type": "event", "uuid": "…", "label": "Second valuation, 12 Oct" } ] },
  "cards": [
    { "uuid": "card-1", "rank": 1, "kind": "call",
      "person": { "uuid": "…", "name": "Sarah Collins", "phone": "+44 7700 900111" },
      "property": { "uuid": "…", "address": "22 Station Road" },
      "opportunity_uuid": "…", "deal_uuid": null, "task_uuid": "…",
      "action": "Call Sarah", "why_now": "Her second valuation was yesterday and she said she'd decide after it.",
      "objective": "Find out what the other agent said and whether Tom agrees.",
      "pa_view": "Lead with speed of completion, not price.",
      "estimated_minutes": 10, "score": 87.5 } ],
  "handled_count": 14 }
```
Cards come ranked; the app never re-ranks. Manager mode returns exception cards (`kind`: `handoff`,
`negotiation`, `relationship_risk`, `deal_risk`, `opportunity`) with `handoff_uuid` where relevant.

## 3. Why #1? — `GET /pa/why/:cardId`
```json
{ "card_uuid": "card-1", "score": 87.5,
  "signals": [ { "key": "event_just_happened", "label": "Second valuation yesterday", "value": 1, "weight": 30, "points": 30,
                 "source": { "type": "event", "uuid": "…" } } ],
  "explanation": "…(model-phrased, optional)…" }
```

## 4. Card actions
`POST /pa/cards/:id/done {note?}` and `POST /pa/cards/:id/later {until?}` → next card or 204.
Queued offline by the app with `Idempotency-Key`.

## 5. Long-running calls are jobs
`POST /pa/prepare/:opportunityId`, `POST /pa/ask` → `202 {job_uuid, status: "queued"}`;
`GET /pa/jobs/:id` → `{status: queued|running|done|failed, result?, error?}`. (A synchronous answer
is fine when it's under ~5 s; the app handles both 200 with a result and 202 with a job.)

**Prepare me result**
```json
{ "opportunity_uuid": "…", "sections": [
    { "key": "snapshot", "title": "Snapshot", "facts": [
      { "text": "Second agent valued it at £240,000", "kind": "stated", "confidence": 0.95,
        "source": { "type": "interaction", "uuid": "…", "label": "Call, 12 Oct" } },
      { "text": "£225,000 might work with a 4-week completion", "kind": "inferred", "confirmed": false,
        "by": "Sophie", "source": { "type": "interaction", "uuid": "…" } } ] },
    { "key": "questions", "title": "Questions to establish", "facts": [ … ] } ],
  "gaps": [ "We don't know Tom's view yet." ], "objective": "…", "playbook": [ { "uuid": "…", "title": "…" } ] }
```
**Ask result:** `{ "answer": "…", "facts": [same fact shape], "gaps": […], "actions": [ { "type": "handoff_created", "handoff_uuid": "…" } ] }`

## 6. Capture
`POST /pa/capture` — multipart: `audio` (m4a/AAC 16 kHz mono, ≤ 5 min) **or** JSON `{text}`; plus
`context` (`card_uuid`, `opportunity_uuid`, `person_uuid`, optional). → `202 {capture_uuid, status}`.

`GET /pa/capture/:id`
```json
{ "uuid": "…", "status": "ready", "transcript": "Spoke to Sarah…",
  "resolved": { "person": { "uuid": "…", "name": "Sarah Collins" }, "property": { "uuid": "…", "address": "22 Station Road" },
                "ambiguous": [ { "field": "person", "candidates": [ { "uuid": "…", "name": "Sarah Collins" }, { "uuid": "…", "name": "Sarah Patel" } ] } ] },
  "updates": [
    { "uuid": "u1", "label": "Seller's stated minimum", "target": { "table": "pa_opportunities", "uuid": "…", "field": "stated_minimum" },
      "old_value": null, "new_value": 235000, "display": "£235,000", "kind": "stated", "confidence": 0.93, "material": true, "status": "proposed" },
    { "uuid": "u4", "label": "Price that might work", "new_value": 225000, "display": "£225,000", "kind": "inferred",
      "by": "Sophie", "confidence": 0.6, "material": true, "status": "proposed" } ],
  "next_action": { "uuid": "u6", "title": "Call Sarah", "due_at": "2026-10-14T10:00:00Z", "owner": { "uuid": "…", "name": "Sophie" },
                   "reason": "She'll decide after speaking to Tom", "material": true },
  "summary": "Call with Sarah about 22 Station Road…" }
```
`status`: `queued | transcribing | extracting | needs_person | ready | confirmed | failed`.
A push `{route: "pa_capture_ready", uuid: capture_uuid}` when it's ready would let the app open the sheet.

`GET /pa/captures?status=open` → this person's captures not yet confirmed (working or ready), newest
first, same shape as above without `updates` if that's cheaper. The app uses it for "Voice notes to
confirm" on Today: a note queued offline gets its uuid only when it's sent, so the app finds it here.

`POST /pa/capture/:id/confirm`
```json
{ "person_uuid": "…", "decisions": [ { "update_uuid": "u1", "action": "confirm" },
  { "update_uuid": "u4", "action": "correct", "value": 230000 }, { "update_uuid": "u5", "action": "reject" } ] }
```
→ the applied capture (statuses updated) and the recalculated card, if any.

## 7. Handoffs
`POST /pa/handoff {to_user_uuid?, opportunity_uuid, question, recommendation}` → HandoffCard.
`GET /pa/handoffs?box=inbox|sent`; `GET /pa/handoffs/:id` (a push or a card opens one); `POST /pa/handoffs/:id/reply {decision: "agree"|"reply", text?}`.
HandoffCard: `{uuid, from, to, opportunity, deal_uuid?, question, recommendation, context_facts:[fact], status, reply?, replied_at?}`.

## 8. Teach PA
`POST /pa/teach {text, scope: personal|team|company}` → proposed rule
`{uuid, rule, rationale, category, triggers:[…], scope, version, status: draft}`;
`POST /pa/knowledge/:id/approve` (managers for company scope); `GET /pa/knowledge?scope=`.

## 9. Sources
Every `source` is `{type, uuid, label}` with `type` in `lead | contact | deal | opportunity | task |
interaction | event | offer | document | knowledge`, so the app can open its own screen for it.

## 10. AI change history
`GET /pa/history?table=&uuid=` → `[{field, old_value, new_value, source:{type,uuid}, model_label, prompt_version, approved_by:{uuid,name}, at}]`.
`model_label` is provider-neutral ("Private model"), no provider or key names.
