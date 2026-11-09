# Shop Analytics

The **Shop → Analytics** page in the dashboard (`/dashboard/shop/analytics`). It reports on sales,
checkout, carts, quotes and the AI advisor for the Workstation shop. Every figure comes from rows
the shop already stores (`shop_orders`, `shop_carts` and `shop_cart_lines`, `shop_quotes`,
`shop_chat_sessions`, `shop_cart_events`, and `shop_memberships` when membership is deployed).
Apart from the survey funnel below, analytics adds no tables, needs no cookies and collects no visitor
data.

**Visitor analytics are off.** Unique and returning visitors, page views, traffic sources and
devices are waiting on a UK privacy and cookie decision. That decision, and who has to sign it off,
is in `workstation-website/shop/docs/ANALYTICS-PRIVACY-SIGNOFF.md`. The API reports
`visitor_tracking: { enabled: false, status: "awaiting_privacy_signoff" }` until then.

## Access

The feature uses a separate RBAC module, `shop_analytics`, with the `read` action. It is separate
from `shop` so that revenue reporting can be given to people who don't edit the catalogue, and kept
from people who only handle fulfilment.

- Migration `zzs33` grants it to the existing **Owner** and **Admin** roles. `requirePermission`
  lets only platform admins bypass RBAC, so without the grant, owners would get a 403.
- New workspaces get it from the `modules` table, in the same way as every other module.
- Members get nothing by default. An owner grants it under Roles.
- The sidebar item (Shop & Orders → Shop Analytics) and the Analytics tab in the shop nav only
  appear for people who have the permission.

## API

| Method | Path | Notes |
|---|---|---|
| GET | `/api/v2/shop/admin/analytics` | `?days=30` or `?from=YYYY-MM-DD&to=YYYY-MM-DD`, `&bucket=day\|week\|month`, `&compare=false` |
| GET | `/api/v2/shop/admin/analytics/survey` | Survey funnel (see below). `?days=30` or `?from=&to=`, `&survey=what-do-i-need` |
| GET | `/api/v2/shop/admin/analytics/export` | `?report=daily\|products\|chat_tools\|survey` plus the same window params. Returns `text/csv` |

Rules for the date window:

- Windows are **UK calendar days** (Europe/London) and include both ends.
- If `to` is in the future, it is moved back to today.
- The maximum window is 731 days.
- Without `compare=false`, the response also includes the previous period of the same length.
- The default bucket is daily for windows up to 92 days, weekly up to 366 days, and monthly beyond
  that.
- Responses are sent with `Cache-Control: private, no-store`.

## Definitions

These definitions are also shown on the page under "How these are measured".

| Metric | Definition |
|---|---|
| Revenue | `total_minor` (inc VAT and shipping) of orders **paid** in the period, by `paid_at`. Includes orders that were later refunded. |
| Refunds | `refunded_minor` on those orders. A full refund recorded only as status `refunded` counts as `total_minor`. Refunds are counted against the order's payment date. |
| Net revenue | Revenue − refunds |
| AOV | Revenue ÷ paid orders |
| New customer | The buyer's (email's) first paid order falls in the period |
| Checkout started | An order created in the period. Repeat attempts on the same cart or quote count once (`sessions` is the raw count). |
| Cart | Created in the period. Carts are created on the first add-to-cart. |
| Abandoned cart | Has items, was never paid for, and hasn't been touched (`last_seen_at`) for 24 hours. `abandonment_rate` = abandoned ÷ (abandoned + paid). Open carts are left out of that rate. |
| Chat | A session created in the period with at least one visitor message |
| AI replied | Has an assistant message that isn't `(no reply)` and isn't only a tools suffix |
| Completed chat | AI replied AND (contact saved via Save chat OR quote OR `add_to_cart` OR order) |
| Chat revenue | Paid orders whose cart the chat was attached to (`shop_chat_sessions.order_id`) |
| Top products | Order line snapshots (`lines` jsonb) of paid orders. Fully refunded orders are left out. |
| Most added to basket | `shop_cart_events`. These rows are kept for 30 days, so for longer windows `basket_adds_complete` is false. |

How tool use is counted: the shop writes a structured `tools` list on each assistant message, plus
a `[tools: …]` suffix on the text that the admin chat view shows. Analytics use the list when it's
present and fall back to the suffix for older transcripts, so a tool is never counted twice.

