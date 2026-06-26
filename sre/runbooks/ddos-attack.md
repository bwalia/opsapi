# Runbook: DDoS / Abuse / Credential Stuffing

**Alerts:** `PossibleDDoSAttack`, `DistributedDDoSAttack`, `CredentialStuffingAttack`, `HighAuthFailureRate` · **Severity:** P1–P3

## Description
Abnormal request volume from one IP (`PossibleDDoSAttack`), in aggregate
(`DistributedDDoSAttack`), or a spike in auth failures (`CredentialStuffingAttack`,
`HighAuthFailureRate`). See also `DDOS_MITIGATION_GUIDE.md` in the repo root.

## Impact
Service degradation/outage from resource exhaustion (**P1** when distributed), or
account-takeover risk from credential stuffing (**P2**).

## Diagnosis
1. Grafana → **OpsAPI · Golden Signals** (traffic spike) and the security metrics
   (`nginx_http_requests_by_ip_total`, `nginx_http_suspicious_requests_total`,
   `api_auth_failures_total`).
2. Top offending IPs:
   `topk(10, rate(nginx_http_requests_by_ip_total[1m]))` in Prometheus.
3. Legitimate spike vs attack? Check Loki access logs for patterns: single IP,
   one endpoint hammered, login brute force, odd user-agents/paths.

## Mitigation
- **Single IP / small set:** block at the edge (firewall/ingress/WAF) or
  rate-limit. Follow `DDOS_MITIGATION_GUIDE.md`.
- **Distributed:** enable/tighten rate limiting; engage the CDN/WAF (e.g.
  Cloudflare) "under attack" mode; scale out to absorb while filtering.
- **Credential stuffing:** enforce/lower auth rate limits per IP/account; ensure
  lockout + 2FA (OTP) are active (`helper/otp.lua`); consider CAPTCHA on login;
  watch for `api_auth_failures_total{reason="invalid_credentials"}`.
- Preserve evidence (logs) before blocking, for follow-up.

## Verify
Request/auth-failure rates back to baseline; no collateral blocking of real users.

## Escalation
P1 for a live distributed attack — engage security/platform owner and the
CDN/WAF provider. File a postmortem covering detection latency and controls.
