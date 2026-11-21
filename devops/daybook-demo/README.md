# Daybook demo back office (`demo.daybook.co.uk`)

A read-only OpsAPI back office that shows AI tax returns with fictional data. It is
the demo behind daybook.co.uk/demo and /demos. One deployment
(`PROJECT_CODE=tax_copilot`) holds **one workspace per use case** ("vertical"). Every
name, figure and address is made up. The spec is `docs/plans/DAYBOOK_DEMO_SPEC.md`.

| Host | What | k3s1, namespace `daybook-demo` |
|---|---|---|
| `demo.daybook.co.uk` | Dashboard, Daybook theme per workspace | Helm release `daybook-demo-dashboard` (image `bwalia/opsapi-dashboard:daybook-demo`) |
| `demo-api.daybook.co.uk` | API, `PROJECT_CODE=tax_copilot` | Helm release `daybook-demo` (`values-daybook-demo.yaml`) |
| (internal) | Postgres | StatefulSet `daybook-demo-db` (`devops/k8s/daybook-demo-db.yaml`) |

Traffic: browser → Cloudflare CNAME (DNS only) → wslproxy edge `lon1.pop0.uk`
(Let's Encrypt), with lon2/pop0 mirroring it → rule `daybook-demo-default` →
k3s1 traefik-edge `193.237.176.232:8888` → pods, routed by Host header.

**Public login:** `demo@daybook.co.uk`, with the password published on daybook.co.uk/demos. It lives in the Actions secret `DAYBOOK_DEMO_PASSWORD`, and the deploy copies it to the k8s Secret `daybook-demo-login`. It's kept out of the repo so secret scanners stay quiet.

- **Role:** a `viewer` in every demo workspace: read on every module, so every change
  through a workspace (RBAC) route is refused with 403.
- **Emailed sign-in code:** off in these workspaces.
- **Reset:** every 30 minutes.

## Files

| File | Purpose |
|---|---|
| `verticals/index.lua` | The live verticals, in order (`{ "practice" }`). The first one is the workspace the demo login opens in |
| `verticals/practice.lua` | Harbour & Lane Accountants, staff, clients C1–C6 and their deterministic transaction generators |
| `verticals/_example.lua` | The shape of a new vertical (not seeded) |
| `daybook-common.lua` | Finds the seed directory and loads verticals (tree or flat ConfigMap layout) |
| `seed-daybook.lua` | Workspaces, viewer role, staff, clients, the demo login, the Daybook theme |
| `seed-daybook-data.lua` | Tax data: profiles, AI-assistant profile, accounts, statements, classified lines, VAT, filing queue |
| `reset.yaml` | CronJob (every 30 min) that re-runs both seeds for every vertical, plus a ServiceAccount that may only exec into pods here |
| `selfheal.yaml` | Copy of `devops/demo/selfheal.yaml` for this namespace |
| `seed-vault-daybook.sh` | Writes `daybook-demo/config` to WSL Vault, once |
| `../k8s/daybook-demo-db.yaml` | Postgres (pgvector) and its ExternalSecret |
| `../helm-charts/*/values-daybook-demo.yaml` | API and dashboard values |
| `../../.github/workflows/deploy-daybook-demo.yml` | DNS → edge → DB → API → dashboard → seed → reset job → checks (weekly too) |
| `../../.github/wslproxy/data/{rules,servers}/prod/*daybook*` | Edge records: `daybook-demo-default` (demo hosts), `daybook-website-pages` and `daybook-www-redirect` (website) |

## Run order (first time)

1. **Vault:**

   ```bash
   export WSLVAULT_API_KEY='wslv_…'
   ./devops/daybook-demo/seed-vault-daybook.sh
   ```

   Then add the HMRC **sandbox** application's `HMRC_CLIENT_ID` / `HMRC_CLIENT_SECRET`
   to `daybook-demo/config`, and add `https://demo-api.daybook.co.uk/auth/hmrc/callback`
   to that application's redirect URIs. You only need this for "Connect to HMRC" in the
   demo.
2. **Repo secrets:** the workflow needs `CLOUDFLARE_API_TOKEN` (zone `daybook.co.uk`,
   DNS:Edit), `KUBE_CONFIG_DATA_K3S`, `DOCKER_USERNAME`/`DOCKER_PASSWD`, and the wslproxy
   secrets the register workflow uses.
3. **Run "Deploy Daybook demo"** (`gh workflow run deploy-daybook-demo.yml`). Everything
   after that is in the workflow.

   The migrate hook creates the platform admin's own workspace `daybook-admin` (kept
   apart from the demo workspaces). The seeds then create `daybook-demo` and the rest.

