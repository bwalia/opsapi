# OpsAPI Marketing Cloud (`opsapi_marketing`)

Multi-channel marketing automation plugin. Delivery reliability uses the
**Postgres transactional outbox** (`helper/plugin-events.lua`) and **leased
plugin jobs** (`helper/plugin-jobs.lua`) — not Kafka.

## Enable

1. Ensure CRM is in `PROJECT_CODE` (plugin `depends` on `crm`).
2. Run `opsapi migrate` / `lapis migrate` (creates `mkt_*` tables).
3. Workspace → Plugins → **Marketing Cloud** → enable.
4. Optional settings: `dry_run`, quiet hours, SMS gateway, `public_base_url`.

## Phase status

| Phase | Status |
|-------|--------|
| 0 Plugin + channels + `can_send` + sender job | Done (`spec/phase0_test.py`) |
| 1 Audience / consent / unsubscribe | Lists, consent, dynamic segments, CSV import |
| 2 TipTap studio | Done — merge registry, sanitise, preview, seed, studio UI (`spec/phase2_test.py`) |
| 3 Full lifecycle / A/B / approval | Done (`spec/phase3_test.py`) |
| 4 Tracking + replies + analytics | Done — overview API, reply ingest/classify, conversations UI (`spec/phase4_test.py`) |
| 5 AI agents + knowledge | Done — `mkt_*` tools + `opsapi-marketing.md` scope (`spec/phase5_test.py`) |
| 6 SMS E2E + §9 hardening | Done — SMS dry-run, STOP webhook, cross-tenant (`spec/phase6_test.py`) |
| 9 Production fixes (step 1) | Quiet hours defer, budgets, caps, template errors, four-eyes approval, admin-only transactional; runs with quiet hours on (`spec/phase9_test.py`) |
| 10 Contact files + batches | CSV/XLSX/PDF import of business contacts (preview → confirm), batched sending, unsubscribe = never again (`spec/phase10_test.py`) |
| 13 View in browser | `{{view_online_url}}` → `GET /public/view?token=…` re-renders the recipient's own email; no open pixel, not counted as an open (`spec/phase13_test.py`) |

## Promoting to bought / business contact lists

1. **Lists → Import from a file**: a CSV, Excel (.xlsx) or PDF, up to 7 MB / 50,000 emails. Every
   email in it is found (any column, or anywhere in a PDF), with name/company/phone/website when
   the file has those columns. The preview shows what will be imported and what is skipped:
   duplicates, anyone already unsubscribed, and — for B2B "legitimate interest" imports under
   UK/EU rules — personal mailboxes (gmail, hotmail…), which need consent first. Nothing is added
   until you confirm. Each import is recorded in `mkt_list_imports` (file, who, when, source note).
2. **Campaign → Audience → Send in batches**: e.g. 400 per batch every 60 minutes. Deliveries get a
   `send_after` slot; the sender only picks due ones, at up to `email_rate_per_min` per run.
3. **Unsubscribe**: every email carries a working link (and List-Unsubscribe headers). An
   unsubscribe suppresses the address for the whole workspace: later campaigns skip it and later
   imports never re-add it. Email campaigns can't be validated until a public base URL is set
   (setting `public_base_url` or env `OPSAPI_PUBLIC_URL`); set `sender_address` so every email
   names the sender.

Channels: email and SMS. Push and webhook adapters were removed — CRM contacts have no
device token or endpoint URL, so those campaigns could never deliver.

## View this email in your browser

Put `{{view_online_url}}` in a template (the `blocks.view_online()` line does it for you). Every
email sent with a public base URL gets a signed link (purpose `view_online`, valid a year) to
`/api/v2/opsapi-marketing/public/view?token=…`, which shows that recipient's email as a web page:
their merge fields, working unsubscribe / preferences links, click tracking — but no open pixel,
and a view is not counted as an open. `noindex`, `no-store`, and a CSP that blocks scripts. If
the campaign or contact is gone, a "no longer available" page (404).

## Tests

```bash
./projects/opsapi-marketing/spec/run.sh
```

## API prefix

`/api/v2/opsapi-marketing/` — campaigns, lists, templates, suppressions, consent,
analytics, replies, channels, and `/public/*` signed endpoints.

## Hard rules

- `can_send` is authoritative; AI cannot override consent/suppression.
- Reply classification never auto-sends.
- Opens are always labelled estimated.
