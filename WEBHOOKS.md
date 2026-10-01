# Workspace webhooks

Webhooks send your workspace's events to your own URL as they happen. Examples: an invoice is paid, a lead comes in, a task moves. Use them to connect OpsAPI to an ERP, Zapier / Make / n8n, Slack, a data warehouse or your own code. You set them up in the dashboard; no code runs inside OpsAPI. For extending OpsAPI itself with code, see [PLUGINS.md](PLUGINS.md).

## Setting one up

1. Open **Dashboard → Webhooks**. You need the **Webhooks** permission; workspace owners and admins have it by default.
2. **Add webhook**: enter an `https://` URL and pick the events you want.
3. Copy the **signing secret**. It is shown only once; use **Rotate** to get a new one.
4. Click **Send test** (the paper-plane icon) to send a signed `webhook.test` event and see your endpoint's answer.

Each webhook has a **delivery log**: every request, your endpoint's HTTP status, how long it took, retries and errors, plus a **Redeliver** button.

## Events

Every entity has `<entity>.created`, `<entity>.updated` and `<entity>.deleted`. Many also have **business events** that say what happened, such as `invoice.paid` or `crm.deal.won` (listed below). Tick **all** to receive every event of an entity (`<entity>.*`).

| Area | Entities |
|---|---|
| Sales | `customer`, `order`, `invoice`, `invoice.payment` |
| CRM | `crm.account`, `crm.contact`, `crm.deal`, `crm.lead`, `crm.activity` |
| People | `employee`, `timesheet`, `member` (workspace membership) |
| Work | `kanban.project`, `kanban.task`, `fs.job`, `fs.visit` |
| Plugins | Whatever installed plugins publish, e.g. `helpdesk.ticket` |

Business events fire once, when a record *enters* the state. `invoice.paid` fires when an invoice is created as paid or changes to paid from any other status; saving it again doesn't repeat it. The payload is the same as `invoice.updated`, including `changes`.

| Entity | Business events |
|---|---|
| `invoice` | `sent`, `paid`, `partially_paid`, `overdue`, `cancelled` (status cancelled or void) |
| `order` | `confirmed`, `shipped`, `delivered`, `cancelled`, `paid` and `refunded` (financial status) |
| `crm.deal` | `won`, `lost` |
| `crm.lead` | `qualified`, `converted`, `lost` |
| `crm.activity` | `completed` |
| `customer` | `disabled` |
| `employee` | `deactivated` |
| `timesheet` | `submitted`, `approved`, `rejected` |
| `kanban.project` | `completed`, `archived` |
| `kanban.task` | `completed`, `blocked` |
| `fs.job` | `scheduled`, `started` (in progress), `completed`, `cancelled` |
| `fs.visit` | `arrived` (on site), `completed`, `cancelled`, `no_access` |
| `member` | `joined` (became active), `suspended`, `left` |

Plugins can add their own, such as `helpdesk.ticket.closed`.

- Only entities enabled on your server are listed.
- You can only subscribe to data your role can read. For example, invoice events need read access to invoices.
- A webhook only ever receives events from its own workspace.

## The request

```http
POST /your/endpoint HTTP/1.1
Content-Type: application/json
User-Agent: OpsAPI-Webhooks/1
X-Opsapi-Event: invoice.updated
X-Opsapi-Delivery: 81234
X-Opsapi-Timestamp: 1790753496
X-Opsapi-Signature-256: sha256=5f2c…
```

```json
{
  "id": "0b9f6c1e-4b0a-4d5e-9d0f-3f6f2f1a9c11",
  "type": "invoice.updated",
  "created_at": "2026-09-30T07:31:36Z",
  "namespace": { "id": "8140ae50-6606-db53-eed4-9a51e1c16151", "slug": "acme" },
  "data": {
    "object": { "uuid": "…", "invoice_number": "INV-1042", "status": "paid", "total_amount": 120.00, "…": "…" },
    "changes": { "status": { "from": "sent", "to": "paid" }, "paid_at": { "from": null, "to": "2026-09-30T07:31:36" } }
  }
}
```

- `data.object` is the record after the change (before it, for `*.deleted`).
- `data.changes` appears on `*.updated` only and lists just the fields that changed. An update that only touches the timestamp sends no event.
- "Invoice paid" is `invoice.updated` with `changes.status.to == "paid"`.
- `data.object` mirrors OpsAPI's database record, so read it defensively. New fields can appear, and fields can change between OpsAPI versions.

