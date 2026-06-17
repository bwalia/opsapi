# OpsAPI SRE on k3s (production)

The production deployment of the same SRE operating model as the Docker demo,
via Helm community charts + a thin layer of OpsAPI-specific CRs. The SLO rules,
golden-signal rules, dashboards and Gatus checks are **identical** to the demo —
only the packaging differs (Operator CRs instead of file mounts).

## What gets installed (namespace `monitoring`)

| Component | Chart | Role |
|-----------|-------|------|
| Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics | `prometheus-community/kube-prometheus-stack` | metrics + alerting + dashboards |
| Loki + Promtail | `grafana/loki`, `grafana/promtail` | logs |
| Tempo + OpenTelemetry Collector | `grafana/tempo`, `open-telemetry/opentelemetry-collector` | traces |
| ServiceMonitor / Probe | `manifests/opsapi-servicemonitor.yaml` | scrape app `/metrics` + probe `/health` |
| PrometheusRule ×2 | `manifests/golden-signals-rules.yaml`, `opsapi-slo-rules.yaml` | recording + SLO burn-rate + dependency alerts |
| AlertmanagerConfig | `manifests/alertmanager-config.yaml` | P1–P4 routing, inhibition, runbook links |
| Grafana dashboards | ConfigMaps generated from `../grafana/dashboards/*.json` | the 5 dashboards |
| Gatus | `manifests/gatus.yaml` | public status page (Deployment+Service+Ingress) |
| Backup CronJob | `manifests/backup-cronjob.yaml` | nightly pg_dump → MinIO (RPO) |

## Prerequisites

- A k3s cluster and `kubectl`/`helm` v3 configured (`KUBECONFIG` set).
- The OpsAPI app running (Helm charts in `devops/helm-charts/`). Adjust the
  `ServiceMonitor` selector / namespaces in `manifests/` to match your release
  (defaults assume app namespace `opsapi`, Service label `app=diytaxreturn-lapis`).
- For real paging, an `opsapi-alert-secrets` Secret (Slack/PagerDuty) — ideally a
  SealedSecret (this repo already uses `devops/kubeseal`).

## Install

```bash
cd sre/k3s
DRY_RUN=1 ./install.sh     # validate: helm --dry-run + kubectl --dry-run=client
./install.sh               # real install (idempotent; safe to re-run)
```

## Verify

```bash
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/opsapi-monitoring-prometheus 9090:9090   # Targets → opsapi UP
kubectl -n monitoring port-forward svc/opsapi-monitoring-grafana 3000:80        # OpsAPI SRE dashboards
# Status page via the Ingress host set in manifests/gatus.yaml
```
Check: Prometheus *Targets* shows `opsapi` up; *Alerts* lists the SLO/burn-rate
rules; Grafana has the **OpsAPI SRE** folder with all 5 dashboards; Tempo/Loki
appear as datasources with trace↔log correlation; the backup CronJob is scheduled
(`kubectl -n opsapi get cronjob`).

## Uninstall

```bash
./uninstall.sh
```

## Domains via wslproxy

Two scenarios, same `wslproxy` ingress class + `cert-manager.io/cluster-issuer:
main-issuer` TLS pattern used across the platform. **There is no wildcard DNS** —
every new host needs a CNAME → `pop0.wslproxy.com` (just like every existing
`*.diytaxreturn.co.uk` host). Always use a **unique host** (the `sre-` prefix) so
it never shares a host with the app's own Ingress — that sharing is what caused
the wslproxy two-Ingress flapping outage on 2026-06-15.

### A. Expose the LOCAL Docker demo (this machine)

`local-docker-wslproxy.yaml` points selector-less Services at this host's
docker-published ports (192.168.1.193) and attaches wslproxy Ingresses:

| Host | → Docker port | Tool |
|------|---------------|------|
| `sre-grafana.diytaxreturn.co.uk` | 3012 | Grafana |
| `sre-status.diytaxreturn.co.uk` | 8878 | Gatus status page |
| `sre-prometheus.diytaxreturn.co.uk` | 9091 | Prometheus (lock down before sharing) |
| `sre-alerts.diytaxreturn.co.uk` | 9093 | Alertmanager (lock down before sharing) |

```bash
kubectl apply -f local-docker-wslproxy.yaml      # already applied
# then: add the 4 DNS CNAMEs, set GRAFANA_ROOT_URL in sre/.env.sre, make demo-up
```

### B. Per-env hosts for the k3s-deployed stack

When you run `install.sh` against int/acc/prod, override the Grafana + Gatus host
per env (the manifests default to `acc-sre-*`):

| Env | Grafana | Status (Gatus) |
|-----|---------|----------------|
| int | `int-sre-grafana.diytaxreturn.co.uk` | `int-sre-status.diytaxreturn.co.uk` |
| acc | `acc-sre-grafana.diytaxreturn.co.uk` | `acc-sre-status.diytaxreturn.co.uk` |
| prod | `sre-grafana.diytaxreturn.co.uk` | `status.diytaxreturn.co.uk` |

```bash
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring \
  -f values/kube-prometheus-stack.values.yaml \
  --set grafana.ingress.hosts[0]=int-sre-grafana.diytaxreturn.co.uk \
  --set grafana.ingress.tls[0].hosts[0]=int-sre-grafana.diytaxreturn.co.uk \
  --set grafana.ingress.tls[0].secretName=grafana-sre-tls \
  --set grafana.grafana\.ini.server.root_url=https://int-sre-grafana.diytaxreturn.co.uk
# edit manifests/gatus.yaml host → int-sre-status.diytaxreturn.co.uk, then apply
```

> Keep **Prometheus/Alertmanager internal** in shared envs (port-forward), or put
> them behind auth before giving them a host.

## Production hardening notes

- **Storage:** point Loki/Tempo at MinIO/S3 (uncomment in `values/loki.values.yaml`)
  for durable, scalable retention instead of filesystem.
- **Multi-AZ / HA:** run Prometheus with 2 replicas + Thanos/Mimir for long-term
  + global query; spread pods across zones with topology spread constraints.
- **TLS/auth:** put Grafana and Gatus behind the ingress with TLS + SSO; restrict
  Prometheus/Alertmanager to cluster-internal.
- **Secrets:** never commit receiver creds — use SealedSecrets/ExternalSecrets
  (the repo already has both patterns).
- **App tracing:** to populate Tempo with real OpsAPI spans, instrument the
  OpenResty app (OTel nginx module / `lua-resty-opentelemetry`) to export OTLP to
  the collector — see ../README.md → "Tracing the Lua app".
