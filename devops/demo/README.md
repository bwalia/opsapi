# OpsAPI `demo` identity stack on k3s1

An isolated OpsAPI (own Postgres, own Vault path, own tenant `demo`) used as a
B2C identity provider for apps on `*.demo.opsapi.org`. Open sign-up through
Google or email; every new user joins the `demo` namespace.

| Host | What | In k3s1 (namespace `demo`) |
|---|---|---|
| `identity.demo.opsapi.org` | OpsAPI API | Helm release `opsapi-demo` |
| `dashboard.demo.opsapi.org` | Admin UI | Helm release `opsapi-demo-dashboard` |
| `hello-java.demo.opsapi.org` | Spring Boot client | Helm release `hello-java` |
| `hello-php.demo.opsapi.org` | PHP client | Helm release `hello-php` |
| `hello-python.demo.opsapi.org` | Python client | Helm release `hello-python` |
| `hello-rust.demo.opsapi.org` | Rust client | Helm release `hello-rust` |
| `hello-go.demo.opsapi.org` | Go client | Helm release `hello-go` |

Traffic: browser → Cloudflare CNAME (DNS-only) → wslproxy edge `lon1.pop0.uk`
(TLS) → k3s1 traefik-edge `193.237.176.232:8888` → pods, routed by Host header.

## Files

| File | Purpose |
|---|---|
| `devops/k8s/opsapi-demo-db.yaml` | pgvector Postgres 16 StatefulSet (`opsapi-demo-db`) |
| `devops/helm-charts/diytaxreturn-lapis/values-opsapi-demo.yaml` | API release values |
| `devops/helm-charts/opsapi-dashboard/values-opsapi-demo.yaml` | Dashboard release values |
| `devops/demo/seed-vault-demo.sh` | Writes secrets to WSL Vault `opsapi-demo/config` |
| `devops/demo/seed-demo-namespace.sql` | Sets the `demo` tenant's redirect origins |
| `devops/demo/opsapi.org.zone` | DNS records |
| `devops/demo/hello-apps.yaml` | Services and Ingresses for the two client apps |
| `.github/wslproxy/data/{servers,rules}/prod/*demo.opsapi.org*` | Edge vhosts and rule |

## Run order

```bash
export KUBECONFIG=~/.kube/k3s1.yaml

# 1. Google OAuth client (Google Cloud Console > Credentials > OAuth client, Web)
#    Authorised redirect URI:  https://identity.demo.opsapi.org/auth/google/callback
#    Put its client ID in values-opsapi-demo.yaml (googleClientId).

# 2. DNS: one CNAME per host, DNS-only
for h in identity dashboard hello-java hello-php; do
  CLOUDFLARE_ZONE=opsapi.org ./devops/scripts/cloudflare-dns.sh \
    --name "$h.demo.opsapi.org" --content lon1.pop0.uk --proxied false
done

# 3. Secrets → WSL Vault (fresh random DB/JWT/encryption keys + Google secret)
export WSLVAULT_API_KEY='wslv_…' GOOGLE_CLIENT_SECRET='GOCSPX-…'
./devops/demo/seed-vault-demo.sh
# then add GOOGLE_CLIENT_ID and the SMTP_* keys to the same path (see Notes)

# 4. Database, then the API (the pre-upgrade hook runs `lapis migrate` and
#    setup-namespace, which creates the `demo` namespace and its admin)
kubectl create namespace demo
kubectl apply -f devops/k8s/opsapi-demo-db.yaml
kubectl -n demo rollout status statefulset/opsapi-demo-db
helm upgrade --install opsapi-demo ./devops/helm-charts/diytaxreturn-lapis \
  -f ./devops/helm-charts/diytaxreturn-lapis/values-opsapi-demo.yaml \
  --namespace demo --timeout 20m
# The migrate hook is pre-UPGRADE only (its Secret doesn't exist during a
# first install), so a fresh install has an empty DB and /ready says
# "connection refused". Run the same command once more, then restart:
helm upgrade opsapi-demo ./devops/helm-charts/diytaxreturn-lapis \
  -f ./devops/helm-charts/diytaxreturn-lapis/values-opsapi-demo.yaml \
  --namespace demo --timeout 20m
kubectl -n demo rollout restart deploy/opsapi-demo
kubectl -n demo rollout status deploy/opsapi-demo

# 5. Dashboard: NEXT_PUBLIC_API_URL is baked in at build time
docker build -t bwalia/opsapi-dashboard:demo \
  --build-arg NEXT_PUBLIC_API_URL=https://identity.demo.opsapi.org opsapi-dashboard
docker push bwalia/opsapi-dashboard:demo
helm upgrade --install opsapi-demo-dashboard ./devops/helm-charts/opsapi-dashboard \
  -f ./devops/helm-charts/opsapi-dashboard/values-opsapi-demo.yaml --namespace demo

# 6. Tenant redirect origins
kubectl -n demo exec -i opsapi-demo-db-0 -- psql -U pguser -d opsapi_demo \
  -v ON_ERROR_STOP=1 < devops/demo/seed-demo-namespace.sql

# 7. Client apps (bring your own Deployments labelled app=hello-java / app=hello-php)
kubectl apply -f devops/demo/hello-apps.yaml

# 7b. Self-heal: every 10 min, re-applies any demo Helm release whose resources went missing
kubectl apply -f devops/demo/selfheal.yaml

# 8. Edge: push the committed vhosts + rule to wslproxy and take them live
gh workflow run wslproxy-register-domains.yml -f TARGET_ENV=prod -f ACTIVATE_CONFIG=true

# 9. Check
curl -s https://identity.demo.opsapi.org/health
```

