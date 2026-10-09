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
  checks and WS fan-out; **BRIN** on `created_at` for time ranges; unique
  constraints stop dup reactions/members. *(Correction: this used to say GIN
  serves full-text search. Search (`ChatMessageQueries.search`) is
  `content ILIKE '%term%'` within one channel; nothing queries the two GIN
  indexes, `search_vector` and `to_tsvector(content)`. They only add write cost.
  See §2a "Search".)*
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

- **Status: unbuilt.** `chat_messages_archive` exists (`LIKE chat_messages
  INCLUDING ALL`, from `migrations/chat-system-production.lua` [9]). So does
  `archive_old_messages(days_old)`, but it is not an archival job and **nothing
  calls it**:
  - it moves only `is_deleted = true` rows;
  - it does so in one unbatched `DELETE … RETURNING` (one long transaction, one
    WAL burst);
  - reactions cascade-delete with each moved message;
  - the archive table has **no foreign keys**, so archived rows would outlive
    their workspace.

  Treat archival as not existing.
- **Trigger:** approaching **~100M** rows in `chat_messages`, or when
  vacuum/index-bloat/backup time on that table becomes a problem. **Do not build
  either step before the trigger: it migrates a live table.** Check:
  ```sql
  SELECT n_live_tup, n_dead_tup, last_autovacuum,
         pg_size_pretty(pg_total_relation_size('chat_messages')) AS total_size
  FROM pg_stat_user_tables WHERE relname = 'chat_messages';
  ```

#### Decisions (2026-10-09)

- **Retention.**
  - Messages are kept for the life of the workspace. Deleting a workspace
    already deletes its channels, messages and reactions (FK cascade). Archival
    moves rows out of the hot table; it does not delete them.
  - **Archive age: 12 months**, measured from `created_at`.
  - **A deleted message is purged after 30 days.** Today "delete" only sets
    `is_deleted`; the content stays forever. The purge blanks `content`,
    `attachments` and `metadata`, deletes their objects, and keeps the row as a
    tombstone so threads and reply counts stay intact. This is the privacy half
    of retention, it is cheap, and it doesn't depend on the trigger.
- **Attachments: object storage only, never Postgres blobs.** Already the case:
  the dashboard uploads to MinIO (`/api/v2/documents/upload`, prefix
  `chat-attachments/`), and messages store `file_url` references.
  - Archiving a message leaves its objects alone.
  - The deleted-message purge deletes them.
  - Deleting a workspace should delete its `chat-attachments/` objects. Today
    nothing does, so they are orphaned (a gap to close with the purge).
- **Search covers the hot table only (the last 12 months).**
  - Archived messages aren't searchable in the app; they're reachable by admin
    SQL or an export.
  - Today's search is a per-channel `ILIKE` (no index; cost grows with the
    channel's size).
  - Before archival, switch it to `search_vector @@ websearch_to_tsquery(...)`
    (a generated column, always up to date), and drop the duplicate
    `chat_messages_content_search_idx`. That is a query change: `EXPLAIN
    (ANALYZE, BUFFERS)` before and after, in its own PR.

#### How, when the trigger fires

1. **Archival job (do this first).**
   - **Which rows:** messages older than 12 months that have **no live thread
     references**:
     - they are not the parent of any hot reply;
     - if they are a reply, their parent is archived or archiving in the same
       batch.
   - **Batches:** 10,000 rows, each batch its own transaction. Tried on a
     1M-row sandbox (one batch, rolled back):
     ```sql
     WITH b AS (SELECT id FROM chat_messages m
                WHERE created_at < now() - interval '12 months'
                  AND NOT EXISTS (SELECT 1 FROM chat_messages r WHERE r.parent_message_uuid = m.uuid)
                ORDER BY id LIMIT 10000 FOR UPDATE SKIP LOCKED),
          m AS (DELETE FROM chat_messages USING b WHERE chat_messages.id = b.id
                RETURNING chat_messages.*)
     INSERT INTO chat_messages_archive (id, uuid, channel_uuid, user_uuid, content, content_type,
         parent_message_uuid, mentions, attachments, metadata, is_edited, is_deleted, is_pinned,
         reply_count, edited_at, deleted_at, created_at, updated_at)
     SELECT id, uuid, channel_uuid, user_uuid, content, content_type,
         parent_message_uuid, mentions, attachments, metadata, is_edited, is_deleted, is_pinned,
         reply_count, edited_at, deleted_at, created_at, updated_at
     FROM m ON CONFLICT (uuid) DO NOTHING;
     ```
     - The columns are listed because `search_vector` is a generated column, so
       `SELECT *` fails.
     - The reply check shown is the simple half (no hot replies). Add the
       "parent archived too" half before using it.
   - **Idempotent and resumable:** the data is the progress marker, and a rerun
     just continues.
   - **Single run:** `pg_try_advisory_lock`.
   - **Off-peak:** scheduled (plugin job or k8s CronJob) at night, stopping
     after a time budget.
   - **Before it runs:**
     - move reactions into a `chat_message_reactions_archive` in the same batch
       (the FK cascades);
     - add `chat_messages_archive.channel_uuid → chat_channels ON DELETE
       CASCADE`, so workspace deletion still erases archived history;
     - replace or drop `archive_old_messages()`.
2. **Declarative partitioning, only if (1) is not enough.**
   - Recreate `chat_messages` as `PARTITION BY RANGE (created_at)` with monthly
     partitions.
   - Backfill, then swap names. Dual-write, or a maintenance window, covers the
     gap.
   - The covering index and unique constraints become per partition. The unique
     `uuid` must include `created_at`, or move to a lookup table.
   - **Rehearse on a restored copy and keep a rollback (the old table, renamed
     but kept).** **Never run this casually against the shared prod DB.**

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
