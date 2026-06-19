# Incident Response Process

> Layer 5. A predictable, low-drama flow from "alert fired" to "postmortem
> filed". Optimised for OpsAPI's small team: roles can be held by one person,
> but the *steps* don't change.

```
  Alert fires (Alertmanager / Gatus / human report)
        │
        ▼
  ┌───────────┐   declare severity (severity-matrix.md)
  │  TRIAGE   │   open the runbook in the alert's runbook_url
  └───────────┘
        │
        ▼
  ┌───────────┐   one person = Incident Commander (IC).
  │ INCIDENT  │   IC coordinates; does NOT necessarily fix.
  │ COMMANDER │   Spin up #inc-<date> channel + (P1/P2) status page entry.
  └───────────┘
        │
        ▼
  ┌───────────┐   follow the runbook: diagnose → mitigate → verify.
  │  MITIGATE │   Prefer fast mitigation (rollback, scale, failover) over
  └───────────┘   slow root-cause fixing. Stop the bleeding first.
        │
        ▼
  ┌───────────┐   confirm SLI recovered on the dashboards; resolve the alert.
  │  RESOLVE  │   Update status page to "resolved".
  └───────────┘
        │
        ▼
  ┌───────────┐   within 48h for P1/P2: blameless postmortem
  │POSTMORTEM │   (postmortem-template.md). Track action items to closure.
  └───────────┘
```

## Roles (collapse as needed on a small team)

- **Incident Commander (IC)** — owns the incident, decides severity, coordinates,
  keeps the timeline. The single source of truth.
- **Ops/Responder** — executes the runbook, applies mitigations.
- **Comms** — updates the status page and stakeholders (IC if nobody else).
- **Scribe** — records the timeline in the incident channel (IC if nobody else).

## During the incident

1. **Acknowledge** the page so others know it's owned.
2. **Open the runbook** linked from the alert (`runbook_url`). Every alert has one.
3. **Communicate early**: a holding update ("investigating elevated errors") beats
   silence. For P1/P2, post to the status page (Gatus) within 15 minutes.
4. **Mitigate before you diagnose**. Roll back the last deploy, scale out, fail
   over, rate-limit — restore the SLI first, understand later.
5. **Watch the dashboards** (Service Overview + SLO/Error Budget) to confirm the
   SLI actually recovers — not just that the alert quieted.

## After the incident

- Resolve the status page entry.
- File a postmortem within 48h for P1/P2 (P3/P4 optional but encouraged).
- Every postmortem produces tracked **action items** with owners and dates.
- Review the error-budget impact: a large burn may trigger the release-freeze
  policy (`../slo/README.md`).

## Tooling

The demo uses a local webhook sink (`make alerts` to view). In production wire
Alertmanager to PagerDuty/Opsgenie/Grafana OnCall and Slack (placeholders in
`../alertmanager/alertmanager.yml`), and Gatus to the same channels.