## How the client apps sign users in

OpsAPI is **not** an OAuth 2.0 / OIDC authorization server: there's no client
registry, no `/authorize`/`/token` endpoints and no discovery document. Spring
Security's `oauth2Login()` (callback `/login/oauth2/code/opsapi`) can't use it
as a provider. The flow it does support:

1. The app sends the browser to
   `https://identity.demo.opsapi.org/auth/google?frontend_url=https://hello-java.demo.opsapi.org&from=/`
2. Google → `identity…/auth/google/callback` → OpsAPI finds or creates the
   user (new users join `demo`) and redirects to
   **`<frontend_url>/auth/callback?token=<JWT>&redirect=<from>`**.
   `frontend_url` must be a trusted origin (`CORS_ALLOWED_DOMAINS=opsapi.org`),
   otherwise the token goes to `FRONTEND_URL` instead.
3. The app's `/auth/callback` handler reads `token` and checks it with
   `GET https://identity.demo.opsapi.org/auth/me` (`Authorization: Bearer <token>`),
   then starts its own session. Don't verify the JWT locally: it is HS256
   signed with `JWT_SECRET_KEY`, which must not leave OpsAPI.

So the callback paths are `https://hello-java.demo.opsapi.org/auth/callback`
and `https://hello-php.demo.opsapi.org/auth/callback`.

## Public demo account (opsapi.org/demo)

`demo@opsapi.org` is published on the website so anyone can look around the
dashboard. It lives in its own workspace, `showcase`, which holds only
fictional `example.com` users owned by a fictional "Ava Patel". Real people who
sign in to the demo apps land in `demo`, which the demo account can't see.

- `viewer` role: `read` on every module, so every page opens and every change
  is refused with 403.
- `showcase` has the emailed sign-in code switched off, so the published
  password works on its own. `demo` keeps it on.
- `demo-account-reset.yaml`: a CronJob that every 30 minutes restores the
  account's password, active flag and viewer role, undoing anything a visitor
  changed from inside.
- `seed-showcase.lua` creates or repairs all of it (safe to re-run; see its
  header for the command). It now runs on the full demo (next section). The reset job's hash is of the published password:
  if you change the password, re-run the seed and update the hash.

## Full demo (showcase): every app, with sample data

A second, separate OpsAPI in the same k8s namespace, running **every** module
(`PROJECT_CODE=all`) on its own database. The `showcase` workspace and the
public `demo@opsapi.org` login live here, with made-up records in each app.
The identity demo above stays `core_only`; the two share nothing.