## Verifying requests

Compute an HMAC-SHA256 of `X-Opsapi-Timestamp + "." + raw body` with your secret and compare it to `X-Opsapi-Signature-256` in constant time. Reject timestamps older than 5 minutes to stop replays.

```js
// Node.js (Express: use express.raw({ type: 'application/json' }) so you have the raw body)
const crypto = require('crypto');
function verify(req, rawBody) {
  const ts = req.headers['x-opsapi-timestamp'];
  const expected = 'sha256=' + crypto.createHmac('sha256', process.env.OPSAPI_WEBHOOK_SECRET)
    .update(ts + '.' + rawBody).digest('hex');
  const given = req.headers['x-opsapi-signature-256'] || '';
  return given.length === expected.length
    && crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))
    && Math.abs(Date.now() / 1000 - Number(ts)) < 300;
}
```

```python
# Python
import hmac, hashlib, os, time
def verify(headers, raw_body: str) -> bool:
    ts = headers["X-Opsapi-Timestamp"]
    expected = "sha256=" + hmac.new(os.environ["OPSAPI_WEBHOOK_SECRET"].encode(),
                                    (ts + "." + raw_body).encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, headers.get("X-Opsapi-Signature-256", "")) \
        and abs(time.time() - int(ts)) < 300
```

## Responding, retries and ordering

- **Answer with any 2xx within 10 seconds.** Do slow work after responding (for example, put it on a queue). Connecting has a 3-second limit.
- **Anything else is retried:** non-2xx, timeouts and connection errors. Retries wait 15s, 30s, 1m and so on, up to 1 hour between tries. After 8 attempts the delivery is marked **failed**. Fix your endpoint and press **Redeliver**.
- **At least once, in any order.** A delivery can arrive more than once, and events can arrive out of order. Store the payload's `id` and skip ids you've already handled. Compare timestamps when order matters.
- **Pausing:** a paused webhook receives nothing, and events that happen while it's paused aren't sent later.
- **Log retention:** the log keeps delivered entries for 7 days and failed ones for 30.

## Security

- **Allowed URLs.** URLs must be `https://` and resolve to public internet addresses. OpsAPI refuses private, loopback, link-local (cloud metadata) and cluster-internal destinations, both when you save and on every send.
- **Secrets.** Signing secrets are encrypted at rest and shown only once. Rotating one invalidates the old secret immediately.
- **Limits.** 25 webhooks per workspace and 100 events per webhook.

## API

Everything the dashboard does is also available over the API. Authenticate with a JWT or an API key, add `X-Namespace-Id`, and have the `webhooks` permission.

| Method | Path | |
|---|---|---|
| `GET` | `/api/v2/namespace/webhooks/events` | Events you can subscribe to. |
| `GET` | `/api/v2/namespace/webhooks` | List, with the latest delivery and pending/failed counts. |
| `POST` | `/api/v2/namespace/webhooks` | `{ url, events, description? }` → `{ webhook, secret }`. |
| `GET` / `PUT` / `DELETE` | `/api/v2/namespace/webhooks/:id` | Read, update (`url`, `events`, `description`, `is_active`) or delete. |
| `POST` | `/api/v2/namespace/webhooks/:id/rotate-secret` | → `{ secret }`. |
| `POST` | `/api/v2/namespace/webhooks/:id/test` | Send `webhook.test` now → `{ delivered, response_status, duration_ms, error }`. |
| `GET` | `/api/v2/namespace/webhooks/:id/deliveries` | Delivery log (`?status=done\|pending\|dead&page=`). |
| `POST` | `/api/v2/namespace/webhooks/:id/deliveries/:delivery_id/redeliver` | Send one again. |

## For operators

- Secrets are encrypted with `OPENSSL_SECRET_KEY`, the same key other stored credentials use. It must be set.
- Delivery runs inside every OpsAPI worker, using the plugin event outbox (`helper/plugin-events.lua`). There is no extra service to run.
- `OPSAPI_WEBHOOKS_ALLOW_PRIVATE=true` allows `http://` and private addresses **for local development only**, for example a receiver in docker-compose. Never set it on a shared or internet-facing deployment.
