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

### 2b. Redis pub/sub for the WebSocket hub

- **Status:** `chat-ws.lua` keeps an **in-process** connection registry. Correct
  for the current deploy (`worker_processes 1`, `replicaCount 1`) — one process
  sees every connection, no Redis needed.
- **Trigger:** the moment chat runs on **2+ pods or workers**. Symptom if you
  scale out without this: users on pod A stop receiving messages sent via pod B
  (each process only knows its own connections).
- **How:** keep everything in `chat-ws.lua`; replace the body of `broadcast()`
  with a Redis `PUBLISH` (channel keyed by tenant/channel), and give each
  connection a Redis `SUBSCRIBE`. The "send only from the owning coroutine" rule
  still holds — the subscriber enqueues onto the connection's queue exactly like
  the local path does today. Redis is already in the stack (`opsapi-redis`).
- **Risk:** low, but adds a runtime dependency on Redis for real-time delivery
  (fallback: the frontend already polls, so a Redis outage degrades to polling,
  it doesn't break chat).

### 2c. PgBouncer in front of Postgres

- **Trigger:** connection pressure — total connections from all OpenResty workers
  (× replicas) approaching Postgres `max_connections`, or "too many connections"
  errors under load.
- **How:** deploy PgBouncer (transaction pooling) in the Helm chart between the
  app and Postgres; point `POSTGRES_HOST` at it. Deployment/infra change, not a
  code change in this repo.
- **Risk:** transaction-pooling caveats (no session-level features like
  `SET`/advisory locks across statements) — chat's simple query pattern is fine.

### 2d. Cache channel membership on the send path (micro-opt)

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
- **App:** p95 latency on `GET /api/chat/channels` (unread fan-out) and
  `GET /api/chat/channels/:uuid/messages` (list).

## 4. Load-bearing invariants (don't break these)

- `getByChannel` stays **cursor-paginated** and **batches reactions**.
- Unread count stays **bounded** (`LIMIT 100`).
- Hot paths (`create`/`show`/broadcast) stay **log-free** (ERR/WARN only).
- WS `broadcast()` only **enqueues** — it never calls `send()` on a foreign
  request's socket.
- New per-message work is **O(1) per page**, never O(1) per message (no N+1).
