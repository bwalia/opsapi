# Domain Management

Namespace-scoped domain registry with **registration + SSL expiry monitoring**, **two-way
Cloudflare DNS management**, and a **k3s job** that periodically syncs the domain list as JSON
to a GitHub repo.

Feature-gated under **`services`** (shares the infrastructure remit — no dedicated `PROJECT_CODE`).
Enabled for any project whose `PROJECT_CODE` includes `services` (e.g. `all`, `collaboration`).

## What it does

- **Central registry** — add/list/edit/soft-delete domains, scoped by `namespace_id`. Platform
  admins get a cross-namespace super-view (`GET /api/v2/domains?all=true`).
- **Expiry monitoring** — per domain:
  - **Registration expiry** via an RDAP lookup (`https://rdap.org` bootstrap, follows redirects),
    also capturing the registrar name + registry status.
  - **SSL/TLS expiry** via a live TLS handshake that reads the leaf certificate's `notAfter`
    and issuer. Colour-coded in the UI; a lifecycle `status` (`active | expiring_soon | expired
    | error`) is stored, and a notification is raised for the domain owner when within the
    per-domain `alert_threshold_days` (default 30).
- **Cloudflare DNS** — list zones and read/create/update/delete DNS records from the dashboard.
- **k3s sync job** — generate a Kubernetes `CronJob` (or run-once `Job`) that pushes
  `domains.json` to a configured GitHub repo/branch/path on a schedule.

## Architecture (follows the standard OpsAPI layering)

| Layer | Files |
|-------|-------|
| Migrations | `lapis/migrations/domain-management.lua` (tables), `lapis/migrations/domain-menu-items.lua` (menu/RBAC), registered in `lapis/migrations.lua` (`600`–`606`, gated on `SERVICES`) |
| Models | `lapis/models/Domain{,Credential,SyncConfig}Model.lua` |
| Queries | `lapis/queries/Domain{,Credential,SyncConfig}Queries.lua` |
| External clients | `lapis/lib/cloudflare.lua` (CF v4 API), `lapis/helper/tls-cert.lua` (raw-TLS cert reader) |
| Expiry engine | `lapis/helper/domain-expiry.lua` (RDAP + TLS + notifications) |
| Sync generator | `lapis/helper/domain-sync-manifest.lua` (CronJob / Job YAML) |
| Routes | `lapis/routes/domains.lua` (gated via `load_if("services", …)` in `app.lua`) |
| Frontend | `opsapi-dashboard/services/domain.service.ts`, `opsapi-dashboard/app/dashboard/domains/page.tsx` |

Tables: `domains`, `domain_credentials`, `domain_sync_configs`.

## Secrets policy (important)

Two distinct credential paths, **neither stored in plaintext**:

1. **Cloudflare API token** — saved per namespace in `domain_credentials.encrypted_secret`,
   **AES-encrypted** at rest via `Global.encryptSecret` (keyed by `OPENSSL_SECRET_KEY`). Decrypted
   server-side only to call the Cloudflare API; never returned over the API (`has_secret` flag only).
   In production, source `OPENSSL_SECRET_KEY` itself from the vault/ESO.

2. **GitHub token + opsapi token for the k3s job** — **never** stored by opsapi and **never** baked
   into the generated manifest. The sync config only references a **Kubernetes Secret name**
   (`github_token_secret_ref`) populated by the **External Secrets Operator** from the vault. The
   generated manifest wires two keys from that Secret into the job's env:
   - `github-token` (default key) → `GITHUB_TOKEN` — the GitHub PAT for `git push`.
   - `opsapi-token` (default key) → `OPSAPI_TOKEN` — an opsapi bearer token the job uses to fetch
     the live export (`GET /api/v2/domains/export`).

### Example ExternalSecret for the sync job

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: domain-sync-secrets
  namespace: default
spec:
  secretStoreRef: { name: wslvault-backend, kind: ClusterSecretStore }
  target: { name: domain-sync-secrets }   # <- github_token_secret_ref
  data:
    - secretKey: github-token
      remoteRef: { key: kv/data/domains/sync, property: github_token }
    - secretKey: opsapi-token
      remoteRef: { key: kv/data/domains/sync, property: opsapi_token }
```

## The k3s sync flow

1. Create a sync config (dashboard → **Sync Jobs**, or `POST /api/v2/domains/sync-configs`) with:
   `github_repo` (owner/repo), `github_branch`, `file_path`, `schedule` (cron),
   `github_token_secret_ref` (the ESO Secret above), and `opsapi_base_url` (in-cluster export URL,
   e.g. `http://opsapi.<ns>.svc.cluster.local`).
2. Download the manifest (`GET …/sync-configs/:uuid/manifest`) and apply it, or commit it to GitOps.
3. On schedule the CronJob: `curl`s the export using `OPSAPI_TOKEN` + `X-Namespace-Id`, writes
   `domains.json`, and `git push`es it to the repo using `GITHUB_TOKEN`.
4. **Sync now**: `POST …/sync-configs/:uuid/run-now` returns an immediately-appliable run-once `Job`.

opsapi has no in-cluster kube credentials, so it **generates** manifests; the cluster (kubectl /
GitOps / Argo) executes them.

## API summary

```
GET    /api/v2/domains                         list (?all=true = admin super-view)
GET    /api/v2/domains/stats                    aggregate counts
GET    /api/v2/domains/export                   JSON export consumed by the k3s job
POST   /api/v2/domains                          create
GET|PUT|DELETE /api/v2/domains/:uuid            get / update / soft-delete
POST   /api/v2/domains/:uuid/refresh-expiry     refresh one (RDAP + TLS)
POST   /api/v2/domains/refresh-expiry           bulk refresh (namespace)

GET|POST  /api/v2/domains/credentials           list / save (encrypts) provider token
POST      /api/v2/domains/credentials/verify     verify Cloudflare token
DELETE    /api/v2/domains/credentials/:provider  delete

GET    /api/v2/domains/cloudflare/zones                        list zones
GET|POST /api/v2/domains/:uuid/cloudflare/records             list / create DNS record
PUT|DELETE /api/v2/domains/:uuid/cloudflare/records/:record_id update / delete

GET|POST  /api/v2/domains/sync-configs           list / create
GET|PUT|DELETE /api/v2/domains/sync-configs/:uuid get / update / delete
GET    /api/v2/domains/sync-configs/:uuid/manifest   render CronJob YAML
POST   /api/v2/domains/sync-configs/:uuid/run-now    render run-once Job YAML
```

All routes require the `domains` RBAC action (`read`/`create`/`update`/`delete`) via
`NamespaceMiddleware.requirePermission`. Platform admins and namespace owners bypass.

## Environment notes

- **SSL expiry detection** uses a minimal TLS 1.2 `ClientHello` (in `helper/tls-cert.lua`) to read
  the cleartext `Certificate` message, because this OpenResty build lacks the
  `lua-resty-openssl-aux-module` needed for the cosocket→peer-cert bridge. A TLS 1.3-only host
  (rare) that refuses TLS 1.2 will report an SSL check error; registration expiry still works, and
  the field can be maintained manually.
- Cloudflare TLS verification is environment-aware (`CLOUDFLARE_ENVIRONMENT` / `OPSAPI_SSL_VERIFY`);
  verified by default. Production already ships `lua_ssl_trusted_certificate` in `nginx.conf`.
- The generated CronJob image is `alpine:3.20` and installs `git curl jq` at runtime.
