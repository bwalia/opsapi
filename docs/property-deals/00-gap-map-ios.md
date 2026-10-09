# Property Deals — gap map, iOS section

Covers SPEC §2 bullets "how the iOS app uses leads" and "how the iOS app adds screens, auth and
push", plus what the phone screens in `PROMPT-ios` can reuse. Written from the code in
`bwalia/wslcrm-app` (branch `main` at `e9fb785`). The backend contract (`API.md`, Swagger) was
not published yet when this was written, so per-screen API calls are **provisional**; see §9.

## 1. App at a glance

- Native Swift 6 / SwiftUI, iOS 17+, strict concurrency, **no third-party dependencies**
  (URLSession, Codable, Keychain, CoreLocation, LocalAuthentication only). XcodeGen
  `project.yml`, generated project committed.
- One bundle id `uk.co.workstation.wslcrm` for both brands (WSLCRM, DBS Ltd); brand is an
  xcconfig. Configs: Int, DBS-Int, Prod, Local.
- Layout: `WSLCRM/App` (composition root), `Core/{Auth,Networking,Offline,Permissions,Storage,Location}`,
  `DesignSystem`, `Features/<Module>/{<Module>API,<Module>Models,<Module>Views}.swift`.
- Tests: `WSLCRMTests` (unit, fixtures) and `WSLCRMUITests` (XCUITest) against an in-process stub
  OpsAPI (`Support/UITestSupport.swift`, launch arg `-UITestStubServer`, role via `-UITestRole`).

## 2. Leads on iOS today

**The app does not use leads at all.** No call to `/api/v2/crm/leads`, no lead model or screen.
The `crm_leads` menu key is only read as one of the keys that turns the CRM module on
(`PermissionSet.Feature.crm.menuKeys`).

What the app *does* use from CRM (`Features/CRM/CRMAPI.swift`, base `/api/v2/crm`): accounts,
contacts, **deals** (`crm_deals`: list by status/account/pipeline, detail, create/update/delete),
pipelines, deals-by-stage, dashboard stats.

Consequences for the backend gap map:
- Extending `crm_leads` (lead_kind, situation, deadline_date, vulnerability, consent…) breaks
  nothing on iOS. Quick capture will be the app's first lead writer.
- If the backend decides a property deal **extends `crm_deals`**, the existing iOS deal list/detail
  must keep decoding: new fields must be optional/additive. If it is a **new table**, the iOS CRM
  screens are untouched and Property Deals gets its own models.

## 3. API client and models

- Hand-written, **not generated** from OpenAPI. Each module has a stateless `struct XxxAPI` wrapping
  the shared `APIClient` (`Core/Networking/APIClient.swift`) and `Endpoint` builders
  (`.get/.post/.put/.delete`, JSON, raw body, `multipart/form-data`).
- Envelopes `{success, data, meta}` and paging handled in `Envelopes.swift` / `Page<T>`;
  snake_case ↔ camelCase in the shared coder; tolerant dates in `APIDate.swift`; typed errors
  (incl. 422 field errors) in `APIError.swift`; retry policy for idempotent calls.
- Plan: add `Features/PropertyDeals/PropertyDealsAPI.swift` + `PropertyDealsModels.swift` written by
  hand to match the published Swagger exactly, plus decoding tests from fixtures copied from the
  Swagger examples. Register it in `Services` (`App/AppEnvironment.swift`).

## 4. Auth, workspace, roles, secrets

- `SessionStore` drives phases: restoring → signedOut → twoFactor → locked → choosingWorkspace →
  signedIn. Login is form-encoded with email 2FA.
- Tokens: `KeychainTokenStore` (access + refresh), readable after first unlock so offline writes
  replay. Automatic refresh in `APIClient`. **No LLM or integration keys are held on device** and
  none are needed: all AI calls are server-side.
- Workspace: `X-Namespace-Id` on every request; `WorkspacePickerView` switches it, and
  `MainTabView().id(session.workspaceGeneration)` rebuilds all screens on switch. Cache and queue
  entries are keyed by namespace (and user, for the queue).
- Roles: `GET /api/v2/user/menu` → `PermissionSet` (grants per module + menu keys). `shows(feature)`
  gates a module on the workspace menu; `can(action, module)` gates actions. Server stays the
  authority.
- **Plugin on/off:** follow the Shop pattern (`NavigationPolicy.showsShop`): show the module only
  when the workspace menu carries the plugin's menu key, so admins don't get an empty tab on
  workspaces without the plugin. Needs from the backend: the plugin's **menu key** and **RBAC module
  keys** (e.g. `property_deals`, plus whatever approval/compliance permissions exist).

## 5. Screens and navigation

- Tabs in `Features/Home/MainTabView.swift`: My Work, Field Service, Tasks, Shop (each conditional),
  More. Secondary modules are rows in `MoreView.moduleLinks`. Value-based routes go through
  `.withAppDestinations()`.
- Plan: a **"Deals"** tab (Today / Approvals / Deals / Capture inside it) when the plugin is on,
  shown in place of tabs that don't apply to the role; `NavigationPolicy.home` lands property
  operators on Today. Light settings (notification prefs) go into the existing `SettingsView`;
  workspace switch and sign out already exist in More.
- Design system to reuse: `LoadState`, `PagedList`, `StatusPresentation` (tone → colour, used for
  urgency/health), `Formatters` (money, dates), `Components`. Accessibility identifiers are already
  used everywhere for XCUITest.

## 6. Existing pieces that map directly

