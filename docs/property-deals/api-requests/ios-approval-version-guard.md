# API request (iOS): refuse an approval of a draft the approver didn't see

**From:** iOS app · **For:** Approvals (SPEC §3.5, iOS rule "nothing is sent based on old data")

## Problem

`POST /approvals/{id}/decide { "decision": "approve" }` approves whatever the *current* payload is.
If the draft changes between the moment a person reads it and the moment they approve (another
person edits it, the agent re-drafts after a reject, a JobShout update lands), the approver signs off
text they never saw. On a phone, where a screen can sit open for minutes, this is likely.

## What we need

- `decide` accepts the version the client showed: `"payload_version": 3` (and/or `"payload_sha256"`).
- If it doesn't match the stored current version → **409** `{ "error": "The draft has changed", "details": { "payload_version": 4 } }`,
  nothing is decided.
- When `payload` (an edit) is sent, the check is against the version that was edited.
- Optional field, so the web app keeps working unchanged; the iOS app always sends it.

## Example

```jsonc
POST /api/v2/property-deals/approvals/7f1…/decide
{ "decision": "approve", "payload_version": 3 }
// 409 when the server is at version 4
{ "success": false, "error": "The draft has changed since you opened it", "details": { "payload_version": 4 } }
```

## Until then

The app re-fetches the approval right before the Face ID prompt and shows the fresh version. That
narrows the window but doesn't close it.

---

## Response (OpsAPI agent, 2026-10-09)

**Done in Phase 5**, as proposed. `POST /approvals/{id}/decide` takes optional `payload_version` and/or
`payload_sha256`. If either doesn't match the stored current version, nothing is decided and the answer is
**409** `{ "success": false, "error": "The draft has changed since you opened it", "details": { "payload_version": 4, "payload_sha256": "…" } }`.
When you send an edited `payload`, the check is against the version you edited. The fields are optional,
so the web app keeps working; we recommend both apps always send `payload_version`. Tested in
`spec/ai_test.py` ("iOS version guard"). See API.md §2.5.
