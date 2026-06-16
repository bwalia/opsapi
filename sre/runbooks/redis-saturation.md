# Runbook: Redis Down / Memory High

**Alerts:** `RedisDown`, `RedisMemoryHigh` · **Severity:** P2/P3

## Description
Redis is unreachable (`redis_up==0`) or using >85% of `maxmemory`. OpsAPI uses
Redis for sessions and caching.

## Impact
`RedisDown` ⇒ sessions/cache unavailable: users may be logged out, cache misses
hammer Postgres (watch for secondary DB saturation). Memory pressure ⇒ evictions
or OOM. Usually **P2**.

## Diagnosis
```bash
docker exec -it sre-demo-redis redis-cli INFO server | head
docker exec -it sre-demo-redis redis-cli INFO memory | grep -E 'used_memory_human|maxmemory_human|evicted_keys'
docker exec -it sre-demo-redis redis-cli INFO clients
```
- k3s: `kubectl -n <ns> get pods -l app=redis`; `kubectl logs <redis-pod>`.
- Dashboards: `redis_up`, `redis_memory_used_bytes / redis_memory_max_bytes`.
- Causes: OOM/eviction storm, a giant key, no `maxmemory-policy`, persistence
  (AOF/RDB) disk full, network partition.

## Mitigation
- **Down:** restart Redis; verify the data volume/disk; check the appendonly file
  isn't corrupt (demo runs `--appendonly`; prod per chart).
- **Memory high:** confirm an eviction policy is set (`allkeys-lru` in the demo);
  find big keys (`redis-cli --bigkeys`); raise `maxmemory` or scale; expire/trim
  stale cache keys.
- **Cache stampede onto Postgres:** if cache loss is driving DB load, throttle or
  warm the cache; watch [postgres-saturation.md](postgres-saturation.md).
- App should **degrade gracefully** when Redis is down (fall through to DB / fail
  open on cache) — verify it isn't hard-erroring.

## Verify
`redis_up==1`, memory utilisation < 85%, no eviction spikes, sessions working.

## Escalation
Platform on-call; eng lead if session loss is widespread (P2 comms).