| Phone need | Already in the app | Notes |
|---|---|---|
| Face ID / Touch ID with passcode fallback | `Core/Auth/BiometricGate.swift` (`deviceOwnerAuthentication`, "Use Passcode") | Today it gates app unlock. Reuse `authenticate(reason:)` before each approval POST. |
| Offline cache of reads | `Core/Offline/ResponseCache.swift` (per-namespace, 64 MB / 30 days) | Already used by field service for My Work. |
| Offline write queue with retries | `MutationQueue` + `PendingMutation` + `SyncCenter` | Durable FIFO, per-entity ordering, backoff, 4xx → visible "failed", never silently dropped, per-user. Add new `Kind`s: task complete, snooze, note, lead capture, photo. |
| "What hasn't synced" | `SyncStatusBanner` + `PendingChangesView` | Already on every tab. |
| Approvals never queued | — | Approve/reject calls bypass `MutationQueue` and require `ConnectivityMonitor.isOnline`; enforce in code and test. |
| Photo upload to MinIO via API | `Endpoint` multipart + `PhotosSection` / `FieldServiceAPI.uploadPhoto` | Same pattern for property photos. Uploading a photo for a lead that is itself still queued needs ordering (see §9). |
| GPS | `Core/Location/LocationProvider.swift` | One-shot coordinates. Address from coordinates: on-device `CLGeocoder` reverse geocode, no API needed. |
| AI agent review UI | `Features/Projects/AgentContract.swift`, `AgentViews.swift`, "Waiting for me" review queue | Kanban cards carry `metadata.agent`; app shows claim, run state (running / needs review / approved / rejected) and refuses agent self-approval. Good model for the Approvals screen; if property tasks extend kanban tasks this may be directly reusable. |
| Tasks (checklist, comments, activity, assignees) | `Features/Projects/KanbanAPI.swift`, `TaskDetailView.swift`, `TaskAgenda.swift` | If the backend extends kanban tasks for property tasks (SPEC asks to extend existing tasks), Task detail reuses most of this. |
| Stub server for XCUITest | `Support/UITestSupport.swift` | Add property-deals routes to the stub; the SPEC §5 scenario test runs against it. |

## 7. Not in the app yet (iOS work, no backend needed)

- **Push:** no `aps-environment` entitlement, no `UNUserNotificationCenter`, no device-token
  registration, no notification handling. `UIBackgroundModes` has only `fetch`.
- **Deep links:** no `onOpenURL`, URL scheme or universal links. Needed for push taps → task /
  approval / deal.
- **Voice notes:** no Speech or audio capture. Plan: `AVAudioRecorder` + `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition` where supported; new Info.plist strings for microphone and speech.
- **Call / WhatsApp / email:** open `tel:`, `https://wa.me/…`, `mailto:` (add `whatsapp` to
  `LSApplicationQueriesSchemes`), then log the contact through the API.
- Usage strings for camera, photo library and location currently mention jobs/visits only; they need
  wording that covers property capture.

## 8. Push: backend gap found (real, independent of the contract)

OpsAPI has `/api/v2/device-tokens` and a `device_tokens` table, but **all sends go through FCM**
(`helper/push-notification.lua`: "Routes all push notifications through FCM… The Flutter mobile app
registers FCM tokens"). This native app has no Firebase SDK and the repo rule is no third-party
dependencies, so it can only register a **raw APNs token**, which FCM cannot deliver to. The APNs
helper (`helper/apns-push.lua`) exists but is unused. Also: `device_tokens` has no namespace column,
and there is no agreed payload for deep links. Written up in
`api-requests/ios-apns-device-tokens.md`.

## 9. Screens → API needs (provisional until API.md exists)

| Screen | Needs from the API |
|---|---|
| Today | My open tasks with urgency score + "why" text, due_at, SLA state, section (overdue / due today / waiting on others), deal ref + health. Complete, snooze (until + reason), "Let AI do it". |
| Task detail | Task with context, deal link, checklist, notes/comments, attachments, contact (phone/email/WhatsApp). Endpoint to **log a contact attempt** (channel, to whom). |
| Approvals | List of pending approvals for me; detail with draft body, sources, agent, provider/model, JobShout origin flag, version; edit draft; approve (with version, so a stale draft is rejected with 409); reject with note. |
| Deals | List filtered by health (red/amber) and "mine"; detail with stage, health, target dates, money at risk + reason, blockers/enquiries, next tasks, compliance status. |
| Quick capture | Create seller lead (extended `crm_leads` fields) and/or property (address, lat/lng, situation, deadline); photo upload to the property/lead. **Idempotency key** on create so a retried offline replay doesn't make duplicates; photos must reference the lead created by an earlier queued write (client UUID or a create-then-upload ordering). |
| Notifications | APNs registration (§8); per-user notification preferences (SLA warnings, escalations, approvals, digest) read/write; push payload with a route (`task`, `approval`, `deal`) and uuid. |
| Settings | Notification preferences (above). Workspace switch and sign out exist. |

These will turn into `api-requests/ios-*.md` files only for items the published contract actually
lacks, once `API.md` and the Swagger are out.

## 10. Open questions for the backend agent

1. Property task = extended kanban task, or a new table? (Decides how much of the iOS task UI is reused.)
2. Property deal = extended `crm_deals`, or a new table?
3. Plugin menu key and RBAC module keys.
4. Do create endpoints accept an `Idempotency-Key` header or a client-supplied uuid?
5. Is the urgency "why" returned as display text, or as structured factors the client formats?
