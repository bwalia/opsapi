# Chat Scaling Runbook

How the chat subsystem is built to scale, what's already optimised, and the
deferred infrastructure moves — each with a **trigger** (when to do it), a
**how**, and the **risk**. Written for engineers maintaining/scaling opsapi
chat; read this before "optimising" chat or reacting to a scale alarm.

Backend: `lapis/routes/chat-*.lua` → `lapis/queries/Chat*Queries.lua` → Postgres.
Real-time: `lapis/lib/chat-ws.lua` (WebSocket hub). Frontend:
`opsapi-dashboard/app/dashboard/chat/page.tsx` + `hooks/useChatSocket.ts`.

---

## 1. What's already done (do NOT redo)

The schema is purpose-built for volume — the read/write paths are index-backed
and free of the usual scale traps.

- **Message list = index-only-ish scan.** `chat_messages_list_covering_idx` is a
  *partial covering* index `(channel_uuid, created_at DESC) INCLUDE (uuid,
  user_uuid, content, content_type, attachments, is_pinned, reply_count) WHERE
  is_deleted=false AND parent_message_uuid IS NULL`. `EXPLAIN` on the message
  list confirms an Index Scan on it.
- **Cursor pagination, not OFFSET.** `ChatMessageQueries.getByChannel` paginates
  with `before`/`after` message cursors + `created_at DESC` (keyset). Stays
  O(log n) at any depth. Never reintroduce `OFFSET`-based paging.
- **Partial active-member indexes** (`WHERE left_at IS NULL`) back membership
  checks and WS fan-out; **BRIN** on `created_at` for time ranges; **GIN**
  (`search_vector`) for full-text search; unique constraints stop dup
  reactions/members.
- **Reactions are batch-loaded.** `getByChannel` calls
  `getReactionsForMessages(uuids)` — one `message_uuid IN (…)` query for the
  whole page (was an N+1: one query per message on every poll). Keep it batched.
- **Unread count is bounded.** `ChatChannelQueries.getByUser` caps the unread
  `COUNT(*)` at 100 (`LIMIT 100` subquery). The UI renders `99+`. Don't turn it
  back into an unbounded correlated count.
- **Hot paths don't log.** `ChatMessageQueries.create`/`show` run on every send
  and every WS broadcast — they carry no `NOTICE` logging (only ERR/WARN). Don't
  add debug logging there.
- **WS fan-out is cross-request-safe & bounded.** `chat-ws.lua` enqueues onto
  each connection's Lua queue + posts a semaphore (never touches a foreign
  socket); a stalled client's queue is capped (`MAX_QUEUE`). The client also
  **backs off polling to 25–30s when the socket is live** and drops the socket
  when the tab is backgrounded — so steady-state API load is low.
- **WS delivery spans pods (Redis pub/sub).** Each pod/worker keeps its own
  connection registry. The pod that handles a send (or reaction, or
  `agent:done`) delivers to its own sockets directly, then `PUBLISH`es
  `{origin, recipients, frame}` to `opsapi:chat:<namespace_id>:<channel_uuid>`
  (`opsapi:chat:user:<uuid>` for `push_user`). Every nginx worker runs **one**
  subscriber (`chat-ws.start()`, from `init_worker`) on `PSUBSCRIBE
  opsapi:chat:*`; it enqueues onto its local connections and skips frames it
  published itself, so nothing is delivered twice. The membership query runs
  once per message on the sending pod; subscribers do no DB work. A heartbeat
  every 10 s proves the subscription is alive (35 s of silence → reconnect).
  Uses `helper/redis-client.lua` (`REDIS_ENABLED`/`HOST`/`PORT`/`PASSWORD`/`DB`).
  - **Redis down:** sends still succeed; delivery stays on the sending pod; one
    `[chat-ws] Redis subscriber down` WARN per outage per worker (plus at most one
    `PUBLISH failed` WARN a minute); the subscriber reconnects by itself (backoff
    to 30 s). Events published during the outage are not replayed (pub/sub is
    fire-and-forget) — other pods' users catch up through the 25–30 s poll.
  - **`REDIS_ENABLED=false`:** local-only, exactly as before: no subscriber, no
    publish. Correct only for a single pod with a single worker.
  - **Replicas:** the `diytaxreturn-lapis` chart runs **2** pods in int, acc,
    prod, workstation-test and workstation-acc, with its own Redis
    (`templates/redis.yaml`: password-protected, no persistence, 128 MB LRU).
    It refuses `replicaCount > 1` without `redis.enabled`. `/ready` answers 503
    while a pod's subscriber is down (`CHAT_REQUIRE_REDIS=true`, set by the
    chart), so that pod gets no traffic until it reconnects. dev (in-pod
    migrations) and workstation-int/prod (pinned to one full node, `Recreate`)
    stay at 1 replica.
  - **Proof:** `lapis/spec/chat-pubsub-e2e/run.sh` runs two app processes on one
    Redis (plus a third with `REDIS_ENABLED=false`), a WebSocket client on each:
    a send on one pod reaches the other exactly once, a Redis stop degrades to
    local delivery without failing the send (and `/ready` goes 503), and a Redis
    restart recovers on its own. `lapis/spec/chat-pubsub_spec.lua` guards the invariants in CI.

