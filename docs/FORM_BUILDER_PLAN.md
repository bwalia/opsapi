# Form Builder: Design Plan

Status: **Phase 1 built** (PR #704) · **Phase 2 built** (feat/forms-phase2, stacked on #704) · user guide: [FORMS.md](FORMS.md) · Feature flag: `forms` · Date: 2026-10-09

> **Changed while building Phase 1** (each is explained where it applies):
> - **Create a user** sends an invitation; the account is created when the person accepts and sets a
>   password (§6.4).
> - The `services` preset doesn't get forms (diy runs `tax_copilot,services`). `forms` is a feature-only
>   code instead (D2).
> - **Paths:** the CSV export is `GET /api/v2/forms/:uuid/export`, and a response's status is set with
>   `PUT` (Lapis has no `app:patch`).
> - **New:** the generic `confirm` option for agent tools (§10), a workspace invitation page
>   `/invite/[token]`, and the invitation email for **Members → Invite**.
> - **Seats (decided 2026-10-09):** an admin's pending invitation holds a seat (as GitHub does);
>   a form request holds none until it is accepted (as Slack does).
>   - Mechanics: the core column `namespace_invitations.source` (`admin` | `form`) and
>     `NamespaceInvitationQueries.seatsUsed` / `seatAvailable`.
>   - Pending form requests are capped at `max(50, 5 × max_users)`.

> **Changed while building Phase 2:**
> - **Logic operators:** `not_in`, `empty` and `contains` were added to the planned set. Rules may
>   only refer to questions above, at most 10 per question. Locked contact fields can't have logic.
> - **Drop-off is per step, not per field.** Per-field drop-off would need an event per answer;
>   a step funnel costs one event per step and answers the same question for multi-step forms.
> - **Prefill is `?<answer_key>=value`**, not `?prefill=`. Hidden fields keep their own `param`.
> - **Custom domain** (`lib/forms/domains.lua`, `form_domains`, migration `zzform6`). It does not
>   go through the domains module: that module is a DevOps tool gated on `services`, which syncs
>   wslproxy configs to a repo. Instead:
>   - a workspace claims one domain and proves control with a TXT record;
>   - the domain must also point at `FORMS_DOMAIN_TARGET`. Pointing at the shared edge alone
>     proves nothing;
>   - the edge asks `GET /api/v2/public/form-domains/check` before issuing a certificate (the
>     on-demand TLS pattern);
>   - the domain serves only that workspace's forms (Origin check plus `opsapi-dashboard/proxy.ts`).
>
>   wslproxy has no on-demand "ask" hook yet (its `allow_domain` only knows configured servers).
>   Until it does, each domain is added there as a server routed to the dashboard.
> - **Plan limits (D7), decided 2026-10-09:** everything is free for now. No plan has limits, and
>   every form shows "Powered by OpsAPI": no plan may hide it. The checks stay in place for pricing
>   later (`lib/forms/limits.lua`).
> - **Framing:** the dashboard now sends `X-Frame-Options: SAMEORIGIN` and `frame-ancestors 'self'`
>   on every page except `/f/*`, which sends `frame-ancestors *` so it can be embedded
>   (`next.config.ts`). Before this, nothing stopped other sites from framing the dashboard.
> - **Turnstile fails closed.** If Cloudflare can't be reached, the response is refused. The
>   secret is stored with `Global.encryptSecret`.
> - **New tables:** `form_uploads` (no FK to the submission, so a file can be uploaded before its
>   response exists; claimed in the submit transaction), `form_daily_stats` and
>   `form_workspace_settings` (migrations `zzform4`, `zzform5`).

## 1. What we're building

A workspace admin builds a form from any mix of field types, publishes it, and shares a
public link. Anyone with the link can fill it in. Each response is stored and shown in the
dashboard.

When building the form, the admin can tick **Create a customer**, **Create a lead** and/or
**Create a user**. Each ticked option adds the fields it needs (name and email) to the
form. The admin can't remove those fields or make them optional; they can add any other
fields.

Every response is saved, all answers included, and linked to the customer, lead or user it
created or matched.

The in-app AI agent can build forms too ("create a job application form with name, email,
CV link and years of experience, and make each applicant a lead").

```
Admin builds form ──► Publish (new version) ──► Public link / embed
                                                   │
                     Visitor fills in and submits ─┘
                                                   ▼
           validate against the published version · spam checks · rate limits
                                                   ▼
   ONE transaction: save response + find-or-create customer / lead / user + links
                                                   ▼
   after commit (outbox, retried): admin email · auto-reply · webhooks · lead alert
```

### Design principles
- **Reuse before building.** Customers, leads, users, invitations, mail, rate limits,
  the outbox, the agent tool registry and @dnd-kit all exist; we call into them.
- **One engine, driven by registries.** A field-type registry and a target registry
  (customer, lead, user, …) define the behaviour. Adding a field type or a new "create X"
  option means adding one entry, not a new code path.
- **The server is the authority.** The builder UI and the AI agent both go through one
  `normalize()` that inserts the required fields, locks them, and validates the schema.
  Responses are validated against the published version on the server; browser checks are
  only for convenience.
- **Strict tenant isolation.** Every table has `namespace_id`. Every authenticated query is
  filtered by it. Public routes take the namespace from the form row and never from the
  client.
- **Public input never edits existing records.** A response can create or link a record.
  It never overwrites one that already exists.

## 2. What exists today, and why we don't reuse the tax tables

The tax "form builder" is two tax_copilot-only engines. Both are built for logged-in tax
users:

| Engine | Tables | Why it can't hold public forms |
|---|---|---|
| Form sections | `tax_form_sections`, `tax_form_items`, `tax_form_records` (`migrations/form-sections-system.lua`) | <ul><li>Every row is keyed to an `income_type_key` and a `tax_year`.</li><li>`user_id` must be the logged-in user, so anonymous visitors can't submit.</li><li>`amount numeric NOT NULL` on items.</li><li>Only 6 field types, with no select or options.</li><li>The section catalogue's unique index is **global**, not per namespace.</li><li>No read path filters by `namespace_id`, so a new namespace would see every other tenant's forms.</li></ul> |
| Profile Builder | `profile_questions`, `profile_question_rules`, `user_profile_answers`, … (`migrations/dynamic-profile-builder.lua`) | <ul><li>It's the richer engine: 20 question types and a rules engine.</li><li>But answers are per logged-in user (`user_profile_answers`), and global rows use `namespace_id = 0`.</li><li>Its route file is 5,300 lines and coupled to tax.</li></ul> |

Both are gated on `tax_copilot`. A deployment without tax would have no tables at all, and
we'd be dragging tax schema into a core business feature.

**Decision D1 (recommended): build new tables, and reuse the ideas behind the old ones.**
- **Profile Builder** lends us its type vocabulary and operator list.
- **`FormSectionQueries.validate_record_data`** lends us its validator approach: drop
  unknown keys, coerce by type, check required fields last.
- **`sdk.validate`** in `helper/plugin-sdk.lua` lends us its server-side validator.

The tax tables are left untouched. Nothing in the tax app changes.

Everything below already exists and is reused:

| Need | Existing piece |
|---|---|
| Customer | `customers` + `CustomerQueries.create` (`queries/CustomerQueries.lua:43`) |
| Lead | `crm_leads` + `CrmLeadQueries.createLead` (`queries/CrmLeadQueries.lua:24`), alerts via `CrmLeadNotificationQueries.notify` |
| User / invite | `UserQueries.create`, `NamespaceInvitationQueries.create`, `PasswordReset.create`, username and temp-password logic in `EmployeeQueries` |
| Role safety | `RbacGuard.can_assign_role_names` (`helper/rbac-guard.lua:103`) |
| Public route | anything under `^/api/v2/public/` skips auth (`app.lua`); `crm-leads-public.lua` is the closest existing example |
| Rate limits | `RateLimit.check/incr`, shared across pods through Redis (`middleware/rate-limit.lua`); `helper/client-ip.lua` |
| Durable side effects | outbox in `helper/plugin-events.lua` (a `CATALOG` entry gives `*.created` events by DB trigger; `CORE_SUBSCRIPTIONS` gives retried core handlers) |
| Webhooks | workspace outbound webhooks already ride on the outbox; one catalog entry makes forms subscribable |
| Email | `NamespaceMail.send` (workspace SMTP and per-tenant templates), `Mail.send` |
| Agent | `lib/agent/tools.lua` `register{}`; page-assistant scope `lib/agent/knowledge/<page>.md` |
| LLM + metering | `Llm.chat(messages, tools, {usage={feature="forms"}})` (`lib/agent/llm.lua:475`) |
| Drag and drop | `@dnd-kit/core` + `@dnd-kit/sortable`, already in `opsapi-dashboard/package.json` |
| Public page fetch | `services/billing-public.service.ts`: native `fetch`, no JWT, no 401 redirect |
| Daily jobs | `lib/chat-retention.lua`: worker 0, advisory lock, batched |
| Module seeding | `migrations/employees.lua`: module row, menu item, role grants, `namespace_menu_config` |

## 3. Decisions

Each one shows the recommended default. Edit this section before the build if you want a
different call. The build follows what is written here.

| # | Decision | Recommended default |
|---|---|---|
| D1 | Reuse the tax tables? | **No.** New `forms*` tables (see §2). |
| D2 | Core module or feature flag? | **New feature `forms`.** Include it in `all` and every business preset (`business`, `field_service`, `ecommerce`, `ecommerce_chat`, `collaboration`, `cms`, `academy`, `billing`, `hospital`, `property`). **Not** in `tax_copilot`, `core_only` or the feature-only `services` code, which diy runs as `tax_copilot,services`. diy can opt in with `PROJECT_CODE=tax_copilot,services,forms`; `forms` is a feature-only code, so it doesn't create a tenant. |
| D3 | Which table is a "customer"? | **`customers`** (the sidebar's Customers page). It only exists where `ecommerce` or `billing` is deployed; elsewhere the "Create a customer" option is hidden. |
| D4 | Lead option availability | **Only where `crm` is deployed.** `crm_leads` is a core table, but the Leads screen exists only with CRM, so leads created elsewhere would be invisible. Permission: `crm_accounts.create`, the module the Leads menu uses. |
| D5 | Accounts from a public form | **Built as an invitation** (§6.4). Each new email gets a workspace invitation with the role the admin chose: limited to roles that admin can assign, `member` by default. The account is created only when the person accepts it from their email and sets a password, so no account exists for an email whose owner never confirmed. An email that already has an account accepts by signing in. The workspace's `max_users` limit is enforced: pending invitations count, as they do in Members. |
| D6 | Existing record with the same email | **Link it ("matched") and never update it.** The response still holds every answer. |
| D7 | Plan limits (number of forms, responses per month) | **Hook only in Phase 1** (one `Forms.quota(namespace)` check that returns unlimited). The actual numbers per `namespaces.plan` are a pricing decision for Phase 2. |

## 4. Data model

Every migration lives in the new file `migrations/forms.lua`, registered in `migrations.lua`
with `load_if_enabled(FEATURES.FORMS, …)`. Keys use the `zzform<n>_` prefix because Lapis
sorts migration keys as strings.

### 4.1 Tables

**`forms`**: one row per form.
| column | type | notes |
|---|---|---|
| id | bigserial PK | |
| uuid | uuid UNIQUE NOT NULL | |
| namespace_id | int NOT NULL → namespaces ON DELETE CASCADE | |
| public_id | varchar(16) UNIQUE NOT NULL | 12 random characters from `helper.uuid.random_string`, used in the public link; unguessable so forms can't be enumerated |
| title | varchar(200) NOT NULL | |
| description | text | |
| status | varchar(16) NOT NULL DEFAULT 'draft' | CHECK `draft \| published \| closed \| archived` |
| draft_schema | jsonb NOT NULL DEFAULT '{"fields":[]}' | what the builder edits |
| targets | jsonb NOT NULL DEFAULT '[]' | e.g. `[{"type":"customer"},{"type":"user","role":"member"}]` |
| settings | jsonb NOT NULL DEFAULT '{}' | see §4.3 |
| published_version_id | bigint NULL → form_versions | |
| submission_count | int NOT NULL DEFAULT 0 | also enforces `max_submissions` atomically |
| last_submission_at | timestamptz | |
| created_by_uuid, updated_by_uuid, published_by_uuid | varchar | |
| published_at, created_at, updated_at, deleted_at | timestamptz | soft delete |

Index: `(namespace_id, updated_at DESC) WHERE deleted_at IS NULL`.

**`form_versions`**: an immutable snapshot taken at each publish.
| column | type | notes |
|---|---|---|
| id | bigserial PK | |
| form_id | → forms ON DELETE CASCADE | |
| namespace_id | int NOT NULL | |
| version | int NOT NULL | UNIQUE (form_id, version) |
| schema | jsonb NOT NULL | fields, frozen |
| targets | jsonb NOT NULL | targets, frozen |
| published_by_uuid | varchar NOT NULL | the person whose permissions authorised the targets |
| created_at | timestamptz | |

Why versions: if a live form's fields change, older responses must keep the labels they
were answered under. A field's `key` never changes, so the responses table can merge
columns across versions.

**`form_submissions`**: the answers, called "responses" in the UI.
| column | type | notes |
|---|---|---|
| id | bigserial PK | |
| uuid | uuid UNIQUE NOT NULL | |
| namespace_id | int NOT NULL | |
| form_id | → forms | |
| version_id | → form_versions | |
| data | jsonb NOT NULL | `{field_key: value}`, all answers including name and email |
| respondent_email | varchar(320) NULL | stored lower-cased; used for "responses from this person" and GDPR lookups |
| status | varchar(16) NOT NULL DEFAULT 'complete' | CHECK `complete \| needs_attention \| spam`; `needs_attention` = a target failed |
| idempotency_key | varchar(64) NULL | UNIQUE (form_id, idempotency_key), so a double-clicked submit is stored once |
| meta | jsonb NOT NULL DEFAULT '{}' | `{ip_hash, user_agent(≤256), referrer, utm:{source,medium,campaign,term,content}, duration_ms}`; the IP is stored as an HMAC, never raw |
| created_at | timestamptz NOT NULL DEFAULT now() | |

Indexes:
- `(form_id, created_at DESC, id DESC)`: keyset pagination, never OFFSET.
- `(namespace_id, respondent_email)`.

**`form_submission_links`**: what each response created or matched. This is the table
the brief asks for to "link the customer".
| column | type | notes |
|---|---|---|
| submission_id | → form_submissions ON DELETE CASCADE | PK (submission_id, target) |
| namespace_id | int NOT NULL | |
| target | varchar(32) NOT NULL | `customer \| lead \| user` (from the registry) |
| entity_uuid | varchar NULL | |
| outcome | varchar(16) NOT NULL | `created \| matched \| invited \| failed` |
| error_code | varchar(64) NULL | e.g. `email_in_use`, `workspace_full`; shown to the admin, never to the public |
| created_at | timestamptz | |

Index: `(namespace_id, target, entity_uuid)`, used by "Form responses" on a customer or lead
page.

Outbox: add `form_submissions` to `PluginEvents.CATALOG` as entity `form.submission`
(module `forms`). This gives `form.submission.created` through the existing trigger, so
workspace webhooks and plugins can subscribe at no extra cost.

### 4.2 Schema JSON (draft and versions)
```json
{
  "fields": [
    { "key": "f_q8m2kd", "type": "name",  "label": "Your name", "required": true,
      "system": "contact.name" },
    { "key": "f_7hx0pa", "type": "email", "label": "Email", "required": true,
      "system": "contact.email" },
    { "key": "f_c1n9re", "type": "phone", "label": "Phone", "maps_to": "phone" },
    { "key": "f_v0d3sj", "type": "single_select", "label": "Budget",
      "options": [{ "value": "lt5k", "label": "Under £5k" }, { "value": "gt5k", "label": "£5k+" }] },
    { "key": "f_m2p7lt", "type": "long_text", "label": "Tell us about the project",
      "validation": { "max_length": 2000 }, "help": "Optional", "width": "full" }
  ]
}
```
- `key`: generated by the server as `f_` plus 6 random characters. It never changes.
- `system`: present only on fields added because of a target. The UI shows a lock icon;
  the label, help text and position can be edited, but the field can't be deleted or made
  optional and its type can't change.
- `maps_to`: an optional, shared vocabulary that applies to every target supporting it:
  `phone, company, job_title, address, notes, marketing_consent`.

**Limits:**
- 200 fields per form, 500 options per field, 300 characters per label.
- 256 KB per schema, 64 KB per response.

### 4.3 Settings JSON
- **Confirmation:** `success_message`, and `redirect_url` (https only).
- **Closing:** `close_at`, `max_submissions`, `closed_message`.
- **Emails:** `notify_emails[]` (defaults to the creator), and
  `auto_reply{enabled, subject, body}` with `{{field_key}}` placeholders, HTML-escaped when
  filled in.
- **Other:** `retention_days` (null means keep forever), `theme{primary_color, logo_url}`
  (Phase 2), `turnstile` (Phase 2).

## 5. Field types

All types live in one registry on each side.
- **Server:** `lib/forms/fields.lua`. Each type has a `validate(value, field) → value | nil, err`
  function and the `maps_to` kinds it can feed.
- **Browser:** `components/forms/field-types.ts`. Each type has a renderer and an editor
  for its properties.

Adding a type means adding one entry on each side. Names follow Profile Builder's
vocabulary.

| Phase | Types |
|---|---|
| **1** | `short_text`, `long_text`, `email`, `phone`, `number` (min, max, decimals), `date`, `time`, `url`, `single_select` (dropdown), `radio`, `multi_select` (checkboxes), `boolean` (yes/no), `rating` (1–5 or 1–10), `consent` (must be ticked; stores the exact consent text and version shown), `name` (first and last), `address` (line1, line2, city, postcode, country), `hidden` (filled from the URL query, e.g. `?utm_source=`), `heading` / `paragraph` (display only, plain text) |
| 2 | `file_upload` (MinIO, per-field size and MIME limits), `page_break` (multi-step with progress bar), `nps` (0–10), `matrix` |
| 3 | `signature`, `payment` (Stripe), `calculated` |

Validation runs on the server for every type:
1. Coerce each value by its type.
2. Check `required` (a hidden conditional field is never required; Phase 2).
3. Check min and max length, and min and max value.
4. Check that option values come from the field's own options.
5. Drop unknown keys.

**No user-supplied regex in Phase 1** (it risks catastrophic-backtracking ReDoS). Phase 2
can add it behind `lua_regex_match_limit`.

## 6. "Create records from this form": targets

### 6.1 Registry (`lib/forms/targets.lua`)
```lua
{ key = "customer", label = "Create a customer",
  features = { "ecommerce", "billing" },          -- any-of; hidden when none is deployed
  permission = { "customers", "create" },         -- the publisher must hold this
  requires = { "contact.name", "contact.email" }, -- system fields it adds and locks
  maps = { phone = "phone", notes = "notes", marketing_consent = "accepts_marketing" },
  apply = function(tx, ctx, contact, mapped) ... end } -- returns outcome, entity_uuid | nil, error_code
```
- `GET /api/v2/forms/targets` returns only the targets that are deployed **and** that the
  current user has permission for. The builder shows only those.
- Ticking a target adds its `requires` fields to the draft through `normalize()`, sharing
  one name field and one email field across all targets. Unticking removes the lock; the
  fields stay, and the admin can then delete them.
- A future "Create a support ticket", "Create a kanban task" or "Create a CRM contact" is
  one more registry entry.

### 6.2 Permission rule: you can't grant what you don't hold
Adding a target means letting the public create records with the admin's authority. So:
- **Save and publish:** both require the editor to hold each target's `permission`. The
  user target also requires `users.create` plus
  `RbacGuard.can_assign_role_names(self, {role})`.
- **Version record:** `form_versions.published_by_uuid` records who authorised it.
- **Without that:** someone with only `forms.update` could otherwise create user accounts.

### 6.3 Processing (inside the submit transaction)
1. Run the targets in a fixed order: **user → customer → lead**. If both a user and a
   customer are created, set `customers.user_id`.
2. For each target, take `pg_advisory_xact_lock(hashtext('forms:'||target||':'||ns||':'||lower(email)))`.
   Two people submitting the same email at the same moment then can't create two
   customers or two leads (`crm_leads` has no unique email to rely on).
3. Find an existing record in **this namespace** by `lower(email)`. If found, the outcome
   is `matched` and nothing is updated (D6). Otherwise create it with the existing query
   function.
4. Wrap each target in a `SAVEPOINT`. A failure (e.g. a unique violation) rolls back only
   that target, records `failed` plus an `error_code`, and sets the response to
   `needs_attention`.
   - The response itself is always kept.
   - The admin can press **Retry** after fixing the cause.

### 6.4 Rules for each target
- **customer:** `CustomerQueries.create{namespace_id, email, first_name, last_name, state='enabled', + maps}`.
  - Known catch: on deployments with `ecommerce` but **not** `billing`, `customers.email`
    is unique **across every namespace** (`customers_email_unique_idx`). Another tenant's
    customer can therefore block this one.
  - That case is caught and recorded as `failed/email_in_use`, which only the admin sees.
  - The proper fix is to apply billing's per-namespace index everywhere. That's tracked
    separately (§15) and is outside this feature.
- **lead:** `CrmLeadQueries.createLead{namespace_id, first_name, last_name, email, source='form', status='new', channel/campaign/landing_page_url/referrer_url from meta, metadata={form_uuid, submission_uuid}}`.
  - Matching ignores soft-deleted leads.
  - After commit, call `CrmLeadNotificationQueries.notify` inside a `pcall`.
- **user** (D5). *As built:* this sends an invitation. `NamespaceInvitationQueries.create` gives
  `invited`, and the account is created when the person accepts at `/invite/<token>`
  (`routes/invitations-public.lua`). An existing member is `matched`; a pending invitation is
  `matched`, with no second email. Two reasons led to this:
  - pre-creating an inactive user didn't work, because the password-reset flow never sets
    `active=true`;
  - it would let bots fill `max_users` with fake members.

  The original design is kept below for the record.
  - **New email:** check the workspace's `max_users` (otherwise `failed/workspace_full`).
    Then call `UserQueries.create{…, active=false, password=<32 random CSPRNG characters>, role='member', namespace_id, namespace_role=<form role>}`.
    - Skip the Have I Been Pwned call for generated passwords. It's a network call inside
      a database transaction, and pointless for a random password.
    - Reuse EmployeeQueries' unique-username logic. Move it into a shared helper, not a
      copy.
    - After commit, email an "Activate your account" link built with `PasswordReset.create`.
      Setting a password through that link sets `active=true`.
    - **Important:** login does **not** check `users.active` today (only token refresh
      does). The real protection is that nobody knows the generated password.
  - **Email already has an account and is a member:** `matched`.
  - **Email has an account but isn't a member:** `NamespaceInvitationQueries.create{…, role_id}`
    gives `invited`. Send the invitation email. That email is still a TODO in
    `routes/namespaces.lua:1120`, so implement it once in a helper that both paths use.
  - **The public sees the same response in every case**, so the form can't be used to
    find out whether an email has an account.
  - **The builder shows a warning:** "Anyone with the link can request an account. They
    get <role> access after confirming their email."

## 7. Public flow

### 7.1 Link and page
- **Dashboard page:** `/f/<public_id>` at `opsapi-dashboard/app/f/[publicId]/page.tsx`. It
  is public, fetches with native `fetch` like `billing-public.service.ts`, and has no auth
  redirect.
- **Renderer:** the same `FormRenderer` component draws the builder preview and the public
  page, so what the admin sees is exactly what the visitor gets.
- **Accessibility and layout:**
  - visible labels, errors next to the field, focus moves to the first error;
  - `aria-live` for the submit result;
  - keyboard-only use works;
  - designed mobile-first.
- **Phase 2:** `?embed=1` for iframes (allow `frame-ancestors` on `/f/*` only), plus a
  copy-paste snippet with auto-resize and a QR code.

### 7.2 Public API (anything under `/api/v2/public/` is already public)

| Method | Path | Behaviour |
|---|---|---|
| GET | `/api/v2/public/forms/:public_id` | The **published version only**: title, description, fields, success message and theme. Never the draft, targets, notify emails or internal ids. Unknown, draft, archived or deleted forms, or a suspended workspace (`namespaces.status <> 'active'`): **404**. Closed or past `close_at`: **410** with `closed_message`. Returns a signed `render_token` (HMAC of form id and time). Cache: `Cache-Control: public, max-age=60` with an ETag from `version_id`. |
| POST | `/api/v2/public/forms/:public_id/submissions` | See §7.3. Requires an `Idempotency-Key` header. Returns **201** `{message, redirect_url?}`, **400** `{errors:{field_key: msg}}`, **409** (full), **410** (closed) or **429**. |

CORS: allow any origin for `^/api/v2/public/forms/`, without credentials. This follows the
existing exception for `/public/billing`, and it's needed for embeds and headless use.

### 7.3 Submit pipeline (`lib/forms/submit.lua`)
1. Load the form and its published version by `public_id`. Check status and namespace as
   in the GET.
2. **Rate limits** (shared across pods through Redis):
   - 5 per minute per IP per form;
   - 30 per hour per IP across all forms;
   - 300 per minute per form overall.
3. **Body:** the size must be at most 64 KB, and the JSON must decode.
4. **Bot checks:**
   - The honeypot field must be empty.
   - The `render_token` must be valid, at least 2 seconds old and at most 24 hours old.
   - Failing either: return the normal 201 so bots get no signal, store the response with
     `status='spam'`, run no targets and send no emails.
5. **Validate** against `version.schema` (§5). On failure: 400 with an error per field.
6. **Transaction:**
   - Atomically claim a slot:
     `UPDATE forms SET submission_count = submission_count + 1, last_submission_at = now() WHERE id = ? AND status = 'published' AND (max_submissions IS NULL OR submission_count < max_submissions) RETURNING id`.
     No row back means the form is full: 409.
   - Insert the response, handling `ON CONFLICT (form_id, idempotency_key)`: return the
     original 201.
   - Run the targets (§6.3) and insert the links.
   - Commit.
7. **After commit:**
   - The outbox trigger emits `form.submission.created`.
   - The `core.forms` subscriber sends the admin notification and the auto-reply, and the
     user target's activation or invitation email. These are retried and survive a pod
     restart, unlike a plain `Mail.send` timer.
   - Lead alert inside a `pcall`.
8. The whole path is free of logging except ERR and WARN. 5xx responses never echo
   `tostring(err)`; use `Errors.classify` as in the house rules.

## 8. Admin API

Every route is wrapped in `requireAuth(requireNamespace(requirePermission("forms", <action>, …)))`.
Every query is filtered by `namespace_id`, and every `:uuid` is re-checked against the
namespace (404 otherwise).

| Method | Path | Action | Notes |
|---|---|---|---|
| GET | `/api/v2/forms?status=&q=&cursor=` | read | keyset by `updated_at, id` |
| POST | `/api/v2/forms` | create | `{title, description?, template?, schema?, targets?}`, goes through `normalize()` |
| GET | `/api/v2/forms/targets` | read | deployed targets the caller has permission for |
| GET | `/api/v2/forms/templates` | read | from `lib/forms/templates.lua`, shared by the UI and the agent |
| GET | `/api/v2/forms/:uuid` | read | draft, published version summary, settings, targets, share URL |
| PUT | `/api/v2/forms/:uuid` | update | partial; requires `expected_updated_at`, **409** if stale (two editors, or autosave racing) |
| POST | `/api/v2/forms/:uuid/publish` | update | `normalize()`, the target permission check (§6.2), then a new `form_versions` row |
| POST | `/api/v2/forms/:uuid/close`, `/reopen` | update | |
| POST | `/api/v2/forms/:uuid/duplicate` | create | new `public_id`, starts as a draft |
| DELETE | `/api/v2/forms/:uuid` | delete | soft delete; the public link returns 404 |
| GET | `/api/v2/forms/:uuid/submissions?cursor=&status=&from=&to=&q=` | read | keyset `(created_at, id)`; links loaded in **one** batched query, no N+1 |
| GET | `/api/v2/forms/:uuid/submissions/:sid` | read | answers, version labels, links (customer, lead and user names and URLs) |
| POST | `/api/v2/forms/:uuid/submissions/:sid/retry` | update | re-runs failed targets; marking spam as "not spam" also runs them |
| PUT | `/api/v2/forms/:uuid/submissions/:sid` | update | `{status}`: spam or complete (Lapis has no `app:patch`) |
| DELETE | `/api/v2/forms/:uuid/submissions/:sid` | delete | hard delete (GDPR) |
| GET | `/api/v2/forms/:uuid/export` | read | streamed in keyset chunks of 1,000; **CSV-injection safe** (cells starting with `= + - @ \t \r` get a `'` prefix) |

New RBAC module `forms` in `PROJECT_MODULES` with full CRUD plus manage. Seed it like
`migrations/employees.lua`: modules row, menu item "Forms" at `/dashboard/forms`, owner
and admin grants, and `namespace_menu_config` for every namespace. Gate both
`app.lua` (`load_if("forms", "routes.forms")`, `load_if("forms", "routes.forms-public")`)
and `migrations.lua` on the same feature.

## 9. Dashboard

- **`/dashboard/forms`:**
  - The list shows title, status pill, response count, last response and actions
    (edit, share, duplicate, close, delete).
  - **Start from a template:** Contact us, Lead capture, Customer sign-up, Event
    registration, Feedback/NPS, Job application, Appointment request.
  - **"Describe it to AI":** opens the page assistant pre-filled.
  - The empty state has a single clear call to action.
- **`/dashboard/forms/[uuid]`:** the builder, with tabs **Build · Settings · Share · Responses**.
  - **Build** has three panes:
    - Left: the field palette. Click or drag a field to add it.
    - Middle: the canvas, reordered with `@dnd-kit/sortable`. Drag has a keyboard
      alternative (move up and down buttons).
    - Right: the inspector for label, help, placeholder, required, options (paste a list
      to bulk-add), `maps_to` and width.
    - Top: a **Create records** card with Customer, Lead and User toggles, showing only
      what `/forms/targets` returns. Locked fields show a lock and a tooltip such as
      "Needed to create a customer".
    - Autosave: a debounced PUT with `expected_updated_at`. A 409 shows "This form changed
      elsewhere, reload".
    - **Preview** toggles between desktop and mobile, using the same `FormRenderer`.
    - A **Publish** button and an "Unpublished changes" badge appear when the draft
      differs from the published version.
  - **Settings:** the §4.3 options.
  - **Share:** link with copy button, an open-in-new-tab button, the status, and an
    explanation of what visitors see when the form is closed. Phase 2 adds embed code
    and a QR code.
  - **Responses:**
    - A table whose columns are every field key across versions, labelled with the
      latest label.
    - Filters: status and date. Keyset "Load more".
    - A detail drawer with all answers and chips for the customer, lead or user the
      response created or matched. A `failed` chip has a Retry button.
    - Spam, delete and CSV export.
- **Public page** `/f/[publicId]`: clean branded card, success state, closed state, 404
  state.
- **Service layer:**
  - `services/forms.service.ts` (authenticated, through `api-client`).
  - `services/forms-public.service.ts` (native `fetch`, sends `Idempotency-Key`, a random
    UUID created per page load).
- Follow the house layout: `ProtectedPage module="forms"`, `PageHeader`, and the
  `@/components/ui` kit. Hide buttons with `usePermissions()` when the user lacks the
  permission.

## 10. AI agent

Typed tools go in `lib/agent/tools.lua`. Use the lazy `q("FormQueries")` require, because
the module may not be deployed. Every tool calls the same query functions as the REST API,
so `normalize()`, the permission checks and the limits apply to the agent too.

| Tool | Perms | Behaviour |
|---|---|---|
| `create_form` | forms.create | `{title, description?, fields:[{label, type, required?, options?, help?, placeholder?}], create_records?:["customer","lead","user"], user_role?}`. Creates a **draft** (never published), returns the uuid and the builder link. Unknown types are rejected with the list of valid types so the model can correct itself. Can start from a template key. |
| `list_forms` | forms.read | title, status, response count, link |
| `get_form` | forms.read | fields, targets, status, link, counts |
| `publish_form` | forms.update | **Asks for confirmation first**, because it makes the form public. |

- **Confirmation for typed tools:** today only `call_api DELETE` asks for confirmation.
  Add a small generic option, `confirm = function(args) return "<question>" end`, on
  `register{}`. It reuses the existing `needs_confirmation`, `pending` and `settle_pending`
  flow (`tools.lua:981`, `chat-agent.lua:442`). Every future tool can use it.
- **Page scope:** add `lib/agent/knowledge/forms.md` with
  `pages: /dashboard/forms`, `api: /api/v2/forms`,
  `tools: create_form, list_forms, get_form, publish_form`, the documented endpoints, and
  suggestions ("Create a contact form that makes each person a lead", "How many responses
  this week?").
  - `spec/page-assistant_spec.lua` requires this file once `app/dashboard/forms` exists.
  - **Never document `/api/v2/public/*`** in it.
- **Name prefix:** tool names starting with `create_` trigger the dashboard to reload its
  data.
- **Phase 2:**
  - `update_form` (add, remove or reorder fields).
  - `summarize_form_responses`: per-field aggregates plus an LLM summary, metered as
    feature `forms`.
  - "Generate with AI" inside the builder.
  - Forms tools on the MCP server (needs the `forms` API-key scope).

## 11. Notifications, webhooks and email
- **Workspace email templates:** register `forms.new_response`, `forms.auto_reply`,
  `account.activate` and `namespace.invitation` in `NamespaceMail.TEMPLATES`. Tenants can
  then rebrand them, and they go out through the workspace SMTP when one is set.
- **Delivery:** sent by the `core.forms` outbox subscriber, which is at-least-once, so it
  must be idempotent per `(submission_uuid, kind)`.
- **Webhooks:** `form.submission.created` appears in the workspace webhooks UI
  automatically once it's in `CATALOG`.
- **Phase 2:** a "Post new responses to chat channel X" option, and in-app notifications.

## 12. Security and privacy checklist
- [ ] **Tenant isolation:**
  - every authenticated query filters `namespace_id`;
  - public routes take the namespace from the form row only;
  - another tenant's `uuid` returns 404, not 403.
- [ ] **Public GET leaks nothing internal:** it returns the published version only and
  never the draft, targets, notify emails, creator or namespace id.
- [ ] **Targets need the permissions above:** the publisher holds each target's
  permission, and roles are checked with RbacGuard (§6.2).
- [ ] **Public input never edits existing records**, and responses look the same whether
  or not an email has an account (no enumeration).
- [ ] **Accounts from forms:** the password is unknown until the person sets it through
  the email link; `max_users` is enforced; the default role is `member`.
- [ ] **Abuse controls:** rate limits, honeypot, render token, idempotency key, 64 KB body
  cap, and the field and option count caps.
- [ ] **Safe output:**
  - labels, help and paragraphs render as text and never as raw HTML;
  - auto-reply placeholders are HTML-escaped;
  - `redirect_url` must be https;
  - CSV export escapes formulas.
- [ ] **No raw IPs:** the IP is stored only as an HMAC.
- [ ] **Retention:**
  - optional per-form `retention_days`, enforced by a daily purge on worker 0 under an
    advisory lock (pattern: `lib/chat-retention.lua`);
  - spam is purged after 30 days.
- [ ] **Consent fields store the exact text and version shown.**
- [ ] **No regex from users** (Phase 1).
- [ ] **Suspended workspaces** return 404 on public routes, which skip the global
  suspended-tenant check.

## 13. Performance and scale
- **Public GET:** the published version never changes, so cache it in a shared dict keyed
  by `public_id:version_id` with a 60 s TTL, plus the CDN and browser `Cache-Control`.
  This is safe across pods because a publish changes `version_id`.
- **Submit:** one transaction with a handful of indexed inserts. The `submission_count`
  row update serialises submissions per form. That's fine up to hundreds per second per
  form; past that, move the cap into a Redis counter (`ponytail:` comment).
- **Responses list:** keyset pagination on `(form_id, created_at DESC, id DESC)` with
  links batched. Put `EXPLAIN (ANALYZE, BUFFERS)` output for 1M responses in the PR.
- **CSV:** streamed and never fully buffered.
- **Partitioning:** don't partition `form_submissions` now. Revisit at about 50M rows or
  when vacuum, bloat or backups start to hurt, as with the chat runbook.
- **Multiple pods:** keep no per-pod state other than the cache. Rate limits already go
  through Redis.

## 14. Phases (each phase is one PR, merged before the next starts)

**Phase 1: MVP (this build).** Sections 4–13 as marked:
- the builder with Phase 1 field types, templates, versions and publish;
- the public page and API with spam and rate-limit protection;
- responses with detail view, retry, spam, delete and CSV;
- the customer, lead and user targets;
- emails through the outbox, webhooks through the catalog;
- the agent tools and knowledge file;
- docs (`docs/FORMS.md`) and tests (§16).

**Phase 2: grow it, and make clients choose it** (built). Each item has the reason it sells.

| Feature | Why clients care |
|---|---|
| Conditional logic (`show_if` with all/any and the operators eq, neq, in, gt, lt, filled), evaluated **on the server too** | Shorter, smarter forms mean more completions |
| Multi-step pages with a progress bar | Long forms, such as applications or onboarding, convert much better |
| File uploads (MinIO, per-field limits, orphan cleanup job) | CVs, photos, documents |
| Embed snippet, QR code, `?prefill=` / UTM capture | Put the form on their own site, flyers, events; know which campaign worked |
| Branding (logo, colour) and a custom domain through the existing domains module | It looks like *their* form, not ours |
| Analytics: views, starts, completions, conversion rate and drop-off per field (`form_daily_stats`) | Shows them the form is working |
| AI: "Generate with AI" in the builder, AI response summaries, `update_form` tool | The headline demo: describe a form, get one in seconds |
| Plan limits per `namespaces.plan` (D7) and Turnstile per workspace | Monetisation and heavy-abuse protection |
| "Form responses" panel on the customer and lead pages | The full history of a person in one place |
| New-response alerts in a chat channel or as in-app notifications | The team reacts immediately |

**Phase 3: differentiators.**
- Stripe payment fields: deposits, paid registrations.
- E-signature.
- Quiz and score, calculated fields.
- Save and resume link.
- Multiple languages.
- More targets: kanban task, support ticket, appointment, CRM contact and deal.
- Approval workflow for responses.
- Scheduled response digests.
- MCP forms tools.

## 15. Risks and follow-ups outside this feature
- **`customers.email` is globally unique** on ecommerce-without-billing deployments, a
  cross-tenant collision (§6.4). Fix it by applying billing's
  `(namespace_id, lower(email))` index everywhere, in its own PR.
- **Invitation emails were never sent** (`routes/namespaces.lua:1120` TODO). *Fixed in Phase 1:*
  `NamespaceInvitationQueries.sendEmail`, which the invite and resend routes now call. The
  `/invite/[token]` page lets people with no account accept.
- **`/api/v2/register` has no rate limit, and login ignores `users.active`.** These are
  pre-existing; note them in the PR rather than fixing them here.
- **CRM lead routes have no RBAC module check** (pre-existing); note it.

## 16. Testing and proof (Phase 1 is not done without these)
- **`lapis/spec/forms_spec.lua`** (standalone LuaJIT, house style). It tests:
  - every field type's validator, including edge cases;
  - `normalize()`: adds the system fields, locks them, rejects removing them, generates
    keys, enforces the caps;
  - CSV escaping;
  - the target registry's feature gating.
- **`lapis/spec/forms-e2e/run.sh [ref]`:** a live Docker harness, following
  `spec/chat-pubsub-e2e`. It uses two namespaces and must show each of these:
  - **Basics:**
    - create, publish and submit through both the API and the agent tool handler;
    - an editor without `customers.create` can't add the customer target;
    - a role-escalation attempt on the user target is rejected.
  - **Targets:**
    - a response with the customer, lead and user targets creates and links all three;
    - the same email again gives `matched` and no duplicates;
    - **20 concurrent submissions with one email give exactly one customer and one lead**;
    - a new user's account has an unknown password, and the activation email is queued;
    - an existing user's email gives an invitation, not membership;
    - `max_users` gives `failed/workspace_full`, and the response is still saved.
  - **Isolation:** namespace B gets 404 on A's form and A's responses.
  - **Public access:**
    - draft and deleted forms give 404 on the public GET; closed gives 410;
    - a suspended workspace gives 404.
  - **Abuse:** rate limit gives 429; honeypot and an early token become spam with no
    targets.
  - **Limits and idempotency:**
    - repeating an `Idempotency-Key` stores one row;
    - `max_submissions` under concurrency gives exactly N.
  - **Versions:** changing a field and republishing keeps the old responses' labels.
- **Cypress:** build, publish, open `/f/<id>`, submit, see the response with its linked
  customer.
- **Regression:** a differential sweep of every route, main against the branch (the API
  regression sandbox recipe). The only expected differences are the new routes.
- **Database:** `EXPLAIN (ANALYZE, BUFFERS)` of the responses list and CSV export at 1M
  rows, included in the PR.
- **Static checks:**
  - `openresty -t`;
  - `luajit -b` on every changed Lua file;
  - `luacheck` on changed files;
  - `npm run type-check`, `lint` and `build`;
  - `spec/page-assistant_spec.lua` passes.
