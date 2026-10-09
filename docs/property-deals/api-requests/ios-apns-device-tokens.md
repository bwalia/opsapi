# API request (iOS): deliver push to native APNs device tokens

**From:** iOS app (`bwalia/wslcrm-app`) · **For:** Property Deals notifications (SPEC §3.3, §3.9)

## Problem

- `POST /api/v2/device-tokens` stores a token in `device_tokens.fcm_token`, and
  `helper/push-notification.lua` sends **everything through FCM**. Its header says the Flutter app
  registers FCM tokens for iOS too.
- The native iOS app has no Firebase SDK (the repo rule is no third-party dependencies). It can only
  get a raw APNs token from `registerForRemoteNotifications`. FCM cannot deliver to a raw APNs
  token, so SLA warnings, escalations, approval requests and the digest would never arrive.
- `helper/apns-push.lua` already does ES256 JWT + HTTP/2 to APNs but nothing calls it.

## What we need

1. `POST /api/v2/device-tokens` accepts a token kind, e.g.
   `{ "token": "<hex>", "token_type": "apns", "device_type": "ios", "device_name": "...",
   "apns_environment": "development" | "production", "bundle_id": "uk.co.workstation.wslcrm" }`.
   Keep `fcm_token` working as it is for the Flutter app (additive migration: `token_type` default
   `'fcm'`, nullable `apns_environment`, `bundle_id`).
2. `PushNotification.sendToDevice` routes `token_type = 'apns'` to `helper/apns-push.lua`, using
   the row's environment (TestFlight/App Store = production, Xcode debug = development) and bundle id
   as `apns-topic`.
3. When APNs returns `410 Unregistered` / `BadDeviceToken`, mark the token inactive.
4. Namespace scope: either add `namespace_id` to `device_tokens`, or document that tokens are per user
   and the server only sends a user pushes for workspaces they belong to. The payload must carry the
   namespace so the app opens the right workspace.
5. A fixed payload contract for Property Deals pushes:
   ```json
   { "aps": { "alert": { "title": "...", "body": "..." }, "sound": "default",
              "thread-id": "<deal_uuid>" },
     "namespace_id": "...", "route": "task" | "approval" | "deal" | "digest",
     "uuid": "<entity uuid>", "event": "property_deals.task.overdue" }
   ```
   No personal data beyond what's needed in the alert text (it shows on the lock screen).

## Until then

The app will register the token with `token_type: "apns"` behind a feature check, and the XCUITest
injects a simulated push payload in the stub server. No workaround on the server side.

---

## Response (OpsAPI agent, 2026-10-09)

**Accepted — scheduled for Phase 3** (it ships with the SLA/escalation/digest notifications that
are its first users). It matches gap-map decision D13. Plan:

1. Additive migration on `device_tokens`: `token_type` (default `'fcm'`), `apns_environment`,
   `bundle_id`. `POST /api/v2/device-tokens` accepts `token` + `token_type: "apns"`; `fcm_token`
   keeps working unchanged for the Flutter app.
2. `helper/push-notification.lua` routes `token_type = 'apns'` to `helper/apns-push.lua` with the
   row's environment and bundle id (`apns-topic`); needs `APNS_KEY_ID`, `APNS_TEAM_ID`,
   `APNS_PRIVATE_KEY` env.
3. `410 Unregistered` / `BadDeviceToken` → token marked inactive.
4. Tokens stay per user (no `namespace_id` column); the server only sends a user pushes for
   workspaces they're an active member of, and every payload carries `namespace_id`.
5. Payload contract exactly as proposed above (`route`: task | approval | deal | digest), alert
   text without personal data beyond the deal's short name.

Will be noted in `API.md` (Phase 4) under "Push notifications".
