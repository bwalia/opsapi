# OpsAPI · World-Class SRE

A complete, self-contained **Site Reliability Engineering** stack for OpsAPI —
the reliability *operating model*, not just a pile of tools. It runs two ways
from the same source of truth:

- **Docker demo** — one command stands up the whole thing with synthetic load,
  so SLOs, golden-signal dashboards, burn-rate alerts and error-budget burn
  visibly fire on their own. Great for learning, demos, and local validation.
- **k3s production** — the identical SLOs/rules/dashboards/status-page deployed
  via Helm community charts (`./k3s/`).

```
                          ┌──────────────────────────────────────────────┐
  OpsAPI app  ──/metrics─▶│  Prometheus  ─rules─▶ recording / SLO / burn   │
   (or synthetic)  logs──▶│  Loki                  ─▶ Alertmanager ─▶ P1–P4 │
                  traces─▶│  Tempo ◀── OTel Collector                       │
                          │            ▼                                    │
                          │         Grafana  (3-pillar correlation)         │
                          │         Gatus    (public status page)           │
                          └──────────────────────────────────────────────┘
```

## Quick start (Docker demo)

```bash
cd sre
cp .env.sre.example .env.sre        # no secrets needed; defaults just work
make demo-up                        # build + start + print the URL map
make demo-load                      # drive traffic → watch SLOs + budget burn
make alerts                         # see the pages/tickets that fired
```

| Service | URL | Notes |
|---------|-----|-------|
| Grafana | http://localhost:3012 | admin / admin · folder **OpsAPI SRE** |
| Prometheus | http://localhost:9091 | Targets, Alerts, rules |
| Alertmanager | http://localhost:9093 | routing + silences |
| Gatus (status page) | http://localhost:8878 | SLO-aligned uptime checks |
| Loki / Tempo | via Grafana → Explore | logs & traces |

Ports are deliberately offset (9091/3012/8878) so this stack can run **alongside**
the inline Prometheus/Grafana/Gatus in `lapis/docker-compose.yml` without clashing.

Try the reliability drills:

```bash
make chaos          # pause Postgres → PostgresDown fires → recovers
make backup-test    # pg_dump + restore verify (proves RPO)
make dr-drill       # kill app tier, measure RTO, write a report
make validate       # lint compose + promtool rules + amtool + dashboards
```

## The 10 SRE layers — where each lives

| # | Layer | Implementation |
|---|-------|----------------|
| 1 | **SLOs** | [`slo/slo-definitions.yaml`](slo/slo-definitions.yaml) — availability 99.95%, P95<200ms, errors<0.1%, DB 99.99% |
| 2 | **Golden signals** | [`prometheus/rules/golden-signals.rules.yml`](prometheus/rules/golden-signals.rules.yml) + the Golden Signals dashboard |
| 3 | **Full observability** | Metrics (Prometheus) · Logs ([Loki](loki/) + [Promtail](promtail/)) · Traces ([Tempo](tempo/) + [OTel Collector](otel-collector/)) — correlated in Grafana |
| 4 | **Error budgets** | [`prometheus/rules/slo-burn-rate.rules.yml`](prometheus/rules/slo-burn-rate.rules.yml) (multi-window burn rate) + [policy](slo/README.md) + SLO dashboard |
| 5 | **Incident management** | [`incident/`](incident/) — severity matrix, response process, postmortem template; Alertmanager P1–P4 routing |
| 6 | **Automate everything** | [`Makefile`](Makefile) + [`scripts/`](scripts/) (demo, backup-test, dr-drill, chaos, validate) + k3s `install.sh` |
| 7 | **Runbooks** | [`runbooks/`](runbooks/) — one per alert, linked from every alert's `runbook_url` |
| 8 | **Reliability eng.** | Backups + restore verification ([`scripts/backup-test.sh`](scripts/backup-test.sh), [k3s CronJob](k3s/manifests/backup-cronjob.yaml)); DR drill (RTO/RPO) |
| 9 | **Capacity planning** | [`capacity/`](capacity/) + [`prometheus/rules/capacity.rules.yml`](prometheus/rules/capacity.rules.yml) (predict_linear forecasts) + dashboard |
| 10 | **Continuous improvement** | Blameless [postmortem template](incident/postmortem-template.md) + action-item tracking + error-budget reviews |

## Directory map

```
sre/
├── slo/                  SLO definitions + error-budget policy
├── prometheus/           scrape config + recording/SLO/capacity/infra rules
├── alertmanager/         P1–P4 routing, inhibition, runbook links
├── grafana/              datasources (3-pillar correlation) + 5 dashboards
├── loki/ promtail/       logs pipeline
├── tempo/ otel-collector/ traces pipeline
├── blackbox/             external availability probing
├── gatus/                public status page
├── synthetic-target/     OpenResty app emitting OpsAPI's exact metric schema
├── incident/             severity matrix, response process, postmortem template
├── runbooks/             one runbook per alert (+ index)
├── capacity/             capacity-planning method & cadence
├── scripts/              demo / load / backup-test / dr-drill / chaos / validate
├── docker-compose.sre.yml + Makefile + .env.sre.example
└── k3s/                  Helm values + CR manifests + install.sh (production)
```

## Observe the real app (instead of the synthetic target)

By default the demo scrapes `synthetic-opsapi`, which emits OpsAPI's exact metric
schema so everything works standalone. To point at the **real** running app:

1. Start the OpsAPI stack (`./start.sh -e local …` from the repo root).
2. Link this stack onto the app network and enable the real target:
   ```bash
   docker network connect opsapi-sre-net opsapi        # join the app container
   ```
   Then in [`prometheus/prometheus.yml`](prometheus/prometheus.yml) uncomment the
   `lapis:80` target (and comment the synthetic one), and in
   [`gatus/config.yml`](gatus/config.yml) swap `synthetic-opsapi`→`lapis`. Reload:
   `curl -X POST http://localhost:9091/-/reload`.

The metric names, rules and dashboards are identical either way — that's the
point: the synthetic target is schema-faithful to production.

## Tracing the Lua app

The trace **pipeline** (OTel Collector → Tempo → Grafana correlation) is fully
built and demonstrated with spans from the load generator. To emit **real**
OpsAPI spans, instrument the OpenResty app to export OTLP to the collector
(`otel-collector:4317`) via the OTel nginx module or `lua-resty-opentelemetry`.
This is the one piece that requires app-side code; everything else is turnkey.

## Design choices worth knowing

- **Burn-rate alerting** (multi-window/multi-burn-rate) instead of static
  thresholds — pages on fast budget burn, tickets on slow erosion. See
  [`slo/README.md`](slo/README.md).
- **One source of truth:** golden-signal recording rules feed both dashboards
  and alerts; the demo rules and the k3s `PrometheusRule` CRs are line-for-line
  mirrors.
- **Every alert has a runbook.** The `runbook_url` annotation resolves to a real
  file in [`runbooks/`](runbooks/).
- **No secrets committed.** Receivers are env-driven; the demo uses a local
  webhook sink so it runs with zero credentials.