| Host | What | Helm release |
|---|---|---|
| `showcase.demo.opsapi.org` | Admin UI (open **Apps** in the sidebar for the catalog) | `opsapi-showcase-dashboard` |
| `showcase-api.demo.opsapi.org` | OpsAPI API, `PROJECT_CODE=all` | `opsapi-showcase` |
| `saml-idp.demo.opsapi.org` | Demo SAML identity provider (BoxyHQ Mock SAML) | `kubectl apply` (`mock-saml-idp`) |

| File | Purpose |
|---|---|
| `devops/k8s/opsapi-showcase-db.yaml` | Its own pgvector Postgres 16 (`opsapi-showcase-db`) |
| `devops/helm-charts/diytaxreturn-lapis/values-opsapi-showcase.yaml` | API release values |
| `devops/helm-charts/opsapi-dashboard/values-opsapi-showcase.yaml` | Dashboard release values |
| `devops/demo/seed-showcase.lua` | The `showcase` workspace, viewer role, demo login, fictional users |
| `devops/demo/seed-showcase-data.lua` | Sample records: CRM, leads, invoices, projects, timesheets, shop, care home, CMS, academy, forms, hiring, field service |
| `devops/k8s/mock-saml-idp.yaml` | Demo SAML IdP: signs a response for any `@example.com` / `@example.org` address |
| `devops/demo/seed-showcase-saml.lua` | Connects the `showcase` workspace to that IdP (role `viewer`) |
| `devops/demo/demo-account-reset.yaml` | Restores the demo login every 30 minutes (points at `opsapi-showcase-db`) |
| `.github/workflows/deploy-opsapi-showcase.yml` | Does all the steps below; runs weekly so the demo stays up and current |

**Automated:** run `gh workflow run deploy-opsapi-showcase.yml`. It also runs every Monday. The
manual steps below are the same thing by hand.

```bash
export KUBECONFIG=~/.kube/k3s1.yaml

# 1. DNS
for h in showcase showcase-api saml-idp; do
  CLOUDFLARE_ZONE=opsapi.org ./devops/scripts/cloudflare-dns.sh \
    --name "$h.demo.opsapi.org" --content lon1.pop0.uk --proxied false
done

# 2. Secrets: nothing to do. The showcase reads the identity demo's Vault
#    path (opsapi-demo/config) for its DB password, JWT/encryption keys and SMTP.

# 3. Database, then the API (run the upgrade twice on a fresh install, as above)
kubectl apply -f devops/k8s/opsapi-showcase-db.yaml
kubectl -n demo rollout status statefulset/opsapi-showcase-db
for i in 1 2; do
  helm upgrade --install opsapi-showcase ./devops/helm-charts/diytaxreturn-lapis \
    -f ./devops/helm-charts/diytaxreturn-lapis/values-opsapi-showcase.yaml \
    --namespace demo --timeout 20m
done
kubectl -n demo rollout restart deploy/opsapi-showcase

# 4. Dashboard (NEXT_PUBLIC_API_URL is baked in at build time)
docker build -t bwalia/opsapi-dashboard:showcase \
  --build-arg NEXT_PUBLIC_API_URL=https://showcase-api.demo.opsapi.org opsapi-dashboard
docker push bwalia/opsapi-dashboard:showcase
helm upgrade --install opsapi-showcase-dashboard ./devops/helm-charts/opsapi-dashboard \
  -f ./devops/helm-charts/opsapi-dashboard/values-opsapi-showcase.yaml --namespace demo

# 5. Workspace + demo login, then the sample data
POD=$(kubectl -n demo get pod -l app=opsapi-showcase -o jsonpath='{.items[0].metadata.name}')
kubectl -n demo cp devops/demo/seed-showcase.lua $POD:/tmp/seed-showcase.lua
kubectl -n demo cp devops/demo/seed-showcase-data.lua $POD:/tmp/seed-showcase-data.lua
kubectl -n demo exec $POD -- sh -c 'cd /app && printf %s "$PASSWORD" > /tmp/demo-password && \
  lapis exec "assert(loadfile(\"/tmp/seed-showcase.lua\"))()"; rm -f /tmp/demo-password'
kubectl -n demo exec $POD -- sh -c 'cd /app && lapis exec "assert(loadfile(\"/tmp/seed-showcase-data.lua\"))()"'

# 6. Demo SAML IdP (key generated once; keep the Secret), then connect the workspace
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=saml-idp.demo.opsapi.org \
  -keyout idp-key.pem -out idp-cert.pem
kubectl -n demo create secret generic mock-saml-idp-keys \
  --from-literal=PUBLIC_KEY="$(base64 -w0 < idp-cert.pem)" --from-literal=PRIVATE_KEY="$(base64 -w0 < idp-key.pem)"
rm idp-key.pem idp-cert.pem
kubectl apply -f devops/k8s/mock-saml-idp.yaml
kubectl -n demo cp devops/demo/seed-showcase-saml.lua $POD:/tmp/seed-showcase-saml.lua
kubectl -n demo exec $POD -- sh -c 'cd /app && curl -fsS -o /tmp/idp-metadata.xml \
  http://mock-saml-idp.demo.svc.cluster.local:4000/api/saml/metadata && \
  lapis exec "assert(loadfile(\"/tmp/seed-showcase-saml.lua\"))()"'

# 7. Demo-login reset job now targets the showcase DB
kubectl apply -f devops/demo/demo-account-reset.yaml

# 8. Edge, then check
gh workflow run wslproxy-register-domains.yml -f TARGET_ENV=prod -f ACTIVATE_CONFIG=true
curl -s https://showcase-api.demo.opsapi.org/api/v2/system/info | head -c 300
```

