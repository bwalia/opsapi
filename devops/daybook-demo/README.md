# Daybook demo back office (`demo.daybook.co.uk`)

A read-only OpsAPI back office that shows AI tax returns with fictional data. It is
the demo behind daybook.co.uk/demo and /demos. One deployment
(`PROJECT_CODE=tax_copilot`) holds **one workspace per use case** ("vertical"). Every
name, figure and address is made up. The spec is `docs/plans/DAYBOOK_DEMO_SPEC.md`.

It runs as **two Ring Promoter apps** on the workstation instance
(https://rp.workstation.co.uk), the same way as jobshout and `workstation-opsapi`:
`daybook-demo` (API) and `daybook-demo-ui` (dashboard). Each ring is a copy of the demo
in the shared k3s1 namespace of the same name; every k8s name is prefixed
`daybook-demo-`, so nothing collides with the other apps there.

| Ring | Namespace | Dashboard | API |
|---|---|---|---|
| int | `int` | `int-demo.daybook.co.uk` | `int-demo-api.daybook.co.uk` |
| test | `test` | `test-demo.daybook.co.uk` | `test-demo-api.daybook.co.uk` |
| acc | `acc` | `acc-demo.daybook.co.uk` | `acc-demo-api.daybook.co.uk` |
| prod | `prod` | **`demo.daybook.co.uk`** (published) | **`demo-api.daybook.co.uk`** |

In every ring:

- **API:** Helm release `daybook-demo` (`values-daybook-demo-<ring>.yaml`), image
  `bwalia/opsapi:<release>`, `PROJECT_CODE=tax_copilot`.
- **Dashboard:** Helm release `daybook-demo-dashboard`, image
  `bwalia/opsapi-dashboard:daybook-<ring>-<release>-<run>`, built per ring because the
  API URL is baked in.
- **Postgres:** StatefulSet `daybook-demo-db` (`devops/k8s/daybook-demo-db.yaml`).

**Promotion:**

1. A merge to main cuts a release. `deploy-k3s.yml`'s seed job seeds it into **int** for
   both apps, next to `workstation-opsapi`.
2. Ring Promoter auto-promotes **int → test → acc** when each ring is healthy.
3. **acc → prod is by hand**, with the production password, like jobshout.

Promote the API before the dashboard, with the same release. RP dispatches
`deploy-daybook-demo.yml` (`TARGET_ENV`, `IMAGE_TAG`) and
`deploy-daybook-dashboard.yml` (`TARGET_ENV`, `VERSION`).

**Secrets:** WSLVault (https://vault.workstation.co.uk, mount `kv`), per ring, synced by
ESO (`ClusterSecretStore` `wslvault-backend`). Like jobshout's `jobshout/<ring>/<name>`,
the chart and manifests commit paths only:

| WSLVault path | Keys | Becomes |
|---|---|---|
| `daybook-demo/<ring>/config` | `POSTGRES_*`, `JWT_SECRET_KEY`, `OPENSSL_SECRET_KEY/IV`, `ADMIN_PASSWORD` (+ optional `HMRC_CLIENT_ID/SECRET`) | `daybook-demo-secrets` (chart), `daybook-demo-db-auth` |
| `daybook-demo/<ring>/login` | `DEMO_PASSWORD` | `daybook-demo-login` (seed, reset job, deploy checks) |

**Traffic:** browser → Cloudflare CNAME (DNS only) → wslproxy edge `lon1.pop0.uk`
(Let's Encrypt), with lon2/pop0 mirroring it → rule `daybook-demo-default` (all 8 hosts)
→ k3s1 traefik-edge `193.237.176.232:8888` → pods, routed by Host header.

**Public login:** `demo@daybook.co.uk`, with the password published on
daybook.co.uk/demos. It's `DEMO_PASSWORD` in WSLVault `daybook-demo/<ring>/login`,
never in git, so secret scanners (GitGuardian) stay quiet.

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
| `reset.yaml` | CronJob (every 30 min) that re-runs both seeds for every vertical, plus a ServiceAccount that may only exec into pods in its ring namespace. Ring-agnostic: applied with `sed s/__RING__/<ring>/ \| kubectl -n <ring> apply` |
| `selfheal.yaml` | Copy of `devops/demo/selfheal.yaml`, limited to the two Daybook releases (the ring namespaces are shared) with a Role narrower than `admin` |
| `seed-vault-daybook.sh` | Writes `daybook-demo/<ring>/config` and `daybook-demo/<ring>/login` to WSLVault (`RING=int\|test\|acc\|prod\|all`) |
| `../k8s/daybook-demo-db.yaml` | Postgres (pgvector) and the ring's two ExternalSecrets (`__RING__` filled at apply) |
| `../helm-charts/*/values-daybook-demo-<ring>.yaml` | API and dashboard values per ring (`host:` / `apiUrl:` are read by the workflows) |
| `../../.github/workflows/deploy-daybook-demo.yml` | One ring of the API: DNS → edge → DB + secrets → API → seed → reset/self-heal → checks. `EDGE_ONLY=true` does DNS + edge for all 8 hosts |
| `../../.github/workflows/deploy-daybook-dashboard.yml` | One ring of the dashboard: build for that ring's API URL → DNS → edge → helm → public probe |
| `../../.github/wslproxy/data/{rules,servers}/prod/*daybook*` | Edge records: `daybook-demo-default` (8 demo hosts), `daybook-website-pages` and `daybook-www-redirect` (website) |
| `ring-promoter` repo, `deploy/k8s/configmap.yaml` | The `daybook-demo` and `daybook-demo-ui` app entries |

## Run order (first time)

1. **WSLVault, per ring** (prompts for the published `DEMO_PASSWORD` without echo):

   ```bash
   export WSLVAULT_API_KEY='wslv_…'    # a scoped key made in the WSLVault UI
   RING=all ./devops/daybook-demo/seed-vault-daybook.sh     # or RING=int, then the others later
   ```

   For "Connect to HMRC" in the demo only: add the HMRC **sandbox** application's
   `HMRC_CLIENT_ID` / `HMRC_CLIENT_SECRET` to `daybook-demo/<ring>/config`. Then add
   each ring's `https://<api host>/auth/hmrc/callback` to that application's redirect
   URIs.
2. **Ring Promoter config:** merge the `daybook-demo` / `daybook-demo-ui` entries in the
   ring-promoter repo (`deploy/k8s/configmap.yaml`). Its deploy workflow applies the
   ConfigMap and restarts RP. RP's `RP_GITHUB_TOKEN` already dispatches workflows in
   bwalia/opsapi for `workstation-opsapi`.
3. **Edge and DNS for all 8 hosts, once:**
   `gh workflow run deploy-daybook-demo.yml -f TARGET_ENV=int -f EDGE_ONLY=true`.
   Every deploy re-ensures its own ring's hosts anyway.
4. **First deploy:** seed int in Ring Promoter, or merge to main and let
   `deploy-k3s.yml` do it:

   ```bash
   curl -X POST https://rp.workstation.co.uk/api/apps/daybook-demo/seed?async=true \
     -H "Authorization: Bearer $RP_TOKEN" -d '{"ring":"int","version":"<release>"}'
   ```

   Then the same for `daybook-demo-ui`. RP carries both to acc; promote acc → prod in
   the RP UI.

   The migrate hook creates the platform admin's own workspace `daybook-admin` (kept
   apart from the demo workspaces). The seeds then create `daybook-demo` and the rest.

Repo secrets used by the workflows (all already exist for the other demos):
`CLOUDFLARE_API_TOKEN` (zone `daybook.co.uk`), `KUBE_CONFIG_DATA_K3S`,
`DOCKER_USERNAME`/`DOCKER_PASSWD`, `WORKSTATION_RING_PROMOTER_TOKEN`, and the wslproxy
login.

### Website hosts (daybook.co.uk, www)

The workflows only register the demo hosts. Register the website hosts by hand,
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

Run it now (in ring `prod`; use the ring's namespace):

```bash
kubectl -n prod create job daybook-demo-reset-now --from=cronjob/daybook-demo-reset
kubectl -n prod logs -l app=daybook-demo-reset --tail=50
```

By hand, one vertical:

```bash
NS=prod
POD=$(kubectl -n $NS get pod -l app=daybook-demo -o jsonpath='{.items[0].metadata.name}')
tar -C devops/daybook-demo -cf - . | kubectl -n $NS exec -i "$POD" -- sh -c \
  'rm -rf /tmp/daybook-seed && mkdir -p /tmp/daybook-seed && tar -C /tmp/daybook-seed -xf -'
kubectl -n $NS get secret daybook-demo-login -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d | \
kubectl -n $NS exec -i "$POD" -- sh -c "cat > /tmp/daybook-seed/demo-password && cd /app && \
  lapis exec 'assert(loadfile(\"/tmp/daybook-seed/seed-daybook.lua\"))(\"practice\")' && \
  lapis exec 'assert(loadfile(\"/tmp/daybook-seed/seed-daybook-data.lua\"))(\"practice\")'"
```

## Adding a vertical

1. Copy `verticals/_example.lua` to `verticals/<slug>.lua`. Use namespace
   `daybook-<slug>`; use `practice.lua` as the worked example.
2. Add `"<slug>"` to `verticals/index.lua`.
3. Merge: the next release carries it through the rings. To try it sooner, update the
   ring's ConfigMap (`daybook-demo-seeds`) and run its reset job.

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
API=https://demo-api.daybook.co.uk     # or https://<ring>-demo-api.daybook.co.uk
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
