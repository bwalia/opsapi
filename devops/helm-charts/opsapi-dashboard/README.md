# opsapi-dashboard chart

Deploys the OpsAPI admin UI (Next.js, `opsapi-dashboard/`) for
`*.workstation.co.uk`, talking to the `workstation-opsapi` API.

- **Release:** `workstation-opsapi-dashboard` (namespace = ring: int|test|acc|prod)
- **Public hosts:**
  - int  https://int-opsapi-ui.workstation.co.uk  → https://int-opsapi.workstation.co.uk
  - test https://test-opsapi-ui.workstation.co.uk → https://test-opsapi.workstation.co.uk
  - acc  https://acc-opsapi-ui.workstation.co.uk  → https://acc-opsapi.workstation.co.uk
  - prod https://opsapi-ui.workstation.co.uk      → https://opsapi.workstation.co.uk
- **Deployed by:** `.github/workflows/deploy-workstation-dashboard.yml`
  (build image → Cloudflare DNS → WSL Proxy vhost → helm upgrade), or via
  Ring Promoter app `workstation-opsapi-ui`.

## Build-time API URL (important)

Next.js inlines `NEXT_PUBLIC_*` into the browser bundle **at build time**, so
the image is built with `--build-arg NEXT_PUBLIC_API_URL=<apiUrl>`. The workflow
reads `apiUrl:` from `values-workstation-<env>.yaml` and uses it both as the
build arg and the runtime env, so they can never drift. Changing the API host
means a **rebuild**, not just a values edit.

## Routing (mirrors the API)

`ingress.className: traefik-edge` — identical to the working `workstation-opsapi`
API hosts. TLS terminates at the WSL Proxy edge; traefik-edge serves plain HTTP
:80 behind it and routes by Host header. Do **not** use `wslproxy` (bare 404 —
controller cannot program its OpenResty data plane). The edge vhost is a stub
under `.github/wslproxy/data/servers/prod/` reusing the `opsapi-prod-default`
rule (same k3s ingress backend as the API); prod UI uses `opsapi-prod-cloud003`.

## Adding an environment

1. Add `values-workstation-<env>.yaml` (set `env`, `apiUrl`, `host`,
   `ingress.hostname`).
2. Add the stub vhost `host:<env>-opsapi-ui.workstation.co.uk.json` and append
   it to the `opsapi-prod-default` rule's `servers`.
3. Deploy via the workflow with that `TARGET_ENV`.
