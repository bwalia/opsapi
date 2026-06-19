# Runbook: High Payment Failure Rate

**Alert:** `HighPaymentFailureRate` (>10% over 10m) · **Severity:** P1

## Description
More than 10% of payment operations are failing
(`ecommerce_payment_operations_total{status!="success"}`). Directly revenue-impacting.

## Impact
Lost revenue and customer trust on every failed checkout. **P1** — declare an
incident even if the rest of the platform is healthy.

## Diagnosis
1. Grafana → **OpsAPI · Service Overview** / business panels: failure rate by
   status. Spike or steady? Started when?
2. Correlate with deploys and with Stripe status (https://status.stripe.com).
3. Logs/traces: Loki for payment errors; Tempo for the failing checkout span.
   Note OpsAPI's single-merchant Stripe model and webhook de-dup
   (`StripeWebhookEventModel`, `BillingPaymentModel`) — see CLAUDE.md.
4. Common causes: Stripe outage/API change, expired/rotated API keys or webhook
   secret, a regression in the `checkout.session.completed` / `invoice.paid`
   path, webhook delivery failing (signature mismatch), entitlement service error.

## Mitigation
- **Provider outage:** show a clear retry-later message; queue/retry idempotently;
  do not double-charge. Post to the status page.
- **Key/secret issue:** rotate/restore the Stripe key + webhook signing secret in
  the secret store; redeploy.
- **Code regression:** roll back the deploy touching the billing paths.
- **Webhook failures:** verify the endpoint is reachable and signatures validate;
  replay missed events once fixed (de-dup protects against double-processing).

## Verify
Failure rate < 1%; successful test transaction end-to-end; webhooks delivering;
no duplicate charges.

## Escalation
P1: engage the payments/billing owner and finance comms. Reconcile any
mischarges. Postmortem with action items on detection and key management.