## Survey funnel ("What do I need?")

The Trade survey at `shop.workstation.co.uk/trade/what-do-i-need` sends first-party funnel events,
stored in `shop_survey_events` (migration `zzs38`, `migrations/shop-survey.lua`).

**What is stored:** the survey slug, a random `visitor_id` the browser makes up, the event, and the
survey's own labels (step, question, answer, product, plan). **Not stored:** IP address, email, name,
user agent or free text. Answers that look like an email address are refused. Rows are deleted after
**13 months** by the daily market-sync job (`ShopInsightsQueries.dailySnapshot`).

> Privacy: how the shop creates and keeps `visitor_id` decides whether this is "visitor tracking"
> under `workstation-website/shop/docs/ANALYTICS-PRIVACY-SIGNOFF.md`. An id held in memory for one
> survey run (no cookie, no `localStorage`) stores nothing on the device. A persistent id needs that
> sign-off first.

### Ingest (public)

`POST /api/v2/public/shop/:namespace/survey-events`, behind the same `public()` wrapper as the other
shop routes (active namespace, `X-Shop-Key` for the BFF). Body: one event, or `{ "events": [...] }`
with 1 to 20 events. Any invalid event rejects the whole request with a 400 (`code` says which
rule); unknown fields are dropped.

| Field | Rule |
|---|---|
| `visitor_id` | required, 8–64 of `A-Z a-z 0-9 _ -` |
| `event` | required: `view`, `start`, `answer`, `back`, `result`, `lead`, `ask`, `apply` |
| `survey` | optional lower-case slug ≤ 48, default `what-do-i-need` |
| `step` | optional whole number 0–100 (JSON number) |
| `question` | text ≤ 120; required on `answer` events |
| `answer` | text ≤ 120, not an email address |
| `product` | key ≤ 32 (`A-Z a-z 0-9 . _ : -`) |
| `plan` | key ≤ 8 (`y` / `m` on `apply`) |

Returns `202 { "success": true, "data": { "accepted": n } }`. Rate limit: 120 requests a minute per
visitor IP, also for BFF calls (the BFF's key skips only the shared `shop_public` limit). The BFF can
name the visitor's IP in `X-Visitor-IP`; otherwise `helper/client-ip.lua` reads `X-Forwarded-For`.
The IP is used for the counter only and is never stored.

### Report

`GET /api/v2/shop/admin/analytics/survey` (module `shop_analytics`, `read`). Every count is
**distinct visitors**.

| Key | Meaning |
|---|---|
| `visitors` | distinct visitors per event type (all eight) |
| `funnel` | view → start → result → lead → apply, with `rate_from_previous` and `rate_from_view` (null, not 0, when there is nothing to divide by) |
| `dropoff` | per step: visitors answering at that step, `lost_from_previous` (the first step is measured against `start`), and visitors per question |
| `answers` | per question, the top 10 answers by visitors, using each visitor's **final** answer (going back and changing it counts once) |
| `results_by_product` | visitors whose result recommended each product |
| `apply_by_plan` | `{ y, m, total }` (and `unknown` when no plan was sent) |
| `trade_signups` | all Trade memberships in the window from `shop_memberships`: `checkouts_started` (created), `joined`, `joined_by_plan { y, m }`. Not linked to survey visitors. `null` when membership is not deployed |
| `complete` | false when the window starts more than 13 months ago (older events are deleted) |

## Performance

Migration `zzs31` adds `(namespace_id, created_at)` indexes on orders, carts, quotes and chat
sessions, and a partial `(namespace_id, paid_at)` index on paid orders. One report runs about 20
indexed, tenant-scoped aggregate queries, and every query filters on `namespace_id`.

## Tests

```bash
luajit lapis/spec/shop-analytics_spec.lua      # CI (lapis-checks): windows, rates, transcript rules,
                                               # every query tenant-scoped with matching placeholders
luajit lapis/spec/shop-survey_spec.lua         # CI: survey event validation, funnel/drop-off maths,
                                               # tenant-scoped queries, route + migration wiring
lapis/spec/shop-analytics-e2e/run.sh           # Docker sandbox: real migrations + Postgres, seeded month,
                                               # hand-worked figures, tenant isolation, 401/403, CSV, menu
```
