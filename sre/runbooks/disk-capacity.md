# Runbook: Disk / Memory / CPU Saturation

**Alerts:** `DiskWillFillIn4Days`, `DiskSpaceLow`, `MemoryUtilizationHigh`, `OpsAPISaturationCPU` · **Severity:** P3

## Description
A host/node resource is saturated or trending toward exhaustion. `DiskWillFillIn4Days`
is a *forecast* from `predict_linear()` (Capacity dashboard).

## Impact
Disk-full causes the nastiest failures: Postgres stops accepting writes, logs
stop, containers crash. Memory pressure ⇒ OOMKills. CPU saturation ⇒ latency.
Acting on the forecast keeps this a **P3 ticket**, not a 3am page.

## Diagnosis
1. Grafana → **OpsAPI · Capacity Planning**: current vs predicted vs threshold;
   "days until disk full".
2. Which filesystem / which consumer?
   ```bash
   df -h                                  # host
   docker system df                       # images/volumes/build cache
   du -sh /var/lib/docker/volumes/* | sort -h | tail
   ```
   - k3s: `kubectl -n <ns> get pvc`; `kubectl describe node <node>` (allocated vs capacity).
3. Usual disk hogs: Postgres data growth, Prometheus/Loki/Tempo TSDB, nginx logs,
   MinIO objects, Docker build cache / dangling images.

## Mitigation
- **Disk:**
  - Reclaim: `docker system prune -af --volumes` (careful — only safe data),
    rotate/ship logs, drop old Prometheus/Loki/Tempo data (retention is set in
    their configs), expire MinIO temp buckets.
  - Grow the volume / add a disk; for PG, move WAL or expand the PVC.
- **Memory:** raise limits or add replicas; find the leaking process; cap
  Ollama/LLM memory (compose sets a 4G limit).
- **CPU:** scale out (`kubectl scale deployment/diytaxreturn-lapis --replicas=N`)
  or enable HPA (`autoscaling.enabled=true` in the Helm values).

## Verify
Utilisation back under threshold; forecast "days to full" comfortably > 14d.

## Escalation
If reclaim doesn't buy headroom, this becomes a capacity-planning decision —
see `../capacity/capacity-planning.md` and involve the platform owner.