### Website hosts (daybook.co.uk, www)

The workflow only registers the two demo hosts. Register the website hosts by hand,
once, after the `bwalia/daybook-website` Pages site exists:

- rule `daybook-website-pages`: 305 to `https://bwalia.github.io/daybook-website`, Host
  `bwalia.github.io`;
- rule `daybook-www-redirect`.

Use either the wslproxy `add-domain` skill, or "Register WSL Proxy Domains" with
`HOSTS: daybook.co.uk www.daybook.co.uk`.

`www.daybook.co.uk` already exists on the edge, attached to the shared rule
`hh-netscaler-grafana-int-3001`. After moving it, take `host:www.daybook.co.uk` out of
that rule's `servers` list in the control plane. Never repoint the shared rule: eight
other hosts use it.

## What's seeded (vertical `practice`, workspace `daybook-demo`)

| Client | Lines | State | What the practice sees |
|---|---|---|---|
| C1 Jordan Hale, 100-property landlord | 275 (2025-26) + 275 (2024-25, all confirmed) | 274 sorted from last year's confirmations; one line (new kitchen) flagged by the AI and settled by Ade as capital | Filing request **filed**, with an HMRC reference and the needs-info / reply exchange |
| C2 Priya Shah, 2 flats | 60 | 3 flagged | Filing request **needs info** (kitchen: repair or improvement?) |
| C3 Tom Reid, IT consultant | 113, two half-year statements | 3 corrected by Ade with notes, 3 still flagged | Filing request **reviewing** |
| C4 Ellie Moss, Corner Cup Café (VAT) | 375, VAT-coded | 5 flagged lines in Oct–Dec with no VAT code | VAT → VAT clients: Q1 **submitted** (sandbox receipt), Q2 **draft ready**, Q3 open |
| C5 Dan Kowalski, CIS builder | 150 | Sorted, not reviewed, 4 flagged | (no filing request yet) |
| C6 Sam Rivers, employee + Etsy | 68 | 2 flagged | Filing request **submitted** |

Every line has:

- a category and HMRC box;
- a confidence;
- who classified it (`learned` = from last year, `rule_engine`, `agent` = AI);
- the reason shown in the review screen;
- its review state.

The figures in the filing queue are built by `lib/tax-report.lua`, the same code a real
request uses.

**What the demo login sees:**

- **Filing requests:** the practice's queue for this workspace (RBAC module
  `tax_filing_requests`, read).
- **VAT clients:** the login has an HMRC-confirmed agent link to C4, so the client's
  returns and lines open read-only (module `vat_agent`, read).
- **Its own Tax pages** (Transactions, Statements, Reports, File My Tax, AI assistant):
  OpsAPI shows these per person, and has no "view as client". So the seed gives the
  demo login a **copy of C3's book** (`viewer_book` in the vertical), with an
  assistant conversation explaining that it's a sample client's book.
- **Users, roles, workspace, theme:** read only.

## Reset

`reset.yaml` runs every 30 minutes:

1. It copies the seed files (ConfigMap `daybook-demo-seeds`) into the API pod.
2. It runs `seed-daybook.lua`: password, viewer role and theme, for every vertical.
3. It runs `seed-daybook-data.lua`: it deletes and rewrites each client's tax rows, and
   the demo login's rows in each workspace.

The generators are deterministic, so the demo comes back identical. A run takes about
1–2 s per vertical.

Run it now:

```bash
kubectl -n daybook-demo create job reset-now --from=cronjob/daybook-demo-reset
kubectl -n daybook-demo logs -l app=daybook-demo-reset --tail=50
```

