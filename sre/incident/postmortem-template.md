# Postmortem: <short incident title>

> **Blameless.** We assume everyone acted in good faith with the information they
> had. We fix systems, not people. Copy this file to
> `incident/postmortems/YYYY-MM-DD-<slug>.md` and fill it in.

| Field | Value |
|-------|-------|
| Date | YYYY-MM-DD |
| Severity | P1 / P2 / P3 / P4 |
| Duration | Xh Ym (detection → resolution) |
| Author(s) | |
| Status | Draft / In review / Final |
| Customer impact | e.g. ~X% of requests 5xx for Ym; N tenants affected |
| Error-budget impact | e.g. burned Z% of the 30d availability budget |

## Summary

2–4 sentences: what broke, who it affected, how it was resolved. Readable by
someone outside the team.

## Impact

- User-facing impact (requests failed, features degraded, tenants affected).
- Revenue / SLA / data-integrity impact.
- SLO/error-budget impact (link the SLO dashboard time range).

## Timeline (UTC)

| Time | Event |
|------|-------|
| 00:00 | Trigger / change that set up the failure |
| 00:0X | Alert fired (`<alertname>`) |
| 00:0X | IC declared, severity set |
| 00:1X | Mitigation applied |
| 00:2X | SLI recovered; alert resolved |

## Root cause

The actual underlying cause (use the "5 whys" — don't stop at the proximate
trigger). Distinguish trigger from root cause.

## Detection

- How did we find out? (alert / customer / chance)
- **Time to detect:** how long from impact start to alert firing?
- Could the alert have fired sooner or more precisely?

## Resolution & recovery

- What actually mitigated it.
- **Time to mitigate / recover.**

## What went well / what went poorly / where we got lucky

- Went well:
- Went poorly:
- Got lucky:  *(luck is a future incident waiting to happen — file an action item)*

## Action items

> Every item has an **owner** and a **due date**, and is tracked to closure.
> Prefer items that make the failure *impossible* or *auto-detected*, over
> "be more careful".

| # | Action | Type (prevent/detect/mitigate) | Owner | Due | Tracking |
|---|--------|--------------------------------|-------|-----|----------|
| 1 | | | | | |
| 2 | | | | | |
