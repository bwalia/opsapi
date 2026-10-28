# OpsAPI `demo` identity stack on k3s1

An isolated OpsAPI (own Postgres, own Vault path, own tenant `demo`) used as a
B2C identity provider for apps on `*.demo.opsapi.org`. Open sign-up through
Google or email; every new user joins the `demo` namespace.

| Host | What | In k3s1 (namespace `demo`) |
|---|---|---|
| `identity.demo.opsapi.org` | OpsAPI API | Helm release `opsapi-demo` |
| `dashboard.demo.opsapi.org` | Admin UI | Helm release `opsapi-demo-dashboard` |
| `hello-java.demo.opsapi.org` | Spring Boot client | Service `hello-java` → :8080 |
| `hello-php.demo.opsapi.org` | PHP client | Service `hello-php` → :80 |

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

## Notes

- `X-Namespace-Slug: demo` is injected by the edge on `identity.demo.opsapi.org`
  only; the API is the only service that reads it. That pins every API call to
  `demo`, including the dashboard's, which is what a single-tenant demo wants.
- `X-Real-IP` / `X-Forwarded-For` / `X-Forwarded-Proto` are already set by the
  edge's proxy location for every vhost; the vhost JSON has no field for them.
- Proxy buffers: wslproxy's server/rule JSON has no buffer-size fields. None
  are needed: the Google `state` is a ~150-byte JSON, and the largest header
  in the flow is the `Location: …/auth/callback?token=<JWT>` redirect (~1–2 KB),
  well under nginx's 4–8 KB default `proxy_buffer_size`.
- `projectCode: core_only` = auth, users, namespaces and RBAC only.
- An ESO `PushSecret` can't seed the Vault path: WSL Vault returns 404 on the
  `kv/metadata/...` write ESO makes first. Use `seed-vault-demo.sh`.