By hand, one vertical:

```bash
POD=$(kubectl -n daybook-demo get pod -l app=daybook-demo -o jsonpath='{.items[0].metadata.name}')
tar -C devops/daybook-demo -cf - . | kubectl -n daybook-demo exec -i "$POD" -- sh -c \
  'rm -rf /tmp/daybook-seed && mkdir -p /tmp/daybook-seed && tar -C /tmp/daybook-seed -xf -'
kubectl -n daybook-demo get secret daybook-demo-login -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d | \
kubectl -n daybook-demo exec -i "$POD" -- sh -c "cat > /tmp/daybook-seed/demo-password && cd /app && \
  lapis exec 'assert(loadfile(\"/tmp/daybook-seed/seed-daybook.lua\"))(\"practice\")' && \
  lapis exec 'assert(loadfile(\"/tmp/daybook-seed/seed-daybook-data.lua\"))(\"practice\")'"
```

## Adding a vertical

1. Copy `verticals/_example.lua` to `verticals/<slug>.lua`. Use namespace
   `daybook-<slug>`; use `practice.lua` as the worked example.
2. Add `"<slug>"` to `verticals/index.lua`.
3. Re-run the workflow, or update the ConfigMap and run the reset job.

The demo login joins the new workspace as a viewer automatically. Only one vertical may
set `viewer_book`, because personal tax pages aren't per workspace.

## Deep links into a workspace

- **No deep link today.** After sign-in, the dashboard opens the user's default
  workspace (the first vertical, set by the seed). Visitors change workspace with the
  workspace switcher.
- **`?namespace=<slug>` themes the login page only.** `/login?namespace=<slug>` applies
  that workspace's theme to the login page (`components/layout/PublicThemeStyles.tsx`),
  but doesn't select the workspace.
- **Without it, the login page shows the default theme.** The host's first label is
  `demo`, which matches no workspace.

So `/demos/<slug>` on the website should link to
`https://demo.daybook.co.uk/login?namespace=daybook-<slug>`, and tell visitors to pick
the workspace by name in the switcher.

Smallest change that makes it a real deep link: after login, if the URL has
`?namespace=` and the user belongs to that workspace, call `switchNamespace` (about 15
lines in the dashboard's post-login redirect).

## Verify

```bash
API=https://demo-api.daybook.co.uk
TOKEN=$(curl -s -X POST $API/auth/login --data-urlencode username=demo@daybook.co.uk \
  --data-urlencode "password=$DEMO_PASSWORD" | jq -r .token)
H=(-H "Authorization: Bearer $TOKEN" -H "X-Namespace-Slug: daybook-demo")
curl -s "${H[@]}" $API/api/v2/tax/filing/queue | jq '.meta.counts'          # filed 1, needs_info 1, reviewing 1, submitted 1
curl -s "${H[@]}" $API/api/v2/vat/agent/clients | jq '.data[].business_name' # "Corner Cup Café"
curl -s "${H[@]}" "$API/api/v2/tax/transactions?perPage=1" | jq .total       # 113 (the copy of C3)
curl -s -o /dev/null -w '%{http_code}\n' "${H[@]}" -X PUT $API/api/v2/namespace -d '{"name":"x"}'   # 403
curl -s "$API/api/v2/themes/active/styles.css?namespace=daybook-demo" | grep -c 1D3A5F           # 1
```

## Known limits

- **The demo login can edit its own book.** It can change its *own* sample lines,
  profile and uploads: personal tax routes check sign-in, not workspace roles. The
  reset puts everything back within 30 minutes. Workspace data (the clients, the queue,
  VAT clients, members, theme) is read-only.
- **No PDFs behind the statements.** Statement rows have no file in MinIO (this
  release has none), so "download statement" has nothing to fetch. Lines, periods and
  balances are all there.
- **CIS isn't modelled by the estimate.** CIS deductions (C5) are recorded in each
  line's note; the estimator has no CIS field, so they aren't credited against the tax.
- **The theme can't change everything.** It sets colours and the brand-name CSS
  variable. The sidebar still shows the workspace name ("Harbour & Lane Accountants")
  and the stock logo slot.
