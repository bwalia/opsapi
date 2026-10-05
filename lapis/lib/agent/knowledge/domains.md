---
title: Domains
pages: /dashboard/domains
api: /api/v2/domains, /api/v2/render-templates
modules: domains
tools:
suggestions: Which domains expire in the next 30 days? | Add example.com to our domains | Check SSL expiry for all domains
readonly: false
---
# Domains
The workspace's domain registry: registration and SSL expiry monitoring, plus the WSL Proxy routing fields used when domains are synced to a Git repo. Status: active | expiring_soon | expired | error | pending (set by expiry checks). Available when the Services feature is enabled.

## Using the page
- Stat cards: Total domains, Expiring soon, Expired, SSL ≤ 30d. Search (domain, registrar, notes) and status filter.
- Table: Domain, Status, Registration, SSL, Registrar. Row actions: Check now (re-check expiry), Cloudflare DNS, Edit, Delete.
- Add Domain / Edit: Domain name*, DNS provider, Registrar, Cloudflare zone ID (auto-resolved if blank), Alert threshold (days); WSL Proxy routing: Environment (prod/acc/test/int/dev), SSL email, Routing rule — "Attach shared rule" (pick an existing WSL Proxy rule) or "Create new rule" (Backend host:port, Path, Rule format template); Server template; Sync to repo; Notes. Then Add domain / Save changes.
- Check All re-checks every domain.
- UI only (credentials, DNS and deployments — do these on the page): Cloudflare Token, Sync Settings, Run Pipeline, Sync to Repo, Sync Jobs, Connect WSL Proxy, and the Cloudflare DNS record editor.

## Rules
- domain_name required, stored lowercase; the same name twice in a workspace → 409.
- Create defaults: dns_provider cloudflare, status active, alert_threshold_days 30, environment prod, ssl_enabled / ssl_auto_renew / ssl_force_https true, ssl_staging false, wslproxy_root /var/www/html, listen_ports "80", rule_path "/". owner = you.
- Routing: EITHER wslproxy_rule_id (attach a shared rule) OR proxy_target ("host:port") + rule_path (new rule). Blank proxy_target = no rule (the server file still syncs).
- server_template_uuid / rule_template_uuid = Templates → Layouts & Formats of type domain_wslproxy / domain_rule (blank = built-in format). sync_repo_uuid blank = the default repo from Sync Settings.
- Expiry dates, registrar status and status come from checks — use Check now instead of editing them.
- Delete is soft.

## API
- `GET /api/v2/domains?page&per_page&search&status&dns_provider&expiring_within_days` — list
- `GET /api/v2/domains/stats` — totals (expired, expiring_soon, errored, reg_expiring_30d, ssl_expiring_30d)
- `GET /api/v2/domains/{uuid}` — one domain
- `POST /api/v2/domains {domain_name*, registrar, dns_provider, cloudflare_zone_id, alert_threshold_days: int, auto_renew: bool, notes, environment, ssl_email, ssl_enabled: bool, ssl_auto_renew: bool, ssl_force_https: bool, wslproxy_rule_id, proxy_target, rule_path, server_template_uuid, rule_template_uuid, sync_repo_uuid}` — add
- `PUT /api/v2/domains/{uuid} {any create field}` — update
- `DELETE /api/v2/domains/{uuid}`
- `POST /api/v2/domains/{uuid}/refresh-expiry` — check one now
- `POST /api/v2/domains/refresh-expiry` — check all
- Lookups: `GET /api/v2/domains/sync-repos` (repos for sync_repo_uuid), `GET /api/v2/domains/wslproxy/rules?search&environment` (shared rules; needs WSL Proxy connected, else 409), `GET /api/v2/render-templates?type=domain_wslproxy` or `?type=domain_rule`
