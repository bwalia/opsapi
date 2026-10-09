# Urgency, SLAs, deal health and money at risk

Everything on this page is **deterministic rules**. The AI may explain the numbers in plain English;
it never sets or clears them (SPEC hard rule 5).
Code: `projects/property-deals/property_deals/{sla,health,engine,workdays}.lua`.

## Working days

- A working day is Monday to Friday and not in the workspace's holiday list (`/holidays`). The list
  is seeded with England & Wales bank holidays, topped up weekly from GOV.UK (`holidays_sync`), and
  editable, so any country can use it.
- Times are stored in UTC. Day boundaries use the workspace `timezone` setting (default
  `Europe/London`).
- `working_days: -5` from a target date means five working days earlier. `0` means the date itself,
  or the working day before it when the date falls on a weekend or holiday.
- A deadline set on a *date* falls due at the `due_time` setting (default 17:00 local).

## SLA clock (`sla_tick`, every minute)

A task's clock runs from `sla_started_at` to `due_at`. The clock starts when the task is created, or
when its last prerequisite is done (`depends_on`, `due.from = task_done`). The share used is
`(now − start) / (due − start)`:

| Used | Action (once each) | Recorded | Event |
|---|---|---|---|
| ≥ `sla_warn_pct` (75%) | owner notified "Due soon" | `sla_warned_at`, level 1 | `property_deals.task.sla_warning` |
| ≥ `sla_breach_pct` (100%) | owner + managers notified "Overdue" | `sla_breached_at`, level 2 | `property_deals.task.overdue` |
| ≥ `sla_reassign_pct` (125%) | `escalation_action`: reassign to a manager, or leave unowned in the escalation queue | level 3 | `property_deals.task.escalated` |

- **Managers** are members with the `pd_manager` role. If there are none, the workspace owners are
  used.
- Snoozed tasks (`snoozed_until` in the future, a reason is required) are skipped.
- Each step is claimed with `UPDATE … WHERE flag IS NULL RETURNING`, so it happens once even when
  two workers tick at the same time.
- Notifications go in-app and as push (FCM, or APNs for the native iOS app).

## Deal facts

Recomputed every minute and after every change made through the API.

| Fact | Rule |
|---|---|
| `wd_left` | working days from today to `target_completion_date` |
| open blocking tasks / overdue blocking tasks | open tasks with `blocking = true` (snoozed ones excluded) |
| `open_blockers` | open enquiries with `blocking = true` |
| `silence_hours` | hours since the last third-party reply in the chase log. If there was never a reply, since the first chase; if no chases, since the oldest open enquiry. 0 when there are no open blockers |

### Completion slip forecast

`remaining_wd` = **current stage** + **later critical-path stages** + **silence**:

- **current stage** = `max(expected_working_days − working days since the stage was entered, working days until each open blocking task of this stage is due)`. An overdue task counts as 1 more day.
- **later stages** = the sum of `expected_working_days` of every later stage that applies to the deal and isn't `parallel` or `optional`.
- **silence** = with open blockers and more than 24 hours since the last reply: `+1` working day, plus 1 for each further full day of silence, up to 5.

`predicted_completion_date = today + remaining_wd working days`
`days_late = max(0, predicted − target)` in calendar days.

Stage durations live in the template (`expected_working_days`, `parallel`). The UK seed puts the
critical path as Searches (10) → Enquiries (5) → Exchange (1) → Completion (1). EPC, survey, lease
pack, seller papers, and funds & buyer run in parallel. Measured supplier, solicitor and council
speeds will refine this in Phase 7.

### Money at risk

`money_at_risk = late_penalty_per_day × min(days_late, late_penalty_cap_days)`. The cap is optional
and the penalty may be 0. The deal's `health_reasons` spell it out, for example
"£7000.00 at risk: 14 day(s) late × £500/day (cap 20 days)".

### Health

| Colour | When (any of) |
|---|---|
| **red** | predicted completion is after the target · a blocking task is overdue · fewer than `red_min_working_days` (10) working days are left and there are open blockers or open blocking tasks |
| **amber** | (not red) predicted completion is within 2 working days of the target · a blocking task has passed its warning threshold · 48h+ third-party silence with open enquiries · fewer than 2 × `red_min_working_days` working days are left with open enquiries |
| **green** | otherwise |

Every reason is stored in `health_reasons`. A change of colour emits
`property_deals.deal.health_changed` with the reasons.

## Urgency score (0–100, per open task)

`score = Σ weight × factor`. Each factor is clamped to 0–1. The weights are workspace settings
(`urgency_w_*`) and needn't add up to 100.

| Factor | Default weight | Value |
|---|---|---|
| `time` | 35 | share of the SLA window used ÷ 1.5 (so 150% used, i.e. well overdue, scores full) |
| `completion` | 20 | `1 − wd_left / 20` (20+ working days away = 0) |
| `blocking` | 15 | 1 if the task is on the path to exchange/completion |
| `blockers` | 10 | open blocking enquiries ÷ 5 |
| `silence` | 10 | hours since the last third-party reply ÷ 120 |
| `money` | 10 | money at risk on the deal ÷ `urgency_money_scale` (£5,000) |

`urgency_why` stores every factor as `{ factor, value, points, why }`, sorted by points, for example
`{"factor": "time", "value": 0.889, "points": 31.1, "why": "Overdue (133% of its time used)"}`.
The UI shows these lines on hover. Today and My Tasks sort by `urgency_score`, then by due time.

## Settings (Workspace → Plugins → Property Deals)

`timezone`, `jurisdiction`, `due_time`, `sla_warn_pct`, `sla_breach_pct`, `sla_reassign_pct`,
`escalation_action`, `red_min_working_days`, `expiring_within_days`, `digest_time`, `digest_email`,
`urgency_w_time`, `urgency_w_completion`, `urgency_w_blocking`, `urgency_w_blockers`,
`urgency_w_silence`, `urgency_w_money`, `urgency_money_scale`.
