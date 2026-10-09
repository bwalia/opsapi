# API request (iOS): idempotent creates for offline replay

**From:** iOS app · **For:** Quick capture and task actions made with poor signal (SPEC §3.9)

## Problem

The app queues writes made offline and replays them. When a request reaches the server but the
response is lost (common on site), the app can't tell and retries. For creates, that makes duplicates:
two leads, two properties, the same photo twice, two chase log rows.

Affected: `POST /api/v2/crm/leads`, `POST /property-deals/properties`, `POST /property-deals/documents`,
`POST /property-deals/chases`, `POST /api/v2/kanban/tasks/{uuid}/comments`.

## What we need

Either of:

1. **`Idempotency-Key: <uuid>` header** (preferred, one rule for every create): the server stores
   key → response per namespace for ~24 h; a repeat with the same key returns the first response
   (same status and body) and creates nothing.
2. **Client-supplied `uuid`** in the body: a repeat with an existing uuid in the same namespace returns
   the existing row with 200 instead of creating.

Documented in API.md §1 Conventions.

## Until then

The app sends the header anyway (ignored today) and the capture chain stores each returned uuid as soon
as it arrives, which avoids most, but not all, duplicates.

---

## Response (OpsAPI agent, 2026-10-09)

**Done in Phase 5 with option 1 (`Idempotency-Key`), platform-wide.**
- Every Property Deals create honours it (all `sdk.crud` creates plus the hand-written ones: deals, tasks,
  documents, suppliers, compliance checks, approvals, contact log, inbound messages), and so do the core
  `POST /api/v2/crm/leads` and `POST /api/v2/kanban/tasks/{uuid}/comments`.
- Scope: workspace + user + key, kept 24 h (core table `idempotency_keys`, `helper/idempotency.lua`).
- A repeat with the same key and the same request returns the first response (same status and body) with
  the header `Idempotent-Replayed: true`, and creates nothing.
- Same key with a different body or path → 422. A repeat while the first is still running → 409 (retry
  shortly). If the first attempt failed with a 5xx, the key is released so the retry runs.
- Plugins get it free (`sdk.idempotent(self, fn)` for hand-written creates).

Documented in API.md §1 Conventions. Tested in `spec/ai_test.py`.
