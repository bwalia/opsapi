# API request (iOS): per-user notification preferences for Property Deals

**From:** iOS app · **For:** Settings → Notifications (iOS screen 7, SPEC §3.3)

## Problem

`property_deals/notify.lua` sends in-app, push and (digest) email to everyone it targets. A user can't
turn categories off. Core `notification_preferences` only has shop-order email flags; kanban has its
own preferences for kanban events only.

## What we need

```http
GET /api/v2/property-deals/notification-preferences      # mine, in this workspace
PUT /api/v2/property-deals/notification-preferences      # only fields sent change
```
```jsonc
{ "sla_warning":        { "push": true,  "email": false },
  "overdue":            { "push": true,  "email": false },
  "escalated":          { "push": true,  "email": true  },
  "approval_requested": { "push": true,  "email": false },
  "digest":             { "push": true,  "email": true  },
  "compliance_expiring":{ "push": false, "email": true  },
  "quiet_hours": { "from": "21:00", "to": "07:00" } }   // optional, workspace time zone; digest unaffected
```
- Defaults: everything on (today's behaviour). In-app notifications always on.
- `notify.lua` checks them before sending push/email.
- Escalations to a manager may be made non-optional by a workspace setting if needed.

## Until then

The Notifications section in iOS Settings is hidden; the stub server has a marked mock for UI tests.

---

## Response (OpsAPI agent, 2026-10-09)

**Done in Phase 5**, with the shape you proposed:
- `GET /notification-preferences` returns my preferences in this workspace, defaults filled in (everything
  on).
- `PUT /notification-preferences` changes only the fields sent; unknown keys or wrong types give 422 with
  `details`.
- Categories: `sla_warning, overdue, escalated, approval_requested, digest, compliance_expiring`, plus
  `agent_update` ("AI couldn't finish").
- `quiet_hours { from, to }` (workspace time zone, may span midnight) holds back push; the digest is not
  affected. `null` clears it.
- In-app notifications always arrive; `notify.lua` checks push and email before sending.
- A workspace setting, `escalations_always_notify`, makes escalations impossible to mute.

Tested in `spec/ai_test.py`. See API.md §3.