---

## 2. Deferred scaling moves

These are **infrastructure decisions**, intentionally not pre-applied. Each is
unnecessary at current scale and risky/pointless to do early. Do them when the
trigger fires.

### 2a. Partition (or archive) `chat_messages`

- **Status:** `chat_messages` is a single regular table. `chat_messages_archive`
  exists (created by `migrations/chat-system-production.lua`) but **nothing
  rotates into it yet**.
- **Trigger:** approaching **~100M** rows in `chat_messages`, or when
  vacuum/index-bloat/backup time on that table becomes a problem. Watch
  `pg_stat_user_tables.n_live_tup` and table size.
- **How (pick one):**
  - *Archival job (lower risk):* a scheduled task (cron/RemoteTrigger) that moves
    messages older than N months (and with no live thread refs) into
    `chat_messages_archive`, in batches, off-peak. Keeps the hot table small
    without changing its structure.
  - *Declarative partitioning (bigger, better long-term):* recreate
    `chat_messages` as `PARTITION BY RANGE (created_at)` with monthly partitions,
    migrate rows, then swap. Search still works per-partition; the covering index
    is created per-partition.
- **Risk:** partitioning a live, populated table = create-new + migrate-all +
  swap. Needs a maintenance window or a careful online migration (e.g. dual-write
  + backfill). **Never run this casually against the shared prod DB.** Rehearse
  on a copy; have a rollback.

### 2b. PgBouncer in front of Postgres

- **Trigger:** connection pressure — total connections from all OpenResty workers
  (× replicas) approaching Postgres `max_connections`, or "too many connections"
  errors under load.
- **How:** deploy PgBouncer (transaction pooling) in the Helm chart between the
  app and Postgres; point `POSTGRES_HOST` at it. Deployment/infra change, not a
  code change in this repo.
- **Risk:** transaction-pooling caveats (no session-level features like
  `SET`/advisory locks across statements) — chat's simple query pattern is fine.

### 2c. Cache channel membership on the send path (micro-opt)

- **Status:** each send does a couple of `SELECT user_uuid FROM
  chat_channel_members WHERE channel_uuid=? AND left_at IS NULL` (push-notif + WS
  fan-out). Indexed and cheap.
- **Trigger:** only if profiling shows this dominating at very high write
  throughput. Likely never worth it.
- **How / risk:** a short-TTL cache of channel membership introduces
  cache-invalidation complexity (add/remove member must bust it). Skip unless
  measured.

---

## 3. What to watch

- **DB:** slowest queries (`pg_stat_statements`), `chat_messages` size &
  `n_live_tup`, index bloat, connection count vs `max_connections`.
- **Real-time:** WS connection count per pod, dropped/rejected handshakes
  (`[chat-ws]` in the error log), reconnect rate.
- **Cross-pod delivery:** `[chat-ws] Redis subscriber down` / `PUBLISH failed`
  WARNs; `redis-cli client list | grep -c ' psub=1 '` should equal pods × workers;
  pods NotReady with `"reason": "Chat Redis subscriber not connected"` on `/ready`.
  **A Redis outage longer than the readiness grace (3 × 15 s) takes every pod out
  of rotation** — restore Redis first (`kubectl -n <ns> rollout restart
  deploy/<release>-redis`).
- **App:** p95 latency on `GET /api/chat/channels` (unread fan-out) and
  `GET /api/chat/channels/:uuid/messages` (list).

## 4. Load-bearing invariants (don't break these)

- `getByChannel` stays **cursor-paginated** and **batches reactions**.
- Unread count stays **bounded** (`LIMIT 100`).
- Hot paths (`create`/`show`/broadcast) stay **log-free** (ERR/WARN only).
- WS `broadcast()` only **enqueues** — it never calls `send()` on a foreign
  request's socket. The Redis subscriber obeys the same rule: it enqueues onto
  local queues and posts their semaphores; only each connection's writer sends.
- A Redis failure **never fails a send**: deliver locally first, publish after,
  WARN on failure.
- New per-message work is **O(1) per page**, never O(1) per message (no N+1).
