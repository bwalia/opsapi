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

Channels: email and SMS. Push and webhook adapters were removed — CRM contacts have no
device token or endpoint URL, so those campaigns could never deliver.

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