Then point the opsapi.org/demo link at `https://showcase.demo.opsapi.org`.

### SAML single sign-on demo

On `showcase.demo.opsapi.org/login` choose **Sign in with SSO**, enter any
address at `example.com` or `example.org` (e.g. `visitor@example.com`), press
**Continue**, then **Sign In** on the Mock SAML page. You come back signed in to
the showcase as a `viewer`, through a real, signed SAML 2.0 response. Workspace
owners see the setup under **Single sign-on** (`/dashboard/namespace/sso`).

Mock SAML asks for no password, so it is trusted by the showcase workspace
only, and SAML users there can't change anything. SAML users accumulate in
`users` (one per address typed); that's harmless and the reset job leaves them.

Both demos are permanent: don't uninstall either release or delete their
databases or workspaces (including the old `showcase` workspace in
`opsapi-demo`). The demo login is read-only, so visitors can't wipe the
sample data; if it's ever lost, re-run the two seed scripts (step 5).

## Notes

- The edge doesn't set `X-Namespace-Slug`. It used to inject `demo` on the
  identity host, which pinned every call to `demo` and broke any other
  workspace (`showcase`); the dashboard and apps send their own.
- `X-Real-IP` / `X-Forwarded-For` / `X-Forwarded-Proto` are already set by the
  edge's proxy location for every vhost; the vhost JSON has no field for them.
- Proxy buffers: wslproxy's server/rule JSON has no buffer-size fields. None
  are needed: the Google `state` is a ~150-byte JSON, and the largest header
  in the flow is the `Location: …/auth/callback?token=<JWT>` redirect (~1–2 KB),
  well under nginx's 4–8 KB default `proxy_buffer_size`.
- `projectCode: core_only` = auth, users, namespaces and RBAC only.
- Vault `opsapi-demo/config` also holds `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` (a dedicated
  OAuth client with the demo redirect URI) and `SMTP_*` (copied from `workstation-opsapi/prod/config`;
  without them 2FA codes can't be emailed and the admin can't finish logging in).
- `backup.enabled: false`: the chart's DB backup CronJobs upload to MinIO, which this release doesn't have.
- An ESO `PushSecret` can't seed the Vault path: WSL Vault returns 404 on the
  `kv/metadata/...` write ESO makes first. Use `seed-vault-demo.sh`.
