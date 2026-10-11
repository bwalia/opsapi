"""The How It Works scenes as model regression checks (P03, P04, P09).

Used two ways:
  * by the sandbox suite (pa_week2_test.py), with the agent's part played by the test, to prove the checker;
  * by scripts/pa_regression.py against a live OpsAPI + JobShout + private model, before any model or prompt
    change (01-private-endpoint.md: "run the P01–P12 regression set first").

compare_scene3(sheet_rows, now) -> list of problems ([] = pass). `sheet_rows` are the proposals on the confirm
sheet (GET /interactions/:id/capture -> data.proposals).
"""
import datetime

SCENE3_NOTE = ("Spoke to Sarah. Second agent valued it at £240k. She won't go below £235k. Her husband Tom needs to "
               "agree. I reckon £225k might work if we can complete in 4 weeks. Call her tomorrow at 11.")

# (target_table, field) the note must produce, and ones it may produce. Anything else is an invented field.
SCENE3_REQUIRED = {("pa_events", "_create"), ("pa_opportunities", "expectation_price"),
                   ("pa_opportunities", "decision_makers"), ("pa_opportunities", "our_position"),
                   ("next_action", "_create")}
SCENE3_OPTIONAL = {("pa_opportunities", "primary_concern"), ("pa_opportunities", "temperature"),
                   ("pa_opportunities", "last_meaningful_contact_at"), ("pa_opportunities", "motivation")}


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _text(v):
    return v if isinstance(v, str) else str(v)


def compare_scene3(rows, now=None, tz_offset_hours=None):
    """P03: exactly these fields; P09: £225k inferred; P04: next action tomorrow 11:00 with owner and reason."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    problems = []
    got = {}
    for r in rows:
        got.setdefault((r["target_table"], r["field"]), []).append(r)
    keys = set(got)
    for k in sorted(SCENE3_REQUIRED - keys):
        problems.append(f"P03 missing: {k[0]}.{k[1]}")
    for k in sorted(keys - SCENE3_REQUIRED - SCENE3_OPTIONAL):
        problems.append(f"P03 extra (not in the note): {k[0]}.{k[1]}")
    for k, rs in got.items():
        if k[1] != "_create" and len(rs) > 1:
            problems.append(f"P03 duplicate proposals for {k[0]}.{k[1]}")

    def one(k):
        return (got.get(k) or [None])[0]

    ev = one(("pa_events", "_create"))
    if ev:
        nv = ev.get("new_value") or {}
        amount = _num((nv.get("details") or {}).get("amount")) if isinstance(nv.get("details"), dict) else None
        if nv.get("kind") != "valuation":
            problems.append("P03 event: should be a valuation")
        if amount != 240000 and "240" not in _text(nv.get("title")):
            problems.append("P03 event: the second valuation should be £240,000")
        if ev.get("is_inferred"):
            problems.append("P03 event: the valuation was stated, not inferred")
    ep = one(("pa_opportunities", "expectation_price"))
    if ep:
        if _num(ep.get("new_value")) != 235000:
            problems.append(f"P03 seller's minimum should be 235000, got {ep.get('new_value')}")
        if ep.get("is_inferred"):
            problems.append("P03 seller's minimum was stated, not inferred")
        if not ep.get("material"):
            problems.append("P03 the seller's minimum is material")
    dm = one(("pa_opportunities", "decision_makers"))
    if dm:
        names = " ".join(_text(x.get("name", "")) if isinstance(x, dict) else _text(x) for x in (dm.get("new_value") or []))
        if "tom" not in names.lower() or "sarah" not in names.lower():
            problems.append(f"P03 decision makers should be Sarah and Tom, got {names!r}")
    pos = one(("pa_opportunities", "our_position"))
    if pos:
        if not pos.get("is_inferred"):
            problems.append("P09 £225k must be stored as inferred")
        if "225" not in _text(pos.get("new_value")):
            problems.append("P09 our position should mention £225k")
        if "JUDGEMENT, UNCONFIRMED" not in _text(pos.get("kind_label")).upper():
            problems.append("P09 £225k must be labelled judgement, unconfirmed")
    na = one(("next_action", "_create"))
    if na:
        nv = na.get("new_value") or {}
        if not _text(nv.get("reason", "")).strip():
            problems.append("P04 next action needs a reason")
        if not (na.get("owner") or {}).get("user_uuid"):
            problems.append("P04 next action needs an owner")
        try:
            due = datetime.datetime.fromisoformat(_text(nv.get("due_at")).replace("Z", "+00:00"))
            if due.tzinfo is None:
                due = due.replace(tzinfo=datetime.timezone.utc)
            local = due + datetime.timedelta(hours=tz_offset_hours if tz_offset_hours is not None else _london_offset(due))
            tomorrow = (now + datetime.timedelta(hours=_london_offset(now))).date() + datetime.timedelta(days=1)
            if local.date() != tomorrow or local.hour != 11 or local.minute != 0:
                problems.append(f"P04 next action should be tomorrow 11:00 (UK), got {nv.get('due_at')}")
        except ValueError:
            problems.append(f"P04 next action due_at isn't a date-time: {nv.get('due_at')!r}")
    return problems


def _london_offset(dt):
    """UK clock offset from UTC at dt: +1 in BST (last Sunday of March 01:00 UTC to last Sunday of October)."""
    y = dt.year

    def last_sunday(month):
        d = datetime.datetime(y, month + 1, 1, tzinfo=datetime.timezone.utc) - datetime.timedelta(days=1) \
            if month < 12 else datetime.datetime(y, 12, 31, tzinfo=datetime.timezone.utc)
        return d - datetime.timedelta(days=(d.weekday() + 1) % 7)
    start = last_sunday(3).replace(hour=1)
    end = last_sunday(10).replace(hour=1)
    return 1 if start <= dt.astimezone(datetime.timezone.utc) < end else 0
