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
  constraints stop dup reactions/members. **Search** (`ChatMessageQueries.search`)
  runs on the `search_vector` GIN index (`websearch_to_tsquery`, stemmed words).
  *(Correction: search used to be `content ILIKE '%term%'`, which scanned the
  whole channel whenever few messages matched. Neither GIN index was used. The
  duplicate `to_tsvector(content)` index is dropped. See §2a "Search".)*
- **Reactions are batch-loaded.** `getByChannel` calls
  `getReactionsForMessages(uuids)` — one `message_uuid IN (…)` query for the
  whole page (was an N+1: one query per message on every poll). Keep it batched.
- **Unread count is bounded.** `ChatChannelQueries.getByUser` caps the unread
  `COUNT(*)` at 100 (`LIMIT 100` subquery). The UI renders `99+`. Don't turn it
  back into an unbounded correlated count. (The old `get_user_unread_counts()`
  SQL function was dropped: on 1M messages it took 33.7 s against 3.9 ms for
  this query, and it joined messages to mentions, multiplying both counts.)
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
  The kanban board hub (`lib/kanban-ws.lua`) rides the same link through
  `chat-ws.relay()`, without a second subscription.
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
  - **A deleted message is purged after 30 days. Built: `lib/chat-retention.lua`.**
    "Delete" only sets `is_deleted`, so before this the content stayed forever.
    The purge doesn't depend on the trigger. What it does:
    - sets `content` to `'[deleted]'` (the `has_content` check needs some text);
    - clears `attachments`, `mentions` and `metadata`;
    - deletes the edit history. It has to: the edit trigger copies the old text
      into it during the purge itself;
    - deletes the uploaded files.

    The row stays as a tombstone, so threads, reply counts and reactions keep
    working. It runs daily on worker 0 behind an advisory lock: 1,000 messages a
    batch, files deleted after each batch commits, and a rerun picks up where it
    stopped.
- **Attachments: object storage only, never Postgres blobs.** Already the case:
  the dashboard uploads to MinIO (`/api/v2/documents/upload`, prefix
  `chat-attachments/`), and messages store `file_url` references.
  - Archiving a message leaves its objects alone.
  - The deleted-message purge deletes them, **but only an object in the
    author's own `chat-attachments/<author uuid>/` folder**. Attachment URLs are
    written by the client, so a URL pointing elsewhere (another user's file,
    `..`, encoded characters, another prefix) is skipped. Tested against MinIO:
    the author's file and thumbnail went; the other user's file, the `..` URL
    and a non-chat file stayed.
  - Deleting a workspace should delete its `chat-attachments/` objects. Today
    nothing does, so they are orphaned (a gap to close with the purge).
- **Search covers the hot table only (the last 12 months).**
  - Archived messages aren't searchable in the app; they're reachable by admin
    SQL or an export.
  - **Done:** search runs on `search_vector @@ websearch_to_tsquery(...)` (a
    generated column, always current), and the unused
    `chat_messages_content_search_idx` is dropped (`zzchat2`; about 60 MB per
    million messages).
  - It now matches words, not substrings: "meetings" finds "meeting"; "mess"
    no longer finds "message".
  - Measured on 1M messages, in a 20k-message channel:

    | Search | `ILIKE` before | Full-text after |
    |---|---|---|
    | Rare term (1 hit) | 84.2 ms | 4.2 ms |
    | No match | 69.7 ms | 0.17 ms |
    | Common term (10k hits) | 0.7 ms | 0.6 ms |

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
